import argparse
import json
import os
import time
from pathlib import Path
from sync import Outbox


def consume(stream, outbox, project, endpoint, token, batch_size=50):
    frames = []
    next_sync = time.monotonic()
    while True:
        raw = stream.readline(16385)
        if len(raw) > 16384:
            raise ValueError("serial frame exceeds 16 KiB")
        if raw:
            try:
                frame = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(frame, dict):
                continue
            frames.append(frame)
        if len(frames) >= batch_size or (frames and time.monotonic() >= next_sync):
            outbox.enqueue(project, "telemetry.batch", {"frames": frames})
            frames = []
        if time.monotonic() >= next_sync:
            if token:
                outbox.drain(endpoint, token)
            next_sync = time.monotonic() + 10


def main():
    import serial

    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument(
        "--project", default=Path(__file__).resolve().parent.parent.name
    )
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--outbox", default=".local/outbox.sqlite3")
    args = parser.parse_args()
    endpoint = os.getenv(
        "BRUNNODEV_API_URL", "https://vercel-home-telemetry-api.vercel.app/api/runs"
    )
    box = Outbox(args.outbox)
    try:
        with serial.Serial(args.port, args.baud, timeout=1) as port:
            consume(
                port, box, args.project, endpoint, os.getenv("BRUNNODEV_ACCESS_TOKEN")
            )
    finally:
        box.close()


if __name__ == "__main__":
    main()
