import hmac
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import wave
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import server

PORT = 8178
RATE = 16000
FORMATS = (".m4a", ".qta")


class Failed(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def run(command):
    return subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, check=False)


def multipart_file(content_type, body):
    """The `file` field's filename and bytes, or None when the body isn't multipart with one."""
    message = BytesParser(policy=policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    if not message.is_multipart():
        return None
    for part in message.iter_parts():
        if part.get_param("name", header="content-disposition") == "file":
            return part.get_filename() or "", part.get_payload(decode=True)
    return None


class Service:
    def __init__(self, config, token, ffmpeg):
        self.config, self.token, self.ffmpeg = config, token, ffmpeg
        self.ffprobe = str(Path(ffmpeg).with_name("ffprobe"))
        self.engine = None
        self.lock = threading.Lock()
        self.in_flight = 0
        self.in_flight_lock = threading.Lock()
        self.last_used = 0.0

    def handle(self, extension, data):
        with tempfile.TemporaryDirectory() as folder:
            upload = os.path.join(folder, "upload" + extension)
            with open(upload, "wb") as file:
                file.write(data)
            index = self.audio_index(upload)
            wav = self.to_wav(upload, index, folder)
            return self.transcribe(wav)

    def audio_index(self, path):
        result = run([self.ffprobe, "-v", "error", "-show_streams", "-of", "json", path])
        if result.returncode:
            raise Failed(422, "ffprobe could not read the upload")
        streams = json.loads(result.stdout).get("streams", [])
        audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
        if not audio:
            raise Failed(415, "the upload has no audio stream")
        # ffprobe names Apple's APAC codec apple_apac, but its tag stays apac.
        usable = [stream for stream in audio if stream.get("codec_tag_string") != "apac"]
        if not usable:
            raise Failed(415, "APAC (spatial Voice Memos audio) is unsupported")
        return usable[0]["index"]

    def to_wav(self, path, index, folder):
        wav = os.path.join(folder, "audio.wav")
        result = run(
            [
                self.ffmpeg,
                "-v",
                "error",
                "-i",
                path,
                "-map",
                f"0:{index}",
                "-ac",
                "1",
                "-ar",
                str(RATE),
                "-c:a",
                "pcm_s16le",
                wav,
            ]
        )
        if result.returncode:
            raise Failed(422, "ffmpeg could not convert the audio")
        return wav

    def load(self):
        try:
            engine = server.Engine(self.config)
            engine.load()
        except Exception as error:
            traceback.print_exc()
            raise Failed(503, f"models failed to load: {error!r}") from error
        self.engine = engine
        if self.config["unloadMinutes"] is not False:
            self.arm(self.config["unloadMinutes"] * 60)

    def arm(self, seconds):
        timer = threading.Timer(seconds, self.expire)
        timer.daemon = True
        timer.start()

    def expire(self):
        with self.in_flight_lock:
            limit = self.config["unloadMinutes"] * 60
            if self.in_flight:
                self.arm(max(limit, 1))  # 0 would spin the timer for as long as the request runs
                return
            idle = time.monotonic() - self.last_used
            if idle < limit:
                self.arm(limit - idle)
                return
            # An in-process unload leaks native memory; only a fresh process gives it back.
            os.closerange(3, os.sysconf("SC_OPEN_MAX"))  # exec keeps MLX's descriptors otherwise
            os.execv(sys.executable, sys.orig_argv)

    def transcribe(self, wav):
        if self.engine is None:
            self.load()
        with wave.open(wav) as audio:
            duration = audio.getnframes() / RATE
        answer = server.attempt(self.engine, lambda: self.engine.process(wav, {}))
        heard = self.engine.heard
        if answer["event"] == "final":
            return 200, {"text": answer["text"], "raw": heard, "duration": duration}
        if heard:
            return 200, {"text": heard, "raw": heard, "duration": duration}
        return 500, {"error": answer["msg"]}


class Handler(BaseHTTPRequestHandler):
    timeout = 60  # a stalled upload would otherwise hold its thread forever

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True, "loaded": self.server.service.engine is not None})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        service = self.server.service
        if self.path != "/transcribe":
            return self.reply(404, {"error": "not found"})
        expected = f"Bearer {service.token}".encode()
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
            challenge = [("WWW-Authenticate", "Bearer")]
            return self.reply(401, {"error": "a bearer token is required"}, challenge)
        with service.in_flight_lock:
            service.in_flight += 1
        try:
            status, reply = self.answer(service)
            self.reply(status, reply)
        finally:
            with service.in_flight_lock:
                service.in_flight -= 1
                service.last_used = time.monotonic()

    def answer(self, service):
        if "Content-Length" not in self.headers:
            return 411, {"error": "send Content-Length"}
        length = self.headers["Content-Length"]
        if not length.isdecimal():
            return 400, {"error": "Content-Length must be a byte count"}
        upload = multipart_file(self.headers.get("Content-Type", ""), self.rfile.read(int(length)))
        if upload is None:
            return 400, {"error": "expected a multipart file field named file"}
        name, data = upload
        extension = os.path.splitext(name)[1].lower()
        if extension not in FORMATS:
            return 415, {"error": "only .m4a and .qta files are supported"}
        with service.lock:
            try:
                return service.handle(extension, data)
            except Failed as failure:
                return failure.status, {"error": failure.message}

    def reply(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)


def make_server(service):
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    httpd.service = service
    return httpd


def main():
    token_path = Path.home() / ".config/dictation/token"
    token = token_path.read_text().strip() if token_path.exists() else ""
    if not token:
        print("dictation service off: no ~/.config/dictation/token", file=sys.stderr)
        return
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    service = Service(json.loads(sys.argv[1]), token, sys.argv[2])
    httpd = make_server(service)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    sys.stdin.read()  # Hammerspoon's end closes stdin; an orphan must not hold the port


if __name__ == "__main__":
    main()
