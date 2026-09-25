"""Can the candidate detectors be converted to Core ML, and what does the result look like?

Converts COCO-pretrained YOLO26n/s, YOLO11n (Ultralytics) and RF-DETR Nano/Small (Roboflow) to
.mlpackage on Linux (conversion works without a Mac; running/profiling needs Xcode on a Mac),
then inventories each package: size, input type, and the ops that tend to leave the Neural
Engine (topk, gather, resample/grid_sample, NMS).

Setup that worked on 2026-09-25 (Python 3.11, CPU only):
    pip install torch==2.7.0 torchvision==0.22.0 --index-url https://download.pytorch.org/whl/cpu
    pip install coremltools==9.0 ultralytics==8.4.162 rfdetr==1.11.0 "numpy<=2.3.5"
    python export_and_inspect.py

coremltools 9.0 is tested up to torch 2.7 and breaks on numpy 2.4 (apple/coremltools#2633).
"""

from __future__ import annotations

import collections
import json
import os
import shutil

import coremltools as ct

WATCH = {"topk", "gather", "gather_nd", "gather_along_axis", "resample", "nonMaximumSuppression"}


def export_all(out_dir: str = "exports") -> dict[str, str]:
    from rfdetr import RFDETRNano, RFDETRSmall
    from ultralytics import YOLO

    os.makedirs(out_dir, exist_ok=True)
    done = {}
    for weights, nms, tag in [("yolo26n.pt", False, "yolo26n_end2end"), ("yolo26n.pt", True, "yolo26n_nms"),
                              ("yolo26s.pt", False, "yolo26s_end2end"), ("yolo11n.pt", True, "yolo11n_nms")]:
        f = YOLO(weights).export(format="coreml", imgsz=640, nms=nms)
        dst = os.path.join(out_dir, f"{tag}.mlpackage")
        shutil.rmtree(dst, ignore_errors=True)
        shutil.move(f, dst)
        done[tag] = dst
    for cls, tag in [(RFDETRNano, "rfdetr_nano_fp16"), (RFDETRSmall, "rfdetr_small_fp16")]:
        done[tag] = str(cls().export(format="coreml", coreml_precision="float16", output_dir=out_dir, verbose=False))
    return done


def inventory(path: str) -> dict:
    spec = ct.utils.load_spec(path)

    def ops(s):
        c = collections.Counter()
        kind = s.WhichOneof("Type")
        if kind == "pipeline":
            for m in s.pipeline.models:
                c += ops(m)
        elif kind == "mlProgram":
            def walk(block):
                for op in block.operations:
                    c[op.type] += 1
                    for b in op.blocks:
                        walk(b)
            for f in s.mlProgram.functions.values():
                for b in f.block_specializations.values():
                    walk(b)
        else:
            c[kind] += 1
        return c

    c = ops(spec)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)
    return dict(size_mb=round(size / 1e6, 1),
                inputs=[(i.name, i.type.WhichOneof("Type")) for i in spec.description.input],
                total_ops=sum(c.values()),
                watch={k: v for k, v in c.items() if k in WATCH},
                transformer_ops={k: c.get(k, 0) for k in ("matmul", "softmax", "layer_norm", "linear")})


if __name__ == "__main__":
    report = {tag: inventory(p) for tag, p in export_all().items()}
    print(json.dumps(report, indent=1))
    json.dump(report, open("inventory.json", "w"), indent=1)
