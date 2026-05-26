# Assistive Navigation

Assistive Navigation is a LiDAR-to-spatial-audio navigation prototype. The main system lives in `system.ipynb`: it takes iPhone LiDAR depth frames, converts nearby structure into spatialized audio sweeps, detects and tracks hazards, and combines both into a semi-real-time assistive navigation loop.

The iOS app is the capture and field-testing companion. It records or streams ARKit LiDAR depth, confidence, camera intrinsics, camera pose, and floor-filtered depth frames so the notebook pipeline can process real or recorded environments.

## Notebook Pipeline

`system.ipynb` is organized as a top-to-bottom prototype:

1. **Load LiDAR recordings**
   - Reads extracted `.npy` depth frames and `metadata.json`.
   - Uses camera intrinsics and pose metadata exported from the iOS app.
   - Provides depth colormap checks before later processing.

2. **Verify HRTF spatial audio**
   - Loads SOFA HRIR/HRTF data.
   - Builds a KDTree for nearest-direction lookup.
   - Generates spatialized pings with pink noise, bandpass filtering, and HRTF convolution.

3. **Convert depth into sweep sonification**
   - Maps image pixels to azimuth/elevation using camera intrinsics.
   - Scans selected depth columns for nearest valid obstacle samples.
   - Applies elevation filtering so the floor does not dominate the scan.
   - Builds left-to-right and right-to-left stereo HRTF sweeps.

4. **Simulate semi-real-time depth sonification**
   - Runs a video loop and an audio loop concurrently.
   - The video loop advances through depth frames.
   - The audio loop continuously builds and crossfades sweeps from the current frame.

5. **Detect and track hazards**
   - Builds a forward-facing hazard mask from depth and viewing-angle limits.
   - Groups depth pixels with Numba-accelerated depth-aware connected clustering.
   - Extracts cluster centroids in image and camera coordinates.
   - Uses camera pose to compare objects in world coordinates.
   - Matches clusters with Hungarian association and smooths tracks with Kalman filters.
   - Classifies tracked objects as static, moving, or temporarily unreliable during camera pan.

6. **Add moving-object audio cues**
   - Keeps the continuous spatial sweep for scene structure.
   - Adds short HRTF-spatialized click cues for moving objects.
   - Increases click rate as a moving object gets closer.

7. **Run the combined navigation system**
   - `run_full_navigation_system` combines the sweep, hazard detection, tracking, visualization, and moving-object click cues on recorded depth.
   - `run_live_navigation_system` runs the same design on live UDP frames from the iOS app.

RGB capture was removed on purpose. The current pipeline uses LiDAR depth, confidence, camera intrinsics, ARKit camera-to-world pose, and plane-aware depth filtering.

## Data Flow

```text
iPhone ARKit LiDAR
  -> .andepth export or UDP stream
  -> Python extraction / LiveDepthReceiver
  -> system.ipynb
  -> depth sweep sonification + hazard tracking + spatial warning cues
```

For recorded runs:

```text
.andepth
  -> streaming/extract_depth_export.py
  -> depth/*.npy + confidence/*.npy + metadata.json
  -> system.ipynb sections 2-9
```

For live runs:

```text
iOS UDP streaming
  -> streaming/live_depth_receiver.py
  -> system.ipynb section 10
```

## Requirements

### Notebook

- Python 3.10 or newer
- `numpy`
- `scipy`
- `opencv-python`
- `matplotlib`
- `sounddevice`
- `sofar`
- `filterpy`
- `numba` recommended for real-time clustering performance
- Headphones for HRTF/spatial-audio testing

Install the main notebook dependencies:

```bash
python -m pip install numpy scipy opencv-python matplotlib sounddevice sofar filterpy numba
```

### iOS Capture App

- macOS with Xcode 16 or newer
- iPhone or iPad with LiDAR support
- Camera, local network, and location permissions enabled
- Supabase project, if using auth, reports, or navigation sessions

## Running The Notebook

1. Export or stream LiDAR data from the iOS app.
2. For recorded exports, convert the `.andepth` file:

```bash
python streaming/extract_depth_export.py path/to/export.andepth
```

3. In `system.ipynb`, update the input paths in section 2:

```python
DEPTH_DIR = r"path\to\DepthExport_extracted\depth"
META = r"path\to\DepthExport_extracted\metadata.json"
SOFA = sf.read_sofa(r"path\to\H10_48K_24bit_256tap_FIR_SOFA.sofa")
```

4. Run the notebook top-to-bottom, or jump to the relevant prototype stage after running its dependencies.

The later sections build on earlier functions, so sections 8-10 expect the depth loading, camera metadata, HRTF, sweep, clustering, and tracking helpers to already be defined.

## iOS App Setup

Open the project in Xcode:

```bash
open AssistNav.xcodeproj
```

Create your local Supabase config if you want auth, reports, maps, or navigation session logging:

```bash
cp AssistNav/SupabaseConfig.example.plist AssistNav/SupabaseConfig.plist
```

Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` inside `AssistNav/SupabaseConfig.plist`, then run:

```text
supabase/schema.sql
```

Build and run the app on a LiDAR-capable device. `AssistNav/SupabaseConfig.plist` is ignored by git so real keys are not committed.

## Capturing Data

### Local `.andepth` Exports

In the app, open the LiDAR depth test and use the export controls. After sharing the `.andepth` file to your laptop, convert it:

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

### Live UDP Streaming

Use this when running section 10 of `system.ipynb`.

In the app:

1. Open Settings.
2. Enable `Stream depth to laptop`.
3. Set `Host` to your laptop IP address on the same Wi-Fi.
4. Set `Port` to `5050`, or the port used by the notebook receiver.
5. Open the LiDAR depth test or start navigation.

The receiver reconstructs chunked UDP frames and stores the latest decoded frame:

```python
from streaming.live_depth_receiver import LiveDepthReceiver

receiver = LiveDepthReceiver(port=5050, debug=True)
receiver.start()
frame = receiver.wait_for_frame()
depth = frame.depth
confidence = frame.confidence
fx, fy, cx, cy = frame.depth_intrinsics()
```

`run_live_navigation_system` uses this receiver internally for the live notebook pipeline.

## Project Layout

```text
system.ipynb      Main assistive navigation pipeline
streaming/        Python export, live receiver, and depth preview tools
AssistNav/        iOS LiDAR capture and field-testing app
HRIR Profiles/    SOFA HRIR assets for spatial audio
supabase/         Database schema for app auth/reports/sessions
```

## Notes

- Use a real LiDAR device. The simulator will not provide ARKit scene depth.
- Keep the phone and laptop on the same network for UDP streaming.
- Firewall rules may block UDP port `5050`; allow Python if frames do not arrive.
- The iOS app includes report, map, profile, HRIR-selection, speech-dictation, and depth-preview UI, but the core assistive navigation algorithm is the notebook pipeline.
- A `SpokenFeedbackService` exists in the app source, but current navigation/status announcements are placeholders until that service is wired into `AppViewModel`.
