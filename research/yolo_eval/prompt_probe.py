"""Is a failed text prompt the wording or the input size? YOLOE-26s and YOLO-World v2 s on some keyframes.

Imports ultralytics (AGPL-3.0): runs only in research/yolo_eval/venv (ADR 002).

    venv/bin/python prompt_probe.py "../walkthrough/out/w2-bay2-yolo/cvat/images/*.jpg"
"""

from __future__ import annotations

import glob
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
MODELS = {"YOLOE-26s": "yoloe-26s-seg.pt", "YOLO-World v2 s": "yolov8s-worldv2.pt"}
PROMPTS = ("bottle cap", "cap", "bottle top", "lid", "bottle")
SIZES = (640, 1280, 1920)


def main():
    images = sorted(glob.glob(os.path.abspath(sys.argv[1])))[::3]  # every third keyframe
    if not images:
        raise SystemExit(f"no images match {sys.argv[1]}")
    os.environ["YOLO_CONFIG_DIR"] = os.path.join(WORK, "config")
    os.environ.setdefault("YOLO_VERBOSE", "False")
    os.makedirs(os.path.join(WORK, "weights"), exist_ok=True)
    os.chdir(os.path.join(WORK, "weights"))  # Ultralytics downloads text encoders into the working directory
    from ultralytics import YOLOE, YOLOWorld
    from ultralytics.utils import SETTINGS
    from ultralytics.utils.events import events

    SETTINGS.update(sync=False)
    events.enabled = False
    print(f"{len(images)} keyframes")
    print("| model | prompt | input | boxes at 0.2 or more, per keyframe | median top score | median height / width |")
    print("|---|---|---|---|---|---|")
    for label, weights in MODELS.items():
        model = (YOLOE if weights.startswith("yoloe") else YOLOWorld)(os.path.join(WORK, "weights", weights))
        for prompt in PROMPTS:
            model.set_classes([prompt])
            for size in SIZES if prompt != "bottle" else SIZES[:1]:
                n, top, shape = 0, [], []
                for f in images:
                    b = model.predict(f, conf=0.05, imgsz=size, device="cpu", verbose=False)[0].boxes
                    s, xyxy = b.conf.numpy(), b.xyxy.numpy()
                    n += int((s >= 0.2).sum())
                    top.append(float(s.max()) if len(s) else 0.0)
                    shape += list(((xyxy[:, 3] - xyxy[:, 1]) / (xyxy[:, 2] - xyxy[:, 0]))[s >= 0.2])
                hw = f"{np.median(shape):.1f}" if shape else "–"
                print(f"| {label} | \"{prompt}\" | {size} | {n / len(images):.1f} | {np.median(top):.2f} | {hw} |",
                      flush=True)


if __name__ == "__main__":
    main()
