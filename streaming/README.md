## AssistNav LiDAR UDP Streaming

### iOS app
In the app:
- Settings → **LiDAR streaming**
  - Enable **Stream depth to laptop**
  - Set **Host** to your laptop IP (same Wi‑Fi)
  - Set **Port** (default `5050`)

### Python receiver (laptop)

Run:

```bash
python3 streaming/receive_depth_udp.py --port 5050
```

Optional live preview:

```bash
python3 -m pip install numpy opencv-python
python3 streaming/receive_depth_udp.py --port 5050
```

Notes:
- The receiver listens for UDP packets chunked by the iOS app.
- Depth is Float32 meters (ARKit `sceneDepth.depthMap`), typically low-res (e.g. `256×192`) and may include row stride.
- Confidence (if present) is UInt8 with values 0/1/2.
- Packet v3 includes the per-frame ARKit camera-to-world pose matrix from `ARFrame.camera.transform`.
- RGB is intentionally not captured or streamed; the project is now LiDAR + confidence + pose metadata only.

### Local export inspection

After recording an `.andepth` file in the iPhone app, inspect it with:

```bash
python3 streaming/read_depth_export.py "/path/to/export.andepth"
```

Optional preview frame export:

```bash
python3 -m pip install numpy opencv-python
python3 streaming/read_depth_export.py "/path/to/export.andepth" \
  --export-dir /tmp/depth_frames \
  --video /tmp/depth_preview.mp4
```

Useful flags:
- `--vmin 0.2` and `--vmax 6.0` control grayscale preview range
- `--limit 120` only processes the first 120 frames

### Convert To Notebook Layout

To turn an `.andepth` export into a Record3D-style extracted folder:

```bash
python3 streaming/extract_depth_export.py "/path/to/export.andepth"
```

This writes:
- `depth/*.npy`
- `confidence/*.npy`
- `metadata.json`

`metadata.json` includes `perFrameMetadata`, where each frame has `fx`, `fy`, `cx`, `cy`, and flattened row-major pose values `t00` through `t33`.

If needed, override the inferred camera resolution:

```bash
python3 streaming/extract_depth_export.py "/path/to/export.andepth" \
  --camera-width 960 \
  --camera-height 720
```
