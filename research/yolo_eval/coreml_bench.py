"""What a Core ML package would ask of the phone, measured without Xcode: size, inputs and outputs, which ops
Core ML places on the Neural Engine (MLComputePlan, on this Mac's Neural Engine), and latency on this Mac.

coremltools only, no ultralytics, so any venv with coremltools 9 runs it (RF-DETR's packages too).
Not the phone: an iPhone's Neural Engine, thermal limits and ARKit's share of it need Xcode and the device
(P0-3). Placement on an Apple-silicon Mac is the nearest stand-in for which ops leave the Neural Engine.

    venv/bin/python coreml_bench.py work/exports/*.mlpackage [--image keyframe.jpg] [--json out.json]
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import shutil
import time

import coremltools as ct
import numpy as np
from coremltools.models.compute_plan import MLComputePlan
from PIL import Image

UNITS = {"cpu_and_ne": ct.ComputeUnit.CPU_AND_NE, "cpu_only": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL}
DEVICE = {"MLNeuralEngineComputeDevice": "ANE", "MLCPUComputeDevice": "CPU", "MLGPUComputeDevice": "GPU"}


def size_mb(path: str) -> float:
    return round(sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs) / 1e6, 1)


def describe(feature) -> str:
    t = feature.type.WhichOneof("Type")
    if t == "imageType":
        return f"{feature.name}: image {feature.type.imageType.width}x{feature.type.imageType.height}"
    if t == "multiArrayType":
        shape = list(feature.type.multiArrayType.shape) or "flexible"
        return f"{feature.name}: array {shape}"
    return f"{feature.name}: {t.replace('Type', '')}"


def placement(path: str, units=ct.ComputeUnit.CPU_AND_NE) -> dict:
    """Where Core ML would run each op, and its estimated share of the cost. Pipelines: every stage; a
    stage that is not an ML program (Apple's NMS layer) runs on the CPU."""
    compiled = ct.models.utils.compile_model(path)
    try:
        plan = MLComputePlan.load_from_path(compiled, compute_units=units)
        dev, off, cost = collections.Counter(), collections.Counter(), collections.Counter()
        stages = []

        def walk(block):
            for op in block.operations:
                u = plan.get_compute_device_usage_for_mlprogram_operation(op)
                if u is not None:  # constants have no device
                    d = DEVICE.get(type(u.preferred_compute_device).__name__, "?")
                    dev[d] += 1
                    c = plan.get_estimated_cost_for_mlprogram_operation(op)
                    cost[d] += c.weight if c is not None else 0.0
                    if d != "ANE":
                        off[f"{op.operator_name} ({d})"] += 1
                for b in op.blocks:
                    walk(b)

        subs = plan.model_structure.pipeline.sub_models if plan.model_structure.pipeline else [
            ("model", plan.model_structure)]
        for name, sub in subs:
            if sub.program is not None:
                for f in sub.program.functions.values():
                    walk(f.block)
                stages.append(f"{name}: ML program")
            else:
                stages.append(f"{name}: not an ML program (NMS layer), CPU")
                off["NMS stage (CPU)"] += 1
        total = sum(cost.values()) or 1.0
        return dict(ops=dict(dev), off_ane=dict(off), cost_share={k: round(v / total, 4) for k, v in cost.items()},
                    stages=stages)
    finally:
        shutil.rmtree(compiled, ignore_errors=True)


def inputs_for(spec, image: Image.Image | None) -> dict:
    feed = {}
    for f in spec.description.input:
        t = f.type.WhichOneof("Type")
        if t == "imageType":
            w, h = f.type.imageType.width, f.type.imageType.height
            feed[f.name] = letterbox(image, w, h) if image is not None else Image.fromarray(
                np.random.default_rng(0).integers(0, 255, (h, w, 3), dtype=np.uint8))
        elif t == "multiArrayType":
            shape = list(f.type.multiArrayType.shape)
            feed[f.name] = np.random.default_rng(0).random(shape, dtype=np.float32)
        else:  # the NMS pipeline's thresholds
            feed[f.name] = 0.7 if "iou" in f.name.lower() else 0.25
    return feed


def letterbox(image: Image.Image, w: int, h: int) -> Image.Image:
    """Fit inside w x h keeping the aspect ratio, grey padding: what Vision's scaleFit hands the model."""
    s = min(w / image.width, h / image.height)
    small = image.resize((round(image.width * s), round(image.height * s)), Image.BILINEAR)
    canvas = Image.new("RGB", (w, h), (114, 114, 114))
    canvas.paste(small, ((w - small.width) // 2, (h - small.height) // 2))
    return canvas


def latency(path: str, units, image, n=50) -> dict:
    m = ct.models.MLModel(path, compute_units=units)
    feed = inputs_for(m.get_spec(), image)
    for _ in range(5):
        m.predict(feed)
    t = []
    for _ in range(n):
        t0 = time.perf_counter()
        m.predict(feed)
        t.append(1000 * (time.perf_counter() - t0))
    return dict(median_ms=round(float(np.median(t)), 2), p90_ms=round(float(np.percentile(t, 90)), 2))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("packages", nargs="+")
    ap.add_argument("--image", help="a keyframe to feed image inputs (default: noise)")
    ap.add_argument("--units", default="cpu_and_ne,cpu_only,all", help=f"latency runs: {', '.join(UNITS)}")
    ap.add_argument("--runs", type=int, default=50)
    ap.add_argument("--json", help="write the results here")
    args = ap.parse_args()
    image = Image.open(args.image).convert("RGB") if args.image else None
    report = {}
    for p in args.packages:
        spec = ct.utils.load_spec(p)
        r = dict(size_mb=size_mb(p), kind=spec.WhichOneof("Type"),
                 inputs=[describe(f) for f in spec.description.input],
                 outputs=[describe(f) for f in spec.description.output],
                 placement=placement(p))
        r["latency"] = {u: latency(p, UNITS[u], image, args.runs) for u in args.units.split(",") if u}
        report[os.path.basename(p)] = r
        print(json.dumps({os.path.basename(p): r}), flush=True)
    if args.json:
        json.dump(report, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
