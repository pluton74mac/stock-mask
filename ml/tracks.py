"""Link detections through the video, for automatic labelling (autolabel.py).

The walk is filmed continuously, so a box in one sampled frame is predicted in the next one by optical flow: one pass
over the clip computes dense flow between consecutive video frames (DIS, as walkthrough.py's --carry track), and
every live track's box moves by the median flow inside it, so each row keeps its own parallax. At each sampled frame,
that frame's detections are matched to the tracks of the same class (Hungarian, IoU 0.3 or more): a match updates the
track with the detection, a detection left over starts a track, a track left over is "missed" in that frame and keeps
its predicted box. A track ends when its box leaves the frame or it is missed for more than `max_miss` sampled frames
in a row.

Every detection above the teachers' floor is linked, so thresholds can be chosen afterwards per track
(autolabel.py's calibration) without another pass over the video.
"""

from __future__ import annotations

import cv2
import numpy as np
from scipy.optimize import linear_sum_assignment

FLOW_SIDE = 640  # long side of the frames for optical flow, as walkthrough.py


def iou_matrix(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    if not len(a) or not len(b):
        return np.zeros((len(a), len(b)))
    ix = np.clip(np.minimum(a[:, None, 2], b[None, :, 2]) - np.maximum(a[:, None, 0], b[None, :, 0]), 0, None)
    iy = np.clip(np.minimum(a[:, None, 3], b[None, :, 3]) - np.maximum(a[:, None, 1], b[None, :, 1]), 0, None)
    inter = ix * iy
    area = lambda x: (x[:, 2] - x[:, 0]) * (x[:, 3] - x[:, 1])  # noqa: E731
    return inter / np.maximum(area(a)[:, None] + area(b)[None] - inter, 1e-9)


def box_flow(flow: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Median flow over the central half of a box (in flow pixels): the item's own motion, parallax included."""
    h, w = flow.shape[:2]
    cx, cy, bw, bh = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2, b[2] - b[0], b[3] - b[1]
    x0, x1 = int(max(0, cx - bw / 4)), int(min(w, cx + bw / 4 + 1))
    y0, y1 = int(max(0, cy - bh / 4)), int(min(h, cy + bh / 4 + 1))
    if x1 <= x0 or y1 <= y0:
        return np.zeros(2)
    return np.median(flow[y0:y1, x0:x1].reshape(-1, 2), axis=0)


def link(read_video, path: str, samples: list, dets: list, max_miss=3, min_iou=0.3, reset_frames=24) -> list:
    """Tracks over one clip. `samples`: video frame indices of the sampled frames, ascending; `dets[k]`: that frame's
    detections as a list of dicts with box (full-resolution x0, y0, x1, y1), cls and score. Runs of samples more than
    `reset_frames` video frames apart are linked separately. Returns tracks: dicts with cls, obs {sample k: detection
    index}, pred {sample k: predicted box} for the samples where it was missed."""
    at = {f: k for k, f in enumerate(samples)}
    tracks, live = [], []
    prev = None
    first, last = samples[0], samples[-1]
    s = None
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    for _, i, _, frame in read_video(path):
        if i < first:
            continue
        if s is None:
            s = FLOW_SIDE / max(frame.shape[:2])
            H, W = frame.shape[:2]
        grey = cv2.cvtColor(cv2.resize(frame, None, fx=s, fy=s, interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        if prev is not None and live:
            flow = dis.calc(prev, grey, None)
            for t in live:
                t["box"] = t["box"] + np.tile(box_flow(flow, t["box"] * s), 2) / s
            live = [t for t in live if 0 <= (t["box"][0] + t["box"][2]) / 2 < W and 0 <= (t["box"][1] + t["box"][3]) / 2 < H]
        prev = grey
        if i in at:
            k = at[i]
            if k > 0 and samples[k] - samples[k - 1] > reset_frames:
                live = []  # a new stretch of the clip
            d = dets[k]
            used = set()
            for c in {x["cls"] for x in d} | {t["cls"] for t in live}:
                di = [j for j, x in enumerate(d) if x["cls"] == c]
                ti = [t for t in live if t["cls"] == c]
                if di and ti:
                    m = iou_matrix(np.array([t["box"] for t in ti]), np.array([d[j]["box"] for j in di]))
                    r, q = linear_sum_assignment(-m)
                    for a, b in zip(r, q):
                        if m[a, b] >= min_iou:
                            t = ti[a]
                            t["obs"][k] = di[b]
                            t["box"] = np.array(d[di[b]]["box"], float)
                            t["last"] = k
                            used.add(di[b])
            for j, x in enumerate(d):
                if j not in used:
                    t = dict(cls=x["cls"], obs={k: j}, pred={}, box=np.array(x["box"], float), last=k)
                    tracks.append(t)
                    live.append(t)
            for t in live:
                if t["last"] != k:
                    t["pred"][k] = t["box"].copy()
            live = [t for t in live if k - t["last"] <= max_miss]
        if i >= last:
            break
    for t in tracks:
        t.pop("box", None)
        t.pop("last", None)
    return tracks


def frame_labels(tracks: list, dets: list, keep, gap=2, width=None, height=None, margin=4) -> list:
    """Per sample, the labels the tracks give. `keep(track, detection)` decides each observation on its own score
    (the teachers' false boxes are as steady through the video as their true ones, so a track-level score separates
    them no better). Between two kept observations of a track at most `gap` samples apart, the samples in between
    are labelled too: with the track's own detection there if it had one too weak to keep, else with its box carried
    by optical flow, if that lies inside the frame. Returns per sample a list of (box, cls, score, filled)."""
    out = [[] for _ in dets]
    for t in tracks:
        kept = [k for k in sorted(t["obs"]) if keep(t, dets[k][t["obs"][k]])]
        for k in kept:
            x = dets[k][t["obs"][k]]
            out[k].append((list(x["box"]), t["cls"], x["score"], False))
        if gap <= 0:
            continue
        for a, b in zip(kept, kept[1:]):
            if 1 < b - a <= gap + 1:
                for k in range(a + 1, b):
                    if k in t["obs"]:  # seen here, but too weak on its own: the frames either side vouch for it
                        x = dets[k][t["obs"][k]]
                        out[k].append((list(x["box"]), t["cls"], x["score"], True))
                        continue
                    p = t["pred"].get(k)
                    if p is None or (width is not None and (p[0] < margin or p[1] < margin or p[2] > width - margin
                                                            or p[3] > height - margin)):
                        continue
                    s = min(dets[a][t["obs"][a]]["score"], dets[b][t["obs"][b]]["score"])
                    out[k].append((list(map(float, p)), t["cls"], s, True))
    return out


def track_stats(t: dict, dets: list) -> dict:
    """n observations, the samples spanned, and the mean of the best three observation scores."""
    ks = sorted(t["obs"])
    scores = sorted((dets[k][t["obs"][k]]["score"] for k in ks), reverse=True)
    span = ks[-1] - ks[0] + 1
    return dict(n=len(ks), span=span, ratio=len(ks) / span, top=float(np.mean(scores[:3])), best=float(scores[0]),
                agree=float(np.mean([dets[k][t["obs"][k]].get("n", 1) for k in ks])))
