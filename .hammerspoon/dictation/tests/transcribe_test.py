import contextlib
import http.client
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server
import transcribe

TOKEN = "test-token"
BOUNDARY = "dictation"
MULTIPART = f"multipart/form-data; boundary={BOUNDARY}"
FFMPEG = shutil.which("ffmpeg")
CONFIG = {
    "speech": {"backend": "parakeet-mlx", "model": "stub", "revision": "0" * 40},
    "cleanup": False,
    "words": {"Ghostty": ["ghost tea"], "Hammerspoon": ["hammer spoon"]},
    "unloadMinutes": False,
}


def refuse(messages, raw, between):
    raise server.Rejected("the cleanup returned no words")


# Only the models are stood in; the rest of Engine runs as shipped.
class Stand(server.Engine):
    loads = peak = active = 0
    seen: ClassVar[list] = []
    says = "ghost tea and hammer spoon"
    delay = 0.0
    fail_load = fail_speech = refuse_cleanup = False
    speaking = threading.Event()
    counter = threading.Lock()

    def load(self):
        if Stand.fail_load:
            raise RuntimeError("no GPU")
        Stand.loads += 1
        self.speech = SimpleNamespace(transcribe=self.transcribe, stream=lambda hint: None, boost=0)
        if Stand.refuse_cleanup:
            self.cleaner = SimpleNamespace(prompt="prompt", complete=refuse)

    def transcribe(self, wav, hint):
        with Stand.counter:
            Stand.active += 1
            Stand.peak = max(Stand.peak, Stand.active)
        try:
            with wave.open(wav) as audio:
                Stand.seen.append(audio.getparams()[:3] + (audio.getnframes(),))
            Stand.speaking.set()
            time.sleep(Stand.delay)
            if Stand.fail_speech:
                raise RuntimeError("boom")
            return Stand.says
        finally:
            with Stand.counter:
                Stand.active -= 1


def reset():
    Stand.loads, Stand.peak, Stand.active, Stand.seen = 0, 0, 0, []
    Stand.says, Stand.delay = "ghost tea and hammer spoon", 0.0
    Stand.fail_load = Stand.fail_speech = Stand.refuse_cleanup = False
    Stand.speaking.clear()


@contextlib.contextmanager
def running(config=CONFIG, ffmpeg=FFMPEG):
    with mock.patch.object(transcribe, "PORT", 0):
        httpd = transcribe.make_server(transcribe.Service(config, TOKEN, ffmpeg))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        with mock.patch.object(server, "Engine", Stand):
            yield httpd.server_address[1]
    finally:
        httpd.shutdown()
        httpd.server_close()


def call(port, method, path, body=None, headers=None, timeout=60):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    reply = json.loads(response.read())
    connection.close()
    return response.status, dict(response.getheaders()), reply


def upload_body(name, data, field="file"):
    return (
        (
            f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="{field}"; filename="{name}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode()
        + data
        + f"\r\n--{BOUNDARY}--\r\n".encode()
    )


def post(port, name, data, token=TOKEN, field="file", timeout=60):
    headers = {"Content-Type": MULTIPART}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    body = upload_body(name, data, field)
    return call(port, "POST", "/transcribe", body, headers, timeout=timeout)


def loaded(port):
    return call(port, "GET", "/health")[2]["loaded"]


def health(port):
    try:
        return call(port, "GET", "/health")[2]
    except (OSError, http.client.HTTPException):
        return None


def wait_for(process, check):
    deadline = time.monotonic() + 15
    while not check():
        assert process.poll() is None, process.stderr.read().decode()
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.1)


def fake_ffprobe(folder, streams):  # the ffprobe JSON boundary, beside the real ffmpeg
    directory = Path(tempfile.mkdtemp(dir=folder))
    (directory / "ffmpeg").symlink_to(FFMPEG)
    (directory / "streams.json").write_text(json.dumps({"streams": streams}))
    probe = directory / "ffprobe"
    probe.write_text('#!/bin/sh\ncat "$(dirname "$0")/streams.json"\n')
    probe.chmod(0o755)
    return str(directory / "ffmpeg")


def token_home(home, contents):
    if contents is not None:
        (home / ".config/dictation").mkdir(parents=True)
        (home / ".config/dictation/token").write_text(contents)
    return {**os.environ, "HOME": str(home)}


def audio(folder, name):
    return (folder / name).read_bytes()


def test_health(folder):
    with running() as port:
        status, _, reply = call(port, "GET", "/health")
    assert status == 200 and reply == {"ok": True, "loaded": False}, reply


def test_binds_loopback_only(folder):
    with mock.patch.object(transcribe, "PORT", 0):
        httpd = transcribe.make_server(transcribe.Service(CONFIG, TOKEN, FFMPEG))
    httpd.server_close()
    assert httpd.server_address[0] == "127.0.0.1", httpd.server_address


def test_transcribe_needs_the_token(folder):
    with running() as port:
        for token in (None, "wrong"):
            status, headers, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"), token)
            assert status == 401 and headers["WWW-Authenticate"] == "Bearer", (status, headers)
            assert "error" in reply, reply
        assert Stand.loads == 0


def test_auth_is_checked_before_the_body_is_read(folder):
    with running() as port:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.putrequest("POST", "/transcribe")
        connection.putheader("Content-Length", "1000000")
        connection.endheaders()
        status = connection.getresponse().status
        connection.close()
    assert status == 401, status


def test_unknown_paths_and_malformed_uploads(folder):
    data = audio(folder, "memo.m4a")
    with running() as port:
        for method in ("GET", "POST"):
            status, _, reply = call(port, method, "/nope")
            assert status == 404, (method, reply)
        status, _, reply = post(port, "memo.m4a", data, field="other")
        assert status == 400 and "file" in reply["error"], reply
        status, _, reply = call(
            port,
            "POST",
            "/transcribe",
            b"x",
            {"Authorization": f"Bearer {TOKEN}", "Content-Type": "text/plain"},
        )
        assert status == 400, reply


def test_upload_without_content_length_is_411(folder):
    with running() as port:
        status, _, reply = call(
            port,
            "POST",
            "/transcribe",
            None,
            {"Authorization": f"Bearer {TOKEN}", "Transfer-Encoding": "chunked"},
        )
    assert status == 411 and reply == {"error": "send Content-Length"}, reply


def test_bad_content_length_is_400(folder):
    with running() as port:
        for length in ("abc", "-1"):
            status, _, reply = call(
                port,
                "POST",
                "/transcribe",
                None,
                {"Authorization": f"Bearer {TOKEN}", "Content-Length": length},
                timeout=5,
            )
            assert status == 400 and "Content-Length" in reply["error"], (length, reply)


def test_other_extensions_are_415_and_load_nothing(folder):
    data = audio(folder, "memo.m4a")
    with running() as port:
        for name in ("memo.wav", "memo.mp3", "memo"):
            status, _, reply = post(port, name, data)
            assert status == 415, (name, reply)
        assert Stand.loads == 0


def test_undecodable_upload_is_422(folder):
    with running() as port:
        status, _, reply = post(port, "memo.m4a", b"not audio at all")
    assert status == 422 and "ffprobe" in reply["error"], reply


def test_ffmpeg_failure_is_422(folder):
    stream = {"index": 7, "codec_type": "audio", "codec_name": "aac", "codec_tag_string": "mp4a"}
    ffmpeg = fake_ffprobe(folder, [stream])  # no stream 7 in the file, so ffmpeg's map fails
    with running(ffmpeg=ffmpeg) as port:
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
    assert status == 422 and "ffmpeg" in reply["error"], reply


def test_apac_only_is_415(folder):
    with running() as port:
        status, _, reply = post(port, "apac.m4a", audio(folder, "apac.m4a"))
    assert status == 415 and "APAC" in reply["error"], reply
    assert Stand.loads == 0


def test_no_audio_stream_is_415(folder):
    ffmpeg = fake_ffprobe(folder, [{"index": 0, "codec_type": "video", "codec_name": "h264"}])
    with running(ffmpeg=ffmpeg) as port:
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
    assert status == 415 and "no audio" in reply["error"], reply


def test_aac_m4a_and_qta_become_16khz_mono_wav(folder):
    with running() as port:
        for name, source in (
            ("memo.m4a", "memo.m4a"),
            ("memo.qta", "memo.qta"),
            ("memo.QTA", "memo.qta"),
        ):
            Stand.seen.clear()
            status, _, reply = post(port, name, audio(folder, source))
            assert status == 200, (name, reply)
            [(channels, width, rate, frames)] = Stand.seen
            assert (channels, width, rate) == (1, 2, 16000), (name, Stand.seen)
            assert frames > 16000, (name, frames)
            expected = {
                "text": "Ghostty and Hammerspoon",
                "raw": "ghost tea and hammer spoon",
                "duration": frames / 16000,
            }
            assert reply == expected, (name, reply)


def test_two_track_qta_transcribes_its_aac_track(folder):
    with running() as port:
        status, _, aac = post(port, "aac.m4a", audio(folder, "aac.m4a"))
        assert status == 200, aac
        status, _, two = post(port, "two.qta", audio(folder, "two.qta"))
    assert status == 200 and abs(two["duration"] - aac["duration"]) < 0.05, (two, aac)


def test_heard_is_typed_when_cleanup_fails(folder):
    Stand.refuse_cleanup = True
    with running() as port:
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
    assert status == 200, reply
    assert reply["text"] == reply["raw"] == "ghost tea and hammer spoon", reply


def test_error_without_heard_is_500(folder):
    Stand.fail_speech = True
    with running() as port, contextlib.redirect_stderr(io.StringIO()):
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
    assert status == 500 and reply == {"error": "boom"}, reply


def test_load_failure_is_503(folder):
    Stand.fail_load = True
    with running() as port, contextlib.redirect_stderr(io.StringIO()):
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
        assert status == 503 and "no GPU" in reply["error"], reply
        assert loaded(port) is False


def test_one_transcription_at_a_time(folder):
    Stand.delay = 0.3
    data = audio(folder, "memo.m4a")
    results = []

    def worker(port):
        results.append(post(port, "memo.m4a", data)[0])

    with running() as port:
        threads = [threading.Thread(target=worker, args=(port,)) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    assert sorted(results) == [200, 200], results
    assert Stand.peak == 1, Stand.peak
    assert Stand.loads == 1, Stand.loads


def test_stalled_upload_does_not_block_another(folder):
    body = upload_body("memo.m4a", audio(folder, "memo.m4a"))
    with running() as port:
        stalled = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        stalled.putrequest("POST", "/transcribe")
        stalled.putheader("Authorization", f"Bearer {TOKEN}")
        stalled.putheader("Content-Type", MULTIPART)
        stalled.putheader("Content-Length", str(len(body)))
        stalled.endheaders(body[:100])
        time.sleep(0.5)  # the stalled upload reaches the server first
        try:
            status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"), timeout=5)
        finally:
            stalled.close()
    assert status == 200, reply


def test_temporary_files_are_removed(folder):
    scratch = folder / "scratch"
    scratch.mkdir()
    with running() as port, mock.patch.object(tempfile, "tempdir", str(scratch)):
        status, _, _ = post(port, "memo.m4a", b"not audio at all")
        assert status == 422, status
        status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
        assert status == 200, reply
    assert list(scratch.iterdir()) == []


def test_models_stay_loaded_during_a_take(folder):
    Stand.delay = 2.5
    data = audio(folder, "memo.m4a")
    results = []
    unloaded = threading.Event()
    with (
        running(dict(CONFIG, unloadMinutes=1 / 60)) as port,
        mock.patch.object(transcribe.os, "execv") as execv,
        mock.patch.object(transcribe.os, "closerange"),
    ):
        execv.side_effect = lambda *_: unloaded.set()
        thread = threading.Thread(target=lambda: results.append(post(port, "memo.m4a", data)))
        thread.start()
        assert Stand.speaking.wait(15), "the take never reached the speech model"
        time.sleep(1.5)  # past the idle limit, while the take still runs
        assert loaded(port) is True and not execv.called, "unloaded during a take"
        thread.join()
        assert results[0][0] == 200, results
        assert loaded(port) is True and not execv.called, "unloaded as soon as the take ended"
        assert unloaded.wait(15), "the idle models never unloaded"


def test_upload_in_flight_is_not_unloaded(folder):
    data = audio(folder, "memo.m4a")
    body = upload_body("memo.m4a", data)
    unloaded = threading.Event()
    with (
        running(dict(CONFIG, unloadMinutes=1 / 60)) as port,
        mock.patch.object(transcribe.os, "execv") as execv,
        mock.patch.object(transcribe.os, "closerange"),
    ):
        execv.side_effect = lambda *_: unloaded.set()
        status, _, reply = post(port, "memo.m4a", data)
        assert status == 200, reply
        upload = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        upload.putrequest("POST", "/transcribe")
        upload.putheader("Authorization", f"Bearer {TOKEN}")
        upload.putheader("Content-Type", MULTIPART)
        upload.putheader("Content-Length", str(len(body)))
        upload.endheaders(body[:100])
        time.sleep(2.5)  # past the idle limit, while the upload is still arriving
        assert not execv.called, "unloaded during an upload"
        upload.send(body[100:])
        response = upload.getresponse()
        answered = time.monotonic()
        reply = json.loads(response.read())
        upload.close()
        assert response.status == 200 and not execv.called, reply
        assert unloaded.wait(15), "the idle models never unloaded"
        assert time.monotonic() - answered > 1, "idle time counted from before the reply"


def test_service_exits_when_stdin_closes(folder):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    launch = (
        f"import sys; sys.path.insert(0, {str(Path(__file__).parent)!r}); "
        "import server, transcribe, transcribe_test; "
        f"server.Engine = transcribe_test.Stand; transcribe.PORT = {port}; transcribe.main()"
    )
    config = dict(CONFIG, unloadMinutes=1 / 60)
    with tempfile.TemporaryDirectory() as home:
        env = token_home(Path(home), TOKEN + "\n")
        process = subprocess.Popen(
            [sys.executable, "-B", "-c", launch, json.dumps(config), FFMPEG],
            cwd=Path(transcribe.__file__).parent,
            env=env,
            stdin=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            wait_for(process, lambda: health(port) is not None)
            assert health(port) == {"ok": True, "loaded": False}, health(port)
            started = time.monotonic()
            status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
            assert status == 200 and loaded(port) is True, reply
            wait_for(process, lambda: health(port) == {"ok": True, "loaded": False})
            assert time.monotonic() - started > 1, "unloaded before its idle time"
            assert process.poll() is None, "the unload ended the process"
            status, _, reply = post(port, "memo.m4a", audio(folder, "memo.m4a"))
            assert status == 200, reply
            process.stdin.close()
            assert process.wait(timeout=15) == 0
            assert health(port) is None, "the port is still open after exit"
        finally:
            process.kill()


def test_missing_or_empty_token_exits_zero(folder):
    for contents in (None, "  \n"):
        with tempfile.TemporaryDirectory() as home:
            env = token_home(Path(home), contents)
            result = subprocess.run(
                [sys.executable, transcribe.__file__, json.dumps(CONFIG), FFMPEG],
                env=env,
                input=b"",
                capture_output=True,
                timeout=30,
                check=False,
            )
        message = b"dictation service off: no ~/.config/dictation/token"
        assert result.returncode == 0 and message in result.stderr, (contents, result)


def main():
    assert FFMPEG, "ffmpeg must be on PATH"
    tests = [
        test_health,
        test_binds_loopback_only,
        test_transcribe_needs_the_token,
        test_auth_is_checked_before_the_body_is_read,
        test_unknown_paths_and_malformed_uploads,
        test_upload_without_content_length_is_411,
        test_bad_content_length_is_400,
        test_other_extensions_are_415_and_load_nothing,
        test_undecodable_upload_is_422,
        test_ffmpeg_failure_is_422,
        test_apac_only_is_415,
        test_no_audio_stream_is_415,
        test_aac_m4a_and_qta_become_16khz_mono_wav,
        test_two_track_qta_transcribes_its_aac_track,
        test_heard_is_typed_when_cleanup_fails,
        test_error_without_heard_is_500,
        test_load_failure_is_503,
        test_one_transcription_at_a_time,
        test_stalled_upload_does_not_block_another,
        test_temporary_files_are_removed,
        test_models_stay_loaded_during_a_take,
        test_upload_in_flight_is_not_unloaded,
        test_service_exits_when_stdin_closes,
        test_missing_or_empty_token_exits_zero,
    ]
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        subprocess.run(
            ["say", "-o", str(folder / "memo.aiff"), "ghost tea and hammer spoon"], check=True
        )
        for name, extra in (("memo.m4a", []), ("memo.qta", ["-f", "mov"])):
            command = [FFMPEG, "-v", "error", "-i", str(folder / "memo.aiff"), "-c:a", "aac"]
            subprocess.run([*command, *extra, str(folder / name)], check=True)
        subprocess.run(
            [
                FFMPEG,
                "-v",
                "error",
                "-i",
                folder / "memo.aiff",
                "-t",
                "1",
                "-c:a",
                "aac",
                "-f",
                "ipod",
                folder / "aac.m4a",
            ],
            check=True,
        )
        subprocess.run(
            ["afconvert", "-f", "mp4f", "-d", "apac", folder / "memo.aiff", folder / "apac.m4a"],
            check=True,
        )
        subprocess.run(
            [
                FFMPEG,
                "-v",
                "error",
                "-i",
                folder / "apac.m4a",
                "-i",
                folder / "aac.m4a",
                "-map",
                "0:a",
                "-map",
                "1:a",
                "-c",
                "copy",
                "-f",
                "mov",
                folder / "two.qta",
            ],
            check=True,
        )
        for test in tests:
            reset()
            test(folder)
            print(f"PASS {test.__name__}")


if __name__ == "__main__":
    main()
