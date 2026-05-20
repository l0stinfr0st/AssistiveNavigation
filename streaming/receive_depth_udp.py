#!/usr/bin/env python3
"""
AssistNav LiDAR UDP receiver.

Listens for chunked UDP frames sent by the iOS app and reconstructs depth,
confidence, and ARKit camera pose metadata.
"""

import argparse
import socket
import struct
import time
from dataclasses import dataclass, field


MAGIC_CHNK = b"CHNK"
MAGIC_FRAME = b"ANDF"


def now() -> float:
    return time.time()


@dataclass
class PartialFrame:
    total_chunks: int
    created_at: float = field(default_factory=now)
    chunks: dict = field(default_factory=dict)

    def add(self, idx: int, payload: bytes) -> None:
        self.chunks[idx] = payload

    def complete(self) -> bool:
        return len(self.chunks) == self.total_chunks

    def assemble(self) -> bytes:
        return b"".join(self.chunks[i] for i in range(self.total_chunks))


def parse_frame(frame_bytes: bytes):
    if len(frame_bytes) < 4:
        raise ValueError("Frame too small")
    if frame_bytes[:4] != MAGIC_FRAME:
        raise ValueError("Bad frame magic")

    off = 4
    (version,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (flags,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (dw, dh, reserved_w, reserved_h) = struct.unpack_from("<HHHH", frame_bytes, off)
    off += 8
    if version >= 2:
        (calw, calh) = struct.unpack_from("<HH", frame_bytes, off)
        off += 4
    else:
        calw, calh = dw, dh
    (ts,) = struct.unpack_from("<d", frame_bytes, off)
    off += 8
    intrinsics = struct.unpack_from("<9f", frame_bytes, off)
    off += 36
    if version >= 3:
        raw_camera_transform = struct.unpack_from("<16f", frame_bytes, off)
        camera_transform = raw_camera_transform if (flags & (1 << 2)) else None
        off += 64
    else:
        camera_transform = None
    (depth_n, conf_n, reserved_n) = struct.unpack_from("<III", frame_bytes, off)
    off += 12

    if len(frame_bytes) < off + depth_n + conf_n + reserved_n:
        raise ValueError("Truncated payload")

    depth_bytes = frame_bytes[off : off + depth_n]
    off += depth_n
    conf_bytes = frame_bytes[off : off + conf_n]

    return {
        "version": version,
        "flags": flags,
        "depth_width": dw,
        "depth_height": dh,
        "reserved_width": reserved_w,
        "reserved_height": reserved_h,
        "calibration_width": calw,
        "calibration_height": calh,
        "timestamp": ts,
        "intrinsics": intrinsics,
        "camera_transform": camera_transform,
        "depth_bytes": depth_bytes,
        "conf_bytes": conf_bytes,
    }


def decode_depth_conf(parsed):
    try:
        import numpy as np  # type: ignore
    except Exception:
        return None, None

    dw = parsed["depth_width"]
    dh = parsed["depth_height"]
    depth_bytes = parsed["depth_bytes"]

    bpr = len(depth_bytes) // max(1, dh)
    stride_w = bpr // 4
    depth = np.frombuffer(depth_bytes, dtype=np.float32).reshape((dh, stride_w))
    depth = depth[:, :dw].copy()

    conf = None
    conf_bytes = parsed["conf_bytes"]
    if conf_bytes:
        cbpr = len(conf_bytes) // max(1, dh)
        conf = np.frombuffer(conf_bytes, dtype=np.uint8).reshape((dh, cbpr))
        conf = conf[:, :dw].copy()

    return depth, conf


def maybe_show(depth, conf, parsed):
    try:
        import numpy as np  # type: ignore
        import cv2  # type: ignore
    except Exception:
        return

    if depth is None:
        return

    d = np.nan_to_num(depth, nan=10.0, posinf=10.0, neginf=10.0)
    vmin = 0.25
    vmax = 5.0
    norm = 1.0 - np.clip((d - vmin) / (vmax - vmin), 0.0, 1.0)
    img = (norm * 255.0).astype(np.uint8)

    if conf is not None:
        img = np.where(conf >= 1, img, 0).astype(np.uint8)

    color = cv2.applyColorMap(img, cv2.COLORMAP_TURBO)
    cv2.putText(
        color,
        f"{parsed['depth_width']}x{parsed['depth_height']} pose={parsed['camera_transform'] is not None}",
        (10, 24),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (255, 255, 255),
        2,
    )
    cv2.imshow("AssistNav Depth", color)
    cv2.waitKey(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0", help="Bind interface")
    ap.add_argument("--port", type=int, default=5050, help="UDP port (must match iOS Settings)")
    ap.add_argument("--timeout_s", type=float, default=2.0, help="Drop incomplete frames after this many seconds")
    ap.add_argument("--print_every", type=int, default=30, help="Log every N complete frames")
    ap.add_argument("--stats_every", type=float, default=2.0, help="Log packet/incomplete-frame stats every N seconds")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(1.0)

    frames = {}
    frame_count = 0
    packet_count = 0
    dropped_partials = 0
    started_at = now()
    last_stats_at = started_at

    print(f"Listening UDP on {args.bind}:{args.port}")

    while True:
        t = now()
        for fid in list(frames.keys()):
            if t - frames[fid].created_at > args.timeout_s:
                dropped_partials += 1
                del frames[fid]

        if t - last_stats_at >= args.stats_every:
            elapsed = max(1e-6, t - started_at)
            print(
                f"stats packets={packet_count} complete_frames={frame_count} "
                f"fps={frame_count / elapsed:.1f} partial_frames={len(frames)} "
                f"dropped_partials={dropped_partials}"
            )
            last_stats_at = t

        try:
            data, _addr = sock.recvfrom(65535)
        except socket.timeout:
            continue

        packet_count += 1
        if len(data) < 12 or data[:4] != MAGIC_CHNK:
            continue

        frame_id, total_chunks, idx = struct.unpack_from("<IHH", data, 4)
        payload = data[12:]

        pf = frames.get(frame_id)
        if pf is None:
            pf = PartialFrame(total_chunks=total_chunks)
            frames[frame_id] = pf

        pf.add(idx, payload)
        if not pf.complete():
            continue

        frame_bytes = pf.assemble()
        del frames[frame_id]

        try:
            parsed = parse_frame(frame_bytes)
        except Exception as exc:
            print("Parse error:", exc)
            continue

        depth, conf = decode_depth_conf(parsed)
        frame_count += 1

        if frame_count % max(1, args.print_every) == 0:
            elapsed = max(1e-6, now() - started_at)
            print(
                f"frame={frame_count} fps={frame_count / elapsed:.1f} "
                f"depth={parsed['depth_width']}x{parsed['depth_height']} "
                f"conf={len(parsed['conf_bytes'])}B "
                f"pose={parsed['camera_transform'] is not None} ts={parsed['timestamp']:.3f}"
            )

        maybe_show(depth, conf, parsed)


if __name__ == "__main__":
    main()
