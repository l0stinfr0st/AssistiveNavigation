#!/usr/bin/env python3
"""
Read and inspect AssistNav local depth exports (.andepth).

Capabilities:
- prints export/frame metadata
- computes simple validity/confidence statistics
- optionally writes grayscale preview PNG frames
- optionally writes an MP4 preview if OpenCV is installed

Dependencies:
- no dependencies required for metadata/stats
- numpy required for frame decoding/export
- opencv-python required for PNG/video export
"""

import argparse
import math
import struct
from dataclasses import dataclass
from pathlib import Path


MAGIC_EXPORT = b"ANPK"
MAGIC_RECORD = b"FRAM"
MAGIC_FRAME = b"ANDF"


@dataclass
class ParsedFrame:
    version: int
    flags: int
    depth_width: int
    depth_height: int
    rgb_width: int
    rgb_height: int
    calibration_width: int
    calibration_height: int
    timestamp: float
    intrinsics: tuple[float, ...]
    camera_transform: tuple[float, ...] | None
    depth_bytes: bytes
    conf_bytes: bytes
    jpeg_bytes: bytes


def parse_payload(payload: bytes) -> ParsedFrame:
    if payload[:4] != MAGIC_FRAME:
        raise ValueError("bad frame payload magic")

    off = 4
    (version,) = struct.unpack_from("<H", payload, off)
    off += 2
    (flags,) = struct.unpack_from("<H", payload, off)
    off += 2
    (dw, dh, rgbw, rgbh) = struct.unpack_from("<HHHH", payload, off)
    off += 8
    if version >= 2:
        (calw, calh) = struct.unpack_from("<HH", payload, off)
        off += 4
    else:
        calw, calh = dw, dh
    (ts,) = struct.unpack_from("<d", payload, off)
    off += 8
    intrinsics = struct.unpack_from("<9f", payload, off)
    off += 36
    if version >= 3:
        raw_camera_transform = struct.unpack_from("<16f", payload, off)
        camera_transform = raw_camera_transform if (flags & (1 << 2)) else None
        off += 64
    else:
        camera_transform = None
    (depth_n, conf_n, jpeg_n) = struct.unpack_from("<III", payload, off)
    off += 12

    if len(payload) < off + depth_n + conf_n + jpeg_n:
        raise ValueError("truncated payload")

    depth_bytes = payload[off : off + depth_n]
    off += depth_n
    conf_bytes = payload[off : off + conf_n]
    off += conf_n
    jpeg_bytes = payload[off : off + jpeg_n]

    return ParsedFrame(
        version=version,
        flags=flags,
        depth_width=dw,
        depth_height=dh,
        rgb_width=rgbw,
        rgb_height=rgbh,
        calibration_width=calw,
        calibration_height=calh,
        timestamp=ts,
        intrinsics=intrinsics,
        camera_transform=camera_transform,
        depth_bytes=depth_bytes,
        conf_bytes=conf_bytes,
        jpeg_bytes=jpeg_bytes,
    )


def iter_export_frames(path: Path):
    data = path.read_bytes()
    if data[:4] != MAGIC_EXPORT:
        raise SystemExit("Not an AssistNav export file")

    version, reserved = struct.unpack_from("<HH", data, 4)
    yield ("header", {"version": version, "reserved": reserved})

    off = 8
    frame_index = 0

    while off < len(data):
        if data[off : off + 4] != MAGIC_RECORD:
            raise SystemExit(f"Bad record magic at offset {off}")
        off += 4

        (payload_n,) = struct.unpack_from("<I", data, off)
        off += 4
        payload = data[off : off + payload_n]
        off += payload_n

        frame_index += 1
        yield ("frame", frame_index, parse_payload(payload))


def optional_imports():
    np = None
    cv2 = None
    try:
        import numpy as np  # type: ignore
    except Exception:
        np = None

    try:
        import cv2  # type: ignore
    except Exception:
        cv2 = None

    return np, cv2


def decode_depth_conf(frame: ParsedFrame, np):
    depth_bpr = len(frame.depth_bytes) // max(1, frame.depth_height)
    depth_stride = depth_bpr // 4
    depth = np.frombuffer(frame.depth_bytes, dtype=np.float32).reshape((frame.depth_height, depth_stride))
    depth = depth[:, : frame.depth_width].copy()

    conf = None
    if frame.conf_bytes:
        conf_bpr = len(frame.conf_bytes) // max(1, frame.depth_height)
        conf_stride = conf_bpr
        conf = np.frombuffer(frame.conf_bytes, dtype=np.uint8).reshape((frame.depth_height, conf_stride))
        conf = conf[:, : frame.depth_width].copy()

    return depth, conf


def build_preview_image(depth, conf, np, vmin, vmax):
    clipped = np.nan_to_num(depth, nan=vmax, posinf=vmax, neginf=vmax)
    normalized = 1.0 - np.clip((clipped - vmin) / max(1e-6, vmax - vmin), 0.0, 1.0)
    gray = np.power(normalized, 0.9)
    gray = (gray * 255.0).astype(np.uint8)

    if conf is not None:
        gray = np.where(conf > 0, gray, 18).astype(np.uint8)

    return gray


def ensure_output_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--print-every", type=int, default=30)
    parser.add_argument("--vmin", type=float, default=0.20, help="Near clamp in meters")
    parser.add_argument("--vmax", type=float, default=6.0, help="Far clamp in meters")
    parser.add_argument("--export-dir", type=Path, help="Write preview PNG frames here")
    parser.add_argument("--video", type=Path, help="Write preview MP4 here")
    parser.add_argument("--limit", type=int, help="Process only the first N frames")
    args = parser.parse_args()

    np, cv2 = optional_imports()

    if (args.export_dir or args.video) and (np is None or cv2 is None):
        raise SystemExit("PNG/video export needs numpy and opencv-python installed")

    if args.export_dir:
        ensure_output_dir(args.export_dir)

    header = None
    frame_count = 0
    first_ts = None
    last_ts = None
    valid_ratio_sum = 0.0
    confident_ratio_sum = 0.0
    writer = None

    for item in iter_export_frames(args.path):
        if item[0] == "header":
            header = item[1]
            print(f"export version={header['version']} reserved={header['reserved']}")
            continue

        _, frame_index, frame = item
        if args.limit is not None and frame_index > args.limit:
            break

        frame_count += 1
        first_ts = frame.timestamp if first_ts is None else first_ts
        last_ts = frame.timestamp

        depth = None
        conf = None
        if np is not None:
            depth, conf = decode_depth_conf(frame, np)
            valid_mask = np.isfinite(depth) & (depth > 0)
            valid_ratio = float(valid_mask.mean())
            valid_ratio_sum += valid_ratio

            if conf is not None:
                confident_ratio = float((conf > 0).mean())
            else:
                confident_ratio = math.nan
            if not math.isnan(confident_ratio):
                confident_ratio_sum += confident_ratio
        else:
            valid_ratio = math.nan
            confident_ratio = math.nan

        if frame_count % max(1, args.print_every) == 0:
            stats = ""
            if not math.isnan(valid_ratio):
                stats = f" valid={valid_ratio * 100:.1f}%"
            if not math.isnan(confident_ratio):
                stats += f" conf>0={confident_ratio * 100:.1f}%"

            print(
                f"frame={frame_count} depth={frame.depth_width}x{frame.depth_height} "
                f"conf={len(frame.conf_bytes)}B jpeg={len(frame.jpeg_bytes)}B "
                f"pose={frame.camera_transform is not None} ts={frame.timestamp:.3f}{stats}"
            )

        if depth is not None and cv2 is not None and (args.export_dir or args.video):
            preview = build_preview_image(depth, conf, np, args.vmin, args.vmax)

            if args.export_dir:
                out_path = args.export_dir / f"frame_{frame_count:05d}.png"
                cv2.imwrite(str(out_path), preview)

            if args.video:
                if writer is None:
                    fps = 15.0
                    if first_ts is not None and last_ts is not None and frame_count > 1:
                        duration = max(1e-6, last_ts - first_ts)
                        fps = frame_count / duration
                    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                    writer = cv2.VideoWriter(str(args.video), fourcc, fps, (preview.shape[1], preview.shape[0]), False)
                writer.write(preview)

    if writer is not None:
        writer.release()

    duration = 0 if first_ts is None or last_ts is None else max(0.0, last_ts - first_ts)
    fps = 0 if duration == 0 else frame_count / duration
    avg_valid = 0 if frame_count == 0 else valid_ratio_sum / frame_count
    avg_conf = 0 if frame_count == 0 else confident_ratio_sum / frame_count

    print(f"frames={frame_count} duration={duration:.2f}s approx_fps={fps:.2f}")
    if np is not None and frame_count > 0:
        print(f"avg_valid={avg_valid * 100:.1f}% avg_conf_gt0={avg_conf * 100:.1f}%")
    if args.export_dir:
        print(f"wrote_png_frames={args.export_dir}")
    if args.video:
        print(f"wrote_video={args.video}")


if __name__ == "__main__":
    main()
