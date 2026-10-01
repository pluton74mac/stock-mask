"""Replay a phone video of a storeroom walk through StockMask's counting loop.

Phase 0 has no app yet (P0-2), but an ordinary phone video of a storeroom walk already answers
part of what the spike will ask. This script replays a video through the steps that don't need
LiDAR or ARKit poses:

  1. Hold-to-count (FR-13, ADR 003). Image motion from optical flow is turned into an angular
     speed with the camera's field of view. Causal, like the app: a commit fires once the view has
     stayed under 10 deg/s for 0.8 s, then re-arms after the view has moved 5 deg. The keyframe
     is the sharpest frame of the hold. Walks that never stop can use --sweep instead (a commit
     per half view moved) or --every (one per N seconds).
  2. Detection at each commit.
       rfdetr        RF-DETR Nano, COCO weights (bottles only: COCO has no can or case). This is
                     P0-3's "COCO weights first", on the detector ADR 002 chose.
       rfdetr_tiled  the same model on overlapping tiles too: is it the model or the 384 px input?
       owlv2         OWLv2 prompted with bottle / can / cardboard box: the ADR 006 pre-labeller.
       owlv2_caps    OWLv2 prompted with "a photo of a bottle cap", each cap counted as a bottle:
                     do the tops of the rows behind the front one count the bottles there?
                     (ADR 006's candidate bottle_top class)
       rfdetr_ft     RF-DETR fine-tuned on bottle, can, case and bottle_top (ml/train.py), from the checkpoint
                     in $RFDETR_FT_CHECKPOINT. A top with no counted bottle of its own counts as a bottle.
     A box counts only if it is whole (not cut by the image border), its centre is in the inner
     frame (FR-14) and its score clears the commit threshold (FR-18).
  3. Double counting between commits, in 2D. Shelf fronts are roughly planar, so a homography
     between two keyframes carries one commit's counted items and counted zone into the other.
     Then strategy S5 from ADR 003: a small common-offset refinement, 1:1 matching, nothing
     auto-added inside counted zones (a "possible miss" instead). This is a stand-in for the 3D
     design, not the design itself: parallax breaks it, and look-alike racks (the same products on
     another rack) can fool it, as they fool relocalisation. Two guards reject look-alikes, and the
     report lists what they rejected and every registration onto a much earlier commit. For
     footage filmed close up while walking, --carry track carries counted items through the video
     by optical flow instead (count_tracked).
  4. Frame conditions per commit: dark, blurry, clipped highlights (PRD section 9 hints).

Outputs, in --out: report.md, summary.json, timeline.png, contact sheets, an annotated image per
commit and detector, and COCO pre-labels for CVAT (ADR 006). Venue footage stays on this machine:
never commit the video or the out/ folder. This repository is public.

    python walkthrough.py VIDEO [--out out/venue1] [--truth bottle=120,case=8] [--every 2]
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime
import json
import math
import os
import platform
import subprocess
import time
from dataclasses import dataclass, field

import cv2
import numpy as np
from scipy.optimize import linear_sum_assignment

CLASSES = ("bottle", "can", "case")
HOLD_S = 0.8  # FR-13: steady this long, then commit
MAX_DEG_S = 10.0  # ADR 003: "angular speed < 10 deg/s"
REARM_DEG = 5.0  # after a commit, the view must move this far before the next commit can fire
HFOV_DEG = 65.0  # field of view across the frame's long side: iPhone 1x camera, video, stabilised
BAND = 0.15  # inner-frame edge band per side, as a fraction of the short side (~half a bottle)
EDGE = 0.005  # a box this close to the image border (fraction of the long side) is cut
MOTION_SIDE = 640  # long side of the frames used for motion and frame quality
KEY_SIDE = 1920  # long side of stored keyframes (ARKit's captured image is 1920 x 1440)
FEATURE_SIDE = 1280  # long side for SIFT registration between keyframes
FLOW_SIDE = 640  # long side of the frames for dense optical flow (--carry track)
DEAD_RECKON_S = 3.0  # an item or zone out of view follows the frame's global motion this long (--carry track)
MIN_INLIERS = 40  # homography inliers needed to call two keyframes registered
MIN_COVERAGE = 0.08  # ... and the share of the features in the claimed overlap that they explain.
# Look-alike shelves (the same products on another rack) give a few dozen consistent matches but
# explain under ~5% of the overlap; true registrations of our test footage explain 13-40%.
GATE = 0.5  # 1:1 match gate, in box widths / heights (ADR 003: "at most half an item width")
LONG_GAP_S = 10.0  # a registration onto a commit older than this is listed for a human to check
DETECTORS = {  # name: (shown, counted) score thresholds; in between = dashed, not counted (FR-18)
    "rfdetr": (0.3, 0.5), "rfdetr_tiled": (0.3, 0.5), "owlv2": (0.2, 0.3), "owlv2_caps": (0.15, 0.2),
    "rfdetr_ft": (0.3, 0.5), "oracle": (0.5, 0.5)}
FT_CHECKPOINT = "RFDETR_FT_CHECKPOINT"  # env var: the fine-tuned RF-DETR checkpoint for rfdetr_ft (ml/train.py)
OWL_MODEL = "google/owlv2-base-patch16-ensemble"
OWL_QUERIES = {"bottle": "a photo of a bottle", "can": "a photo of a beverage can",
               "case": "a photo of a cardboard box"}
OWL_CAP_QUERY = "a photo of a bottle cap"  # 0.2 came within 12% of the tops counted by eye in six bay views
# BGR colours in the visual language of PRD section 9
GREEN, AMBER, YELLOW, GREY, WHITE, BLACK = (70, 200, 60), (0, 165, 255), (0, 225, 255), (150, 150, 150), \
    (255, 255, 255), (0, 0, 0)


@dataclass
class Commit:
    n: int  # 1-based, in firing order
    t: float  # when the app would have fired
    hold_from: float  # start of the steady hold that fired it
    frame: int  # keyframe index in the video
    t_key: float
    image: np.ndarray  # BGR keyframe, long side <= KEY_SIDE
    scale: float  # keyframe pixels per video pixel
    step_deg: float  # how far the view moved since the previous commit (nan if tracking was lost)
    luma: float  # mean grey level, 0-255
    clipped: float  # fraction of pixels at 250 or above
    sharp: float  # variance of the Laplacian
    flags: list = field(default_factory=list)


@dataclass
class Dets:
    boxes: np.ndarray  # (N, 4) x0 y0 x1 y1 in keyframe pixels
    scores: np.ndarray
    cls: np.ndarray  # class names

    @staticmethod
    def empty() -> Dets:
        return Dets(np.zeros((0, 4)), np.zeros(0), np.zeros(0, dtype="<U6"))

    def take(self, m) -> Dets:
        return Dets(self.boxes[m], self.scores[m], self.cls[m])

    @staticmethod
    def cat(parts: list) -> Dets:
        parts = [p for p in parts if len(p.scores)]
        if not parts:
            return Dets.empty()
        return Dets(np.vstack([p.boxes for p in parts]), np.concatenate([p.scores for p in parts]),
                    np.concatenate([p.cls for p in parts]))


# ---------------------------------------------------------------------------------------------
# 1. Hold-to-count


def read_video(path: str, start: float = 0.0, end: float | None = None):
    """Yield (fps, index, seconds, BGR frame), upright: iPhone portrait video is stored landscape
    with a rotation flag, which OpenCV applies."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {path}")
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    i, last = -1, -1.0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if not t > last:  # some containers report no timestamps
            t = i / fps
        last = t
        if t < start:
            continue
        if end is not None and t > end:
            break
        yield fps, i, t, frame
    cap.release()


def stream_info(path: str) -> str:
    """ffmpeg's one-line description of the video stream, e.g. 'hevc (Main 10) ... arib-std-b67 ...'."""
    try:
        import imageio_ffmpeg

        r = subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-i", path], capture_output=True, text=True)
        return next((ln.split("Video:", 1)[1].strip() for ln in r.stderr.splitlines() if "Video:" in ln), "")
    except (ImportError, OSError):
        return ""


def image_motion(prev: np.ndarray, cur: np.ndarray):
    """Median feature displacement between two grey frames in pixels, and its median vector.
    NaN when there is too little texture to track (treated as moving)."""
    p0 = cv2.goodFeaturesToTrack(prev, maxCorners=300, qualityLevel=0.01, minDistance=8)
    if p0 is None or len(p0) < 20:
        return math.nan, np.zeros(2)
    p1, st, _ = cv2.calcOpticalFlowPyrLK(prev, cur, p0, None, winSize=(21, 21), maxLevel=3)
    back, st2, _ = cv2.calcOpticalFlowPyrLK(cur, prev, p1, None, winSize=(21, 21), maxLevel=3)
    ok = (st[:, 0] == 1) & (st2[:, 0] == 1) & (np.linalg.norm((p0 - back)[:, 0], axis=1) < 1.0)
    if ok.sum() < 15:
        return math.nan, np.zeros(2)
    d = (p1 - p0)[ok, 0]
    return float(np.median(np.linalg.norm(d, axis=1))), np.median(d, axis=0)


def replay(path: str, hfov=HFOV_DEG, hold=HOLD_S, max_speed=MAX_DEG_S, rearm=REARM_DEG, every=None,
           start=0.0, end=None, sweep=None, sweep_speed=None, fallback=None):
    """Run the video through the hold-to-count trigger, frame by frame, the way the app would.
    For walks filmed without pausing, two alternatives ignore holds. With `every`, commit the sharpest
    frame of every `every` seconds. With `sweep`, commit each time the view has advanced `sweep` of a
    frame since the last keyframe: the sharpest frame of the second half of that advance. The overlap
    between neighbouring commits then stays near 1 - `sweep`. With `sweep_speed`, only frames slower
    than that (deg/s) can be keyframes: past the goal, the commit waits for the view to slow down.
    With `fallback`, hold-to-count stays the trigger, and the sweep rule is its safety net: a view
    passed without a hold still commits once the view has advanced `fallback` of a frame since the
    last keyframe (flagged "no hold")."""
    track = collections.defaultdict(list)
    commits, holds = [], []  # holds: every stretch under the speed limit, for the timeline
    prev = run_from = since = timed = None
    window = collections.deque()  # (sharpness, index, t, keyframe, luma, clipped) over the current hold
    armed, moved, lost, shift = True, np.zeros(2), False, np.zeros(2)
    for fps, i, t, frame in read_video(path, start, end):
        if prev is None:
            h, w = frame.shape[:2]
            s_motion, s_key = MOTION_SIDE / max(h, w), min(1.0, KEY_SIDE / max(h, w))
            f_px = (MOTION_SIDE / 2) / math.tan(math.radians(hfov) / 2)
            speeds = collections.deque(maxlen=max(3, round(0.1 * fps)))  # ~0.1 s median filter
            t_prev = win_from = t - 1 / fps
            degrees = lambda v: math.degrees(math.atan(np.linalg.norm(v) / f_px))  # noqa: E731
        grey = cv2.cvtColor(cv2.resize(frame, None, fx=s_motion, fy=s_motion, interpolation=cv2.INTER_AREA),
                            cv2.COLOR_BGR2GRAY)
        sharp, luma, clipped = cv2.Laplacian(grey, cv2.CV_64F).var(), float(grey.mean()), float((grey >= 250).mean())
        px, vec = image_motion(prev, grey) if prev is not None else (math.nan, np.zeros(2))
        dt = t - t_prev if t > t_prev else 1 / fps
        speeds.append(math.degrees(math.atan(px / f_px)) / dt if math.isfinite(px) else math.inf)
        speed = float(np.median(speeds))
        steady = speed < max_speed
        moved += vec
        shift += vec  # image shift since the last keyframe (sweep), in motion-frame pixels
        lost |= prev is not None and not math.isfinite(px)
        for k, v in (("t", t), ("speed", speed), ("luma", luma), ("sharp", sharp)):
            track[k].append(v)
        if steady and run_from is None:
            run_from = t
        elif not steady and run_from is not None:
            holds.append((run_from, t_prev))
            run_from = None
        keyframe = lambda: frame.copy() if s_key == 1.0 else cv2.resize(  # noqa: E731
            frame, None, fx=s_key, fy=s_key, interpolation=cv2.INTER_AREA)
        fire, no_hold = None, False
        if every:
            if timed is None or sharp > timed[0]:
                timed = (sharp, i, t, keyframe(), luma, clipped)
            if t - win_from >= every - 1e-6:
                fire, win_from, timed = (timed, win_from), t, None
        elif sweep:
            gh, gw = grey.shape
            advance = 1 - max(0.0, 1 - abs(shift[0]) / gw) * max(0.0, 1 - abs(shift[1]) / gh)  # 1 - overlap
            goal = sweep if commits else sweep / 2  # the first view: the sharpest frame of the first half-step
            slow = sweep_speed is None or speed < sweep_speed
            if advance >= goal - sweep / 2 and slow and (timed is None or sharp > timed[0]):
                timed = (sharp, i, t, keyframe(), luma, clipped, shift.copy())
            if advance >= goal and timed is not None:
                fire = (timed[:6], win_from)
                shift -= timed[6]  # the next advance counts from the keyframe, not from this frame
                win_from, timed = timed[2], None
        else:
            if not armed and (not math.isfinite(px) or degrees(moved) >= rearm):
                armed = True  # the view has changed: the hold timer starts again from here
                since = t if steady else None
                window.clear()
            if steady:
                if since is None:
                    since = t
                    window.clear()
                window.append((sharp, i, t, keyframe(), luma, clipped))
                while window[0][2] < t - hold:
                    window.popleft()
                if armed and t - since >= hold - 1e-6:
                    fire = (max(window, key=lambda x: x[0]), since)
            else:
                since = None
                window.clear()
            if fallback and fire:  # the view stood still at the hold's keyframe: the next advance counts from there
                shift, timed = np.zeros(2), None
            elif fallback:  # passed without a hold: the sweep rule commits it anyway
                gh, gw = grey.shape
                advance = 1 - max(0.0, 1 - abs(shift[0]) / gw) * max(0.0, 1 - abs(shift[1]) / gh)
                slow = sweep_speed is None or speed < sweep_speed
                if advance >= fallback / 2 and slow and (timed is None or sharp > timed[0]):
                    timed = (sharp, i, t, keyframe(), luma, clipped, shift.copy())
                if advance >= fallback and timed is not None and not steady:  # a hold under way commits itself
                    fire, no_hold = (timed[:6], timed[2]), True
                    shift -= timed[6]
                    timed = None
        if fire:
            (sharp_k, i_k, t_k, key, luma_k, clipped_k), from_ = fire
            commits.append(Commit(len(commits) + 1, t, from_, i_k, t_k, key, s_key,
                                  math.nan if (lost or not commits) else degrees(moved), luma_k, clipped_k, sharp_k,
                                  ["no hold"] if no_hold else []))
            # a fallback commit leaves the hold rule armed: a hold that follows it still commits
            armed, moved, lost = armed and no_hold, np.zeros(2), False
        prev, t_prev = grey, t
    if run_from is not None:
        holds.append((run_from, t_prev))
    if prev is None:
        raise SystemExit(f"no frames read from {path}")
    info = stream_info(path)
    video = dict(file=os.path.basename(path), fps=round(fps, 2), frames=len(track["t"]), t0=round(track["t"][0], 3),
                 seconds=round(track["t"][-1] - track["t"][0] + 1 / fps, 2), width=w, height=h,
                 codec=info.split(",")[0], hdr="arib-std-b67" in info or "smpte2084" in info)
    sharp_ref = np.median([c.sharp for c in commits]) if commits else 0
    for c in commits:
        if c.luma < 50:
            c.flags.append("dark")
        if c.sharp < 0.35 * sharp_ref:
            c.flags.append("blurry")
        if c.clipped > 0.02:
            c.flags.append("glare")
    return video, commits, holds, {k: np.array(v) for k, v in track.items()}


# ---------------------------------------------------------------------------------------------
# 2. Detection


def box_iou(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ix = np.clip(np.minimum(a[:, None, 2], b[None, :, 2]) - np.maximum(a[:, None, 0], b[None, :, 0]), 0, None)
    iy = np.clip(np.minimum(a[:, None, 3], b[None, :, 3]) - np.maximum(a[:, None, 1], b[None, :, 1]), 0, None)
    inter = ix * iy
    area = lambda x: (x[:, 2] - x[:, 0]) * (x[:, 3] - x[:, 1])
    return inter / np.maximum(area(a)[:, None] + area(b)[None] - inter, 1e-9)


def clean(d: Dets, iou=0.5) -> Dets:
    """Class-agnostic NMS, then drop boxes drawn around a whole row of one class, and boxes around
    part of an object that a higher-scoring box of the same class already covers. Open-vocabulary
    detectors produce both."""
    order, keep = np.argsort(-d.scores), []
    while len(order):
        keep.append(order[0])
        order = order[1:][box_iou(d.boxes[order[:1]], d.boxes[order[1:]])[0] < iou]
    d = d.take(np.array(keep, dtype=int))
    b, n = d.boxes, len(d.scores)
    area = (b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])
    cx, cy = (b[:, 0] + b[:, 2]) / 2, (b[:, 1] + b[:, 3]) / 2
    ok = np.ones(n, dtype=bool)
    for i in range(n):
        inside = (d.cls == d.cls[i]) & (cx > b[i, 0]) & (cx < b[i, 2]) & (cy > b[i, 1]) & (cy < b[i, 3]) \
            & (area < 0.6 * area[i])
        if inside.sum() >= 2 and area[inside].sum() > 0.5 * area[i]:
            ok[i] = False  # a row or a stack, not an item
    for i in np.argsort(area):
        big = ok & (d.cls == d.cls[i]) & (area > area[i]) & (d.scores >= d.scores[i])
        if ok[i] and big.any():
            ix = np.clip(np.minimum(b[big, 2], b[i, 2]) - np.maximum(b[big, 0], b[i, 0]), 0, None)
            iy = np.clip(np.minimum(b[big, 3], b[i, 3]) - np.maximum(b[big, 1], b[i, 1]), 0, None)
            ok[i] = not (ix * iy / area[i] > 0.8).any()
    return d.take(ok)


class RFDETR:
    """RF-DETR Nano with its COCO weights; COCO's only class of ours is bottle."""

    def __init__(self, tiled=False):
        from rfdetr import RFDETRNano

        self.model, self.tiled = RFDETRNano(), tiled
        self.name = "rfdetr_tiled" if tiled else "rfdetr"

    def _run(self, rgb, x0=0, y0=0) -> Dets:
        r = self.model.predict(np.ascontiguousarray(rgb), threshold=DETECTORS[self.name][0])
        m = r.data["class_name"] == "bottle" if len(r) else np.zeros(0, dtype=bool)
        return Dets(r.xyxy[m] + [x0, y0, x0, y0], r.confidence[m], np.full(int(m.sum()), "bottle"))

    def __call__(self, c: Commit) -> Dets:
        rgb = c.image[..., ::-1]
        parts = [self._run(rgb)]
        if self.tiled:  # 2 x 3 overlapping tiles (portrait) or 3 x 2 (landscape), plus the full frame
            h, w = rgb.shape[:2]
            cols, rows = (2, 3) if h > w else (3, 2)
            tw, th = w / (cols - 0.25 * (cols - 1)), h / (rows - 0.25 * (rows - 1))
            for y0 in (round(r * th * 0.75) for r in range(rows)):
                for x0 in (round(q * tw * 0.75) for q in range(cols)):
                    x1, y1 = min(w, round(x0 + tw)), min(h, round(y0 + th))
                    p = self._run(rgb[y0:y1, x0:x1], x0, y0)
                    b = p.boxes  # drop boxes cut by an inner tile edge; another tile sees them whole
                    cut = ((b[:, 0] < x0 + 2) & (x0 > 0)) | ((b[:, 2] > x1 - 2) & (x1 < w)) | \
                          ((b[:, 1] < y0 + 2) & (y0 > 0)) | ((b[:, 3] > y1 - 2) & (y1 < h))
                    parts.append(p.take(~cut))
        return Dets.cat(parts)


class RFDETRFineTuned:
    """RF-DETR fine-tuned on our classes (ml/train.py), from the checkpoint in $RFDETR_FT_CHECKPOINT. Its bottle_top
    boxes are merged into bottles by the counting rule of docs/mvp-test-app.md (ml/common.py pair_tops): a top in the
    top region of a counted bottle is that bottle's own top and is dropped; every other top is a bottle in a row behind
    and is reported as a bottle. Only bottles that reach the commit threshold claim a top. Each class is cleaned on its
    own before the merge, so clean() can't remove back-row tops that lie inside a front bottle's box."""

    name = "rfdetr_ft"

    def __init__(self):
        from rfdetr import RFDETR as _RFDETR

        path = os.environ.get(FT_CHECKPOINT)
        if not path or not os.path.exists(path):
            raise SystemExit(f"--detectors rfdetr_ft needs ${FT_CHECKPOINT} set to a checkpoint from ml/train.py")
        self.model = _RFDETR.from_checkpoint(path, trust_checkpoint=True)  # our own training output
        self.names = list(self.model.class_names)

    def __call__(self, c: Commit) -> Dets:
        shown, counted = DETECTORS[self.name]
        r = self.model.predict(np.ascontiguousarray(c.image[..., ::-1]), threshold=shown)
        known = np.array([k < len(self.names) for k in r.class_id], dtype=bool) if len(r) else np.zeros(0, bool)
        d = Dets(r.xyxy[known], r.confidence[known], np.array([self.names[k] for k in r.class_id[known]], dtype="<U10"))
        d = Dets.cat([clean(d.take(d.cls == k)) for k in ("bottle", "can", "case", "bottle_top")])
        bottle, top = d.cls == "bottle", d.cls == "bottle_top"
        b, t = d.boxes, d.boxes[top]
        cand = []  # (distance, bottle index, top index) for tops in a counted bottle's top region
        for i in np.nonzero(bottle & (d.scores >= counted))[0]:
            x0, y0, x1, y1 = b[i]
            h, cx, cy = y1 - y0, (x0 + x1) / 2, y0 + 0.06 * (y1 - y0)
            for j, (tx, ty) in enumerate(zip((t[:, 0] + t[:, 2]) / 2, (t[:, 1] + t[:, 3]) / 2)):
                if x0 <= tx <= x1 and y0 - 0.05 * h <= ty <= y0 + 0.25 * h:
                    cand.append((math.hypot(tx - cx, ty - cy) / max(1.0, x1 - x0), i, j))
        own, used = set(), set()
        for _, i, j in sorted(cand):
            if i not in used and j not in own:
                used.add(i)
                own.add(j)
        keep = ~top
        keep[np.nonzero(top)[0][[j for j in range(int(top.sum())) if j not in own]]] = True
        out = d.take(keep)
        return Dets(out.boxes, out.scores, np.where(out.cls == "bottle_top", "bottle", out.cls).astype("<U6"))


def checkpoint_tag(name: str) -> str:
    """Part of the detection cache's folder name: rfdetr_ft's cache belongs to one checkpoint file."""
    if name != "rfdetr_ft" or not os.path.exists(os.environ.get(FT_CHECKPOINT, "")):
        return ""
    import hashlib

    with open(os.environ[FT_CHECKPOINT], "rb") as f:
        return "-" + hashlib.sha1(f.read()).hexdigest()[:10]


class OWLv2:
    """OWLv2 (Apache-2.0), open vocabulary: the pre-labeller named in ADR 006. With caps=True it
    looks for bottle caps only, and each cap counts as one bottle."""

    def __init__(self, caps=False):
        import torch
        from transformers import Owlv2ForObjectDetection, Owlv2Processor

        self.torch, self.caps = torch, caps
        self.name = "owlv2_caps" if caps else "owlv2"
        # a GPU when there is one: about 13x faster on an Apple M5 (MPS), same boxes (scores within 1e-4)
        self.device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        self.proc = Owlv2Processor.from_pretrained(OWL_MODEL)
        self.model = Owlv2ForObjectDetection.from_pretrained(OWL_MODEL).eval().to(self.device)

    def __call__(self, c: Commit) -> Dets:
        from PIL import Image

        h, w = c.image.shape[:2]
        queries = [OWL_CAP_QUERY] if self.caps else [OWL_QUERIES[k] for k in CLASSES]
        inputs = self.proc(text=[queries], images=Image.fromarray(c.image[..., ::-1]),
                           return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            out = self.model(**inputs)
        side = max(h, w)  # OWLv2 pads to a square before resizing, so boxes are relative to that square
        r = self.proc.image_processor.post_process_object_detection(out, threshold=DETECTORS[self.name][0],
                                                                     target_sizes=[(side, side)])[0]
        boxes = np.clip(r["boxes"].cpu().numpy(), 0, [w, h, w, h])
        labels = r["labels"].cpu().numpy()
        cls = np.full(len(labels), "bottle") if self.caps else np.array(CLASSES)[labels]
        return Dets(boxes, r["scores"].cpu().numpy(), cls)


class Oracle:
    """The true boxes of a synthetic video (make_test_video.py), with no detector errors."""

    name = "oracle"

    def __init__(self, truth_path: str):
        t = json.load(open(truth_path))
        self.affine = np.array(t["affine"]).reshape(-1, 2, 3)
        self.box = np.array([o["box"] for o in t["objects"]], dtype=float)
        self.cls = np.array([o["cls"] for o in t["objects"]])

    def __call__(self, c: Commit) -> Dets:
        a = self.affine[c.frame] * c.scale
        x0, y0, x1, y1 = self.box.T
        corners = np.stack([np.stack([x, y], -1) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))], 1)
        p = corners @ a[:, :2].T + a[:, 2]
        b = np.concatenate([p.min(1), p.max(1)], 1)
        h, w = c.image.shape[:2]
        b = np.clip(b, 0, [w, h, w, h])
        seen = (b[:, 2] - b[:, 0] > 2) & (b[:, 3] - b[:, 1] > 2)
        return Dets(b[seen], np.ones(int(seen.sum())), self.cls[seen])


def make_detector(name: str, truth_path: str | None):
    if name == "rfdetr":
        return RFDETR()
    if name == "rfdetr_tiled":
        return RFDETR(tiled=True)
    if name == "owlv2":
        return OWLv2()
    if name == "owlv2_caps":
        return OWLv2(caps=True)
    if name == "rfdetr_ft":
        return RFDETRFineTuned()
    if name == "oracle":
        if not truth_path or not os.path.exists(truth_path):
            raise SystemExit("--detectors oracle needs the synthetic video's .truth.json (make_test_video.py)")
        return Oracle(truth_path)
    raise SystemExit(f"unknown detector {name}; choose from {', '.join(DETECTORS)}")


def view_status(boxes: np.ndarray, w: int, h: int, band_px: float) -> np.ndarray:
    """'cut' if the box touches the image border, else 'inner' if its centre is in the inner frame,
    else 'band': whole, but left for the neighbouring view (FR-14)."""
    m = EDGE * max(w, h)
    x0, y0, x1, y1 = boxes.T
    cut = (x0 <= m) | (y0 <= m) | (x1 >= w - m) | (y1 >= h - m)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    inner = (cx >= band_px) & (cx <= w - band_px) & (cy >= band_px) & (cy <= h - band_px)
    return np.where(cut, "cut", np.where(inner, "inner", "band"))


# ---------------------------------------------------------------------------------------------
# 3. Double counting between commits, in 2D


def quad(x0, y0, x1, y1) -> np.ndarray:
    return np.float32([[x0, y0], [x1, y0], [x1, y1], [x0, y1]]).reshape(-1, 1, 2)


def inside_convex(q: np.ndarray, pts: np.ndarray) -> np.ndarray:
    """Which points lie inside a convex quadrilateral."""
    q = q.reshape(-1, 2)
    e = np.roll(q, -1, 0) - q
    cross = e[None, :, 0] * (pts[:, None, 1] - q[None, :, 1]) - e[None, :, 1] * (pts[:, None, 0] - q[None, :, 0])
    return (cross >= 0).all(1) | (cross <= 0).all(1)


def overlap_area(a: np.ndarray, b: np.ndarray) -> float:
    return cv2.intersectConvexConvex(a.reshape(-1, 2), b.reshape(-1, 2))[0]


class Registration:
    """Planar homographies between commit keyframes (SIFT, ratio test, RANSAC), computed on demand."""

    def __init__(self, images: list):
        sift = cv2.SIFT_create(nfeatures=3000)
        self.feats, self.cache = [], {}
        for img in images:
            s = min(1.0, FEATURE_SIDE / max(img.shape[:2]))
            grey = cv2.cvtColor(cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
            kp, des = sift.detectAndCompute(grey, None)
            self.feats.append((np.float32([k.pt for k in kp]) / s, des))
        self.h, self.w = images[0].shape[:2] if images else (0, 0)
        self.matcher = cv2.FlannBasedMatcher(dict(algorithm=1, trees=4), dict(checks=48))

    def __call__(self, a: int, b: int):
        """(H mapping keyframe a into keyframe b, inliers, overlap fraction of b), or None."""
        if (a, b) not in self.cache:
            self.cache[(a, b)] = self._estimate(a, b)
        return self.cache[(a, b)]

    def linked(self, a: int, b: int) -> bool:
        return self(min(a, b), max(a, b)) is not None

    def _estimate(self, a, b):
        (pa, da), (pb, db) = self.feats[a], self.feats[b]
        if da is None or db is None or len(da) < MIN_INLIERS or len(db) < MIN_INLIERS:
            return None
        good = [m for m, n in (x for x in self.matcher.knnMatch(da, db, k=2) if len(x) == 2)
                if m.distance < 0.75 * n.distance]
        if len(good) < MIN_INLIERS:
            return None
        src = pa[[m.queryIdx for m in good]]
        dst = pb[[m.trainIdx for m in good]]
        H, mask = cv2.findHomography(src, dst, cv2.RANSAC, 0.004 * max(self.h, self.w))
        if H is None or mask.sum() < max(MIN_INLIERS, 0.25 * len(good)):
            return None
        frame = quad(0, 0, self.w, self.h)
        q = cv2.perspectiveTransform(frame, H)
        area = abs(cv2.contourArea(q)) / (self.w * self.h)
        if not cv2.isContourConvex(q) or not 0.2 < area < 5:
            return None  # a fold or an implausible zoom: a bad fit, not a view
        overlap = overlap_area(q, frame) / (self.w * self.h)
        if overlap < 0.03:
            return None
        back = cv2.perspectiveTransform(frame, np.linalg.inv(H))
        shared = min(inside_convex(q, pb).sum(), inside_convex(back, pa).sum())
        return (H, int(mask.sum()), overlap) if mask.sum() >= MIN_COVERAGE * shared else None


def warp_boxes(boxes: np.ndarray, H: np.ndarray) -> np.ndarray:
    if not len(boxes):
        return boxes
    x0, y0, x1, y1 = boxes.T
    p = np.stack([np.stack([x, y], -1) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))], 1)
    p = cv2.perspectiveTransform(p.reshape(-1, 1, 2).astype(np.float64), H).reshape(-1, 4, 2)
    return np.concatenate([p.min(1), p.max(1)], 1)


def centres(b: np.ndarray) -> np.ndarray:
    return np.stack([(b[:, 0] + b[:, 2]) / 2, (b[:, 1] + b[:, 3]) / 2], 1)


def refine(dc, dcls, tc, tcls, size) -> np.ndarray:
    """Common offset of this view's detections against the carried-over items, searched within half
    an item only (ADR 003 step 4). Needs at least 3 and 25% of the detections to agree."""
    lim = GATE * np.median(size, axis=0)
    cands = [np.zeros((1, 2))]
    for c in np.unique(dcls):
        diff = (tc[tcls == c][None] - dc[dcls == c][:, None]).reshape(-1, 2)
        cands.append(diff[(np.abs(diff) <= lim).all(1)])
    cands = np.unique(np.round(np.vstack(cands) / 2) * 2, axis=0)
    support = np.zeros(len(cands))
    for c in np.unique(dcls):
        a, b, sz = dc[dcls == c], tc[tcls == c], size[dcls == c]
        if len(a) and len(b):
            d = (a[None, :, None] + cands[:, None, None] - b[None, None]) / (GATE * sz[None, :, None])
            support += (np.hypot(d[..., 0], d[..., 1]) <= 1).any(2).sum(1)
    best = support.max()
    if best < max(3, 0.25 * len(dc)):
        return np.zeros(2)
    tied = cands[support >= best]
    return tied[np.argmin(np.linalg.norm(tied, axis=1))]


def match(D: Dets, T: np.ndarray, tcls: np.ndarray) -> np.ndarray:
    """Index of the carried-over item each detection is matched to one-to-one, or -1."""
    out = -np.ones(len(D.scores), dtype=int)
    if not len(D.scores) or not len(T):
        return out
    dc, tc = centres(D.boxes), centres(T)
    size = np.stack([D.boxes[:, 2] - D.boxes[:, 0], D.boxes[:, 3] - D.boxes[:, 1]], 1)
    dc = dc + refine(dc, D.cls, tc, tcls, size)
    for c in np.unique(D.cls):
        i, j = np.nonzero(D.cls == c)[0], np.nonzero(tcls == c)[0]
        if not len(j):
            continue
        d = (dc[i, None] - tc[None, j]) / (GATE * size[i, None])
        cost = np.hypot(d[..., 0], d[..., 1])
        r, q = linear_sum_assignment(np.where(cost <= 1, cost, 1e3))
        ok = cost[r, q] <= 1
        out[i[r[ok]]] = j[q[ok]]
    return out


def consistent_links(reg: Registration, k: int, w: int, h: int):
    """Earlier commits registered onto commit k, strongest first. Two of them that share a large part
    of this view (30%: registration normally works there) must also register with each other. If they
    don't, one of them is a look-alike (another rack with the same products): drop the weaker link."""
    frame = quad(0, 0, w, h)
    cands = sorted(((c, *r) for c in range(k) if (r := reg(c, k)) is not None), key=lambda x: -x[2])
    keep, dropped = [], []
    for c, H, inl, ov in cands:
        _, q = cv2.intersectConvexConvex(cv2.perspectiveTransform(frame, H).reshape(-1, 2), frame.reshape(-1, 2))
        clash = next((a for a, _, _, _, qa in keep if overlap_area(q, qa) > 0.3 * w * h and not reg.linked(a, c)), None)
        if clash is None:
            keep.append((c, H, inl, ov, q))
        else:
            dropped.append((c, inl, clash))
    return [x[:4] for x in sorted(keep, key=lambda x: x[0])], dropped


def count_2d(commits: list, dets: list, reg: Registration, thr: float, band_px: float) -> list:
    """Strategy S5 of ADR 003 with homographies in place of ARKit anchors. Returns, per commit, the
    status of every detection: new, seen (already counted), miss (possible miss, never auto-added),
    edge (left for the neighbour view), cut, or low (below the commit threshold)."""
    items = []  # counted items: class and the box of every sighting, by commit index
    out = []
    for k, cm in enumerate(commits):
        d = dets[k]
        h, w = cm.image.shape[:2]
        where = view_status(d.boxes, w, h, band_px)
        status = np.where(d.scores < thr, "low", np.where(where == "cut", "cut", "")).astype("<U4")
        links, rejected = consistent_links(reg, k, w, h)
        zones = [cv2.perspectiveTransform(quad(band_px, band_px, w - band_px, h - band_px), H)
                 for _, H, _, _ in links]
        linked = {c: (H, inl) for c, H, inl, _ in links}
        carried, idx = [], []
        for j, it in enumerate(items):  # carry each counted item through its best-registered sighting
            options = [(linked[c][1], c) for c in it["seen"] if c in linked]
            if options:
                c = max(options)[1]
                carried.append(warp_boxes(it["seen"][c][None], linked[c][0])[0])
                idx.append(j)
        live = np.nonzero(status == "")[0]
        m = match(d.take(live), np.array(carried).reshape(-1, 4), np.array([items[j]["cls"] for j in idx]))
        for di, mi in zip(live, m):
            cx, cy = centres(d.boxes[di:di + 1])[0]
            if mi >= 0:
                status[di] = "seen"
                items[idx[mi]]["seen"][k] = d.boxes[di]
            elif any(cv2.pointPolygonTest(z, (float(cx), float(cy)), False) >= 0 for z in zones):
                status[di] = "miss"
            elif where[di] == "inner":
                status[di] = "new"
                items.append(dict(cls=str(d.cls[di]), seen={k: d.boxes[di]}))
            else:
                status[di] = "edge"
        out.append(dict(status=status, zones=zones, links=[(c, inl, ov) for c, _, inl, ov in links], rejected=rejected,
                        overlap_prev=next((round(ov, 2) for c, _, _, ov in links if c == k - 1), None)))
    return out


def global_motion(flow: np.ndarray, step: int = 16):
    """The frame-to-frame similarity transform that explains most of a dense flow field (RANSAC), as a
    3 x 3 matrix, or None. A similarity, not a homography: chained over seconds, per-frame perspective
    terms blow up."""
    h, w = flow.shape[:2]
    ys, xs = np.mgrid[step // 2:h:step, step // 2:w:step]
    p = np.stack([xs.ravel(), ys.ravel()], 1).astype(np.float32)
    M, mask = cv2.estimateAffinePartial2D(p, p + flow[ys.ravel(), xs.ravel()], method=cv2.RANSAC,
                                          ransacReprojThreshold=1.0)
    return None if M is None or mask.sum() < 0.3 * len(p) else np.vstack([M, [0, 0, 1]])


def box_flow(flow: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Median flow over the central half of a box: the item's own motion, parallax included."""
    h, w = flow.shape[:2]
    cx, cy, bw, bh = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2, b[2] - b[0], b[3] - b[1]
    x0, x1 = int(max(0, cx - bw / 4)), int(min(w, cx + bw / 4 + 1))
    y0, y1 = int(max(0, cy - bh / 4)), int(min(h, cy + bh / 4 + 1))
    return np.median(flow[y0:y1, x0:x1].reshape(-1, 2), axis=0) if x1 > x0 and y1 > y0 else np.zeros(2)


def zone_transform(z: dict, items: list, t: float):
    """Where a counted zone is now, as a 3 x 3 transform from where it was at its commit. A zone lies at
    its items' depth (ADR 003), so the transform is fitted to its own counted items as they are followed
    now; with none of them followed, the frame's global motion carries it for up to DEAD_RECKON_S.
    None: the zone is lost (a registered revisit can still bring it back)."""
    now = [(b, items[j]["box"]) for j, b in zip(z["members"], z["base"]) if items[j]["box"] is not None]
    if len(now) >= 4:  # enough items for rotation and scale; a few close items make them up
        src, dst = (np.float32([centres(x[None])[0] for x in col]) for col in zip(*now))
        size = float(np.median([b[2] - b[0] for b, _ in now]))
        M, _ = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=max(2.0, size / 2))
        if M is not None and 2 / 3 < math.hypot(M[0, 0], M[1, 0]) < 1.5 and abs(math.atan2(M[1, 0], M[0, 0])) < 0.26:
            return np.vstack([M, [0, 0, 1]])
    if now:
        dx, dy = np.median([centres(c[None])[0] - centres(b[None])[0] for b, c in now], axis=0)
        return np.array([[1, 0, dx], [0, 1, dy], [0, 0, 1]])
    return z["A"] if t - z["t"] <= DEAD_RECKON_S else None


def count_tracked(path: str, start: float, end, commits: list, dets: dict, reg: Registration, band_px: float) -> dict:
    """Strategy S5 again, but with counted items carried through the video between commits instead of
    registered between keyframes. This is the 2D stand-in closest to the app, where ARKit tracks the
    camera continuously: frame-to-frame motion is small, so blur and a moving camera don't break it.
      - Dense optical flow moves each counted item in view by the flow inside its own box, so rows at
        different depths keep their own parallax.
      - An item out of view follows the frame's global motion for up to DEAD_RECKON_S, like an anchor
        with no new observation, then only a registered revisit (count_2d's keyframe homographies) can
        bring it back.
      - A counted zone follows its own items (zone_transform).
    One pass over the video serves every detector: returns {detector: per-commit results}, in
    count_2d's format."""
    at = {c.frame: k for k, c in enumerate(commits)}
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_FAST)
    state = {name: dict(items=[], zones=[], out=[]) for name in dets}
    prev = prev_frame = None
    for _, i, t, frame in read_video(path, start, end):
        if i < commits[0].frame:
            continue
        if prev is None:
            s_flow = FLOW_SIDE / max(frame.shape[:2])
        grey = cv2.cvtColor(cv2.resize(frame, None, fx=s_flow, fy=s_flow, interpolation=cv2.INTER_AREA),
                            cv2.COLOR_BGR2GRAY)
        fh, fw = grey.shape
        full = quad(0, 0, fw, fh)
        if prev is not None:
            flow = dis.calc(prev, grey, None)
            G = global_motion(flow)
            if G is not None and prev_frame is not None:
                prev_frame = cv2.perspectiveTransform(prev_frame, G)
            for st in state.values():
                for it in st["items"]:
                    b = it["box"]
                    if b is None:
                        continue
                    if 0 <= (b[0] + b[2]) / 2 < fw and 0 <= (b[1] + b[3]) / 2 < fh:
                        it["box"], it["t"] = b + np.tile(box_flow(flow, b), 2), t
                    elif t - it["t"] > DEAD_RECKON_S:
                        it["box"] = None
                    elif G is not None:
                        it["box"] = warp_boxes(b[None], G)[0]
                for z in st["zones"]:
                    if G is not None:
                        z["A"] = G @ z["A"]
                    if any(st["items"][j]["box"] is not None for j in z["members"]):
                        z["t"] = t
        prev = grey
        if i in at:
            k, cm = at[i], commits[at[i]]
            h, w = cm.image.shape[:2]
            f2k = cm.scale / s_flow  # flow pixels to keyframe pixels
            links, rejected = consistent_links(reg, k, w, h)
            linked = {c: (Hc, inl) for c, Hc, inl, _ in links}
            inner = quad(band_px, band_px, w - band_px, h - band_px)
            overlap_prev = None if prev_frame is None else round(overlap_area(prev_frame, full) / (fw * fh), 2)
            for name, st in state.items():
                d, items = dets[name][k], st["items"]
                where = view_status(d.boxes, w, h, band_px)
                status = np.where(d.scores < DETECTORS[name][1], "low", np.where(where == "cut", "cut", "")).astype("<U4")
                carried, idx, tracked = [], [], 0
                for j, it in enumerate(items):
                    if it["box"] is not None:
                        carried.append(it["box"] * f2k)
                        idx.append(j)
                        tracked += 1
                        continue
                    options = [(linked[c][1], c) for c in it["seen"] if c in linked]
                    if options:
                        c = max(options)[1]
                        carried.append(warp_boxes(it["seen"][c][None], linked[c][0])[0])
                        idx.append(j)
                followed, zones, zones_from = [], [], []
                for z in st["zones"]:
                    T = zone_transform(z, items, t)
                    if T is not None:
                        followed.append(z)
                        zones.append((cv2.perspectiveTransform(z["q0"], T) * f2k).astype(np.float32))
                        zones_from.append(z["k"])
                st["zones"] = followed
                for c, Hc, _, _ in links:
                    if c not in zones_from:
                        zones.append(cv2.perspectiveTransform(inner, Hc))
                        zones_from.append(c)
                live = np.nonzero(status == "")[0]
                m = match(d.take(live), np.array(carried).reshape(-1, 4), np.array([items[j]["cls"] for j in idx]))
                members = []
                for di, mi in zip(live, m):
                    cx, cy = centres(d.boxes[di:di + 1])[0]
                    if mi >= 0:
                        status[di] = "seen"
                        it = items[idx[mi]]
                        it["seen"][k], it["box"], it["t"] = d.boxes[di], d.boxes[di] / f2k, t  # re-observed
                        members.append(idx[mi])
                    elif any(cv2.pointPolygonTest(z, (float(cx), float(cy)), False) >= 0 for z in zones):
                        status[di] = "miss"
                    elif where[di] == "inner":
                        status[di] = "new"
                        items.append(dict(cls=str(d.cls[di]), seen={k: d.boxes[di]}, box=d.boxes[di] / f2k, t=t))
                        members.append(len(items) - 1)
                    else:
                        status[di] = "edge"
                st["zones"].append(dict(k=k, q0=(inner / f2k).astype(np.float32), members=members,
                                        base=[items[j]["box"].copy() for j in members], A=np.eye(3), t=t))
                st["out"].append(dict(status=status, zones=zones, links=[(c, inl, ov) for c, _, inl, ov in links],
                                      rejected=rejected, overlap_prev=overlap_prev, tracked=tracked,
                                      carried=np.array(carried).reshape(-1, 4), zones_from=zones_from))
            prev_frame = full.copy()
            if k == len(commits) - 1:
                break
    return {name: st["out"] for name, st in state.items()}


# ---------------------------------------------------------------------------------------------
# 4. Pictures and report


def dashed_rect(img, p0, p1, colour, width, dash=14):
    (x0, y0), (x1, y1) = p0, p1
    for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        n = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) // dash))
        for s in range(0, n, 2):
            u, v = s / n, min(1, (s + 1) / n)
            cv2.line(img, (int(a[0] + (b[0] - a[0]) * u), int(a[1] + (b[1] - a[1]) * u)),
                     (int(a[0] + (b[0] - a[0]) * v), int(a[1] + (b[1] - a[1]) * v)), colour, width)


def draw(cm: Commit, d: Dets, res: dict, band_px: float, title: str) -> np.ndarray:
    img = cm.image.copy()
    h, w = img.shape[:2]
    lw = max(1, round(max(h, w) / 700))
    tint = img.copy()
    for z in res["zones"]:
        cv2.fillPoly(tint, [z.reshape(-1, 2).astype(np.int32)], GREEN)
    img = cv2.addWeighted(tint, 0.15, img, 0.85, 0)
    fill = img.copy()
    for b, st in zip(d.boxes.astype(int), res["status"]):
        if st in ("new", "seen"):
            cv2.rectangle(fill, tuple(b[:2]), tuple(b[2:]), GREEN, -1)
    img = cv2.addWeighted(fill, 0.4, img, 0.6, 0)
    for b, st in zip(d.boxes.astype(int), res["status"]):
        p0, p1 = tuple(b[:2]), tuple(b[2:])
        if st == "new":
            cv2.rectangle(img, p0, p1, GREEN, 3 * lw)
        elif st == "seen":
            cv2.rectangle(img, p0, p1, GREEN, lw)
        elif st == "miss":
            cv2.rectangle(img, p0, p1, AMBER, 2 * lw)
            c, r = ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2), max(6, (b[2] - b[0]) // 4)
            cv2.line(img, (c[0] - r, c[1]), (c[0] + r, c[1]), AMBER, 3 * lw)
            cv2.line(img, (c[0], c[1] - r), (c[0], c[1] + r), AMBER, 3 * lw)
        elif st == "edge":
            cv2.rectangle(img, p0, p1, YELLOW, lw)
        elif st == "cut":
            cv2.rectangle(img, p0, p1, GREY, lw)
        else:
            dashed_rect(img, p0, p1, YELLOW, lw, dash=8)
    dashed_rect(img, (int(band_px), int(band_px)), (int(w - band_px), int(h - band_px)), WHITE, lw)
    s = min(1.0, 1280 / max(h, w))
    img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    fs = 0.55 if img.shape[1] < 900 else 0.7
    cv2.rectangle(img, (0, 0), (img.shape[1], int(34 * fs / 0.55)), BLACK, -1)
    cv2.putText(img, title, (8, int(24 * fs / 0.55)), cv2.FONT_HERSHEY_SIMPLEX, fs, WHITE, 1, cv2.LINE_AA)
    return img


def contact_sheet(images: list, cols=6, width=300) -> np.ndarray:
    thumbs = [cv2.resize(i, (width, round(i.shape[0] * width / i.shape[1])), interpolation=cv2.INTER_AREA)
              for i in images]
    th = max(t.shape[0] for t in thumbs)
    rows = [thumbs[r:r + cols] for r in range(0, len(thumbs), cols)]
    sheet = np.full((len(rows) * (th + 4), cols * (width + 4), 3), 255, np.uint8)
    for r, row in enumerate(rows):
        for c, t in enumerate(row):
            sheet[r * (th + 4):r * (th + 4) + t.shape[0], c * (width + 4):c * (width + 4) + width] = t
    return sheet


def plot_timeline(track, holds, commits, path, max_speed):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(3, 1, figsize=(12, 5.5), sharex=True, gridspec_kw=dict(height_ratios=[3, 1, 1]))
    t = track["t"]
    ax[0].plot(t, np.clip(track["speed"], 0, 60), lw=0.8, color="#444")
    ax[0].axhline(max_speed, ls="--", lw=0.8, color="#c33")
    for a, b in holds:
        ax[0].axvspan(a, b, color="#3a3", alpha=0.12, lw=0)
    every = max(1, len(commits) // 60)  # keep the labels readable on long walks
    for c in commits:
        ax[0].axvline(c.t, color="#2a2", lw=1.2)
        if c.n % every == 0 or c.n == 1:
            ax[0].text(c.t, 57, str(c.n), fontsize=7, ha="center", va="top")
    ax[0].set_ylabel("view speed (deg/s)")
    ax[0].set_ylim(0, 60)
    ax[0].set_title("Hold-to-count: green lines = commits, shaded = under the speed limit (dashed)", fontsize=9)
    ax[1].plot(t, track["luma"], lw=0.8, color="#a60")
    ax[1].set_ylabel("brightness")
    ax[2].plot(t, track["sharp"], lw=0.8, color="#06a")
    ax[2].set_ylabel("sharpness")
    ax[2].set_xlabel("seconds")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def parse_truth(s: str | None) -> dict:
    if not s:
        return {}
    out = {}
    for part in s.split(","):
        k, v = part.split("=")
        if k.strip() not in CLASSES:
            raise SystemExit(f"--truth: unknown class {k}; use {', '.join(CLASSES)}")
        out[k.strip()] = int(v)
    return out


def pct(a, b):
    return f"{100 * (a - b) / b:+.0f}%" if b else "n/a"


def report(args, video, commits, holds, per, dets, truth, view_truth, out, seconds):
    n, dur, t0 = len(commits), video["seconds"], video["t0"]
    steady = sum(b - a for a, b in holds)
    gaps = np.diff([t0] + [c.t for c in commits] + [t0 + dur])
    steps = np.array([c.step_deg for c in commits[1:] if math.isfinite(c.step_deg)])
    short = min(video["width"], video["height"]) / max(video["width"], video["height"])
    view_short = 2 * math.degrees(math.atan(short * math.tan(math.radians(args.hfov) / 2)))
    rule = (f"Timed commits: the sharpest frame of every {args.every:g} s; hold-to-count is off for this run."
            if args.every else
            f"Sweep commits: one each time the view has advanced {100 * args.sweep:g}% of a frame since the last "
            "keyframe (the sharpest frame of the second half of that advance), "
            + (f"only from frames slower than {args.sweep_speed:g}°/s" if args.sweep_speed else "at any speed")
            + "; hold-to-count is off for this run." if args.sweep else
            f"Commit rule: view under {args.max_speed:g}°/s for {args.hold:g} s; the next commit needs the view to "
            f"move {args.rearm:g}° first."
            + (f" Fallback: a view passed without a hold commits anyway once the view has advanced "
               f"{100 * args.fallback:g}% of a frame since the last keyframe (the sharpest frame of the second half of "
               "that advance" + (f", only from frames slower than {args.sweep_speed:g}°/s" if args.sweep_speed else "")
               + "), flagged \"no hold\"." if args.fallback else ""))
    defaults = dict(hfov=HFOV_DEG, band=BAND)
    flags = "".join(f" --{k} {v:g}" for k, v in (("hfov", args.hfov), ("every", args.every), ("sweep", args.sweep),
                                                  ("fallback", args.fallback), ("sweep-speed", args.sweep_speed),
                                                  ("band", args.band), ("start", args.start), ("end", args.end))
                    if v and v != defaults.get(k)) + (" --carry track" if args.carry == "track" else "")
    L = [f"# Walkthrough replay: `{video['file']}`", "",
         f"Generated {datetime.date.today()} by `python walkthrough.py {os.path.basename(args.video)}"
         f" --detectors {args.detectors}{flags}` in {seconds / 60:.1f} min. "
         "What StockMask's counting loop would have done with this video, minus everything that needs LiDAR or "
         "ARKit (see the end).", "",
         "## Video", "", "| length | size | frame rate | frames | format |", "|---|---|---|---|---|",
         f"| {dur:.0f} s | {video['width']} × {video['height']} | {video['fps']} fps | {video['frames']} | "
         f"{video['codec'] or '?'}{', HDR' if video['hdr'] else ''} |", ""]
    if video["hdr"]:
        L += ["HDR video, read without tone mapping: frames look flatter and darker than on the phone. Fine for "
              "a first look; for accuracy numbers, record with HDR off (Settings → Camera → Record Video).", ""]
    L += ["## Hold-to-count (FR-13)", "",
          f"{rule} Field of view assumed: {args.hfov:g}° across the long side ({view_short:.0f}° across the short "
          "side).", "",
          f"- **{n} commits** in {dur / 60:.1f} min ({n / max(dur / 60, 1e-9):.1f} per minute).",
          f"- Steady (under {args.max_speed:g}°/s) {100 * steady / dur:.0f}% of the time, in {len(holds)} stretches; "
          f"{sum(1 for a, b in holds if b - a >= args.hold)} of them long enough to commit ({args.hold:g} s).",
          f"- Longest time without a commit: {gaps.max():.1f} s. Median time between commits: "
          f"{np.median(gaps[1:-1]) if n > 1 else float('nan'):.1f} s.",
          f"- View moved {np.median(steps):.0f}° between commits (median; p10–p90 {np.percentile(steps, 10):.0f}–"
          f"{np.percentile(steps, 90):.0f}°). ADR 003 assumes about half a view, here about {view_short / 2:.0f}°."
          if len(steps) else "- View step between commits: not enough commits.",
          f"- Keyframe flags: {', '.join(f'{k} ×{v}' for k, v in collections.Counter(f for c in commits for f in c.flags).items()) or 'none'}"
          " (dark: mean grey < 50; blurry: sharpness < 35% of the median commit; glare: > 2% of pixels clipped"
          + ("; no hold: committed by the fallback" if args.fallback else "") + ").",
          "", "![timeline](timeline.png)", ""]
    L += ["## Counts", "",
          "Per detector: the sum of every commit's count (what the app would add with no memory of earlier "
          "commits), then the count after 2D matching between commits (ADR 003 S5, with "
          + ("counted items carried through the video by optical flow standing in for ARKit tracking, and keyframe "
             "homographies for revisits" if args.carry == "track" else "homographies standing in for ARKit anchors")
          + "). Possible misses are detections inside an already counted zone that match nothing: "
          "the app would ask, not add.", "",
          "| detector | class | sum of per-commit counts | after matching | possible misses |"
          + (" truth | error after matching |" if truth else ""),
          "|---|---|---|---|---|" + ("---|---|" if truth else "")]
    for name, rs in per.items():
        for cl in CLASSES:
            if name in ("rfdetr", "rfdetr_tiled", "owlv2_caps") and cl != "bottle":
                continue
            naive = sum(int(((d.cls == cl) & (d.scores >= DETECTORS[name][1])
                             & (view_status(d.boxes, *c.image.shape[1::-1], args.band_px) == "inner")).sum())
                        for c, d in zip(commits, dets[name]))
            new = sum(int(((dets[name][k].cls == cl) & (r["status"] == "new")).sum()) for k, r in enumerate(rs))
            miss = sum(int(((dets[name][k].cls == cl) & (r["status"] == "miss")).sum()) for k, r in enumerate(rs))
            row = f"| {name} | {cl} | {naive} | **{new}** | {miss} |"
            if truth:
                row += f" {truth.get(cl, '–')} | {pct(new, truth[cl]) if cl in truth else '–'} |"
            L.append(row)
    L += ["", "Pictures, one per commit: `commits/<detector>/NNN.jpg`, all together in `contact_<detector>.jpg`. "
          "Green fill = counted in this commit; thin green = already counted; amber + = possible miss; "
          "yellow = whole but in the edge band (left for the next view); grey = cut by the image border; "
          "dashed yellow = below the commit threshold; dashed white = inner frame; green tint = counted zones.", ""]
    if view_truth:
        L += ["## Per-view accuracy (gate G2's metric)", "",
              "Your counts inside the dashed frame of some commits, against each detector's count there (score "
              "at or above the commit threshold, centre inside the frame, not cut).", "",
              "| detector | views | median abs. error | p90 abs. error |", "|---|---|---|---|"]
        for name in per:
            errs = []
            for (cn, cl), true in view_truth.items():
                k = cn - 1
                if 0 <= k < n and true > 0:
                    d = dets[name][k]
                    st = view_status(d.boxes, *commits[k].image.shape[1::-1], args.band_px)
                    got = int(((d.cls == cl) & (st == "inner") & (d.scores >= DETECTORS[name][1])).sum())
                    errs.append(abs(got - true) / true)
            if errs:
                L.append(f"| {name} | {len(errs)} | {100 * np.median(errs):.0f}% | {100 * np.percentile(errs, 90):.0f}% |")
        L.append("")
    L += ["## Per commit", "", "| # | t (s) | flags | overlap with previous | " +
          " | ".join(f"{d}: new / seen / miss" for d in per) + " |", "|---|---|---|---|" + "---|" * len(per)]
    for k, c in enumerate(commits):
        first = next(iter(per.values()))[k]
        ov = f"{100 * first['overlap_prev']:.0f}%" if first["overlap_prev"] is not None else ("–" if k == 0 else "not registered")
        cells = []
        for name, rs in per.items():
            s = collections.Counter(rs[k]["status"].tolist())
            cells.append(f"{s['new']} / {s['seen']} / {s['miss']}")
        L.append(f"| {c.n} | {c.t:.1f} | {', '.join(c.flags)} | {ov} | " + " | ".join(cells) + " |")
    first = next(iter(per.values()))
    far = {k: [c for c, _, _ in r["links"] if commits[k].t - commits[c].t > LONG_GAP_S and k - c > 2]
           for k, r in enumerate(first)}
    far = {k: cs for k, cs in far.items() if cs}
    L += ["", "## Revisits and look-alike shelves", ""]
    if far:
        L += [f"Commits that registered onto a commit more than {LONG_GAP_S:g} s earlier. Each is either the same "
              "shelf seen again (a revisit, or the next band of a snake over the rack: fine, nothing is counted "
              "twice) or a different shelf that looks the same, which would hide real stock: the wrong-rack failure "
              "of ADR 003 and gate G5. Compare the pictures.", "",
              "| commit | earlier commits it registered onto (seconds earlier) |", "|---|---|"]
        L += [f"| {commits[k].n} | " + ", ".join(f"{commits[c].n} ({commits[k].t - commits[c].t:.0f} s)" for c in cs)
              + " |" for k, cs in far.items()]
    else:
        L.append("No commit registered onto one more than "
                 f"{LONG_GAP_S:g} s older: no revisits, or none this method could see.")
    dropped = [(k, c, inl, a) for k, r in enumerate(first) for c, inl, a in r["rejected"]]
    if dropped:
        L += ["", "Registrations rejected as look-alikes: the earlier commit seemed to show part of this view, but "
              "another earlier commit that shows the same part does not match it. Usually the same products on a "
              "different rack. Worth a look: if some are real revisits, the matching was too strict.", "",
              "| commit | rejected earlier commit | matched features | conflicts with commit |", "|---|---|---|---|"]
        L += [f"| {commits[k].n} | {commits[c].n} | {inl} | {commits[a].n} |" for k, c, inl, a in dropped]
    L += ["", "## What this replay cannot tell us", "",
          "- **3D.** No LiDAR depth and no ARKit pose: nothing about glass depth (gate G4) or drift on "
          "revisits (G5). The 2D matching assumes each view shows one flat shelf front; rows at different "
          "depths, deep racks and big viewpoint changes break it.",
          "- **The detector we will ship.** RF-DETR Nano here has COCO weights and knows only `bottle`. "
          "Fine-tuning on our own labelled storeroom images comes first (P0-7, gate G2). OWLv2 is far too slow for "
          "the phone; it is here as the pre-labeller.",
          f"- **Speed, heat, battery on the phone** (G3): this ran on a {platform.system()} {platform.machine()} CPU.",
          "- **How a person holds a phone when the app is guiding them.** The walk was filmed without the app, so "
          "the holds are whatever the camera person did.", "",
          "`cvat/` holds the keyframes and the OWLv2 boxes as COCO pre-labels: correct them in CVAT and they are the "
          "first labelled images for dataset v0 (ADR 006). Blur any faces before they leave this machine."]
    open(os.path.join(out, "report.md"), "w").write("\n".join(L) + "\n")


def write_coco(out: str, commits: list, dets: Dets, lo: float):
    os.makedirs(os.path.join(out, "cvat", "images"), exist_ok=True)
    os.makedirs(os.path.join(out, "cvat", "annotations"), exist_ok=True)
    images, anns = [], []
    for c, d in zip(commits, dets):
        name = f"commit_{c.n:03d}.jpg"
        cv2.imwrite(os.path.join(out, "cvat", "images", name), c.image, [cv2.IMWRITE_JPEG_QUALITY, 92])
        images.append(dict(id=c.n, file_name=name, width=c.image.shape[1], height=c.image.shape[0]))
        for b, s, cl in zip(d.boxes, d.scores, d.cls):
            if s >= lo:
                x, y, w, h = float(b[0]), float(b[1]), float(b[2] - b[0]), float(b[3] - b[1])
                anns.append(dict(id=len(anns) + 1, image_id=c.n, category_id=CLASSES.index(cl) + 1,
                                 bbox=[round(v, 1) for v in (x, y, w, h)], area=round(w * h, 1), iscrowd=0,
                                 score=round(float(s), 3)))
    json.dump(dict(images=images, annotations=anns, categories=[dict(id=i + 1, name=c) for i, c in enumerate(CLASSES)]),
              open(os.path.join(out, "cvat", "annotations", "instances_default.json"), "w"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video")
    ap.add_argument("--out", help="output folder (default: out/<video name>)")
    ap.add_argument("--detectors", default="rfdetr,rfdetr_tiled,owlv2", help=f"comma-separated: {', '.join(DETECTORS)}")
    ap.add_argument("--hfov", type=float, default=HFOV_DEG, help="field of view across the long side, degrees")
    ap.add_argument("--hold", type=float, default=HOLD_S, help="seconds steady before a commit")
    ap.add_argument("--max-speed", type=float, default=MAX_DEG_S, help="steady means slower than this, deg/s")
    ap.add_argument("--rearm", type=float, default=REARM_DEG, help="degrees the view must move between commits")
    ap.add_argument("--every", type=float, help="ignore holds: commit the sharpest frame of every N seconds "
                                                "(for a walk filmed without pausing)")
    ap.add_argument("--sweep", type=float, help="ignore holds: commit each time the view has advanced this fraction "
                                                "of a frame, e.g. 0.5 (for a walk filmed without pausing)")
    ap.add_argument("--sweep-speed", type=float, help="with --sweep or --fallback: only frames slower than this "
                                                      "(deg/s) can be keyframes")
    ap.add_argument("--fallback", type=float, help="with hold-to-count: a view passed without a hold still commits "
                                                   "once the view has advanced this fraction of a frame, e.g. 0.7")
    ap.add_argument("--band", type=float, default=BAND, help="edge band per side, fraction of the short side")
    ap.add_argument("--carry", choices=("homography", "track"), default="homography",
                    help="how counted items reach later commits: keyframe homographies, or tracked through the "
                         "video by optical flow (for close, moving cameras)")
    ap.add_argument("--start", type=float, default=0.0, help="seconds to skip")
    ap.add_argument("--end", type=float, help="stop at this second")
    ap.add_argument("--truth", help="true totals for what the video covers, e.g. bottle=120,can=0,case=8")
    ap.add_argument("--view-truth", help="CSV with columns commit,class,count: true counts inside the dashed "
                                         "frame of some commits")
    args = ap.parse_args()
    if args.every and args.sweep:
        raise SystemExit("--every and --sweep are alternatives: choose one")
    if args.fallback and (args.every or args.sweep):
        raise SystemExit("--fallback backs up hold-to-count: use it without --every and --sweep")
    t0 = time.time()
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out",
                                   os.path.splitext(os.path.basename(args.video))[0])
    os.makedirs(out, exist_ok=True)
    video, commits, holds, track = replay(args.video, args.hfov, args.hold, args.max_speed, args.rearm, args.every,
                                          args.start, args.end, args.sweep, args.sweep_speed, args.fallback)
    print(f"{video['frames']} frames, {video['seconds']:.0f} s: {len(commits)} commits ({time.time() - t0:.0f} s)",
          flush=True)
    plot_timeline(track, holds, commits, os.path.join(out, "timeline.png"), args.max_speed)
    if not commits:
        raise SystemExit("no commits: the view was never steady long enough. Try --max-speed 15 or check --hfov.")
    h, w = commits[0].image.shape[:2]
    args.band_px = args.band * min(h, w)
    names = [s.strip() for s in args.detectors.split(",") if s.strip()]
    truth_path = os.path.splitext(args.video)[0] + ".truth.json"
    dets = {}
    # raw detections per keyframe, reused by later runs over the same video (other triggers, other carry)
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", ".detcache",
                         f"{os.path.splitext(os.path.basename(args.video))[0]}-{os.path.getsize(args.video)}")
    for name in names:
        t1, det, dets[name] = time.time(), None, []
        folder = os.path.join(cache, f"{name}{checkpoint_tag(name)}-{DETECTORS[name][0]:g}")
        if name != "oracle":
            os.makedirs(folder, exist_ok=True)
        for c in commits:
            f = os.path.join(folder, f"{c.frame}.npz")
            if name != "oracle" and os.path.exists(f):
                z = np.load(f)
                d = Dets(z["boxes"], z["scores"], z["cls"])
            else:
                det = det or make_detector(name, truth_path)
                d = det(c)
                if name != "oracle":
                    np.savez(f, boxes=d.boxes, scores=d.scores, cls=d.cls)
            dets[name].append(d if name in ("oracle", "rfdetr_ft") else clean(d))  # rfdetr_ft cleans per class itself
        print(f"{name}: {sum(len(d.scores) for d in dets[name])} boxes ({time.time() - t1:.0f} s)", flush=True)
        del det
    t1 = time.time()
    reg = Registration([c.image for c in commits])
    if args.carry == "track":
        per = count_tracked(args.video, args.start, args.end, commits, dets, reg, args.band_px)
    else:
        per = {name: count_2d(commits, dets[name], reg, DETECTORS[name][1], args.band_px) for name in names}
    print(f"2D matching, carry {args.carry} ({time.time() - t1:.0f} s)", flush=True)
    for name in names:
        os.makedirs(os.path.join(out, "commits", name), exist_ok=True)
        pics = []
        for k, c in enumerate(commits):
            s = collections.Counter(per[name][k]["status"].tolist())
            title = f"#{c.n}  t={c.t:.1f}s  {name}: +{s['new']} new, {s['seen']} seen, {s['miss']} miss" + \
                    (f"  [{', '.join(c.flags)}]" if c.flags else "")
            pic = draw(c, dets[name][k], per[name][k], args.band_px, title)
            cv2.imwrite(os.path.join(out, "commits", name, f"{c.n:03d}.jpg"), pic, [cv2.IMWRITE_JPEG_QUALITY, 85])
            pics.append(pic)
        cv2.imwrite(os.path.join(out, f"contact_{name}.jpg"), contact_sheet(pics), [cv2.IMWRITE_JPEG_QUALITY, 80])
    pre = "owlv2" if "owlv2" in names else names[0]
    write_coco(out, commits, dets[pre], DETECTORS[pre][0])
    view_truth = {}
    if args.view_truth:
        for row in csv.DictReader(open(args.view_truth)):
            view_truth[(int(row["commit"]), row["class"].strip())] = int(row["count"])
    report(args, video, commits, holds, per, dets, parse_truth(args.truth), view_truth, out, time.time() - t0)
    summary = dict(video=video, settings=dict(hfov=args.hfov, hold=args.hold, max_speed=args.max_speed,
                                              rearm=args.rearm, every=args.every, sweep=args.sweep,
                                              sweep_speed=args.sweep_speed, fallback=args.fallback, band=args.band,
                                              carry=args.carry, start=args.start, end=args.end,
                                              detectors=names),
                   holds=[[round(a, 3), round(b, 3)] for a, b in holds],
                   commits=[dict(n=c.n, t=round(c.t, 3), hold_from=round(c.hold_from, 3), frame=c.frame,
                                 t_key=round(c.t_key, 3), step_deg=None if math.isnan(c.step_deg) else round(c.step_deg, 1),
                                 luma=round(c.luma, 1), clipped=round(c.clipped, 4), flags=c.flags,
                                 detections={name: dict(collections.Counter(per[name][k]["status"].tolist()))
                                             for name in names},
                                 overlap_prev=per[names[0]][k]["overlap_prev"],
                                 links=[[commits[a].n, inl, round(ov, 3)] for a, inl, ov in per[names[0]][k]["links"]],
                                 rejected=[[commits[a].n, inl, commits[b].n] for a, inl, b in per[names[0]][k]["rejected"]])
                            for k, c in enumerate(commits)],
                   totals={name: {cl: int(sum(((dets[name][k].cls == cl) & (r["status"] == "new")).sum()
                                              for k, r in enumerate(per[name]))) for cl in CLASSES} for name in names})
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
    print(f"done in {(time.time() - t0) / 60:.1f} min: {os.path.join(out, 'report.md')}")


if __name__ == "__main__":
    main()
