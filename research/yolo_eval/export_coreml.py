"""Export the YOLO candidates to Core ML (.mlpackage), for coreml_bench.py to inspect.

Imports ultralytics (AGPL-3.0), so it runs only in research/yolo_eval/venv (ADR 002). The packages go to
work/exports/, which is git-ignored, like every *.mlpackage in this repository.

    venv/bin/python export_coreml.py            # all of EXPORTS
    venv/bin/python export_coreml.py yolo26n_nms_fp16 yolo26n_seg_fp16
    venv/bin/python export_coreml.py --parity "../walkthrough/out/w2-bay*-yolo/cvat/images/*.jpg"

--parity runs each package and its PyTorch weights on the same keyframes (CPU and Neural Engine for Core
ML, CPU for PyTorch, both letterboxed to 640 x 640) and compares the bottles found at a score of 0.25.

Ultralytics 8.4 export options used here:
  nms=True    detect models: Apple's NMS layer as a pipeline stage, so Vision returns
              VNRecognizedObjectObservations. For YOLO26 it switches from the NMS-free one-to-one head to
              the one-to-many head. Segment models bake NMS into the graph instead.
  nms=False   YOLO26's end-to-end head: top-k inside the graph, a (1, 300, 6 + masks) array out, no NMS.
  quantize    16 = FP16 weights and compute; 8 = 8-bit k-means palettized weights with FP16 compute
              (W8A16; Ultralytics calls it INT8).
"""

from __future__ import annotations

import os
import shutil
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
# tag: (weights, text prompts or None, export kwargs)
EXPORTS = {
    "yolo26n_nms_fp16": ("yolo26n.pt", None, dict(nms=True, quantize=16)),
    "yolo26n_nms_int8": ("yolo26n.pt", None, dict(nms=True, quantize=8)),
    "yolo26n_e2e_fp16": ("yolo26n.pt", None, dict(nms=False, quantize=16)),
    "yolo26s_nms_fp16": ("yolo26s.pt", None, dict(nms=True, quantize=16)),
    "yolo26s_nms_int8": ("yolo26s.pt", None, dict(nms=True, quantize=8)),
    "yolo26n_seg_fp16": ("yolo26n-seg.pt", None, dict(nms=False, quantize=16)),
    "yoloe26s_fp16": ("yoloe-26s-seg.pt", ["bottle", "bottle cap"], dict(nms=False, quantize=16)),
    "yoloworld_tops_nms_fp16": ("yolov8s-worldv2.pt", ["bottle top"], dict(nms=True, quantize=16)),
}


def load(weights: str, prompts):
    from ultralytics import YOLO, YOLOE, YOLOWorld

    path = os.path.join(WORK, "weights", weights)
    if prompts is None:
        return YOLO(path)
    model = (YOLOE if weights.startswith("yoloe") else YOLOWorld)(path)
    model.set_classes(prompts)  # the text embeddings become constants of the exported graph
    return model


def iou(a, b):
    ix = np.clip(np.minimum(a[:, None, 2], b[None, :, 2]) - np.maximum(a[:, None, 0], b[None, :, 0]), 0, None)
    iy = np.clip(np.minimum(a[:, None, 3], b[None, :, 3]) - np.maximum(a[:, None, 1], b[None, :, 1]), 0, None)
    area = lambda x: (x[:, 2] - x[:, 0]) * (x[:, 3] - x[:, 1])  # noqa: E731
    return ix * iy / np.maximum(area(a)[:, None] + area(b)[None] - ix * iy, 1e-9)


def parity(pattern: str, tags: list, conf=0.25):
    """Bottles (or tops) found by each package against its PyTorch weights, on the same keyframes."""
    import glob

    from ultralytics import YOLO

    images = sorted(glob.glob(pattern))
    if not images:
        raise SystemExit(f"no images match {pattern}")
    print(f"{len(images)} keyframes, score >= {conf}, bottles only (tops for a tops prompt)")
    print("| package | boxes, PyTorch | boxes, Core ML | matched (IoU >= 0.5) | keyframes with another count |")
    print("|---|---|---|---|---|")
    for tag in tags or EXPORTS:
        weights, prompts, kw = EXPORTS[tag]
        pkg = os.path.join(WORK, "exports", f"{tag}.mlpackage")
        if not os.path.exists(pkg):
            continue
        pt, ml = load(weights, prompts), YOLO(pkg, task="segment" if "seg" in weights else "detect")
        keep = [k for k, v in pt.names.items() if v == "bottle"] or list(pt.names)
        n_pt = n_ml = n_match = n_diff = 0
        for f in images:
            args = dict(conf=conf, imgsz=640, rect=False, classes=keep, verbose=False)  # 640 x 640, as exported
            a = pt.predict(f, device="cpu", nms=kw["nms"] if kw["nms"] is False else None, **args)[0].boxes
            b = ml.predict(f, **args)[0].boxes
            a, b = a.xyxy.cpu().numpy(), b.xyxy.cpu().numpy()
            n_pt, n_ml, n_diff = n_pt + len(a), n_ml + len(b), n_diff + (len(a) != len(b))
            if len(a) and len(b):
                m = iou(a, b)
                while m.size and m.max() >= 0.5:  # greedy one-to-one
                    i, j = np.unravel_index(m.argmax(), m.shape)
                    n_match += 1
                    m[i, :], m[:, j] = 0, 0
        print(f"| {tag} | {n_pt} | {n_ml} | {n_match} | {n_diff} of {len(images)} |", flush=True)


def main():
    pattern = os.path.abspath(sys.argv[2]) if sys.argv[1:2] == ["--parity"] else None  # before the chdir below
    os.environ["YOLO_CONFIG_DIR"] = os.path.join(WORK, "config")
    os.environ.setdefault("YOLO_VERBOSE", "False")
    os.makedirs(os.path.join(WORK, "weights"), exist_ok=True)
    os.chdir(os.path.join(WORK, "weights"))  # Ultralytics downloads text encoders into the working directory
    from ultralytics.utils import SETTINGS
    from ultralytics.utils.events import events

    SETTINGS.update(sync=False)  # no usage analytics from this machine
    events.enabled = False
    if pattern:
        return parity(pattern, sys.argv[3:])
    out_dir = os.path.join(WORK, "exports")
    os.makedirs(out_dir, exist_ok=True)
    for tag in sys.argv[1:] or EXPORTS:
        weights, prompts, kw = EXPORTS[tag]
        model = load(weights, prompts)
        t0 = time.time()
        f = model.export(format="coreml", imgsz=640, batch=1, device="cpu", **kw)
        dst = os.path.join(out_dir, f"{tag}.mlpackage")
        shutil.rmtree(dst, ignore_errors=True)
        shutil.move(f, dst)
        print(f"{tag}: {dst} ({time.time() - t0:.0f} s)", flush=True)


if __name__ == "__main__":
    main()
