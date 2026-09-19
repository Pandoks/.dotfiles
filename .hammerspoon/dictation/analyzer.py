"""Stream PCM meters, optionally owning the ffmpeg capture process."""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading


def analyze(stream, rate, bands, fps, size, ready=None):
    import numpy as np

    hop = max(1, int(rate / fps))
    window = np.hanning(size).astype(np.float32)
    edges = np.logspace(np.log10(80), np.log10(rate / 2 * 0.98), bands + 1)
    bins = np.clip((edges / (rate / 2) * (size // 2)).astype(int), 1, size // 2)
    buffer = np.zeros(0, dtype=np.int16)
    peak = np.full(bands, 1e-4, dtype=np.float32)
    while chunk := stream.read(hop * 2):
        if ready is not None:
            ready.set()
            ready = None
        if len(chunk) % 2:
            raise ValueError("incomplete PCM sample")
        buffer = np.concatenate([buffer, np.frombuffer(chunk, dtype=np.int16)])
        if len(buffer) < size:
            continue
        frame = buffer[-size:].astype(np.float32) / 32768.0
        buffer = buffer[-size:]
        rms = float(np.sqrt(np.mean(frame * frame)) + 1e-9)
        level = max(0.0, min(1.0, (20 * np.log10(rms) + 50) / 40))
        spectrum = np.abs(np.fft.rfft(frame * window))
        output = np.array(
            [
                spectrum[bins[index] : max(bins[index] + 1, bins[index + 1])].mean()
                for index in range(bands)
            ],
            dtype=np.float32,
        )
        output = np.sqrt(output)
        peak = np.maximum(peak * 0.999, output)
        values = np.clip(output / (peak + 1e-6), 0, 1)
        print(
            json.dumps(
                {
                    "b": [round(float(value), 3) for value in values],
                    "l": round(level, 3),
                }
            ),
            flush=True,
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rate", type=int, default=16000)
    parser.add_argument("--bands", type=int, default=15)
    parser.add_argument("--fps", type=float, default=30.0)
    parser.add_argument("--fft", type=int, default=1024)
    parser.add_argument("--capture", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if not options.capture:
        analyze(sys.stdin.buffer, options.rate, options.bands, options.fps, options.fft)
        return 0

    # Own the child directly so cancellation cannot leave a microphone process behind.
    with subprocess.Popen(
        options.capture, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE
    ) as capture:
        assert capture.stdout is not None
        ready = threading.Event()
        stopping = False

        def terminate(_signal, _frame):
            capture.kill()

        signal.signal(signal.SIGTERM, terminate)

        def stop():
            nonlocal stopping
            os.read(sys.stdin.fileno(), 1)
            ready.wait()  # Wait for ffmpeg to install its signal handlers.
            stopping = True
            capture.send_signal(signal.SIGINT)

        threading.Thread(target=stop, daemon=True).start()
        try:
            analyze(
                capture.stdout,
                options.rate,
                options.bands,
                options.fps,
                options.fft,
                ready,
            )
        except (BrokenPipeError, ValueError):
            capture.kill()
            raise
        finally:
            ready.set()
        status = capture.wait()
        return 0 if stopping and status == 255 else status


if __name__ == "__main__":
    sys.exit(main())
