"""OWLv2 pre-labels for the training frames, as COCO JSON (ADR 006 step 2).

One OWLv2 pass per frame with four prompts: "a photo of a bottle", "a photo of a beverage can" and "a photo of a
cardboard box" (walkthrough.py's owlv2 detector, classes bottle, can, case) plus "a photo of a bottle cap" (its
owlv2_caps detector, class bottle_top). The image is encoded once; the logits are post-processed per group exactly
as the two walkthrough detectors do (max over the group's prompts, sigmoid, threshold), in about half the time of two
passes.

Each group is then cleaned like walkthrough.clean() (non-maximum suppression, then boxes drawn around a whole row,
then boxes around part of an object), with one change: a box counts as a row only if the boxes inside it are at least
60% of its height, i.e. whole objects side by side. walkthrough.clean() also drops a front bottle whose box holds the
short neck and cap boxes of the bottles behind it: in the labelling pilot a front bottle had no draft box in 9 of 14
frames, and in the 5 checked OWLv2 had found it before clean() (ml/LABELING.md). With this rule the draft's bottle
recall against the reviewed pilot frames went from 0.73 to 0.92.

Every box above the replay's "shown" threshold is kept with its score (bottle, can, case 0.2; bottle_top 0.15).
common.draft() picks the boxes a reviewer starts from.

Writes ml/data/prelabels/owlv2.json (COCO: images carry frame_id, clip, t, split and kind from the manifest;
annotations carry score). Per-frame results are cached in ml/data/prelabels/cache/, so an interrupted run resumes.

    ml/.venv/bin/python ml/prelabel.py [--split test] [--limit 5]

About 5 s per frame on an Apple M5 (MPS); 192 frames take about 15 minutes.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np

import common


def clean(wt, d, iou=0.5):
    """walkthrough.clean(), except that a row box must hold boxes of at least 60% of its height (whole objects side
    by side), so a front bottle that holds the necks and caps of the bottles behind it survives."""
    order, keep = np.argsort(-d.scores), []
    while len(order):
        keep.append(order[0])
        order = order[1:][wt.box_iou(d.boxes[order[:1]], d.boxes[order[1:]])[0] < iou]
    d = d.take(np.array(keep, dtype=int))
    b, n = d.boxes, len(d.scores)
    area = (b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])
    height = b[:, 3] - b[:, 1]
    cx, cy = (b[:, 0] + b[:, 2]) / 2, (b[:, 1] + b[:, 3]) / 2
    ok = np.ones(n, dtype=bool)
    for i in range(n):
        inside = (d.cls == d.cls[i]) & (cx > b[i, 0]) & (cx < b[i, 2]) & (cy > b[i, 1]) & (cy < b[i, 3]) \
            & (area < 0.6 * area[i]) & (height >= 0.6 * height[i])
        if inside.sum() >= 2 and area[inside].sum() > 0.5 * area[i]:
            ok[i] = False  # a row or a stack of whole objects, not an item
    for i in np.argsort(area):
        big = ok & (d.cls == d.cls[i]) & (area > area[i]) & (d.scores >= d.scores[i])
        if ok[i] and big.any():
            ix = np.clip(np.minimum(b[big, 2], b[i, 2]) - np.maximum(b[big, 0], b[i, 0]), 0, None)
            iy = np.clip(np.minimum(b[big, 3], b[i, 3]) - np.maximum(b[big, 1], b[i, 1]), 0, None)
            ok[i] = not (ix * iy / area[i] > 0.8).any()
    return d.take(ok)


def detector(wt):
    """walkthrough.OWLv2's processor and model on the GPU, and a function frame -> {class: (boxes, scores)}."""
    import torch
    from PIL import Image

    owl = wt.OWLv2()
    queries = [wt.OWL_QUERIES[c] for c in wt.CLASSES] + [wt.OWL_CAP_QUERY]
    groups = [(("bottle", "can", "case"), [0, 1, 2], wt.DETECTORS["owlv2"][0]),
              (("bottle_top",), [3], wt.DETECTORS["owlv2_caps"][0])]

    def run(bgr: np.ndarray) -> list:
        h, w = bgr.shape[:2]
        inputs = owl.proc(text=[queries], images=Image.fromarray(bgr[..., ::-1]), return_tensors="pt").to(owl.device)
        with torch.no_grad():
            out = owl.model(**inputs)
        logits, boxes = out.logits[0].float().cpu(), out.pred_boxes[0].float().cpu()
        side = max(h, w)  # OWLv2 pads to a square: boxes are relative to it
        cx, cy, bw, bh = boxes.unbind(-1)
        xyxy = (torch.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], -1) * side).numpy()
        found = []
        for names, cols, thr in groups:
            best = logits[:, cols].max(-1)
            score = torch.sigmoid(best.values).numpy()
            keep = score > thr
            d = wt.Dets(np.clip(xyxy[keep], 0, [w, h, w, h]), score[keep],
                        np.array(names, dtype="<U10")[best.indices.numpy()[keep]])
            found.append(clean(wt, d))
        return found

    return run


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--split", help="only frames of this split (train, val, test)")
    ap.add_argument("--clip", help="only frames of this clip")
    ap.add_argument("--limit", type=int, help="at most this many frames")
    ap.add_argument("--out", default=str(common.PRELABELS))
    args = ap.parse_args()
    import cv2

    rows = [r for r in common.read_manifest() if (not args.split or r["split"] == args.split)
            and (not args.clip or r["clip"] == args.clip)][:args.limit]
    cache = Path(args.out).parent / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    wt = common.walkthrough()
    run, t0, done = None, time.time(), 0
    images, anns = [], []
    for n, r in enumerate(rows, 1):
        f = cache / f"{r['frame_id']}.npz"
        if not f.exists():
            run = run or detector(wt)
            parts = run(cv2.imread(str(common.DATA / r["file"])))
            d = wt.Dets.cat(parts)
            np.savez(f, boxes=d.boxes, scores=d.scores, cls=d.cls.astype("<U10"))
            done += 1
            if done % 10 == 0:
                print(f"{n}/{len(rows)} frames, {(time.time() - t0) / done:.1f} s per frame", flush=True)
        z = np.load(f)
        image_id = len(images) + 1
        images.append(dict(id=image_id, file_name=r["file"], width=r["width"], height=r["height"],
                           frame_id=r["frame_id"], clip=r["clip"], t=r["t"], split=r["split"], kind=r["kind"]))
        for b, s, c in zip(z["boxes"], z["scores"], z["cls"]):
            x0, y0, x1, y1 = (float(v) for v in b)
            anns.append(dict(id=len(anns) + 1, image_id=image_id, category_id=common.ALL_LABELS.index(str(c)) + 1,
                             bbox=[round(x0, 1), round(y0, 1), round(x1 - x0, 1), round(y1 - y0, 1)],
                             area=round((x1 - x0) * (y1 - y0), 1), iscrowd=0, score=round(float(s), 4)))
    common.save_json(dict(info=dict(description="OWLv2 pre-labels, unchecked", model="google/owlv2-base-patch16-"
                                    "ensemble"), images=images, annotations=anns,
                          categories=common.categories(common.CLASSES)), Path(args.out))
    per = {c: sum(1 for a in anns if a["category_id"] == i + 1) for i, c in enumerate(common.CLASSES)}
    print(f"{len(images)} frames, {len(anns)} boxes ({per}); {done} frames run in {(time.time() - t0) / 60:.1f} min: "
          f"{args.out}")


if __name__ == "__main__":
    main()
