#!/usr/bin/env python3
"""
Notebook-friendly live UDP receiver for AssistNav LiDAR depth frames.
"""

from __future__ import annotations

import socket
import struct
import threading
import time
from dataclasses import dataclass, field


MAGIC_CHNK = b"CHNK"
MAGIC_FRAME = b"ANDF"


def _now() -> float:
    return time.time()


@dataclass
class PartialFrame:
    total_chunks: int
    created_at: float = field(default_factory=_now)
    chunks: dict[int, bytes] = field(default_factory=dict)

    def add(self, idx: int, payload: bytes) -> None:
        self.chunks[idx] = payload

    def complete(self) -> bool:
        return len(self.chunks) == self.total_chunks

    def assemble(self) -> bytes:
        return b"".join(self.chunks[i] for i in range(self.total_chunks))


@dataclass
class LiveDepthFrame:
    depth: "np.ndarray"
    confidence: "np.ndarray | None"
    timestamp: float
    intrinsics: tuple[float, ...]
    camera_transform: tuple[float, ...] | None
    depth_width: int
    depth_height: int
    calibration_width: int
    calibration_height: int

    def depth_intrinsics(self) -> tuple[float, float, float, float]:
        return (
            float(self.intrinsics[0]),
            float(self.intrinsics[4]),
            float(self.intrinsics[2]),
            float(self.intrinsics[5]),
        )

    def notebook_metadata(self) -> dict:
        fx, fy, cx, cy = self.depth_intrinsics()
        frame_metadata = {
            "timestamp": self.timestamp,
            "fx": fx,
            "fy": fy,
            "cx": cx,
            "cy": cy,
        }
        if self.camera_transform is not None:
            for index, value in enumerate(self.camera_transform):
                row = index // 4
                column = index % 4
                frame_metadata[f"t{row}{column}"] = float(value)

        return {
            "perFrameIntrinsicCoeffs": [[fx, fy, cx, cy]],
            "perFrameMetadata": [frame_metadata],
            "dw": self.depth_width,
            "dh": self.depth_height,
            "w": self.calibration_width,
            "h": self.calibration_height,
            "timestamps": [self.timestamp],
        }


def parse_frame(frame_bytes: bytes) -> dict:
    if len(frame_bytes) < 4 or frame_bytes[:4] != MAGIC_FRAME:
        raise ValueError("Bad frame")

    off = 4
    (version,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (flags,) = struct.unpack_from("<H", frame_bytes, off)
    off += 2
    (dw, dh, _reserved_w, _reserved_h) = struct.unpack_from("<HHHH", frame_bytes, off)
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
    (depth_n, conf_n, _reserved_n) = struct.unpack_from("<III", frame_bytes, off)
    off += 12

    if len(frame_bytes) < off + depth_n + conf_n:
        raise ValueError("Truncated payload")

    depth_bytes = frame_bytes[off : off + depth_n]
    off += depth_n
    conf_bytes = frame_bytes[off : off + conf_n]

    return {
        "depth_width": dw,
        "depth_height": dh,
        "calibration_width": calw,
        "calibration_height": calh,
        "timestamp": ts,
        "intrinsics": intrinsics,
        "camera_transform": camera_transform,
        "depth_bytes": depth_bytes,
        "conf_bytes": conf_bytes,
    }


def decode_depth_conf(parsed: dict):
    import numpy as np  # type: ignore

    dw = parsed["depth_width"]
    dh = parsed["depth_height"]
    depth_bytes = parsed["depth_bytes"]

    depth_bpr = len(depth_bytes) // max(1, dh)
    depth_stride = depth_bpr // 4
    depth = np.frombuffer(depth_bytes, dtype=np.float32).reshape((dh, depth_stride))
    depth = depth[:, :dw].copy()

    conf = None
    conf_bytes = parsed["conf_bytes"]
    if conf_bytes:
        conf_bpr = len(conf_bytes) // max(1, dh)
        conf = np.frombuffer(conf_bytes, dtype=np.uint8).reshape((dh, conf_bpr))
        conf = conf[:, :dw].copy()

    return depth, conf


class LiveDepthReceiver:
    def __init__(self, bind: str = "0.0.0.0", port: int = 5050, timeout_s: float = 2.0, debug: bool = False):
        self.bind = bind
        self.port = port
        self.timeout_s = timeout_s
        self.debug = debug

        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._frame_event = threading.Event()
        self._lock = threading.Lock()

        self._frames: dict[int, PartialFrame] = {}
        self._latest_frame: LiveDepthFrame | None = None
        self._frame_count = 0
        self._packet_count = 0
        self._dropped_partials = 0
        self._last_error: str | None = None

    @property
    def latest_frame(self) -> LiveDepthFrame | None:
        with self._lock:
            return self._latest_frame

    @property
    def frame_count(self) -> int:
        with self._lock:
            return self._frame_count

    @property
    def packet_count(self) -> int:
        with self._lock:
            return self._packet_count

    @property
    def dropped_partials(self) -> int:
        with self._lock:
            return self._dropped_partials

    @property
    def last_error(self) -> str | None:
        with self._lock:
            return self._last_error

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return

        self._stop.clear()
        self._frame_event.clear()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((self.bind, self.port))
        self._sock.settimeout(1.0)
        if self.debug:
            print(f"LiveDepthReceiver listening UDP on {self.bind}:{self.port}")

        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=1.5)

    def wait_for_frame(self, timeout: float = 5.0) -> LiveDepthFrame:
        got_one = self._frame_event.wait(timeout)
        if not got_one:
            raise TimeoutError("Timed out waiting for a live depth frame")

        frame = self.latest_frame
        if frame is None:
            raise TimeoutError("Frame event fired but no frame was stored")
        return frame

    def get_camera_data(self) -> tuple[float, float, float, float]:
        frame = self.latest_frame
        if frame is None:
            raise RuntimeError("No live frame available yet")
        return frame.depth_intrinsics()

    def get_notebook_metadata(self) -> dict:
        frame = self.latest_frame
        if frame is None:
            raise RuntimeError("No live frame available yet")
        return frame.notebook_metadata()

    def _run(self) -> None:
        while not self._stop.is_set():
            self._cleanup_old_frames()

            try:
                assert self._sock is not None
                data, _ = self._sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break

            if len(data) < 12 or data[:4] != MAGIC_CHNK:
                continue

            with self._lock:
                self._packet_count += 1

            frame_id, total_chunks, idx = struct.unpack_from("<IHH", data, 4)
            payload = data[12:]

            pf = self._frames.get(frame_id)
            if pf is None:
                pf = PartialFrame(total_chunks=total_chunks)
                self._frames[frame_id] = pf

            pf.add(idx, payload)
            if not pf.complete():
                continue

            frame_bytes = pf.assemble()
            del self._frames[frame_id]

            try:
                parsed = parse_frame(frame_bytes)
                depth, conf = decode_depth_conf(parsed)
            except Exception as exc:
                with self._lock:
                    self._last_error = repr(exc)
                if self.debug:
                    print("decode error:", repr(exc))
                continue

            live_frame = LiveDepthFrame(
                depth=depth,
                confidence=conf,
                timestamp=parsed["timestamp"],
                intrinsics=tuple(parsed["intrinsics"]),
                camera_transform=parsed["camera_transform"],
                depth_width=parsed["depth_width"],
                depth_height=parsed["depth_height"],
                calibration_width=parsed["calibration_width"],
                calibration_height=parsed["calibration_height"],
            )

            with self._lock:
                self._latest_frame = live_frame
                self._frame_count += 1
                self._last_error = None

            self._frame_event.set()

    def _cleanup_old_frames(self) -> None:
        t = _now()
        for fid in list(self._frames.keys()):
            if t - self._frames[fid].created_at > self.timeout_s:
                del self._frames[fid]
                with self._lock:
                    self._dropped_partials += 1
