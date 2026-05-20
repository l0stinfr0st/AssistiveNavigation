# Assistive Navigation

The full depth-processing and notebook workflow runs on Python. The mobile app is an iOS Swift app that captures LiDAR depth with ARKit, detects floor planes, and sends or exports the data for Python analysis.

## What It Does

Assistive Navigation is an iPhone app for testing accessible navigation ideas with LiDAR depth, location, hazard reports, and spoken feedback.

Main features:

- ARKit LiDAR depth capture with camera pose metadata
- Horizontal plane detection for floor-aware depth filtering
- Live depth preview inside the app
- Optional UDP depth streaming to a laptop
- Local `.andepth` recording and export
- Python tools for receiving, inspecting, previewing, and extracting depth data
- Supabase-backed sign-in, hazard reports, report history, and navigation sessions
- Map and report views for nearby hazards

RGB capture was removed on purpose. The current pipeline uses LiDAR depth, confidence, ARKit pose, and plane detection only.

## Requirements

### iPhone App

- macOS with Xcode 16 or newer
- iPhone or iPad with LiDAR support
- Camera and location permissions enabled
- Supabase project, if using auth/reports/history

### Python Tools

- Python 3.10 or newer
- `numpy`
- `opencv-python` for live preview, PNG export, and video export
- `matplotlib` for `streaming/play_depth.py`

Install the Python dependencies:

```bash
python -m pip install numpy opencv-python matplotlib
```

## iOS Setup

1. Open the project in Xcode:

```bash
open AssistNav.xcodeproj
```

2. Create your local Supabase config:

```bash
cp AssistNav/SupabaseConfig.example.plist AssistNav/SupabaseConfig.plist
```

3. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` inside `AssistNav/SupabaseConfig.plist`.

4. In Supabase, run the SQL in:

```text
supabase/schema.sql
```

5. Build and run the app on a LiDAR-capable device.

`AssistNav/SupabaseConfig.plist` is ignored by git so real keys are not committed.

## Live Depth Streaming

Start the Python UDP receiver on your laptop:

```bash
python streaming/receive_depth_udp.py --port 5050
```

Then in the app:

1. Open Settings.
2. Enable `Stream depth to laptop`.
3. Set `Host` to your laptop IP address on the same Wi-Fi.
4. Set `Port` to `5050`, or whatever port you used above.
5. Open the LiDAR depth test or start navigation.

The receiver reconstructs chunked UDP frames and prints frame stats. If `numpy` and `opencv-python` are installed, it also shows a live depth preview.

For notebook-style live access, use:

```python
from streaming.live_depth_receiver import LiveDepthReceiver

receiver = LiveDepthReceiver(port=5050)
receiver.start()
frame = receiver.wait_for_frame()
depth = frame.depth
metadata = frame.notebook_metadata()
```

## Local Depth Exports

The app can record local `.andepth` files. After exporting one to your laptop, inspect it with:

```bash
python streaming/read_depth_export.py path/to/export.andepth
```

Write preview PNG frames or a video:

```bash
python streaming/read_depth_export.py path/to/export.andepth --export-dir depth_preview --video depth_preview.mp4
```

Convert an `.andepth` file into the notebook-friendly folder layout:

```bash
python streaming/extract_depth_export.py path/to/export.andepth
```

This creates:

```text
depth/*.npy
confidence/*.npy
metadata.json
```

Preview extracted depth frames:

```bash
python streaming/play_depth.py path/to/export_extracted/depth
```

## Project Layout

```text
AssistNav/        iOS app source
streaming/        Python receiver, export, and preview tools
supabase/         Database schema
HRIR Profiles/    Audio spatialization profile assets
system.ipynb      Main notebook workflow
```

## Notes

- Use a real LiDAR device. The simulator will not provide ARKit scene depth.
- Keep the phone and laptop on the same network for UDP streaming.
- Firewall rules may block UDP port `5050`; allow Python if frames do not arrive.
- `system.ipynb` is the main analysis notebook and expects extracted depth data or live receiver data.
