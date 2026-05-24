#!/usr/bin/env python3
"""
Convert an AssistNav .andepth export into a notebook-friendly extracted folder.

Output layout:
  extracted/
    depth/00000.npy
    confidence/00000.npy
    metadata.json

The metadata stores session-level camera calibration once, then per-frame
timestamp and pose. Depth/confidence samples remain as separate .npy files.
"""

import argparse
import json
import math
import shutil
import struct
from pathlib import Path


MAGIC_EXPORT = b"ANPK"
MAGIC_RECORD = b"FRAM"
MAGIC_FRAME = b"ANDF"


def optional_imports():
    np = None
    try:
        import numpy as np  # type: ignore
    except Exception:
        np = None
    return np


def parse_payload(payload: bytes):
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

    depth_bytes = payload[off : off + depth_n]
    off += depth_n
    conf_bytes = payload[off : off + conf_n]
    off += conf_n
    jpeg_bytes = payload[off : off + jpeg_n]

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
        "intrinsics": intrinsics,
        "camera_transform": camera_transform,
        "depth_bytes": depth_bytes,
        "conf_bytes": conf_bytes,
        "jpeg_bytes": jpeg_bytes,
    }


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


def decode_depth(parsed, np):
    dh = parsed["depth_height"]
    dw = parsed["depth_width"]
    depth_bpr = len(parsed["depth_bytes"]) // max(1, dh)
    depth_stride = depth_bpr // 4
    depth = np.frombuffer(parsed["depth_bytes"], dtype=np.float32).reshape((dh, depth_stride))
    return depth[:, :dw].copy()


def decode_confidence(parsed, np):
    if not parsed["conf_bytes"]:
        return None

    dh = parsed["depth_height"]
    dw = parsed["depth_width"]
    conf_bpr = len(parsed["conf_bytes"]) // max(1, dh)
    conf_stride = conf_bpr
    conf = np.frombuffer(parsed["conf_bytes"], dtype=np.uint8).reshape((dh, conf_stride))
    return conf[:, :dw].copy()


def infer_camera_resolution(intrinsics, depth_width, depth_height):
    # Record3D-style metadata stores intrinsics at the camera resolution, then
    # the notebook scales them down to depth resolution using dw/w and dh/h.
    #
    # Our current export does not yet persist camera image resolution, so infer
    # it from the optical center: cx ~= w/2 and cy ~= h/2.
    cx = intrinsics["cx"]
    cy = intrinsics["cy"]

    inferred_w = int(round(cx * 2.0))
    inferred_h = int(round(cy * 2.0))

    # Clamp to a sane 4:3-ish fallback if inference looks broken.
    if inferred_w <= depth_width or inferred_h <= depth_height:
        inferred_w = 960
        inferred_h = 720

    return inferred_w, inferred_h


def frame_metadata(timestamp, camera_transform):
    return {
        "timestamp": timestamp,
        "pose": None if camera_transform is None else [float(v) for v in camera_transform],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument(
        "--out",
        type=Path,
        help="Output extracted folder. Defaults next to the export file.",
    )
    parser.add_argument("--print-every", type=int, default=100)
    parser.add_argument("--camera-width", type=int, help="Override inferred camera width")
    parser.add_argument("--camera-height", type=int, help="Override inferred camera height")
    args = parser.parse_args()

    np = optional_imports()
    if np is None:
        raise SystemExit("This converter needs numpy installed")

    export_path = args.path
    out_dir = args.out or export_path.with_name(f"{export_path.stem}_extracted")
    depth_dir = out_dir / "depth"
    conf_dir = out_dir / "confidence"
    depth_dir.mkdir(parents=True, exist_ok=True)
    conf_dir.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(out_dir / "rgb", ignore_errors=True)

    header = None
    frame_count = 0
    camera_intrinsics = None
    frames_metadata = []
    timestamps = []
    depth_width = None
    depth_height = None
    calibration_width = 0
    calibration_height = 0
    has_confidence = False

    for item in iter_export_frames(export_path):
        if item[0] == "header":
            header = item[1]
            continue

        _, frame_index, parsed = item
        frame_count += 1

        depth = decode_depth(parsed, np)
        conf = decode_confidence(parsed, np)

        np.save(depth_dir / f"{frame_index - 1:05d}.npy", depth)
        if conf is not None:
            has_confidence = True
            np.save(conf_dir / f"{frame_index - 1:05d}.npy", conf)

        K = parsed["intrinsics"]
        fx = float(K[0])
        fy = float(K[4])
        if parsed["version"] >= 3:
            cx = float(K[2])
            cy = float(K[5])
        else:
            # Older app builds accidentally serialized simd matrices column-major.
            cx = float(K[6])
            cy = float(K[7])
        if camera_intrinsics is None:
            camera_intrinsics = {
                "fx": fx,
                "fy": fy,
                "cx": cx,
                "cy": cy,
            }
        frames_metadata.append(frame_metadata(parsed["timestamp"], parsed["camera_transform"]))
        timestamps.append(parsed["timestamp"])

        depth_width = parsed["depth_width"]
        depth_height = parsed["depth_height"]
        calibration_width = parsed["calibration_width"]
        calibration_height = parsed["calibration_height"]

        if frame_count % max(1, args.print_every) == 0:
            print(f"extracted frame {frame_count}")

    if frame_count == 0 or depth_width is None or depth_height is None:
        raise SystemExit("No frames found")

    if args.camera_width and args.camera_height:
        camera_width = args.camera_width
        camera_height = args.camera_height
    elif calibration_width > 0 and calibration_height > 0:
        camera_width = calibration_width
        camera_height = calibration_height
    else:
        camera_width, camera_height = infer_camera_resolution(camera_intrinsics, depth_width, depth_height)

    duration = max(0.0, timestamps[-1] - timestamps[0]) if len(timestamps) > 1 else 0.0
    fps = 0.0 if duration == 0 else frame_count / duration

    metadata = {
        "format": "assistnav-extracted-v2",
        "sourceExport": str(export_path),
        "exportVersion": header["version"] if header else 1,
        "frameCount": frame_count,
        "fps": fps,
        "depth": {
            "width": depth_width,
            "height": depth_height,
            "dir": "depth",
            "dtype": "float32",
            "units": "meters",
        },
        "confidence": {
            "present": has_confidence,
            "dir": "confidence",
            "dtype": "uint8",
            "values": "0/1/2 ARKit confidence when present",
        },
        "camera": {
            "width": camera_width,
            "height": camera_height,
            "intrinsics": camera_intrinsics,
        },
        "frames": frames_metadata,
        "poseFormat": "row-major 4x4 ARKit camera-to-world transform; null for pre-v3 exports",
        "worldCoordinateSystem": "ARKit gravity-aligned right-handed world coordinates",
        "hasRGB": False,
        "notes": {
            "cameraResolutionWasInferred": not (args.camera_width and args.camera_height),
            "calibrationResolutionFromExport": calibration_width > 0 and calibration_height > 0,
            "inferenceHint": "Override with --camera-width/--camera-height if you know the exact capture resolution.",
            "compatibility": "v1 metadata duplicated timestamps, intrinsics, and pose; v2 stores intrinsics once and one frame row per timestamp/pose.",
        },
    }

    (out_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print(f"wrote_extracted={out_dir}")
    print(f"frames={frame_count} depth={depth_width}x{depth_height} approx_fps={fps:.2f}")
    print(f"metadata={out_dir / 'metadata.json'}")


if __name__ == "__main__":
    main()
