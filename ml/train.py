"""Fine-tune RF-DETR Nano on dataset v0 (P0-7, ADR 002, ADR 006).

Input: COCO labels whose images carry frame_id and split (train, val, test), as written by review.py export (the
reviewed labels) or prelabel.py (unchecked OWLv2 boxes, only for --pseudo smoke tests). The classes are those of
docs/mvp-test-app.md: bottle, can, case, bottle_top; parked labels (carton, bag) are dropped, so they train as
background.

Steps: build an rfdetr dataset (Roboflow COCO layout, images symlinked) in ml/data/datasets/<name>/, train RF-DETR
Nano from its COCO checkpoint with `rfdetr`, and write ml/data/runs/<name>/ (checkpoints, logs, run.json).
The checkpoint for walkthrough.py's rfdetr_ft detector and for eval.py is checkpoint_best_total.pth.

Device: MPS when it works, else CPU (--device auto); run.json records which. On an Apple M5 (torch 2.7.0, rfdetr
1.11.0) MPS trains in full fp32 at about a minute per epoch of ~100 frames, against 2.4 minutes on the CPU. Mixed
precision is used on CUDA only: on MPS, torch 2.7's fp16 GradScaler converts to float64, which MPS doesn't support.
PYTORCH_ENABLE_MPS_FALLBACK=1 lets any op MPS lacks run on the CPU.

    ml/.venv/bin/python ml/train.py --name v0 --epochs 60
    ml/.venv/bin/python ml/train.py --name smoke --pseudo --epochs 10     # unchecked OWLv2 boxes: pipeline test only
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import common  # noqa: E402

SPLITS = {"train": "train", "val": "valid", "test": "test"}  # our split -> rfdetr's folder


def load_labels(path: Path, pseudo: bool) -> tuple[list, dict]:
    """(images, frame_id -> [(class, [x0, y0, x1, y1])]). Pseudo labels keep only the draft a reviewer would start
    from (common.draft)."""
    coco = common.load_coco(path)
    by_image = common.boxes_by_image(coco)
    boxes = {}
    for im in coco["images"]:
        bs = [(c, [b[0], b[1], b[0] + b[2], b[1] + b[3]], s) for c, b, s in by_image[im["id"]]]
        if pseudo:
            bs = common.draft(bs)[0]
        boxes[im["frame_id"]] = [(c, b) for c, b, _ in bs]
    return coco["images"], boxes


def build_dataset(images: list, boxes: dict, classes: list, out: Path) -> dict:
    """rfdetr's Roboflow COCO layout: out/{train,valid,test}/_annotations.coco.json with the images symlinked
    next to it. Category ids 1..K in `classes` order, flat, so every class keeps its output slot."""
    counts = {}
    for split, folder in SPLITS.items():
        d = out / folder
        d.mkdir(parents=True, exist_ok=True)
        for f in d.iterdir():
            f.unlink()
        ims, anns = [], []
        for im in (i for i in images if i["split"] == split):
            name = f"{im['frame_id']}.jpg"
            os.symlink(common.DATA / im["file_name"], d / name)
            image_id = len(ims) + 1
            ims.append(dict(id=image_id, file_name=name, width=im["width"], height=im["height"]))
            for c, (x0, y0, x1, y1) in boxes[im["frame_id"]]:
                if c not in classes:
                    continue
                anns.append(dict(id=len(anns) + 1, image_id=image_id, category_id=classes.index(c) + 1,
                                 bbox=[x0, y0, x1 - x0, y1 - y0], area=(x1 - x0) * (y1 - y0), iscrowd=0))
        cats = [dict(id=k + 1, name=c, supercategory="none") for k, c in enumerate(classes)]
        common.save_json(dict(images=ims, annotations=anns, categories=cats), d / "_annotations.coco.json")
        per = collections.Counter(classes[a["category_id"] - 1] for a in anns)
        counts[split] = dict(images=len(ims), boxes=len(anns), **{c: per[c] for c in classes})
    return counts


def git_commit() -> str:
    try:
        return subprocess.run(["git", "-C", str(common.REPO), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True).stdout.strip()
    except OSError:
        return ""


def train(dataset: Path, out: Path, device: str, args) -> None:
    from rfdetr import RFDETRNano

    model = RFDETRNano()
    model.train(dataset_dir=str(dataset), output_dir=str(out), device=device, epochs=args.epochs,
                batch_size=args.batch, grad_accum_steps=args.accum, lr=args.lr, num_workers=args.workers,
                resolution=args.resolution, tensorboard=False, progress_bar=None, checkpoint_interval=max(1, args.epochs),
                amp_dtype="auto" if device == "cuda" and not args.fp32 else None, early_stopping=args.patience > 0,
                early_stopping_patience=max(1, args.patience))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--labels", default=str(common.LABELS), help="COCO labels with frame_id and split per image")
    ap.add_argument("--pseudo", action="store_true", help="the labels are unchecked OWLv2 pre-labels: keep the draft "
                                                          "boxes only (a pipeline smoke test, not a model)")
    ap.add_argument("--name", required=True, help="dataset and run name")
    ap.add_argument("--classes", default=",".join(common.CLASSES))
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--accum", type=int, default=4, help="gradient accumulation: effective batch = batch x accum")
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--resolution", type=int, default=384, help="square input; 384 is Nano's, the latency ADR 002 "
                                                                "quotes. A multiple of 32")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--patience", type=int, default=0, help="early stopping after this many epochs without a better "
                                                             "val mAP (0: off)")
    ap.add_argument("--device", default="auto", choices=("auto", "mps", "cpu", "cuda"))
    ap.add_argument("--fp32", action="store_true", help="no mixed precision on CUDA either (MPS and CPU are always fp32)")
    args = ap.parse_args()
    if args.resolution % 32:
        raise SystemExit("--resolution must be a multiple of 32 (patch 16 x 2 windows)")
    classes = [c.strip() for c in args.classes.split(",") if c.strip()]
    if not Path(args.labels).exists():
        raise SystemExit(f"no labels at {args.labels}: run `ml/review.py export` (or pass --pseudo with --labels "
                         f"{common.PRELABELS})")
    images, boxes = load_labels(Path(args.labels), args.pseudo)
    dataset = common.DATA / "datasets" / args.name
    counts = build_dataset(images, boxes, classes, dataset)
    print(json.dumps(counts))
    if not counts["train"]["images"] or not counts["val"]["images"]:
        raise SystemExit("need train and val images")
    out = common.DATA / "runs" / args.name
    out.mkdir(parents=True, exist_ok=True)
    import torch

    tried, used, t0, error = [], None, time.time(), None
    order = {"auto": ["mps", "cpu"] if torch.backends.mps.is_available() else ["cpu"]}.get(args.device, [args.device])
    for device in order:
        tried.append(device)
        try:
            train(dataset, out, device, args)
            used = device
            break
        except (RuntimeError, NotImplementedError, TypeError, ValueError) as e:  # an op or dtype MPS can't run
            error = f"{type(e).__name__}: {e}"
            print(f"training on {device} failed: {error}", file=sys.stderr)
            if device == order[-1]:
                raise
    run = dict(name=args.name, created=datetime.datetime.now().isoformat(timespec="seconds"), commit=git_commit(),
               labels=str(args.labels), pseudo=args.pseudo, classes=classes, counts=counts, device=used, tried=tried,
               first_error=error if len(tried) > 1 else None, minutes=round((time.time() - t0) / 60, 1),
               settings=dict(epochs=args.epochs, batch=args.batch, accum=args.accum, lr=args.lr,
                             resolution=args.resolution, fp32=args.fp32, patience=args.patience),
               checkpoint=str(out / "checkpoint_best_total.pth"))
    common.save_json(run, out / "run.json")
    print(json.dumps(run, indent=1))


if __name__ == "__main__":
    main()
