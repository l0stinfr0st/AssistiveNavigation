import numpy as np
import matplotlib.pyplot as plt
import glob
import sys

# Use path from command line arg or default
if len(sys.argv) > 1:
    depth_dir = sys.argv[1]
else:
    depth_dir = "/Users/kareemhijazi/Documents/AssistiveNavigationOriginal/DepthExport-2026-05-02T08-33-45.032Z_extracted/depth"

frames = sorted(glob.glob(f"{depth_dir}/*.npy"))

if not frames:
    print(f"No .npy files found in: {depth_dir}")
    sys.exit(1)

print(f"Found {len(frames)} frames — press Ctrl+C to stop")

plt.ion()
fig, ax = plt.subplots()

for path in frames:
    frame = np.load(path)
    ax.clear()
    ax.imshow(frame, cmap="plasma")
    ax.set_title(path.split("/")[-1])
    plt.pause(0.010)  # ~30fps, adjust as needed

plt.ioff()
plt.show()
