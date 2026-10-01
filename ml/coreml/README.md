# The detector as a Core ML model

`export_detector.py` turns RF-DETR (ADR 002) into the `.mlpackage` the app runs;
`parity.py` checks it against PyTorch. Results: [`RESULTS.md`](RESULTS.md).

**The model never goes into git** (`*.mlpackage` and `out/` are ignored): about 54 MB, and the
parity frames come from venue footage. Make it locally, as below.

## Set up

```sh
cd ml/coreml
uv venv --python 3.11 .venv          # or: python3.11 -m venv .venv
uv pip install --python .venv/bin/python torch==2.7.0 torchvision==0.22.0 \
    coremltools==9.0 rfdetr==1.11.0 "numpy<=2.3.5" opencv-python-headless==5.0.0.93 pillow
```

These are the versions that worked on 2 October 2026 on an Apple M5. coremltools 9.0 is tested up
to torch 2.7 and breaks on numpy 2.4. The COCO weights (`rf-detr-nano.pth`) download on first use,
to `~/.roboflow/models`.

## Export

```sh
.venv/bin/python export_detector.py                           # RF-DETR Nano, COCO weights
.venv/bin/python export_detector.py --weights best.pth        # a fine-tuned checkpoint (ml/)
.venv/bin/python export_detector.py --weights best.pth --classes bottle,can,case,bottle_top
```

It writes `out/StockMaskDetector.mlpackage` (`--out` to change it). On a Mac it also runs the
package once on a synthetic image.

**What the package looks like:**

| | |
|---|---|
| Input `image` | RGB, 384 x 384 (Nano). The ImageNet normalisation is folded into the graph (ADR 002's risk table), so Core ML takes a plain image. |
| Output `boxes` | 1 x 300 x 4: cx, cy, w, h, normalised to the input image |
| Output `logits` | 1 x 300 x C: class logits by slot; scores are their sigmoid |
| Precision | FP16 (`--precision float32` for a reference export of about 108 MB) |
| Deployment target | iOS 16, the target rfdetr's own exporter tests (`--target`) |

**Metadata the app reads** (creator-defined, all strings). Nothing about the model is hard-coded
in the app:

| Key | Example | Used for |
|---|---|---|
| `stockmask.classes` | `["", "person", …, "bottle", …]` (JSON, by logit slot; "" = unused) | The class list. The app keeps the names that are its classes (`bottle`, `can`, `case`, `bottle_top`) and ignores the rest. COCO checkpoints use the sparse category id as the slot (bottle = 44); fine-tuned ones use 0-based indices into their class names. |
| `stockmask.decoder` | `detr` | How to decode: `detr` (these outputs), or `vision` for a model Vision reads as objects (e.g. a YOLO with Core ML's NMS stage) |
| `stockmask.boxes`, `stockmask.logits` | `boxes`, `logits` | Output names |
| `stockmask.num_select` | `300` | rfdetr's top-k over query/class pairs |
| `stockmask.resize` | `stretch-bilinear` | How the app makes the input: the upright frame stretched to the square, bilinear without antialiasing, as rfdetr resizes |
| `stockmask.score_shown`, `stockmask.score_commit` | `0.3`, `0.5` | Below `shown`: not drawn. Between them: dashed, never counted (FR-18). A fine-tuned model can set its own (`--score-shown`, `--score-commit`). |
| `stockmask.source` | `RF-DETR nano (COCO weights), rfdetr 1.11.0, coremltools 9.0, weights md5 …` | Shown in the HUD and written to capture manifests |

**A fine-tuned model drops in** with no app change: export it with `--weights`, and either bundle
it (below) or copy it to the app's Documents/Models folder on the phone.

## Parity

```sh
.venv/bin/python export_detector.py --precision float32 --out out/StockMaskDetector_fp32.mlpackage
.venv/bin/python parity.py ../../research/walkthrough/videos/w2-bay2.MOV --fp32-model out/StockMaskDetector_fp32.mlpackage
```

It picks 6 sharp frames across the clip and compares rfdetr's own `predict()` with:
- the same model in PyTorch on the 8-bit input Core ML gets;
- the package on each compute unit;
- the FP32 export.

It exits non-zero when the app's configuration (FP16 on CPU + GPU) fails. The frames are decoded
with OpenCV, so the clip's metadata, GPS included, is never read. It also leaves the frames as PNG,
with PyTorch's boxes as JSON, in `out/parity/`. `StockMaskAR`'s `CoreMLDetectorTests` runs the
Swift path on those frames.

ADR 002 asks for this check on 200 test images before release. Run the same script on the
labelled holdout set when the fine-tuned model exists.

## How the app bundles the model

See [`app/StockMask/README.md`](../../app/StockMask/README.md), step 6:
- drag `out/StockMaskDetector.mlpackage` into the Xcode project as a reference (not a copy);
- Xcode compiles it into `StockMaskDetector.mlmodelc` in the app bundle;
- `DetectorModelLocator` loads it by URL.

A `.mlpackage` copied to the app's Documents/Models folder takes precedence. It is compiled on the
phone at the next start (`MLModel.compileModel`), so a new model can be tried without a rebuild.

## In the app (StockMaskAR)

- **`ModelInputResizer`** makes the 384 x 384 input itself: it turns the camera image upright,
  stretches it with rfdetr's resize, and converts ARKit's YCbCr. Vision's resize is antialiased,
  and on the parity frames that alone loses bottles (RESULTS.md).
- **`DETRDecoder`** is rfdetr's post-processing.
- **`CoreMLDetector`** runs it on CPU + GPU by default. The HUD can switch to the Neural Engine
  for P0-3.
