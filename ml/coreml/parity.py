"""Core ML vs PyTorch parity for the StockMask detector (ADR 002: "compare Core ML output with
PyTorch output ... fail the build if the counts differ").

For a few frames of a video it runs:
- **the reference:** rfdetr's own `predict()` on the full frame (its resize and normalisation);
- **the same model in PyTorch on the 8-bit input Core ML gets** (the frame resized as `predict()`
  resizes it, then rounded to 8 bits): what part of any gap is only the 8-bit input;
- **the exported package through coremltools, on each compute unit**, decoded exactly as the app
  decodes it (`DETRDecoder.swift`: sigmoid, top-300 query/class pairs, cx cy w h -> corners).
  `CoreMLDetector` defaults to CPU + GPU, which decides pass or fail here. The app on the phone
  asks for the Neural Engine for now, which drifts on a Mac (see RESULTS.md). With `--fp32-model`,
  also an FP32 export on the CPU, which checks the conversion.

Boxes are paired 1:1 by IoU (Hungarian, IoU >= 0.5, all boxes shown at >= 0.3). A run fails when
a detection at >= 0.55 has no partner, or a pair has one score >= 0.55 and the other < 0.5 (the
commit threshold is 0.5; scores within 0.05 of it may cross it on any rounding). The same pairing,
within each class, gives the agreement per class.

It also writes, for the Swift test (CoreMLDetectorTests), each frame as a lossless PNG plus a JSON
of the reference boxes. Frames come from venue footage, so everything goes to the git-ignored
`out/parity/`. The clip's metadata (including GPS) is never read: frames are decoded with OpenCV.

    python parity.py VIDEO [VIDEO ...] [--model out/StockMaskDetector.mlpackage] [--fp32-model PATH] [--frames 6]
    python parity.py VIDEO --weights ckpt.pth --model out/StockMaskDetector-x.mlpackage   # a fine-tuned model
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import cv2
import numpy as np
import torch
import torchvision.transforms.functional as F
from scipy.optimize import linear_sum_assignment

HERE = os.path.dirname(os.path.abspath(__file__))
COMMIT, SHOWN, BORDER = 0.5, 0.3, 0.05
OURS = ("bottle", "can", "case", "bottle_top", "carton", "bag")  # ObjectClass in StockMaskCounting


def pick_frames(video: str, n: int) -> list[tuple[float, np.ndarray]]:
    """n frames spread over 10-90% of the clip; each the sharpest within +-0.5 s (holds, not blur)."""
    cap = cv2.VideoCapture(video)
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)  # upright, as the phone showed it
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    centres = [int(count * (0.1 + 0.8 * i / max(n - 1, 1))) for i in range(n)]
    half = int(fps * 0.5)
    wanted = {c: range(max(c - half, 0), min(c + half, count - 1) + 1) for c in centres}
    last = max(r.stop for r in wanted.values())
    best: dict[int, tuple[float, int, np.ndarray]] = {}
    i = -1
    while i < last:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        for c, r in wanted.items():
            if i in r:
                grey = cv2.cvtColor(cv2.resize(frame, None, fx=0.5, fy=0.5), cv2.COLOR_BGR2GRAY)
                sharp = cv2.Laplacian(grey, cv2.CV_64F).var()
                if c not in best or sharp > best[c][0]:
                    best[c] = (sharp, i, frame.copy())
    cap.release()
    return [(best[c][1] / fps, cv2.cvtColor(best[c][2], cv2.COLOR_BGR2RGB)) for c in centres if c in best]


def decode(boxes: np.ndarray, logits: np.ndarray, classes: list[str], threshold: float, num_select: int):
    """The app's decoder (DETRDecoder.swift) in numpy: scores are sigmoid(logits); the top
    `num_select` query/class pairs by score (ties: lower flat index first), kept if score >
    threshold; cx cy w h -> x0 y0 x1 y1, clamped to [0, 1]. Returns (boxes, scores, labels)."""
    _, c = logits.shape
    flat = (1 / (1 + np.exp(-logits.astype(np.float64)))).reshape(-1)
    order = np.lexsort((np.arange(flat.size), -flat))[:num_select]
    order = order[flat[order] > threshold]
    qi, ci = order // c, order % c
    cx, cy, w, h = boxes[qi].astype(np.float64).T
    xyxy = np.clip(np.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], 1), 0, 1)
    return xyxy, flat[order], [classes[k] for k in ci]


def ours(boxes, scores, labels):
    keep = [i for i, c in enumerate(labels) if c in OURS]
    return boxes[keep], scores[keep], [labels[i] for i in keep]


def iou(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    x0 = np.maximum(a[:, None, 0], b[None, :, 0]); y0 = np.maximum(a[:, None, 1], b[None, :, 1])
    x1 = np.minimum(a[:, None, 2], b[None, :, 2]); y1 = np.minimum(a[:, None, 3], b[None, :, 3])
    inter = np.clip(x1 - x0, 0, None) * np.clip(y1 - y0, 0, None)
    area = lambda z: (z[:, 2] - z[:, 0]) * (z[:, 3] - z[:, 1])
    return inter / (area(a)[:, None] + area(b)[None, :] - inter + 1e-12)


def compare(ta, ts, ca, cs) -> dict:
    """Pair boxes 1:1 by IoU and report what differs, ignoring borderline scores."""
    pairs = []
    if len(ta) and len(ca):
        m = iou(ta, ca)
        r, c = linear_sum_assignment(-m)
        pairs = [(i, j, float(m[i, j])) for i, j in zip(r, c) if m[i, j] >= 0.5]
    pi, pj = {p[0] for p in pairs}, {p[1] for p in pairs}
    lone = [float(ts[i]) for i in range(len(ta)) if i not in pi] + [float(cs[j]) for j in range(len(ca)) if j not in pj]
    flipped = [(float(ts[i]), float(cs[j])) for i, j, _ in pairs
               if (ts[i] >= COMMIT + BORDER and cs[j] < COMMIT) or (cs[j] >= COMMIT + BORDER and ts[i] < COMMIT)]
    hard = [s for s in lone if s >= COMMIT + BORDER]
    return dict(reference=int((ts >= COMMIT).sum()), candidate=int((cs >= COMMIT).sum()), pairs=len(pairs),
                mean_iou=float(np.mean([p[2] for p in pairs])) if pairs else 1.0,
                min_iou=float(np.min([p[2] for p in pairs])) if pairs else 1.0,
                max_dscore=float(max((abs(ts[i] - cs[j]) for i, j, _ in pairs), default=0.0)),
                unpaired=len(lone), hard_unpaired=len(hard), flipped=len(flipped), ok=not hard and not flipped,
                iou_sum=float(sum(p[2] for p in pairs)))


def compare_by_class(ta, ts, tl, ca, cs, cl) -> dict:
    """compare() within each class: a box that changed class counts as unpaired in both classes."""
    out = {}
    for c in OURS:
        ti = [i for i, x in enumerate(tl) if x == c]
        ci = [j for j, x in enumerate(cl) if x == c]
        if ti or ci:
            out[c] = compare(ta[ti] if ti else np.zeros((0, 4)), ts[ti] if ti else np.zeros(0),
                             ca[ci] if ci else np.zeros((0, 4)), cs[ci] if ci else np.zeros(0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("video", nargs="+", help="one or more clips; --frames are taken from each")
    ap.add_argument("--model", default=os.path.join(HERE, "out", "StockMaskDetector.mlpackage"))
    ap.add_argument("--weights", help="the fine-tuned checkpoint the package was exported from (default: COCO weights)")
    ap.add_argument("--fp32-model", help="an FP32 export (export_detector.py --precision float32) to check the conversion")
    ap.add_argument("--frames", type=int, default=6, help="frames per clip")
    ap.add_argument("--out", default=os.path.join(HERE, "out", "parity"),
                    help="frames, fixtures and parity.json (git-ignored); use another folder for another model")
    args = ap.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Core ML predictions need macOS")

    import coremltools as ct
    from PIL import Image
    from rfdetr import RFDETRNano

    cu = ct.ComputeUnit
    app = "fp16 CPU+GPU (CoreMLDetector's default)"
    runs = {app: (args.model, cu.CPU_AND_GPU), "fp16 CPU+NE (the app, for now)": (args.model, cu.CPU_AND_NE),
            "fp16 CPU": (args.model, cu.CPU_ONLY)}
    if args.fp32_model:
        runs["fp32 CPU"] = (args.fp32_model, cu.CPU_ONLY)
    models = {name: ct.models.MLModel(path, compute_units=unit) for name, (path, unit) in runs.items()}
    meta = models[app].user_defined_metadata
    classes = json.loads(meta["stockmask.classes"])
    num_select = int(meta["stockmask.num_select"])
    res = models[app].get_spec().description.input[0].type.imageType.width
    if args.weights:
        from export_detector import md5
        if md5(args.weights) not in meta.get("stockmask.source", ""):
            print(f"warning: {args.model} was not exported from {args.weights} (stockmask.source: "
                  f"{meta.get('stockmask.source')})")
    rf = RFDETRNano(pretrain_weights=args.weights) if args.weights else RFDETRNano()
    net = rf.model.model.eval()
    mean = torch.tensor(rf.means).view(1, 3, 1, 1)
    std = torch.tensor(rf.stds).view(1, 3, 1, 1)
    os.makedirs(args.out, exist_ok=True)

    torch_8bit = "PyTorch, 8-bit input"
    results: dict[str, list[dict]] = {name: [] for name in [torch_8bit, *models]}
    by_class: dict[str, list[dict]] = {name: [] for name in results}
    latency: dict[str, list[float]] = {name: [] for name in models}
    frames = [(os.path.basename(v), t, rgb) for v in args.video for t, rgb in pick_frames(v, args.frames)]
    for k, (clip, t, rgb) in enumerate(frames):
        h, w = rgb.shape[:2]
        name = f"frame_{k:02d}"
        cv2.imwrite(os.path.join(args.out, name + ".png"), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))

        # The reference: rfdetr's predict() on the full frame.
        r = rf.predict(rgb, threshold=SHOWN)
        keep = [i for i in range(len(r)) if r.data["class_name"][i] in OURS]
        ta = (r.xyxy[keep] / [w, h, w, h]).astype(np.float64) if keep else np.zeros((0, 4))
        ts = r.confidence[keep].astype(np.float64) if keep else np.zeros(0)
        tl = [str(r.data["class_name"][i]) for i in keep]
        tag = {"frame": name, "clip": clip, "t": round(t, 2)}

        # The 8-bit input Core ML gets: resized as predict() resizes (bilinear, no antialias), rounded.
        x = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255
        x8 = F.resize(x, [res, res], antialias=False).mul(255).round().clamp(0, 255).byte()
        dev = next(net.parameters()).device  # predict() may have moved the model to MPS
        with torch.no_grad():
            o = net(((x8.float().unsqueeze(0) / 255 - mean) / std).to(dev))
        b, s, l = ours(*decode(o["pred_boxes"][0].cpu().numpy(), o["pred_logits"][0].cpu().numpy(), classes, SHOWN,
                               num_select))
        results[torch_8bit].append(compare(ta, ts, b, s) | tag)
        by_class[torch_8bit].append(compare_by_class(ta, ts, tl, b, s, l))

        image = Image.fromarray(x8.permute(1, 2, 0).numpy())
        for mname, m in models.items():
            m.predict({"image": image})  # warm-up, then time one run
            t0 = time.perf_counter()
            out = m.predict({"image": image})
            latency[mname].append((time.perf_counter() - t0) * 1000)
            b, s, l = ours(*decode(out["boxes"][0], out["logits"][0], classes, SHOWN, num_select))
            results[mname].append(compare(ta, ts, b, s) | tag)
            by_class[mname].append(compare_by_class(ta, ts, tl, b, s, l))

        fixture = dict(image=name + ".png", width=w, height=h, commit=COMMIT, shown=SHOWN,
                       torch=[dict(label=tl[i], score=float(ts[i]), box=[float(v) for v in ta[i]]) for i in range(len(ts))])
        with open(os.path.join(args.out, name + ".json"), "w") as f:
            json.dump(fixture, f, indent=1)

    n = len(results[torch_8bit])
    ref_total = sum(r["reference"] for r in results[torch_8bit])
    print(f"{n} frames; reference (rfdetr predict on the full frame): {ref_total} detections >= {COMMIT}\n")
    print("| run | detections ≥ 0.5 | frames passing | pairs | mean IoU | min IoU | max Δscore | unpaired (≥ 0.55) | "
          "flipped across 0.5 | Mac latency ms |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    summary = {}
    for name, rows in results.items():
        lat = f"{np.median(latency[name]):.0f}" if name in latency else "–"
        summary[name] = dict(frames=rows, ok=all(r["ok"] for r in rows),
                             median_latency_ms=float(np.median(latency[name])) if name in latency else None)
        print(f"| {name} | {sum(r['candidate'] for r in rows)} | {sum(r['ok'] for r in rows)}/{n} | "
              f"{sum(r['pairs'] for r in rows)} | {np.mean([r['mean_iou'] for r in rows]):.3f} | "
              f"{min(r['min_iou'] for r in rows):.3f} | {max(r['max_dscore'] for r in rows):.3f} | "
              f"{sum(r['unpaired'] for r in rows)} ({sum(r['hard_unpaired'] for r in rows)}) | "
              f"{sum(r['flipped'] for r in rows)} | {lat} |")

    # Per class: boxes paired within the class, so a box that changed class is unpaired in both.
    print("\n| class | run | reference ≥ 0.5 | run ≥ 0.5 | pairs | mean IoU | min IoU | max Δscore | "
          "unpaired (≥ 0.55) | flipped across 0.5 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for c in OURS:
        for name, frames_c in by_class.items():
            rows = [f[c] for f in frames_c if c in f]
            if not rows:
                continue
            pairs = sum(r["pairs"] for r in rows)
            agg = dict(reference=sum(r["reference"] for r in rows), candidate=sum(r["candidate"] for r in rows),
                       pairs=pairs, mean_iou=sum(r["iou_sum"] for r in rows) / pairs if pairs else 1.0,
                       min_iou=min(r["min_iou"] for r in rows), max_dscore=max(r["max_dscore"] for r in rows),
                       unpaired=sum(r["unpaired"] for r in rows), hard_unpaired=sum(r["hard_unpaired"] for r in rows),
                       flipped=sum(r["flipped"] for r in rows))
            summary[name].setdefault("by_class", {})[c] = agg
            print(f"| {c} | {name} | {agg['reference']} | {agg['candidate']} | {pairs} | {agg['mean_iou']:.3f} | "
                  f"{agg['min_iou']:.3f} | {agg['max_dscore']:.3f} | {agg['unpaired']} ({agg['hard_unpaired']}) | "
                  f"{agg['flipped']} |")
    with open(os.path.join(args.out, "parity.json"), "w") as f:
        json.dump(dict(model=os.path.basename(args.model), weights=os.path.basename(args.weights or "COCO"),
                       reference_total=ref_total, runs=summary), f, indent=1)
    app_ok = summary[app]["ok"]
    print(f"\n{app}: {'PASS' if app_ok else 'FAIL'}")
    sys.exit(0 if app_ok else 1)


if __name__ == "__main__":
    main()
