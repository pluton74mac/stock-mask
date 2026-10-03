"""Count every object of a synthetic video exactly: how many times each one was counted, per commit
trigger and per carry method.

make_test_video.py --check proves hold-to-count against the scripted holds. The alternative triggers
(--every, --sweep, and the extra commits of --fallback) fire at other moments, so this check follows
object identities instead: the oracle detector returns the true boxes, so each counted item maps back
to the object it came from.
Each trigger runs with both ways of carrying counted items to later commits: keyframe homographies
(count_2d) and optical-flow tracking (count_tracked, --carry track).

    python make_test_video.py out/synth.mp4
    python check_sweep.py out/synth.mp4 [--carry homography,track]
"""

from __future__ import annotations

import argparse
import collections
import json
import os

import numpy as np

import walkthrough as wt


def run(video: str, carry: str, **trigger) -> dict:
    _, commits, _, _ = wt.replay(video, **trigger)
    oracle = wt.Oracle(os.path.splitext(video)[0] + ".truth.json")
    h, w = commits[0].image.shape[:2]
    band_px = wt.BAND * min(h, w)
    dets, ids = [], []
    for c in commits:  # the oracle keeps the objects that are visible, in truth order: remember which
        a = oracle.affine[c.frame] * c.scale
        x0, y0, x1, y1 = oracle.box.T
        corners = np.stack([np.stack([x, y], -1) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))], 1)
        p = corners @ a[:, :2].T + a[:, 2]
        b = np.clip(np.concatenate([p.min(1), p.max(1)], 1), 0, [w, h, w, h])
        ids.append(np.nonzero((b[:, 2] - b[:, 0] > 2) & (b[:, 3] - b[:, 1] > 2))[0])
        dets.append(oracle(c))
    reg = wt.Registration([c.image for c in commits])
    if carry == "track":
        per = wt.count_tracked(video, 0.0, None, commits, {"oracle": dets}, reg, band_px)["oracle"]
    else:
        per = wt.count_2d(commits, dets, reg, wt.DETECTORS["oracle"][1], band_px)
    counted = collections.Counter(int(ids[k][j]) for k, r in enumerate(per) for j in np.nonzero(r["status"] == "new")[0])
    prompts = sum(int((r["status"] == "miss").sum()) for r in per)
    n = len(oracle.cls)
    times = collections.Counter(counted.get(o, 0) for o in range(n))
    return dict(commits=len(commits), objects=n, once=times[1], twice_or_more=sum(v for k, v in times.items() if k >= 2),
                never=times[0], extra_counts=sum(max(0, counted.get(o, 0) - 1) for o in range(n)), prompts=prompts)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video", help="a synthetic video from make_test_video.py (with its .truth.json)")
    ap.add_argument("--carry", default="homography,track", help="comma-separated: homography, track")
    args = ap.parse_args()
    runs = {"hold-to-count": {}, "every 2 s": dict(every=2.0), "sweep 0.5": dict(sweep=0.5),
            "sweep 0.5, keyframes < 20°/s": dict(sweep=0.5, sweep_speed=20.0),
            "sweep 0.5, keyframes < 30°/s": dict(sweep=0.5, sweep_speed=30.0),
            "hold-to-count, fallback 0.7 < 30°/s": dict(fallback=0.7, sweep_speed=30.0)}
    print("| trigger | carry | commits | counted once | counted twice or more | never counted | possible-miss prompts |")
    print("|---|---|---|---|---|---|---|")
    out = {}
    for name, trigger in runs.items():
        for carry in args.carry.split(","):
            r = out[f"{name} / {carry}"] = run(args.video, carry, **trigger)
            print(f"| {name} | {carry} | {r['commits']} | {r['once']} | {r['twice_or_more']} (+{r['extra_counts']}) | "
                  f"{r['never']} | {r['prompts']} |", flush=True)
    json.dump(out, open(os.path.splitext(args.video)[0] + ".triggers.json", "w"), indent=1)


if __name__ == "__main__":
    main()
