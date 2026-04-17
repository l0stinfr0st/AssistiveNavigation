#!/usr/bin/env python3
"""
AssistNav RGB UDP receiver.

Receives chunked JPEG frames from the iPhone and displays them live.
"""

import argparse
import socket
import struct
import time
from dataclasses import dataclass, field


MAGIC_CHUNK = b"RCHK"
MAGIC_FRAME = b"ANRG"


def now():
    return time.time()


@dataclass
class PartialFrame:
    total_chunks: int
    created_at: float = field(default_factory=now)
    chunks: dict = field(default_factory=dict)

    def add(self, idx: int, payload: bytes):
        self.chunks[idx] = payload

    def complete(self):
        return len(self.chunks) == self.total_chunks

    def assemble(self):
        return b"".join(self.chunks[i] for i in range(self.total_chunks))


def parse_frame(frame_bytes):
    if len(frame_bytes) < 24 or frame_bytes[:4] != MAGIC_FRAME:
        raise ValueError("bad rgb frame")

    off = 4
    version, reserved = struct.unpack_from("<HH", frame_bytes, off)
    off += 4
    width, height = struct.unpack_from("<HH", frame_bytes, off)
    off += 4
    (timestamp,) = struct.unpack_from("<d", frame_bytes, off)
    off += 8
    (jpeg_n,) = struct.unpack_from("<I", frame_bytes, off)
    off += 4

    jpeg = frame_bytes[off : off + jpeg_n]
    if len(jpeg) != jpeg_n:
        raise ValueError("truncated rgb jpeg")

    return {
        "version": version,
        "reserved": reserved,
        "width": width,
        "height": height,
        "timestamp": timestamp,
        "jpeg": jpeg,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=5051)
    ap.add_argument("--timeout_s", type=float, default=2.0)
    ap.add_argument("--print_every", type=int, default=30)
    args = ap.parse_args()

    try:
        import numpy as np  # type: ignore
        import cv2  # type: ignore
    except Exception:
        print("This receiver needs numpy and opencv-python installed.")
        raise

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(1.0)

    partials = {}
    frame_count = 0

    print(f"Listening RGB UDP on {args.bind}:{args.port}")

    while True:
        t = now()
        for fid in list(partials.keys()):
            if t - partials[fid].created_at > args.timeout_s:
                del partials[fid]

        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue

        if len(data) < 12 or data[:4] != MAGIC_CHUNK:
            continue

        frame_id, total_chunks, idx = struct.unpack_from("<IHH", data, 4)
        payload = data[12:]

        pf = partials.get(frame_id)
        if pf is None:
            pf = PartialFrame(total_chunks=total_chunks)
            partials[frame_id] = pf

        pf.add(idx, payload)
        if not pf.complete():
            continue

        frame_bytes = pf.assemble()
        del partials[frame_id]

        try:
            parsed = parse_frame(frame_bytes)
        except Exception as exc:
            print("RGB parse error:", exc)
            continue

        frame_count += 1
        if frame_count % max(1, args.print_every) == 0:
            print(
                f"frame={frame_count} rgb={parsed['width']}x{parsed['height']} ts={parsed['timestamp']:.3f}"
            )

        buf = np.frombuffer(parsed["jpeg"], dtype=np.uint8)
        frame = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if frame is None:
            continue

        cv2.putText(
            frame,
            f"RGB {parsed['width']}x{parsed['height']}",
            (10, 24),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.7,
            (255, 255, 255),
            2,
        )
        cv2.imshow("AssistNav RGB", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break


if __name__ == "__main__":
    main()
