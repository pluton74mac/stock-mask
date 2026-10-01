# Capture replay

The app's **capture mode** (P0-2) records a walk as keyframes with LiDAR depth and ARKit poses, at
1–2 Hz. `read_capture.py` reads those recordings on a Mac, so a walk can be replayed offline:
detectors, 3D lifting (P0-4), tracks and counting, with the depth and poses the phone had. It does
for the app what [`research/walkthrough`](../walkthrough/) does for plain phone videos.

**Captures are venue footage.** Keep them in `captures/` here (git-ignored), never in the
repository. The app never records location.

## Getting a capture off the phone

1. In the app, turn **Capture** on in the debug HUD, walk, then turn it off.
2. **Share capture** zips the folder and opens the share sheet: AirDrop it to the Mac, or save it
   to Files.
3. Or, with the phone plugged in: Finder → the phone → Files → StockMask → `Captures/`. (The app
   sets `UIFileSharingEnabled` for this.)

## Read it

```bash
python read_capture.py captures/capture-20261002-101500.zip            # summary
python read_capture.py captures/capture-20261002-101500.zip --check    # all files there?
python read_capture.py captures/capture-20261002-101500 --ply 12 out/f12.ply
python read_capture.py captures/capture-20261002-101500 --frames out/frames/
```

It needs numpy plus OpenCV or Pillow. The walkthrough venv has all three.

```python
from read_capture import Capture

cap = Capture("captures/capture-20261002-101500.zip")
for f in cap:
    rgb = f.upright(f.image())            # the keyframe as the user saw it
    depth = f.upright(f.depth())          # metres, the same turn
    pts = f.points(min_confidence=2)      # N x 3 world points (high-confidence LiDAR only)
    f.K, f.T, f.detections                # intrinsics, camera-to-world pose, the app's boxes
```

## Format, version 1

A capture is a folder, zipped for sharing:

```
capture-YYYYMMDD-HHMMSS/
  manifest.json                  one object, below
  frames.jsonl                   one object per keyframe, in time order
  images/000001.jpg              ARFrame.capturedImage, JPEG quality 0.8, as stored (landscape)
  depth/000001.f32               ARFrame.sceneDepth.depthMap: float32 little-endian, row-major
  confidence/000001.u8           ARFrame.sceneDepth.confidenceMap: uint8, 0 low, 1 medium, 2 high
  smoothed/000001.f32            ARFrame.smoothedSceneDepth.depthMap (when ARKit gives it)
  smoothed_confidence/000001.u8  ARFrame.smoothedSceneDepth.confidenceMap
```

Each frame's files are written before its line goes into `frames.jsonl`, so a capture cut short by
a crash still reads up to its last complete frame.

**`manifest.json`:**

| key | meaning |
|---|---|
| `format`, `version` | `"stockmask-capture"`, `1` |
| `created` | ISO 8601, UTC |
| `app`, `device`, `system` | app version, model identifier (e.g. `iPhone14,2`), iOS version |
| `rate_hz` | the keyframe rate that was set (1–2) |
| `orientation` | how the stored images turn upright: `right` for a phone held in portrait |
| `detector` | the detector model's description, from its metadata |
| `notes` | free text |

**`frames.jsonl`, one object per line:**

| key | meaning |
|---|---|
| `index` | 1, 2, 3, ... |
| `timestamp` | `ARFrame.timestamp`, seconds on the device's uptime clock |
| `image`, `image_size` | the JPEG's path and its `[width, height]` (1920 x 1440 on current iPhones) |
| `depth`, `confidence`, `depth_size` | paths and `[width, height]` (256 x 192) of the depth files; absent without depth |
| `smoothed_depth`, `smoothed_confidence` | the same for `smoothedSceneDepth` |
| `intrinsics` | 3 x 3, **rows**: `[[fx, 0, cx], [0, fy, cy], [0, 0, 1]]`, in pixels of the stored image |
| `camera_transform` | 4 x 4, **rows**: camera to world (`ARCamera.transform`) |
| `orientation` | as in the manifest |
| `tracking` | `normal`, `limited:initializing`, `limited:relocalizing`, `limited:excessiveMotion`, `limited:insufficientFeatures`, `notAvailable` |
| `mapping` | `ARFrame.worldMappingStatus`: `notAvailable`, `limited`, `extending`, `mapped` |
| `exposure_duration`, `exposure_offset` | seconds, EV, from `ARCamera` |
| `ambient_intensity`, `ambient_color_temperature` | ARKit's light estimate (lumens; about 1000 is a well-lit room) and kelvin |
| `detections` | the app's detector boxes at that moment: `label`, `score`, `box` (`[x0, y0, x1, y1]`, normalised, **upright** image) |

**Conventions (ARKit's):**
- World space is metres with +y up, fixed for the session.
- The camera looks along its −z axis. +x points to the stored image's right, +y to its top.
- A pixel `(x, y)` of the stored image (origin top-left, y down) at depth `d` is the camera point
  `((x − cx) / fx · d, −(y − cy) / fy · d, −d)`.
- The depth map covers the same field of view as the image at a lower resolution. Scale the
  intrinsics by `depth_size / image_size` to use them on depth pixels; `Frame.points` does this.
- Images and depth are stored in the sensor's orientation (landscape). `orientation: right` means
  turn 90° clockwise to see them as the user did (`Frame.upright`, `np.rot90(a, -1)`).
- Detector boxes are in the upright image, as the app uses them.

`StockMaskAR`'s `CaptureWriter`/`CaptureReader` (Swift) and this reader are tested against the same
files: the Swift test writes a capture, and this reader checks it (`--check`) and turns its depth
into world points.
