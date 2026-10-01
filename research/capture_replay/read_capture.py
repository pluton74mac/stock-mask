"""Read a StockMask capture (the app's capture mode, format v1) so recorded walks can be replayed
offline, like research/walkthrough replays phone videos, but with LiDAR depth and ARKit poses.

    python read_capture.py CAPTURE                    # summary: frames, duration, tracking, depth
    python read_capture.py CAPTURE --check            # every file present, every size right
    python read_capture.py CAPTURE --ply 12 out.ply   # frame 12's LiDAR points in world space
    python read_capture.py CAPTURE --frames out/      # upright keyframes as JPEG files

CAPTURE is a capture folder, or the .zip the app shares. The format is documented in README.md.

In Python:

    from read_capture import Capture
    cap = Capture("capture-20261002-101500.zip")
    for f in cap:                           # frames in time order
        rgb = f.image()                     # H x W x 3 uint8, as stored (sensor orientation)
        up = f.upright(rgb)                 # turned the way the phone was held
        depth, conf = f.depth(), f.confidence()   # float32 metres / uint8 0-2 (sensor orientation)
        K, T = f.K, f.T                     # 3x3 intrinsics (pixels of image()), 4x4 camera-to-world
        pts = f.points(min_confidence=2)    # N x 3 world points from the depth map
        f.detections                        # the app's detector boxes (upright image, normalised)

Needs numpy, and OpenCV or Pillow for the JPEGs. Captures are venue footage: keep them in the
git-ignored captures/ folder, never in the repository.
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import os
import sys
import zipfile

import numpy as np

FORMAT, VERSION = "stockmask-capture", 1
TURNS = {"up": 0, "right": -1, "down": 2, "left": 1}  # np.rot90 k that turns a sensor image upright


class Capture:
    """A capture folder or zip. Iterating yields Frame objects in time order."""

    def __init__(self, path: str):
        self.path = path
        if zipfile.is_zipfile(path):
            self._zip = zipfile.ZipFile(path)
            names = [n for n in self._zip.namelist() if n.endswith("manifest.json") and n.count("/") <= 1]
            if not names:
                raise ValueError(f"{path}: no manifest.json")
            self._root = names[0][: -len("manifest.json")]
        else:
            self._zip, self._root = None, ""
        self.manifest = json.loads(self.read("manifest.json"))
        if self.manifest.get("format") != FORMAT:
            raise ValueError(f"{path}: not a StockMask capture ({self.manifest.get('format')!r})")
        if self.manifest.get("version", 0) > VERSION:
            raise ValueError(f"{path}: format version {self.manifest['version']} is newer than this reader")
        lines = self.read("frames.jsonl").decode("utf-8").splitlines()
        self.frames = [Frame(self, json.loads(line)) for line in lines if line.strip()]

    def read(self, name: str) -> bytes:
        if self._zip is not None:
            return self._zip.read(self._root + name)
        with open(os.path.join(self.path, name), "rb") as f:
            return f.read()

    def exists(self, name: str) -> int | None:
        """Size of a file in the capture, or None."""
        if self._zip is not None:
            try:
                return self._zip.getinfo(self._root + name).file_size
            except KeyError:
                return None
        p = os.path.join(self.path, name)
        return os.path.getsize(p) if os.path.exists(p) else None

    def __iter__(self):
        return iter(self.frames)

    def __len__(self):
        return len(self.frames)

    def __getitem__(self, i: int) -> "Frame":
        return self.frames[i]


class Frame:
    """One keyframe: the record from frames.jsonl plus lazy access to its files."""

    def __init__(self, capture: Capture, record: dict):
        self.capture, self.record = capture, record
        self.index = record["index"]
        self.timestamp = record["timestamp"]
        self.orientation = record["orientation"]
        self.tracking = record["tracking"]
        self.mapping = record["mapping"]
        self.K = np.array(record["intrinsics"], dtype=np.float64)          # rows: fx 0 cx / 0 fy cy / 0 0 1
        self.T = np.array(record["camera_transform"], dtype=np.float64)    # camera to world
        self.image_size = tuple(record["image_size"])                      # (width, height)
        self.depth_size = tuple(record["depth_size"]) if record.get("depth_size") else None
        self.detections = record.get("detections", [])

    def image(self) -> np.ndarray:
        """The stored keyframe, RGB, sensor orientation."""
        data = self.capture.read(self.record["image"])
        try:
            import cv2

            return cv2.cvtColor(cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
        except ImportError:
            from PIL import Image

            return np.array(Image.open(io.BytesIO(data)).convert("RGB"))

    def _map(self, key: str, dtype) -> np.ndarray | None:
        name = self.record.get(key)
        if not name or not self.depth_size:
            return None
        w, h = self.depth_size
        return np.frombuffer(self.capture.read(name), dtype=dtype).reshape(h, w)

    def depth(self) -> np.ndarray | None:
        """sceneDepth: metres along the camera axis, sensor orientation."""
        return self._map("depth", "<f4")

    def confidence(self) -> np.ndarray | None:
        return self._map("confidence", np.uint8)

    def smoothed_depth(self) -> np.ndarray | None:
        return self._map("smoothed_depth", "<f4")

    def smoothed_confidence(self) -> np.ndarray | None:
        return self._map("smoothed_confidence", np.uint8)

    def upright(self, array: np.ndarray) -> np.ndarray:
        """Turn an image or depth map from the sensor's orientation to the way the phone was held."""
        return np.ascontiguousarray(np.rot90(array, TURNS[self.orientation]))

    def points(self, min_confidence: int = 2, smoothed: bool = False) -> np.ndarray:
        """World-space points (N x 3, metres) from the depth map, using the intrinsics scaled from
        the image to the depth map (same field of view). ARKit's camera looks along -z, +y up."""
        d = self.smoothed_depth() if smoothed else self.depth()
        c = self.smoothed_confidence() if smoothed else self.confidence()
        if d is None:
            return np.zeros((0, 3))
        h, w = d.shape
        sx, sy = self.image_size[0] / w, self.image_size[1] / h
        v, u = np.mgrid[0:h, 0:w]
        x = (u + 0.5) * sx
        y = (v + 0.5) * sy
        ok = np.isfinite(d) & (d > 0)
        if c is not None:
            ok &= c >= min_confidence
        fx, fy, cx, cy = self.K[0, 0], self.K[1, 1], self.K[0, 2], self.K[1, 2]
        z = d[ok]
        cam = np.stack([(x[ok] - cx) / fx * z, -(y[ok] - cy) / fy * z, -z, np.ones_like(z)])
        return (self.T @ cam)[:3].T


def write_ply(points: np.ndarray, path: str) -> None:
    with open(path, "w") as f:
        f.write(f"ply\nformat ascii 1.0\nelement vertex {len(points)}\nproperty float x\nproperty float y\n"
                "property float z\nend_header\n")
        for p in points:
            f.write(f"{p[0]:.4f} {p[1]:.4f} {p[2]:.4f}\n")


def check(cap: Capture) -> list[str]:
    """Problems with the capture's files (an empty list means it is complete)."""
    problems = []
    for f in cap:
        r = f.record
        if not cap.exists(r["image"]):
            problems.append(f"frame {f.index}: missing {r['image']}")
        if f.depth_size:
            w, h = f.depth_size
            for key, size in (("depth", 4), ("confidence", 1), ("smoothed_depth", 4), ("smoothed_confidence", 1)):
                if r.get(key) and cap.exists(r[key]) != w * h * size:
                    problems.append(f"frame {f.index}: {r[key]} is not {w} x {h} x {size} bytes")
    return problems


def summary(cap: Capture) -> str:
    m = cap.manifest
    if not len(cap):
        return f"{cap.path}: no frames"
    t = [f.timestamp for f in cap]
    tracking = collections.Counter(f.tracking for f in cap)
    depth_ok, med = [], []
    for f in cap:
        d = f.depth()
        if d is not None:
            ok = np.isfinite(d) & (d > 0)
            depth_ok.append(ok.mean())
            if ok.any():
                med.append(float(np.median(d[ok])))
    dets = collections.Counter(d["label"] for f in cap for d in f.detections)
    light = [f.record["ambient_intensity"] for f in cap if f.record.get("ambient_intensity") is not None]
    moved = sum(np.linalg.norm(b.T[:3, 3] - a.T[:3, 3]) for a, b in zip(cap.frames, cap.frames[1:]))
    lines = [
        f"{os.path.basename(cap.path)}: {len(cap)} frames over {t[-1] - t[0]:.1f} s "
        f"({(len(cap) - 1) / max(t[-1] - t[0], 1e-9):.2f} Hz; set to {m.get('rate_hz')} Hz)",
        f"recorded {m.get('created')} on {m.get('device')} ({m.get('system')}), {m.get('app')}; "
        f"orientation {m.get('orientation')}; detector: {m.get('detector') or 'none'}",
        f"image {cap[0].image_size[0]} x {cap[0].image_size[1]}, depth "
        f"{'x'.join(map(str, cap[0].depth_size)) if cap[0].depth_size else 'none'}",
        "tracking: " + ", ".join(f"{k} {v}" for k, v in tracking.most_common()),
        f"camera path: {moved:.2f} m",
    ]
    if depth_ok:
        lines.append(f"depth: {100 * np.mean(depth_ok):.0f}% of pixels valid; median scene depth "
                     f"{np.median(med):.2f} m (range {min(med):.2f}-{max(med):.2f} m)")
    if light:
        lines.append(f"ARKit light estimate: {min(light):.0f}-{max(light):.0f} lm")
    if dets:
        lines.append("detections: " + ", ".join(f"{k} {v}" for k, v in dets.most_common()))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("capture", help="capture folder or .zip")
    ap.add_argument("--check", action="store_true", help="verify every file is present with the right size")
    ap.add_argument("--ply", nargs=2, metavar=("FRAME", "OUT"), help="write a frame's world points as PLY")
    ap.add_argument("--min-confidence", type=int, default=2)
    ap.add_argument("--frames", metavar="DIR", help="write the upright keyframes as JPEG files")
    args = ap.parse_args()

    cap = Capture(args.capture)
    print(summary(cap))
    if args.check:
        problems = check(cap)
        print("\n".join(problems) if problems else "check: all files present, sizes right")
        if problems:
            sys.exit(1)
    if args.ply:
        frame = next(f for f in cap if f.index == int(args.ply[0]))
        pts = frame.points(args.min_confidence)
        write_ply(pts, args.ply[1])
        print(f"wrote {len(pts)} points of frame {frame.index} to {args.ply[1]}")
    if args.frames:
        from PIL import Image

        os.makedirs(args.frames, exist_ok=True)
        for f in cap:
            Image.fromarray(f.upright(f.image())).save(os.path.join(args.frames, f"{f.index:06d}.jpg"), quality=90)
        print(f"wrote {len(cap)} upright keyframes to {args.frames}")


if __name__ == "__main__":
    main()
