#!/usr/bin/env python3
"""
Depth video player
==================
Plays depth frames (.npy files) as a colorized video using OpenCV.

Usage:
  python play_depth.py <depth_dir> [options]

Options:
  --fps N         Playback FPS (default: 30)
  --colormap NAME OpenCV colormap name: TURBO (default), JET, MAGMA, PLASMA, INFERNO, VIRIDIS, HOT
  --min-depth M   Min depth in meters for color scale (default: auto)
  --max-depth M   Max depth in meters for color scale (default: auto)
  --loop          Loop playback

Controls:
  SPACE       Pause / resume
  LEFT / ,    Step back one frame
  RIGHT / .   Step forward one frame
  [ / ]       Decrease / increase FPS
  Q / ESC     Quit
"""

import sys
import os
import glob
import time
import argparse
import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("OpenCV not found. Install it with:  pip install opencv-python")

COLORMAPS = {
    'TURBO':   cv2.COLORMAP_TURBO,
    'JET':     cv2.COLORMAP_JET,
    'MAGMA':   cv2.COLORMAP_MAGMA,
    'PLASMA':  cv2.COLORMAP_PLASMA,
    'INFERNO': cv2.COLORMAP_INFERNO,
    'VIRIDIS': cv2.COLORMAP_VIRIDIS,
    'HOT':     cv2.COLORMAP_HOT,
}


def load_frames(depth_dir):
    paths = sorted(glob.glob(os.path.join(depth_dir, '*.npy')))
    if not paths:
        sys.exit(f"No .npy files found in: {depth_dir}")
    print(f"Found {len(paths)} depth frames in {depth_dir}")
    return paths


def compute_global_range(paths, sample_every=10):
    """Scan a subset of frames to get a stable global depth range."""
    mins, maxs = [], []
    for p in paths[::sample_every]:
        arr = np.load(p)
        valid = arr[np.isfinite(arr) & (arr > 0)]
        if valid.size:
            mins.append(float(valid.min()))
            maxs.append(float(valid.max()))
    return (min(mins), max(maxs)) if mins else (0.0, 10.0)


def depth_to_rgb(arr, d_min, d_max, colormap):
    norm = np.clip((arr - d_min) / max(d_max - d_min, 1e-6), 0.0, 1.0)
    gray8 = (norm * 255).astype(np.uint8)
    return cv2.applyColorMap(gray8, colormap)


def play(depth_dir, fps=30, colormap_name='TURBO', min_depth=None, max_depth=None, loop=False):
    paths = load_frames(depth_dir)
    colormap = COLORMAPS.get(colormap_name.upper(), cv2.COLORMAP_TURBO)

    print("Computing depth range from frames...", end=' ', flush=True)
    auto_min, auto_max = compute_global_range(paths)
    d_min = min_depth if min_depth is not None else auto_min
    d_max = max_depth if max_depth is not None else auto_max
    print(f"{d_min:.2f}m – {d_max:.2f}m")

    win = 'Depth Player  |  SPACE=pause  ◄/►=step  [/]=fps  Q=quit'
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    idx = 0
    paused = False
    frame_ms = int(1000 / fps)
    total = len(paths)

    while True:
        arr = np.load(paths[idx])
        vis = depth_to_rgb(arr, d_min, d_max, colormap)

        # Overlay: frame number, timestamp hint, depth at cursor centre
        h, w = vis.shape[:2]
        cx, cy = w // 2, h // 2
        centre_depth = float(arr[cy, cx])
        label = (f"Frame {idx+1}/{total}  |  FPS {fps}"
                 f"  |  centre {centre_depth:.2f}m"
                 f"  |  range {d_min:.1f}-{d_max:.1f}m"
                 + ("  |  PAUSED" if paused else ""))
        cv2.putText(vis, label, (10, h - 12),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)

        # Crosshair at centre
        cv2.drawMarker(vis, (cx, cy), (255, 255, 255),
                       cv2.MARKER_CROSS, 16, 1, cv2.LINE_AA)

        cv2.imshow(win, vis)
        key = cv2.waitKey(1 if paused else frame_ms) & 0xFF

        if key in (ord('q'), 27):   # Q or ESC
            break
        elif key == ord(' '):
            paused = not paused
        elif key in (81, ord(','), 2):    # LEFT arrow or comma
            idx = max(0, idx - 1)
            paused = True
        elif key in (83, ord('.'), 3):    # RIGHT arrow or period
            idx = min(total - 1, idx + 1)
            paused = True
        elif key == ord('['):
            fps = max(1, fps - 1)
            frame_ms = int(1000 / fps)
        elif key == ord(']'):
            fps = min(120, fps + 1)
            frame_ms = int(1000 / fps)
        elif not paused:
            idx += 1
            if idx >= total:
                if loop:
                    idx = 0
                else:
                    break

    cv2.destroyAllWindows()
    print("Done.")


def main():
    parser = argparse.ArgumentParser(description='Play depth frames as a colorized video')
    parser.add_argument('depth_dir', help='Directory containing .npy depth frames')
    parser.add_argument('--fps', type=int, default=30)
    parser.add_argument('--colormap', default='TURBO',
                        choices=list(COLORMAPS.keys()), metavar='NAME',
                        help='Colormap: ' + ', '.join(COLORMAPS.keys()) + ' (default: TURBO)')
    parser.add_argument('--min-depth', type=float, default=None, metavar='M')
    parser.add_argument('--max-depth', type=float, default=None, metavar='M')
    parser.add_argument('--loop', action='store_true')
    args = parser.parse_args()

    play(args.depth_dir, fps=args.fps, colormap_name=args.colormap,
         min_depth=args.min_depth, max_depth=args.max_depth, loop=args.loop)


if __name__ == '__main__':
    main()
