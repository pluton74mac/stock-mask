"""Put Ultralytics YOLO detections into walkthrough.py's detection cache, then replay with walkthrough.py.

ADR 002 keeps Ultralytics (AGPL-3.0) to throwaway benchmarking: nothing the app uses may import it, and
walkthrough.py doesn't. So the work is split between two processes that share only files:

  1. This script, in the walkthrough venv, imports walkthrough and calls its replay() with the arguments
     walkthrough.py will get. That gives exactly the keyframes walkthrough.py uses. It lists the
     (detector, keyframe) pairs missing from walkthrough's detection cache and saves those keyframes as
     .npy files in a scratch folder.
  2. yolo_detect.py, in the Ultralytics venv (research/yolo_eval/venv), runs the models on them and
     writes the cache's .npz files (boxes, scores, cls) where this script tells it to.
  3. Then this script runs walkthrough.py with the same arguments. It finds every YOLO detection cached,
     so it never needs Ultralytics itself; without the cache it stops with "run research/yolo_eval/run.py
     first".

Why two processes and not one venv with both: the replay has to run on walkthrough's own OpenCV and
numpy builds, or the hold trigger could pick other frames, and Ultralytics' export stack needs numpy
2.3 where walkthrough's has 2.4. Keeping ultralytics out of the walkthrough venv also means no import
of it can creep into code the app will use. The files they exchange are the cache walkthrough.py
already reads, so walkthrough.py needed only the new names and thresholds in DETECTORS.

    cd research/walkthrough
    venv/bin/python ../yolo_eval/run.py videos/w2-bay1.MOV --detectors rfdetr,yolo26n,yoloe26s_caps \\
        --start 2.4 --carry track --truth bottle=82 --out out/w2-bay1-yolo

Every argument except --yolo-python, --device and --cache-only goes to walkthrough.py unchanged.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "walkthrough"))
import walkthrough as wt  # noqa: E402

WORK = os.path.join(HERE, "work")  # weights, Ultralytics settings, scratch keyframes: git-ignored
IMGSZ = 640  # Ultralytics' default input, and what a Core ML export for the phone takes
# Detector names in walkthrough.DETECTORS (which holds their thresholds) -> what yolo_detect.py runs.
# Every box counts as one bottle: a COCO bottle, or the top of one (like owlv2_caps).
YOLO_MODELS = {
    "yolo26n": dict(weights="yolo26n.pt", classes=["bottle"]),  # COCO
    "yolo26s": dict(weights="yolo26s.pt", classes=["bottle"]),
    "yolo11n": dict(weights="yolo11n.pt", classes=["bottle"]),
    "yolo11s": dict(weights="yolo11s.pt", classes=["bottle"]),
    "yolo26n_seg": dict(weights="yolo26n-seg.pt", classes=["bottle"]),  # COCO instance segmentation: boxes only
    "yoloe26s": dict(weights="yoloe-26s-seg.pt", prompts=["bottle"]),  # open vocabulary, text prompts
    "yoloe26s_caps": dict(weights="yoloe-26s-seg.pt", prompts=["bottle cap"]),
    "yoloe26n_caps": dict(weights="yoloe-26n-seg.pt", prompts=["bottle cap"]),
    "yoloworld": dict(weights="yolov8s-worldv2.pt", prompts=["bottle"]),
    "yoloworld_caps": dict(weights="yolov8s-worldv2.pt", prompts=["bottle cap"]),
    # exploratory: the one wording of four tried on bay 2 that found tops (RESULTS.md)
    "yoloworld_tops": dict(weights="yolov8s-worldv2.pt", prompts=["bottle top"]),
}


def replay_args(argv: list) -> argparse.Namespace:
    """The arguments walkthrough.main() passes to replay(), parsed with its defaults; the rest is ignored."""
    ap = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    ap.add_argument("video")
    ap.add_argument("--detectors", default="rfdetr,rfdetr_tiled,owlv2")
    for flag, default in (("--hfov", wt.HFOV_DEG), ("--hold", wt.HOLD_S), ("--max-speed", wt.MAX_DEG_S),
                          ("--rearm", wt.REARM_DEG), ("--start", 0.0)):
        ap.add_argument(flag, type=float, default=default)
    for flag in ("--every", "--sweep", "--sweep-speed", "--fallback", "--end"):
        ap.add_argument(flag, type=float)
    return ap.parse_known_args(argv)[0]


def cache_folder(video: str) -> str:
    """walkthrough.main()'s cache folder for this video: out/.detcache/<stem>-<size in bytes>."""
    return os.path.join(os.path.dirname(os.path.abspath(wt.__file__)), "out", ".detcache",
                        f"{os.path.splitext(os.path.basename(video))[0]}-{os.path.getsize(video)}")


def fill_cache(a: argparse.Namespace, yolo_python: str, device: str) -> None:
    names = [s.strip() for s in a.detectors.split(",") if s.strip()]
    for n in names:
        if n.startswith("yolo") and (n not in YOLO_MODELS or n not in wt.DETECTORS):
            raise SystemExit(f"{n}: not a YOLO detector here; choose from {', '.join(YOLO_MODELS)}")
    names = [n for n in names if n in YOLO_MODELS]
    if not names:
        return
    if a.every and a.sweep:
        raise SystemExit("--every and --sweep are alternatives: choose one")
    t0 = time.time()
    video, commits, _, _ = wt.replay(a.video, a.hfov, a.hold, a.max_speed, a.rearm, a.every, a.start, a.end,
                                     a.sweep, a.sweep_speed, a.fallback)
    print(f"replay: {len(commits)} keyframes ({time.time() - t0:.0f} s)", flush=True)
    cache = cache_folder(a.video)
    todo = {}  # commit index -> {detector: .npz path}
    for n in names:
        for k, c in enumerate(commits):
            f = os.path.join(cache, f"{n}-{wt.DETECTORS[n][0]:g}", f"{c.frame}.npz")
            if not os.path.exists(f):
                todo.setdefault(k, {})[n] = f
    if not todo:
        print("YOLO detections: all cached", flush=True)
        return
    os.makedirs(WORK, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="keyframes-", dir=WORK)  # venue frames: deleted below, never committed
    try:
        frames = []
        for k, out in sorted(todo.items()):
            path = os.path.join(scratch, f"{commits[k].frame}.npy")
            np.save(path, commits[k].image)
            frames.append(dict(image=path, out=out))
        models = {n: dict(YOLO_MODELS[n], conf=wt.DETECTORS[n][0], imgsz=IMGSZ) for n in names}
        job = os.path.join(scratch, "job.json")
        json.dump(dict(work=WORK, device=device, models=models, frames=frames), open(job, "w"), indent=1)
        print(f"yolo_detect.py: {sum(len(o) for o in todo.values())} detections to run on {len(frames)} keyframes",
              flush=True)
        r = subprocess.run([yolo_python, os.path.join(HERE, "yolo_detect.py"), job])
        if r.returncode:
            raise SystemExit(f"yolo_detect.py failed ({r.returncode})")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    missing = [f for out in todo.values() for f in out.values() if not os.path.exists(f)]
    if missing:
        raise SystemExit(f"yolo_detect.py left {len(missing)} detections unwritten, e.g. {missing[0]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], allow_abbrev=False)
    ap.add_argument("--yolo-python", default=os.path.join(HERE, "venv", "bin", "python"),
                    help="the Ultralytics venv's Python (default: research/yolo_eval/venv)")
    ap.add_argument("--device", default="cpu", help="for the YOLO models: cpu (default) or mps")
    ap.add_argument("--cache-only", action="store_true", help="fill the cache, don't run walkthrough.py")
    own, rest = ap.parse_known_args()
    if not rest or rest[0].startswith("-"):
        raise SystemExit("usage: run.py VIDEO [walkthrough.py options], e.g. --detectors yolo26n --start 2.4")
    fill_cache(replay_args(rest), own.yolo_python, own.device)
    if not own.cache_only:
        r = subprocess.run([sys.executable, wt.__file__] + rest)
        sys.exit(r.returncode)


if __name__ == "__main__":
    main()
