"""Two checks behind RESULTS.md, from walkthrough's detection cache: how the counts move with the commit
threshold, and how many counted top boxes sit on a bottle that is also counted whole in the same view.

Runs in the walkthrough venv and imports walkthrough only (no Ultralytics). For one bay it replays the
video, loads every detector's cached detections, and reruns walkthrough's tracked counting (count_tracked)
once, with each detector at several commit thresholds. The shown threshold stays the cache's, so
walkthrough.clean() removes the same boxes at every threshold. Run it after run.py has cached the bay.

    cd research/walkthrough
    venv/bin/python ../yolo_eval/analyse.py w2-bay1 --start 2.4 --truth 82 --json out/w2-bay1-analysis.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "walkthrough"))
import walkthrough as wt  # noqa: E402

from run import cache_folder  # noqa: E402

SWEEP = {  # detector: commit thresholds to try (none below the cache's shown threshold)
    "rfdetr": (0.3, 0.4, 0.5), "rfdetr_tiled": (0.3, 0.4, 0.5), "owlv2": (0.2, 0.3, 0.4),
    "owlv2_caps": (0.15, 0.2, 0.3), "yolo26n": (0.15, 0.25, 0.4), "yolo26s": (0.15, 0.25, 0.4),
    "yolo11n": (0.15, 0.25, 0.4), "yolo11s": (0.15, 0.25, 0.4), "yolo26n_seg": (0.15, 0.25, 0.4),
    "yoloe26s": (0.15, 0.25, 0.4), "yoloworld": (0.15, 0.25, 0.4), "yoloworld_tops": (0.15, 0.2, 0.3),
}
TOPS = ("owlv2_caps", "yoloworld_tops")  # detectors whose boxes should be tops only
TALL = 2.0  # height / width above which a box is a bottle (or most of one), not a top


def load(video: str, commits: list, name: str) -> list:
    folder = os.path.join(cache_folder(video), f"{name}-{wt.DETECTORS[name][0]:g}")
    out = []
    for c in commits:
        f = os.path.join(folder, f"{c.frame}.npz")
        if not os.path.exists(f):
            raise SystemExit(f"{name}: {f} not cached; run walkthrough.py or research/yolo_eval/run.py first")
        z = np.load(f)
        out.append(wt.clean(wt.Dets(z["boxes"], z["scores"], z["cls"])))
    return out


def doubles(d: wt.Dets, status: np.ndarray) -> tuple:
    """Counted boxes in one view: how many are tall (a bottle, not a top), and how many tall ones have a
    counted or already-counted top box inside their upper 40% (the same bottle twice)."""
    b, counted = d.boxes, status == "new"
    w, h = b[:, 2] - b[:, 0], b[:, 3] - b[:, 1]
    tall = counted & (h > TALL * w)
    cx, cy = (b[:, 0] + b[:, 2]) / 2, (b[:, 1] + b[:, 3]) / 2
    top = np.isin(status, ("new", "seen")) & (h <= TALL * w)
    twice = 0
    for i in np.nonzero(tall)[0]:
        inside = top & (cx > b[i, 0]) & (cx < b[i, 2]) & (cy > b[i, 1]) & (cy < b[i, 1] + 0.4 * h[i])
        twice += bool(inside.any())
    return int(counted.sum()), int(tall.sum()), twice


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("bay", help="video stem, e.g. w2-bay1")
    ap.add_argument("--videos", default=os.path.join(os.path.dirname(os.path.abspath(wt.__file__)), "videos"))
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--truth", type=int, help="true bottles in the bay")
    ap.add_argument("--json", help="write the results here")
    a = ap.parse_args()
    video = os.path.join(a.videos, f"{a.bay}.MOV")
    t0 = time.time()
    _, commits, _, _ = wt.replay(video, start=a.start)
    h, w = commits[0].image.shape[:2]
    band_px = wt.BAND * min(h, w)
    dets = {}
    for name, ts in SWEEP.items():
        cleaned = load(video, commits, name)
        for t in ts:
            wt.DETECTORS[f"{name}@{t:g}"] = (wt.DETECTORS[name][0], t)  # this process only
            dets[f"{name}@{t:g}"] = cleaned
    reg = wt.Registration([c.image for c in commits])
    per = wt.count_tracked(video, a.start, None, commits, dets, reg, band_px)
    res = {"bay": a.bay, "truth": a.truth, "commits": len(commits), "sweep": {}, "tops": {}}
    for key, rs in per.items():
        name, t = key.split("@")
        new = sum(int(((dets[key][k].cls == "bottle") & (r["status"] == "new")).sum()) for k, r in enumerate(rs))
        miss = sum(int(((dets[key][k].cls == "bottle") & (r["status"] == "miss")).sum()) for k, r in enumerate(rs))
        res["sweep"].setdefault(name, {})[t] = dict(counted=new, prompts=miss)
        if name in TOPS and float(t) == wt.DETECTORS[name][1]:
            c = np.array([doubles(dets[key][k], r["status"]) for k, r in enumerate(rs)]).sum(0)
            res["tops"][name] = dict(counted=int(c[0]), tall=int(c[1]), tall_with_own_top=int(c[2]))
    print(f"{a.bay}: {len(commits)} commits, truth {a.truth} ({time.time() - t0:.0f} s)")
    for name, row in res["sweep"].items():
        cells = "  ".join(f"@{t}: {v['counted']:3d} ({v['prompts']:3d})" for t, v in row.items())
        print(f"  {name:15s} {cells}")
    for name, v in res["tops"].items():
        print(f"  {name}: {v['counted']} counted, {v['tall']} of them tall boxes (a bottle, not a top), "
              f"{v['tall_with_own_top']} of those with their own top also counted")
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
