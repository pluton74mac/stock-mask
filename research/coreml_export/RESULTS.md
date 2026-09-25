# Core ML export test: YOLO26 / YOLO11 vs RF-DETR

Run on 2026-09-25 in a Linux container (CPU only) with `export_and_inspect.py`.
Conversion to `.mlpackage` works on Linux; running and profiling the models on the Neural Engine
needs Xcode on a Mac and a real iPhone, so latency is **not** measured here. That measurement is
Phase 0 task P0-3.

Versions: torch 2.7.0, coremltools 9.0, ultralytics 8.4.162 (AGPL-3.0), rfdetr 1.11.0 (Apache-2.0).

## Result

| model (COCO weights) | converts? | package | input | params | ops that tend to leave the Neural Engine | transformer ops (matmul/softmax/layer_norm/linear) |
|---|---|---|---|---|---|---|
| YOLO26n end-to-end (no NMS), fp32 | yes | 9.9 MB (about 5 MB as fp16) | image | 2.4 M | topk ×2, gather_nd ×3 (final selection) | 4 / 2 / 0 / 0 |
| YOLO26n + Core ML NMS pipeline, fp16 | yes | 5.1 MB | image + thresholds | 2.4 M | NMS (runs on CPU, returns Vision observations) | 4 / 2 / 0 / 0 |
| YOLO26s end-to-end, fp32 | yes | 38.3 MB | image | 9.5 M | topk ×2, gather_nd ×3 | 4 / 2 / 0 / 0 |
| YOLO11n + Core ML NMS pipeline, fp16 | yes | 5.5 MB | image + thresholds | 2.6 M | NMS | 2 / 2 / 0 / 0 |
| RF-DETR Nano (384 px), fp16 | yes (exporter marked experimental) | 54.3 MB | raw tensor | 30.5 M | topk ×1, gather_along_axis ×2, resample ×2 (deformable attention) | 28 / 16 / 46 / 102 |
| RF-DETR Small (512 px), fp16 | yes (experimental) | 57.7 MB | raw tensor | 32.1 M | topk ×1, gather_along_axis ×2, resample ×3 | 30 / 18 / 49 / 112 |

Full op inventory: `inventory.json`.

## What this tells us

1. **Both families are deployable in principle.** RF-DETR's native Core ML exporter (new in the
   1.x line, still flagged experimental) converted Nano and Small without edits. Ultralytics' exporter
   is mature and needed only a numpy pin (`numpy<=2.3.5`; coremltools 9.0 breaks on numpy 2.4).
2. **YOLO is the lower-risk runtime.** A 2.4 M-parameter CNN whose only off-ANE ops are the final
   selection (or Core ML's NMS, which Vision turns straight into `VNRecognizedObjectObservation`s).
   Package ~5 MB.
3. **RF-DETR is the higher-risk runtime.** 30 M parameters (23 M of them the DINOv2-style backbone),
   a transformer graph, and `resample`/`topk`/`gather` in the middle of the network, which may force
   Neural Engine ↔ GPU/CPU hand-offs. It takes a raw normalized tensor, so the Swift side has to do
   resize + ImageNet normalization itself (or we wrap the model with a normalization layer and
   re-export with an image input). ~54 MB before weight compression.
4. **The license, not the conversion, is what separates them for a closed-source app**:
   Ultralytics code and models are AGPL-3.0 unless an Enterprise License is bought; RF-DETR
   (Nano/Small/Medium) and its training code are Apache-2.0. See `docs/decisions/002-detector.md`.
5. **Unknown that decides it:** p95 latency on an iPhone 13 Pro / 15 Pro *while ARKit is running*.
   We need ≥ 10 detector runs per second for the live preview; anything ≤ 60 ms per frame is enough
   because counting happens on a steady "hold" rather than on every frame.

## Reproduce

```bash
python -m venv venv && . venv/bin/activate
pip install torch==2.7.0 torchvision==0.22.0 --index-url https://download.pytorch.org/whl/cpu
pip install coremltools==9.0 ultralytics==8.4.162 rfdetr==1.11.0 "numpy<=2.3.5"
python export_and_inspect.py      # writes exports/*.mlpackage and inventory.json
```

On a Mac, open each `.mlpackage` in Xcode → Performance tab → run on a connected iPhone to get
per-op compute-unit placement and latency (Phase 0, task P0-3).
