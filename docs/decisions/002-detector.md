# ADR 002: On-device detector, and where Ultralytics and supervision fit

Status: **Accepted, pending the Phase 0 device benchmark (P0-3)** · 2026-09-25

## Decision

- **Ship RF-DETR Nano (Roboflow, Apache-2.0), fine-tuned on our own storeroom data, as a Core ML
  FP16 model.** Classes: `bottle`, `can`, `case`.
- **Fallback: YOLO26n (Ultralytics).** Switch if RF-DETR-N misses the Phase 0 bar: p95 ≤ 60 ms
  per frame on an iPhone 13 Pro with ARKit running, and count accuracy on our test set within 1
  point of YOLO26n. The fallback means buying an Ultralytics Enterprise License before release.
- **Use `supervision` (MIT) offline only:** dataset conversion, evaluation, debug visualisation.
  Nothing from it ships in the app.
- **Keep the detector swappable.** It sits behind a Swift protocol (`Detector`). Labels are
  stored in COCO format, which `supervision` converts to YOLO format in one call. Changing models
  is a retrain, not a rewrite.

## Update, 2 October 2026: Ultralytics measured on real footage

Full results: [`research/yolo_eval/RESULTS.md`](../../research/yolo_eval/RESULTS.md).

**The test.** With COCO or zero-shot weights, through the walkthrough replay. The reference is the
234 bottles of the second storeroom walk (three bays), counted per product.

| detector | bottles counted |
|---|---|
| RF-DETR Nano | 99 |
| YOLO26n | 81 |
| YOLO26s | 106 |
| YOLO11s | 99 |

- **Every whole-bottle detector counts about the front row,** so model choice isn't the gap. Depth
  is: walkthrough RESULTS §16–17.
- **Speed on an Apple M5, from Core ML's placement plan; iPhone latency is still P0-3:**
  - YOLO26n: 5.1 MB, 1.8 ms.
  - RF-DETR Nano: 54.3 MB, 9.4 ms, with 592 of its 600 ops on the Neural Engine.
- **"Bottle cap" prompts fail on YOLOE and YOLO-World.** Only OWLv2's cap prompt works zero-shot,
  and OWLv2 doesn't run on a phone.

**Decision unchanged.** RF-DETR Nano stays the default and Ultralytics the paid fallback. If the
fallback is ever used, take **YOLO26s** over YOLO26n: it counts closer, for 19 MB and 3.3 ms.

**Revisit if:**
- RF-DETR fails P0-3 on the phone;
- a fine-tuned YOLO counts more than a point better than a fine-tuned RF-DETR on our test set.

## What the detector has to do

- **Find:** the three classes on shelves, pallets and in open cases, 0.5 to 2.5 m from the
  camera, in 50 to 300 lux, with glare on glass. Up to about 100 objects per frame.
- **Speed:** about 10 detector runs per second is enough. Counting happens when the user holds
  the phone still (ADR 003), so the detector does not need to run at camera frame rate.
- **Constraints:**
  - Runs inside a **closed-source, paid** iOS app.
  - Shares the Neural Engine and GPU with ARKit and RealityKit.
  - One or two engineers train and maintain it.

## Options compared

| | **RF-DETR Nano** | **YOLO26n** | YOLOv9-T via YOLO-MIT / LibreYOLO | D-FINE-N / DEIM | Apple Create ML |
|---|---|---|---|---|---|
| License for a closed-source app | **Apache-2.0** (code + weights; also N/S/M/L) | **AGPL-3.0, or an Enterprise License.** Ultralytics says it covers models you train yourself, even from scratch. Price is quote-only; anecdotal 2024 quotes are about $4.5–5k per year. Terms are annual, and if you stop renewing you must stop distributing. | MIT | Apache-2.0. The D-FINE README warns that its Objects365 checkpoints are not commercially cleared. | Apple tool, no restriction |
| COCO AP (paper, FP32) | 48.4. Drops to 45.1 in FP16 on the Neural Engine, per RF-DETR's Core ML docs. | 40.9, or 40.1 with the NMS-free head | 38.3 | 42.8 / 43.0 | not published |
| Size | 30.5 M params, 54 MB FP16 | 2.4 M params, about 5 MB FP16 | 2.0 M params | 4 M params | – |
| Published iPhone latency | iPhone 13: 44 ms (Core ML FP32), 30.5 ms (Core AI FP16). M3 Pro Mac: 20.8 ms (FP16, Neural Engine). | iPhone 17 Pro: 3.2 ms (INT8, including preprocessing); about 11 ms per frame sustained with a live camera | none found | none found | none found |
| Core ML path | Official exporter, experimental since 1.9 (July 2026). **Converted without edits in our test.** | Official and mature, with an optional NMS pipeline that Vision reads directly. **Converted in our test.** | Community (LibreYOLO) | Community conversions only; same deformable-attention risk as RF-DETR | Native |
| Training tooling | `rfdetr` (Apache), COCO format, works with Roboflow | Best in class (`ultralytics` CLI) | Research code | Research code | Create ML app on a Mac; little control over augmentation |
| Neural Engine friendliness | Transformer. 7 of about 600 ops run on the CPU (`topk`/`gather`); the deformable-attention sampler was rewritten for Apple | CNN; ideal | CNN; ideal | Transformer decoder | – |

Sources are in the linked research notes. Our own conversion test is in
[`research/coreml_export/RESULTS.md`](../../research/coreml_export/RESULTS.md).

## Why RF-DETR-N by default

1. **The license settles it for a small company.** YOLO26 is the better runtime, but the
   Enterprise License is an open-ended yearly cost. If it lapses, we have to stop distributing
   the app. The obligation also covers models we train ourselves. RF-DETR is Apache-2.0 end to
   end, weights included.
2. **Its speed is enough for this product.** Published iPhone 13 latency (30–44 ms) gives 20+
   runs per second before ARKit contention. We need about 10, because a commit happens on a
   steady hold, not on every frame.
3. **It is more accurate:** +7 COCO AP over YOLO26n (FP32), and still about +4 after the FP16
   loss. Fine-tuned accuracy on *our* classes is what counts, so Phase 0 measures it.
4. **The permissive CNNs are too old or too thin.** YOLOv9-T MIT and YOLOX have no maintained
   first-party Core ML path, and YOLOX is years behind. DEIMv2 moved to a non-commercial license.
   Create ML gives up too much control for dense-shelf accuracy. Any of them could fill the
   fallback slot if the Ultralytics license turns out unaffordable.

## Risks we accept, and how we check them

| Risk | Check |
|---|---|
| The Core ML exporter is marked experimental: FP16 `topk` corrupted indices until a fix merged on 2026-09-24. | Phase 0: pin `rfdetr` ≥ 1.11. Compare Core ML output with PyTorch output on 200 test images, and fail the build if the counts differ. |
| The model takes a raw tensor, not an image. | Wrap it with a normalisation layer and re-export with an image input, so Vision handles resize and rotation. If that fails, write about 50 lines of Swift preprocessing. |
| ARKit contention makes it too slow. | P0-3: Xcode Core ML performance report plus an in-app timer, 20-minute run on an iPhone 13 Pro. Fallback: YOLO26n. |
| 54 MB app size | Acceptable; the 200 MB cellular download limit is far away. Weight palettization gives about 30 MB (8-bit) or 15 MB (4-bit) if needed. |
| Objects365-pretrained weights: YOLO26 and RF-DETR are *both* Objects365-pretrained. | Get a legal opinion before launch. This does not separate the two options. |

## Ultralytics vs supervision: they solve different problems

The draft framed these as alternatives. They are not.

- **`ultralytics`** is a model zoo plus a training and export framework. It would matter only
  if YOLO becomes the fallback. Using it internally is still covered by AGPL, per Ultralytics'
  own license page. That makes even internal experiments with it a license question for us, so
  keep it to throwaway benchmarking.
- **`supervision`** (MIT, v0.30.5) is model-agnostic Python glue:
  - `sv.Detections` with connectors for every framework;
  - dataset load, split, merge and convert (COCO ↔ YOLO ↔ VOC);
  - metrics (mAP, precision/recall, confusion matrix);
  - annotators to render boxes on recorded sessions;
  - `InferenceSlicer` for tiled auto-labelling.

  It has no iOS runtime. Its trackers (ByteTrack, now in the separate `trackers` package) assume
  objects move in 2D video. Our objects are static in 3D and the *camera* moves, so ARKit's pose
  plus 3D matching (ADR 003) does that job instead.

So the answer to "Ultralytics, supervision, or both?" is:
**RF-DETR for the model, `supervision` for the tooling, Ultralytics only as a paid fallback.**
