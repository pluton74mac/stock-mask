"""Detection metrics for a fine-tuned RF-DETR checkpoint on labelled frames (P0-7, ADR 006 step 5).

Reports, for one split (test by default: walk 2's hold keyframes):
  - mAP@0.5 and mAP@0.5:0.95, overall and per class (supervision's COCO evaluator, every score);
  - precision and recall per class at the commit threshold (IoU 0.5, one-to-one, highest score first);
  - the per-view count error ADR 006 defines, |predicted - true| / true per frame, for each class and for bottle
    units: bottles plus the tops that have no bottle of their own (common.pair_tops, the counting rule of
    docs/mvp-test-app.md). Gate G2 asks for a median of 3% or less and a p90 of 8% or less, and precision of 98% or
    more at the commit threshold. The counts here cover the whole frame; the app counts only the inner frame (FR-14).
  - the confusion matrix at the commit threshold.
Writes eval_<split>.json next to the checkpoint.

    ml/.venv/bin/python ml/eval.py --run v0
    ml/.venv/bin/python ml/eval.py --run smoke --pseudo --labels ml/data/prelabels/owlv2.json   # pipeline test only

With --pseudo the "truth" is unchecked OWLv2 boxes (the draft a reviewer starts from): the numbers then say whether
the pipeline runs, not how good the model is.
"""

from __future__ import annotations

import argparse
import collections
import os
from pathlib import Path

import numpy as np

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import common  # noqa: E402


def greedy_match(pred: np.ndarray, scores: np.ndarray, true: np.ndarray, iou=0.5) -> int:
    """True positives of one class in one frame: predictions by falling score, each to its best unmatched truth."""
    if not len(pred) or not len(true):
        return 0
    used, tp = set(), 0
    for k in np.argsort(-scores):
        best, arg = iou, None
        for j, t in enumerate(true):
            if j not in used:
                o = common.iou(pred[k], t)
                if o >= best:
                    best, arg = o, j
        if arg is not None:
            used.add(arg)
            tp += 1
    return tp


def pct(values) -> str:
    if not values:
        return "–"
    return f"{100 * np.median(values):.0f}% / {100 * np.percentile(values, 90):.0f}%"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--run", help="run name: ml/data/runs/<run>/checkpoint_best_total.pth")
    ap.add_argument("--checkpoint", help="a checkpoint path instead of --run")
    ap.add_argument("--labels", default=str(common.LABELS))
    ap.add_argument("--pseudo", action="store_true", help="the labels are unchecked OWLv2 pre-labels (smoke test)")
    ap.add_argument("--split", default="test", help="split(s), comma-separated, e.g. test or train,val")
    ap.add_argument("--kinds", default="hold", help="frame kinds to evaluate, e.g. hold or hold,periodic")
    ap.add_argument("--threshold", type=float, default=0.5, help="the commit threshold (FR-18)")
    ap.add_argument("--sweep", action="store_true", help="also print the bottle-unit count error for commit "
                                                        "thresholds 0.2-0.6, to choose one on these frames")
    args = ap.parse_args()
    ckpt = Path(args.checkpoint) if args.checkpoint else common.DATA / "runs" / (args.run or "") / \
        "checkpoint_best_total.pth"
    if not ckpt.exists():
        raise SystemExit(f"no checkpoint at {ckpt}")
    import cv2
    import supervision as sv
    from rfdetr import RFDETR
    from supervision.metrics import MeanAveragePrecision

    coco = common.load_coco(Path(args.labels))
    by_image = common.boxes_by_image(coco)
    kinds = set(args.kinds.split(","))
    images = [im for im in coco["images"] if im["split"] in args.split.split(",") and im.get("kind", "hold") in kinds]
    if not images:
        raise SystemExit(f"no labelled {args.split} frames of kind {args.kinds} in {args.labels}")
    model = RFDETR.from_checkpoint(str(ckpt), trust_checkpoint=True)  # our own training output
    names = list(model.class_names)
    classes = [c for c in common.CLASSES if c in names]
    preds, targets, per_frame = [], [], []
    for im in images:
        boxes = [(c, [b[0], b[1], b[0] + b[2], b[1] + b[3]], s) for c, b, s in by_image[im["id"]]]
        if args.pseudo:
            boxes = common.draft(boxes)[0]
        boxes = [(c, b) for c, b, *_ in boxes if c in classes]
        t = sv.Detections(xyxy=np.array([b for _, b in boxes], dtype=float).reshape(-1, 4),
                          class_id=np.array([classes.index(c) for c, _ in boxes], dtype=int))
        rgb = cv2.imread(str(common.DATA / im["file_name"]))[..., ::-1]
        r = model.predict(np.ascontiguousarray(rgb), threshold=0.01)
        # at very low scores the head's extra (no-object) slot can show up as a class index past the names
        keep = np.array([k < len(names) and names[k] in classes for k in r.class_id], dtype=bool)
        p = sv.Detections(xyxy=r.xyxy[keep], confidence=r.confidence[keep],
                          class_id=np.array([classes.index(names[k]) for k in r.class_id[keep]], dtype=int))
        preds.append(p)
        targets.append(t)
        per_frame.append(im["frame_id"])
    result = MeanAveragePrecision().update(preds, targets).compute()
    ap50 = {classes[c]: float(result.ap_per_class[i, 0]) for i, c in enumerate(result.matched_classes)}
    ap5095 = {classes[c]: float(result.ap_per_class[i].mean()) for i, c in enumerate(result.matched_classes)}
    if args.sweep:  # the commit threshold that counts bottle units best on these frames
        bi, ti = classes.index("bottle"), classes.index("bottle_top")
        print("| commit threshold | bottle units: mean error | median | p90 | signed mean |\n|---|---|---|---|---|")
        for thr in np.arange(0.2, 0.61, 0.05):
            err = []
            for p, t in zip(preds, targets):
                true = common.bottle_units(t.xyxy[t.class_id == bi].tolist(), t.xyxy[t.class_id == ti].tolist())
                q = p[p.confidence >= thr]
                got = common.bottle_units(q.xyxy[q.class_id == bi].tolist(), q.xyxy[q.class_id == ti].tolist())
                if true:
                    err.append((got - true) / true)
            a = np.abs(err)
            print(f"| {thr:.2f} | {a.mean():.0%} | {np.median(a):.0%} | {np.percentile(a, 90):.0%} | {np.mean(err):+.0%} |")
        print()
    tp, npred, ntrue = collections.Counter(), collections.Counter(), collections.Counter()
    errs = collections.defaultdict(list)
    for p, t in zip(preds, targets):
        p = p[p.confidence >= args.threshold]
        for k, c in enumerate(classes):
            pb, tb = p.xyxy[p.class_id == k], t.xyxy[t.class_id == k]
            tp[c] += greedy_match(pb, p.confidence[p.class_id == k], tb)
            npred[c] += len(pb)
            ntrue[c] += len(tb)
            if len(tb):
                errs[c].append(abs(len(pb) - len(tb)) / len(tb))
        bi, ti = classes.index("bottle") if "bottle" in classes else -1, \
            classes.index("bottle_top") if "bottle_top" in classes else -1
        true_units = common.bottle_units(t.xyxy[t.class_id == bi].tolist(), t.xyxy[t.class_id == ti].tolist())
        pred_units = common.bottle_units(p.xyxy[p.class_id == bi].tolist(), p.xyxy[p.class_id == ti].tolist())
        if true_units:
            errs["bottle units"].append(abs(pred_units - true_units) / true_units)
    cm = sv.ConfusionMatrix.from_detections(preds, targets, classes=classes, conf_threshold=args.threshold,
                                            iou_threshold=0.5)
    title = f"{ckpt.parent.name}: {args.split} ({args.kinds}), {len(images)} frames" + \
        (" — truth is unchecked OWLv2 boxes: a pipeline smoke test, not a model result" if args.pseudo else "")
    lines = [f"## {title}", "", f"mAP@0.5 {result.map50:.3f}, mAP@0.5:0.95 {result.map50_95:.3f}", "",
             f"| class | true boxes | AP@0.5 | AP@0.5:0.95 | precision @{args.threshold:g} | recall @{args.threshold:g} | "
             "count error per frame, median / p90 |", "|---|---|---|---|---|---|---|"]
    for c in classes:
        prec = tp[c] / npred[c] if npred[c] else float("nan")
        rec = tp[c] / ntrue[c] if ntrue[c] else float("nan")
        lines.append(f"| {c} | {ntrue[c]} | {ap50.get(c, float('nan')):.3f} | {ap5095.get(c, float('nan')):.3f} | "
                     f"{prec:.2f} | {rec:.2f} | {pct(errs[c])} |")
    lines.append(f"| bottle units | | | | | | {pct(errs['bottle units'])} |")
    lines += ["", "Confusion matrix at the commit threshold (rows: truth, columns: prediction; last: background):", "",
              "| | " + " | ".join(classes + ["background"]) + " |", "|---" * (len(classes) + 2) + "|"]
    for k, row in enumerate(cm.matrix):
        lines.append(f"| {(classes + ['background'])[k]} | " + " | ".join(str(int(v)) for v in row) + " |")
    print("\n".join(lines))
    out = ckpt.parent / f"eval_{args.split.replace(',', '+')}{'_pseudo' if args.pseudo else ''}.json"
    common.save_json(dict(checkpoint=str(ckpt), labels=args.labels, pseudo=args.pseudo, split=args.split,
                          kinds=args.kinds, frames=per_frame, threshold=args.threshold, map50=result.map50,
                          map50_95=result.map50_95, ap50=ap50, ap50_95=ap5095,
                          precision={c: tp[c] / npred[c] if npred[c] else None for c in classes},
                          recall={c: tp[c] / ntrue[c] if ntrue[c] else None for c in classes},
                          count_error_median={c: float(np.median(v)) for c, v in errs.items() if v},
                          count_error_p90={c: float(np.percentile(v, 90)) for c, v in errs.items() if v},
                          confusion=cm.matrix.tolist()), out)
    print(f"\n{out}")


if __name__ == "__main__":
    main()
