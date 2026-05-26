"""
live_depth_receiver.py
----------------------
UDP receiver for AssistNav LiDAR depth frames streamed by the iOS app.

Packet protocol (all little-endian):

  CHNK datagram — one chunk of a larger ANDF frame:
    magic        : 4 bytes  "CHNK"
    frameId      : UInt32   random ID shared across all chunks of one frame
    totalChunks  : UInt16   how many chunks this frame was split into
    chunkIdx     : UInt16   0-based index of this chunk
    payload      : bytes    slice of the ANDF packet

  ANDF packet — reassembled from all CHNK chunks:
    magic            : 4 bytes  "ANDF"
    version          : UInt16   (3)
    flags            : UInt16   bit0=hasConfidence, bit2=hasCameraPose
    depthWidth       : UInt16
    depthHeight      : UInt16
    reservedWidth    : UInt16   (0)
    reservedHeight   : UInt16   (0)
    calibrationWidth : UInt16   RGB resolution used for intrinsics
    calibrationHeight: UInt16
    timestamp        : Float64  seconds
    intrinsics       : 9×Float32  row-major 3×3 camera matrix at calibration res
    cameraTransform  : 16×Float32 row-major 4×4 ARKit camera-to-world
    depthBytes       : UInt32   byte count of depth payload (includes row padding)
    confBytes        : UInt32   byte count of confidence payload (0 if absent)
    reservedBytes    : UInt32   (0)
    <depth>          : depthBytes bytes  Float32 metres, row-stride may include padding
    <confidence>     : confBytes bytes   UInt8 per pixel (0=low,1=med,2=high)
"""

import socket
import struct
import threading
import time
from dataclasses import dataclass
from typing import Optional

import numpy as np

# packet format constants
_ANDF_HDR = struct.Struct("<4sHHHHHHHHd9f16fIII")   # 140 bytes
_CHNK_HDR = struct.Struct("<4sIHH")                  # 12 bytes


@dataclass
class LiveDepthFrame:
    """One decoded depth frame received from the iOS app."""

    depth: np.ndarray                    
    confidence: Optional[np.ndarray]     
    intrinsics: np.ndarray               
    camera_transform: Optional[np.ndarray] 
    timestamp: float                     
    depth_width: int
    depth_height: int
    calibration_width: int               
    calibration_height: int

    def depth_intrinsics(self):
        """Return (fx, fy, cx, cy) at *calibration* resolution."""
        K = self.intrinsics
        return float(K[0, 0]), float(K[1, 1]), float(K[0, 2]), float(K[1, 2])


class LiveDepthReceiver:
    def __init__(
        self,
        bind: str = "0.0.0.0",
        port: int = 5050,
        debug: bool = False,
        max_incomplete_frames: int = 8,
        socket_rcvbuf: int = 4 * 1024 * 1024,
    ):
        self._bind = bind
        self._port = port
        self._debug = debug
        self._max_incomplete = max_incomplete_frames
        self._socket_rcvbuf = socket_rcvbuf

        self._lock = threading.Lock()
        self._latest: Optional[LiveDepthFrame] = None
        self._count: int = 0
        self._running: bool = False
        self._thread: Optional[threading.Thread] = None

        # Chunk reassembly: frameId → {chunkIdx: bytes}
        self._pending: dict = {}
        self._pending_total: dict = {} 

    # public API

    @property
    def latest_frame(self) -> Optional[LiveDepthFrame]:
        with self._lock:
            return self._latest

    @property
    def frame_count(self) -> int:
        with self._lock:
            return self._count

    def start(self) -> None:
        """Start the background receive thread."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._recv_loop, daemon=True, name="LiveDepthReceiver")
        self._thread.start()

    def stop(self) -> None:
        """Stop the receive thread and close the socket."""
        self._running = False
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def wait_for_frame(self, timeout: float = 20.0) -> LiveDepthFrame:
        """
        Block until the first frame arrives and return it.
        Raises TimeoutError if no frame is received within *timeout* seconds.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if self._latest is not None:
                    return self._latest
            time.sleep(0.02)
        raise TimeoutError(
            f"No depth frame received within {timeout}s on {self._bind}:{self._port}. "
            "Check that LiDAR streaming is enabled in the app and the host IP is correct."
        )

    # internal receive loop

    def _recv_loop(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self._socket_rcvbuf)
            sock.settimeout(1.0)
            sock.bind((self._bind, self._port))
        except OSError as e:
            print(f"[LiveDepthReceiver] Failed to bind {self._bind}:{self._port}: {e}")
            return

        try:
            while self._running:
                try:
                    data, _ = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                except OSError:
                    break

                if len(data) < 4:
                    continue

                magic = data[:4]
                if magic == b"CHNK":
                    self._handle_chunk(data)
                elif magic == b"ANDF":
                    # Un-chunked direct send (single-packet frame)
                    frame = _parse_andf(data, self._debug)
                    if frame is not None:
                        self._deliver(frame)
        finally:
            sock.close()

    def _handle_chunk(self, data: bytes) -> None:
        if len(data) < _CHNK_HDR.size:
            return

        _, frame_id, total_chunks, chunk_idx = _CHNK_HDR.unpack_from(data)
        payload = data[_CHNK_HDR.size:]

        if chunk_idx >= total_chunks:
            return
        
        # Evict oldest incomplete frame if buffer is full
        if frame_id not in self._pending and len(self._pending) >= self._max_incomplete:
            oldest = min(self._pending.keys())
            del self._pending[oldest]
            self._pending_total.pop(oldest, None)

        if frame_id not in self._pending:
            self._pending[frame_id] = {}
            self._pending_total[frame_id] = total_chunks

        self._pending[frame_id][chunk_idx] = payload

        if len(self._pending[frame_id]) == total_chunks:
            chunks = self._pending.pop(frame_id)
            self._pending_total.pop(frame_id, None)
            packet = b"".join(chunks[i] for i in range(total_chunks))
            frame = _parse_andf(packet, self._debug)
            if frame is not None:
                self._deliver(frame)

    def _deliver(self, frame: LiveDepthFrame) -> None:
        with self._lock:
            self._latest = frame
            self._count += 1
        if self._debug:
            pose_tag = "pose" if frame.camera_transform is not None else "no-pose"
            conf_tag = "conf" if frame.confidence is not None else "no-conf"
            print(
                f"[Receiver] #{self._count:5d}  "
                f"{frame.depth_width}×{frame.depth_height}  "
                f"cal={frame.calibration_width}×{frame.calibration_height}  "
                f"ts={frame.timestamp:.3f}  {pose_tag}  {conf_tag}"
            )


# ANDF packet parser (module-level so it can be called directly)

def _parse_andf(data: bytes, debug: bool = False) -> Optional[LiveDepthFrame]:
    """
    Parse a complete ANDF payload into a LiveDepthFrame.
    Returns None if the packet is malformed or truncated.
    """
    if len(data) < _ANDF_HDR.size:
        return None

    vals = _ANDF_HDR.unpack_from(data)
    offset = _ANDF_HDR.size

    magic       = vals[0]
    flags       = vals[2]
    dw          = int(vals[3])
    dh          = int(vals[4])
    cal_w       = int(vals[7]) or dw
    cal_h       = int(vals[8]) or dh
    timestamp   = float(vals[9])
    depth_bytes = int(vals[35])
    conf_bytes  = int(vals[36])

    if magic != b"ANDF":
        return None
    if dw <= 0 or dh <= 0:
        return None
    if len(data) - offset < depth_bytes + conf_bytes:
        if debug:
            print(f"[parse_andf] Truncated: need {depth_bytes + conf_bytes}, have {len(data) - offset}")
        return None

    has_confidence = bool(flags & 0x01)
    has_pose       = bool(flags & 0x04)

    # depth
    if dh > 0 and depth_bytes % dh == 0:
        bytes_per_row_d = depth_bytes // dh
    else:
        bytes_per_row_d = dw * 4
        
    stride_d = bytes_per_row_d // 4 

    depth_raw = np.frombuffer(data, dtype="<f4", count=depth_bytes // 4, offset=offset)
    if len(depth_raw) < dh * stride_d:
        return None
    depth_img = depth_raw.reshape(dh, stride_d)[:, :dw].copy().astype(np.float32)
    offset += depth_bytes

    # confidence
    conf_img = None
    if has_confidence and conf_bytes > 0:
        if dh > 0 and conf_bytes % dh == 0:
            bytes_per_row_c = conf_bytes // dh
        else:
            bytes_per_row_c = dw

        conf_raw = np.frombuffer(data, dtype=np.uint8, count=conf_bytes, offset=offset)
        if len(conf_raw) >= dh * bytes_per_row_c:
            conf_img = conf_raw.reshape(dh, bytes_per_row_c)[:, :dw].copy()
    offset += conf_bytes

    # intrinsics

    K = np.array(vals[10:19], dtype=np.float32).reshape(3, 3)

    # camera-to-world transform
    T = None
    if has_pose:
        T = np.array(vals[19:35], dtype=np.float64).reshape(4, 4)

    return LiveDepthFrame(
        depth=depth_img,
        confidence=conf_img,
        intrinsics=K,
        camera_transform=T,
        timestamp=timestamp,
        depth_width=dw,
        depth_height=dh,
        calibration_width=cal_w,
        calibration_height=cal_h,
    )
