"""The Ultralytics half of run.py: run YOLO models on keyframes, write one .npz per keyframe and model.

Ultralytics is AGPL-3.0, so ADR 002 keeps it to throwaway benchmarking. This file imports it, so it runs
only in its own venv (research/yolo_eval/venv), like export_coreml.py and prompt_probe.py. It knows
nothing about walkthrough.py: run.py hands it a job file, and it writes the arrays of walkthrough's
detection cache.

Job file (JSON):
    work    folder for weights and Ultralytics settings (git-ignored)
    device  "cpu" or "mps"
    models  {name: {weights, conf, imgsz, and either classes (COCO names to keep) or prompts (text
            prompts for YOLOE / YOLO-World)}}. Every box is labelled "bottle": a COCO bottle, or a cap
            or top that counts as one bottle.
    frames  [{image: keyframe .npy (BGR uint8, as walkthrough's Commit.image), out: {name: .npz path}}]

Each .npz holds boxes (N, 4) x0 y0 x1 y1 in keyframe pixels, scores (N,) and cls (N,), like
walkthrough.py's own cache entries.

    venv/bin/python yolo_detect.py JOB.json
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np


def load(spec: dict, work: str):
    """The model, ready to predict: COCO weights as they are, open-vocabulary ones with their prompts."""
    from ultralytics import YOLO, YOLOE, YOLOWorld

    weights = os.path.join(work, "weights", spec["weights"])
    if "prompts" not in spec:
        return YOLO(weights)
    if os.path.basename(weights).startswith("yoloe"):
        model = YOLOE(weights)
    else:
        model = YOLOWorld(weights)
    model.set_classes(list(spec["prompts"]))
    return model


def main():
    job = json.load(open(sys.argv[1]))
    work = job["work"]
    os.environ["YOLO_CONFIG_DIR"] = os.path.join(work, "config")  # settings stay in the ignored folder
    os.environ.setdefault("YOLO_VERBOSE", "False")
    os.makedirs(os.path.join(work, "weights"), exist_ok=True)
    os.chdir(os.path.join(work, "weights"))  # Ultralytics downloads text encoders into the working directory
    from ultralytics.utils import SETTINGS
    from ultralytics.utils.events import events

    SETTINGS.update(sync=False)  # no usage analytics from this machine
    events.enabled = False
    import torch
    import ultralytics

    print(f"  ultralytics {ultralytics.__version__}, torch {torch.__version__}, device {job['device']}", flush=True)
    for name, spec in job["models"].items():
        frames = [f for f in job["frames"] if name in f["out"]]
        if not frames:
            continue
        t0 = time.time()
        model = load(spec, work)
        keep = None
        if "classes" in spec:
            keep = [k for k, v in model.names.items() if v in spec["classes"]]
            if len(keep) != len(spec["classes"]):
                raise SystemExit(f"{name}: classes {spec['classes']} not all in the model's names")
        n = 0
        for f in frames:
            img = np.load(f["image"])
            r = model.predict(img, conf=spec["conf"], imgsz=spec["imgsz"], classes=keep, device=job["device"],
                              verbose=False)[0]
            boxes = r.boxes.xyxy.cpu().numpy().astype(np.float64)
            scores = r.boxes.conf.cpu().numpy().astype(np.float64)
            cls = np.full(len(scores), "bottle")
            out = f["out"][name]
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out + ".part", "wb") as fh:  # a file handle: np.savez would append .npz to the name
                np.savez(fh, boxes=boxes.reshape(-1, 4), scores=scores, cls=cls)
            os.replace(out + ".part", out)
            n += len(scores)
        print(f"  {name}: {len(frames)} keyframes, {n} boxes ({time.time() - t0:.0f} s)", flush=True)
        del model


if __name__ == "__main__":
    main()
