#!/usr/bin/env python3
"""
AssistNav LiDAR UDP receiver.

Listens for chunked UDP frames sent by the iOS app and reconstructs depth/confidence
and optional RGB JPEG.

No hard dependencies. If you have numpy installed, it will decode depth into arrays.
If you also have opencv-python, it will show a live preview window.
"""

import argparse
import os
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
    chunks: dict = field(default_factory=dict)  # idx -> bytes

    def add(self, idx: int, payload: bytes) -> None:
        self.chunks[idx] = payload

    def complete(self) -> bool:
        return len(self.chunks) == self.total_chunks

    def assemble(self) -> bytes:
        return b"".join(self.chunks[i] for i in range(self.total_chunks))


def parse_frame(frame_bytes: bytes):
    """
    Returns dict with parsed metadata and raw payload slices.
    Packet format documented in iOS: AssistNav/Main/DepthStreaming.swift
    """
    if len(frame_bytes) < 4:
        raise ValueError("Frame too small")
    if frame_bytes[:4] != MAGIC_FRAME:
        raise ValueError("Bad frame magic")

    off = 4
    (version,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (flags,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (dw, dh, rgbw, rgbh) = struct.unpack_from("<HHHH", frame_bytes, off)
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
    (depth_n, conf_n, jpeg_n) = struct.unpack_from("<III", frame_bytes, off)
    off += 12

    if len(frame_bytes) < off + depth_n + conf_n + jpeg_n:
        raise ValueError("Truncated payload")

    depth_bytes = frame_bytes[off : off + depth_n]
    off += depth_n
    conf_bytes = frame_bytes[off : off + conf_n]
    off += conf_n
    jpeg_bytes = frame_bytes[off : off + jpeg_n]

    return {
        "version": version,
        "flags": flags,
        "depth_width": dw,
        "depth_height": dh,
        "rgb_width": rgbw,
        "rgb_height": rgbh,
        "calibration_width": calw,
        "calibration_height": calh,
        "timestamp": ts,
        "intrinsics": intrinsics,  # row-major 3x3
        "depth_bytes": depth_bytes,
        "conf_bytes": conf_bytes,
        "jpeg_bytes": jpeg_bytes,
    }


def decode_depth_conf(parsed):
    """
    Attempts to decode into numpy arrays if available.
    Handles row-stride (bytesPerRow) because iOS sends bytesPerRow*height.
    """
    try:
        import numpy as np  # type: ignore
    except Exception:
        return None, None

    dw = parsed["depth_width"]
    dh = parsed["depth_height"]
    depth_bytes = parsed["depth_bytes"]

    bpr = len(depth_bytes) // max(1, dh)
    stride_w = bpr // 4  # Float32
    depth = np.frombuffer(depth_bytes, dtype=np.float32).reshape((dh, stride_w))
    depth = depth[:, :dw].copy()

    conf = None
    conf_bytes = parsed["conf_bytes"]
    if conf_bytes:
        cbpr = len(conf_bytes) // max(1, dh)
        cstride_w = cbpr  # uint8
        conf = np.frombuffer(conf_bytes, dtype=np.uint8).reshape((dh, cstride_w))
        conf = conf[:, :dw].copy()

    return depth, conf


def decode_rgb_jpeg(parsed):
    jpeg_bytes = parsed["jpeg_bytes"]
    if not jpeg_bytes:
        return None

    try:
        import numpy as np  # type: ignore
        import cv2  # type: ignore
    except Exception:
        return None

    buf = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    rgb = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return rgb


def maybe_show(depth, conf, rgb, parsed):
    try:
        import numpy as np  # type: ignore
        import cv2  # type: ignore
    except Exception:
        return

    # Visualize depth (meters) with a clamp similar to the app.
    d = depth
    if d is None:
        return
    # Replace NaNs/Infs.
    d = np.nan_to_num(d, nan=10.0, posinf=10.0, neginf=10.0)
    vmin = 0.25
    vmax = 5.0
    norm = 1.0 - np.clip((d - vmin) / (vmax - vmin), 0.0, 1.0)
    img = (norm * 255.0).astype(np.uint8)

    # Mask low confidence (0) if present.
    if conf is not None:
        img = np.where(conf >= 1, img, 0).astype(np.uint8)

    color = cv2.applyColorMap(img, cv2.COLORMAP_TURBO)
    cv2.putText(
        color,
        f"{parsed['depth_width']}x{parsed['depth_height']}  rgb={bool(parsed['jpeg_bytes'])}",
        (10, 24),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (255, 255, 255),
        2,
    )
    cv2.imshow("AssistNav Depth", color)

    if rgb is not None:
        rgb_preview = rgb.copy()
        cv2.putText(
            rgb_preview,
            f"RGB {parsed['rgb_width']}x{parsed['rgb_height']}",
            (10, 24),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.7,
            (255, 255, 255),
            2,
        )
        cv2.imshow("AssistNav RGB", rgb_preview)

    cv2.waitKey(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0", help="Bind interface")
    ap.add_argument("--port", type=int, default=5050, help="UDP port (must match iOS Settings)")
    ap.add_argument("--timeout_s", type=float, default=2.0, help="Drop incomplete frames after this many seconds")
    ap.add_argument("--print_every", type=int, default=30, help="Log every N frames")
    ap.add_argument("--save_rgb_dir", default=None, help="Optional directory to save incoming RGB JPEGs")
    ap.add_argument("--save_every", type=int, default=30, help="Save every Nth RGB frame when --save_rgb_dir is set")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(1.0)

    frames = {}  # frameId -> PartialFrame
    frame_count = 0

    if args.save_rgb_dir:
        os.makedirs(args.save_rgb_dir, exist_ok=True)

    print(f"Listening UDP on {args.bind}:{args.port}")

    while True:
        # Cleanup old partial frames
        t = now()
        for fid in list(frames.keys()):
            if t - frames[fid].created_at > args.timeout_s:
                del frames[fid]

        try:
            data, _addr = sock.recvfrom(65535)
        except socket.timeout:
            continue

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
        except Exception as e:
            print("Parse error:", e)
            continue

        depth, conf = decode_depth_conf(parsed)
        rgb = decode_rgb_jpeg(parsed)
        frame_count += 1

        if frame_count % max(1, args.print_every) == 0:
            print(
                f"frame={frame_count} depth={parsed['depth_width']}x{parsed['depth_height']} "
                f"rgb={'yes' if parsed['jpeg_bytes'] else 'no'} "
                f"rgb_size={parsed['rgb_width']}x{parsed['rgb_height']} ts={parsed['timestamp']:.3f}"
            )

        if args.save_rgb_dir and rgb is not None and frame_count % max(1, args.save_every) == 0:
            try:
                import cv2  # type: ignore
                out_path = os.path.join(args.save_rgb_dir, f"rgb_{frame_count:06d}.jpg")
                cv2.imwrite(out_path, rgb)
            except Exception:
                pass

        maybe_show(depth, conf, rgb, parsed)


if __name__ == "__main__":
    main()
