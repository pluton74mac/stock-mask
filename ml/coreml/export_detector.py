"""Export the StockMask detector (RF-DETR) to a Core ML package with an image input.

What this adds over rfdetr's own `export(format="coreml")` (research/coreml_export):
- **An image input.** rfdetr's package takes a raw, already-normalised tensor. This one takes an
  RGB image (`image`, 384 x 384 for Nano) with the ImageNet normalisation folded into the graph
  (ADR 002's risk table), so Core ML converts the pixel buffer and normalises it. The app makes
  that 384 x 384 image itself (StockMaskAR's ModelInputResizer): rfdetr's resize, bilinear without
  antialiasing. Vision's resize is antialiased, and that alone costs bottles (RESULTS.md).
- **Named outputs:** `boxes` (1 x Q x 4: cx, cy, w, h, normalised to the input image) and
  `logits` (1 x Q x C, before the sigmoid), as float32.
- **Metadata the app reads** (creator-defined keys, all strings):
  - `stockmask.classes`: JSON list of class names by logit slot ("" for unused slots). The app
    maps names to its classes (`bottle`, `can`, `case`, `bottle_top`) and ignores the rest, so a
    fine-tuned model replaces the COCO one without code changes.
  - `stockmask.decoder` = `detr`, `stockmask.boxes`, `stockmask.logits`, `stockmask.num_select`,
    `stockmask.resize` = `stretch-bilinear`, `stockmask.score_shown`, `stockmask.score_commit`,
    `stockmask.source`.

Usage (macOS or Linux; the parity check in parity.py needs macOS):
    python export_detector.py                         # RF-DETR Nano, COCO weights
    python export_detector.py --weights ckpt.pth      # a fine-tuned checkpoint; classes from it
    python export_detector.py --classes bottle,can,case,bottle_top --weights ckpt.pth

Setup that worked on 2026-10-02 (Python 3.11, Apple M5):
    uv venv --python 3.11 .venv
    uv pip install --python .venv/bin/python torch==2.7.0 torchvision==0.22.0 coremltools==9.0 \
        rfdetr==1.11.0 "numpy<=2.3.5" opencv-python-headless==5.0.0.93 pillow
coremltools 9.0 is tested up to torch 2.7 and breaks on numpy 2.4 (apple/coremltools#2633).
The output .mlpackage (about 54 MB) is git-ignored: never commit it.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import sys
from copy import deepcopy

import numpy as np
import torch
from torch import nn

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)
# Score thresholds the app starts from (walkthrough.py: shown, counted). A fine-tuned model can ship
# its own through --score-shown / --score-commit.
SCORE_SHOWN, SCORE_COMMIT = 0.3, 0.5
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "out", "StockMaskDetector.mlpackage")


class ImageInputDetector(nn.Module):
    """Takes an RGB image scaled to [0, 1] (Core ML applies the 1/255 scale), applies the ImageNet
    normalisation rfdetr's predict() applies, and runs the export-mode detector.

    The per-channel std can't go into Core ML's ImageType preprocessing (its scale is one scalar),
    so it lives in the graph as two constants."""

    def __init__(self, detector: nn.Module, mean=IMAGENET_MEAN, std=IMAGENET_STD):
        super().__init__()
        self.detector = detector
        self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("inv_std", 1.0 / torch.tensor(std, dtype=torch.float32).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor):
        boxes, logits = self.detector((image - self.mean) * self.inv_std)[:2]
        return boxes, logits


def load_rfdetr(variant: str, weights: str | None):
    import rfdetr

    cls = {"nano": rfdetr.RFDETRNano, "small": rfdetr.RFDETRSmall}[variant]
    return cls(pretrain_weights=weights) if weights else cls()


def class_slots(model, num_slots: int, override: list[str] | None) -> list[str]:
    """Class name for every logit slot. Pretrained COCO checkpoints use the sparse COCO category id
    as the slot (slot 44 = bottle); fine-tuned ones use 0-based indices into their class names."""
    from rfdetr.assets.coco_classes import COCO_CLASSES

    names = override or list(model.class_names)
    if override is None and names == list(COCO_CLASSES.values()):
        return [COCO_CLASSES.get(i, "") for i in range(num_slots)]
    if len(names) > num_slots:
        raise SystemExit(f"{len(names)} class names but the model has only {num_slots} logit slots")
    return names + [""] * (num_slots - len(names))


def md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def op_inventory(spec) -> dict:
    """Op counts of an mlprogram, plus the ops that tend to leave the Neural Engine (as in
    research/coreml_export/export_and_inspect.py)."""
    counts = collections.Counter()

    def walk(block):
        for op in block.operations:
            counts[op.type] += 1
            for b in op.blocks:
                walk(b)

    for f in spec.mlProgram.functions.values():
        for b in f.block_specializations.values():
            walk(b)
    watch = {"topk", "gather", "gather_nd", "gather_along_axis", "resample"}
    return {"total_ops": sum(counts.values()), "watch": {k: v for k, v in counts.items() if k in watch}}


def export(args) -> str:
    import coremltools as ct
    from rfdetr.export._backend import _switch_to_export_mode
    from rfdetr.export._coreml.torch_ops import ensure_coreml_torch_op_patches
    from rfdetr.export.prepare import prepare_export_graph

    model = load_rfdetr(args.variant, args.weights)
    res = model.model.resolution
    inner = deepcopy(model.model.model).cpu().eval()
    # The same preparation rfdetr's exporter does: freeze the backbone's position embeddings to the
    # export shape, then switch every module to its export forward (boxes, logits).
    graph = prepare_export_graph(inner, model.model_config, shape=(res, res), device="cpu")
    _switch_to_export_mode(graph.model)
    wrapped = ImageInputDetector(graph.model).eval()

    example = torch.rand(1, 3, res, res)
    with torch.no_grad():
        boxes, logits = wrapped(example)
    num_queries, num_slots = logits.shape[1], logits.shape[2]
    classes = class_slots(model, num_slots, args.classes.split(",") if args.classes else None)
    print(f"model: RF-DETR {args.variant}, input {res}x{res}, {num_queries} queries, {num_slots} logit slots")

    with torch.no_grad():
        program = torch.export.export(wrapped, (example,), strict=False).run_decompositions({})
    ensure_coreml_torch_op_patches()
    precision = {"float16": ct.precision.FLOAT16, "float32": ct.precision.FLOAT32}[args.precision]
    if args.precision == "float16" and args.fp32_ops:
        # Mixed precision: these op types stay FP32 (they then run off the Neural Engine).
        keep = set(args.fp32_ops.split(","))
        precision = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in keep)
    mlmodel = ct.convert(
        program,
        inputs=[ct.ImageType(name="image", shape=(1, 3, res, res), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="boxes", dtype=np.float32), ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=getattr(ct.target, args.target),
        compute_precision=precision,
    )

    from importlib.metadata import version

    from rfdetr.assets.model_weights import get_model_cache_dir

    weights = args.weights or os.path.join(get_model_cache_dir(), f"rf-detr-{args.variant}.pth")
    source = f"RF-DETR {args.variant} ({'fine-tuned' if args.weights else 'COCO weights'}), " \
             f"rfdetr {version('rfdetr')}, coremltools {version('coremltools')}"
    if os.path.exists(weights):
        source += f", weights md5 {md5(weights)}"
    meta = {
        "stockmask.decoder": "detr",
        "stockmask.classes": json.dumps(classes),
        "stockmask.boxes": "boxes",
        "stockmask.logits": "logits",
        "stockmask.num_select": str(model.model_config.num_select),
        "stockmask.resize": "stretch-bilinear",
        "stockmask.score_shown": str(args.score_shown),
        "stockmask.score_commit": str(args.score_commit),
        "stockmask.source": source,
    }
    mlmodel.user_defined_metadata.update(meta)
    mlmodel.short_description = ("StockMask detector. Input: RGB image, stretched to the input size. Outputs: "
                                 "boxes (cx, cy, w, h normalised to the input) and logits (sigmoid gives scores).")
    mlmodel.author = "StockMask; model by Roboflow (RF-DETR)"
    mlmodel.license = "Apache-2.0"
    mlmodel.version = args.version
    mlmodel.input_description["image"] = (f"RGB image, {res} x {res}: the upright frame stretched to it, "
                                         "bilinear without antialiasing (rfdetr's resize)")
    mlmodel.output_description["boxes"] = "1 x Q x 4: cx, cy, w, h normalised to the input image"
    mlmodel.output_description["logits"] = "1 x Q x C class logits by slot; slot names in stockmask.classes"

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    if os.path.exists(args.out):
        import shutil

        shutil.rmtree(args.out)
    mlmodel.save(args.out)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(args.out) for f in fs)
    spec = ct.utils.load_spec(args.out)
    print(f"wrote {args.out} ({size / 1e6:.1f} MB)")
    print("inputs:", [(i.name, i.type.WhichOneof("Type")) for i in spec.description.input])
    print("outputs:", [(o.name, list(o.type.multiArrayType.shape)) for o in spec.description.output])
    print("classes in use:", [(i, c) for i, c in enumerate(classes) if c in ("bottle", "can", "case", "bottle_top")])
    print("ops:", json.dumps(op_inventory(spec)))
    if sys.platform == "darwin" and not args.no_check:
        check(args.out, res, num_queries, num_slots)
    return args.out


def check(path: str, res: int, num_queries: int, num_slots: int) -> None:
    """Load the package with Core ML and run one synthetic image through it (macOS only)."""
    import coremltools as ct
    from PIL import Image

    m = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)
    img = Image.fromarray(np.random.default_rng(0).integers(0, 256, (res, res, 3), dtype=np.uint8))
    out = m.predict({"image": img})
    assert out["boxes"].shape == (1, num_queries, 4), out["boxes"].shape
    assert out["logits"].shape == (1, num_queries, num_slots), out["logits"].shape
    print(f"check: Core ML ran on a synthetic image; boxes {out['boxes'].shape}, logits {out['logits'].shape}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--variant", default="nano", choices=["nano", "small"])
    ap.add_argument("--weights", help="fine-tuned checkpoint (.pth); default: the COCO weights")
    ap.add_argument("--classes", help="comma-separated class names by slot, overriding the checkpoint's")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--precision", default="float16", choices=["float16", "float32"])
    ap.add_argument("--fp32-ops", help="with float16: comma-separated MIL op types to keep in FP32, "
                    "e.g. layer_norm,softmax (an experiment against Neural Engine drift)")
    ap.add_argument("--target", default="iOS16", help="coremltools deployment target (rfdetr tests iOS16)")
    ap.add_argument("--score-shown", type=float, default=SCORE_SHOWN)
    ap.add_argument("--score-commit", type=float, default=SCORE_COMMIT)
    ap.add_argument("--version", default="coco-0")
    ap.add_argument("--no-check", action="store_true", help="skip the Core ML run on a synthetic image")
    export(ap.parse_args())


if __name__ == "__main__":
    main()
