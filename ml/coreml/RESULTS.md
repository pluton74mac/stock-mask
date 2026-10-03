# Core ML parity: RF-DETR Nano (COCO weights), 2 October 2026

**Setup:**
- RF-DETR Nano with COCO weights, exported by `export_detector.py`: image input, normalisation in
  the graph, FP16, 54.3 MB.
- Compared with rfdetr's own `predict()` on 6 sharp frames spread over one clip of the second
  storeroom walk (bay 2, 78 s, portrait 1080 x 1920). The frames stay on the Mac (git-ignored).
- COCO knows one of our classes, `bottle`.
- A detection counts at a score of 0.5 or more (FR-18's commit threshold). Boxes are paired 1:1 by
  IoU (at least 0.5). Scores within 0.05 of the threshold may land on either side of it.
- Apple M5, macOS 26, coremltools 9.0, torch 2.7.0, rfdetr 1.11.0.

## Result

The reference, rfdetr `predict()` on the full frames, finds **38 bottles** at 0.5 or more.

| run | bottles ≥ 0.5 | frames passing | mean IoU | worst IoU | worst score change | unpaired at ≥ 0.55 | crossed 0.5 | Mac ms |
|---|---|---|---|---|---|---|---|---|
| PyTorch on the same 8-bit 384 x 384 input | 36 | 6/6 | 0.996 | 0.964 | 0.039 | 0 | 0 | – |
| Core ML FP32, CPU (checks the conversion) | 36 | 6/6 | 0.996 | 0.964 | 0.039 | 0 | 0 | 31 |
| **Core ML FP16, CPU + GPU (the app's default)** | **36** | **6/6** | 0.995 | 0.959 | 0.040 | 0 | 0 | 6 |
| Core ML FP16, CPU only | 35 | 6/6 | 0.993 | 0.934 | 0.133 | 0 | 0 | 16 |
| Core ML FP16, CPU + Neural Engine (ADR 001's plan) | 32 | 4/6 | 0.926 | 0.514 | 0.185 | 1 | 2 | 8 |
| **Swift: `ModelInputResizer` + Core ML FP16, CPU + GPU** (`CoreMLDetectorTests`) | **35** | **6/6** | 0.992–0.999 per frame | – | 0.038 | 0 | 0 | ~40 in a debug build |
| Swift through Vision (`scaleFill`), CPU + GPU: the first version | 34 | 5/6 | 0.923–0.993 per frame | – | 0.147 | – | – | – |

Notes on the table:
- "Unpaired at ≥ 0.55" counts confident boxes with no partner on the other side. "Crossed 0.5"
  counts pairs with one score at 0.55 or more and the other under 0.5. A run fails a frame on
  either.
- Mac ms is one timed prediction per frame after a warm-up, median of 6; not a benchmark.
- The Swift times include drawing the 1080 x 1920 PNG and resizing it in an unoptimised build.

## What it shows

1. **The conversion is exact.** FP32 Core ML gives what PyTorch gives on the same input: same
   boxes, same scores.
2. **The 8-bit input already moves 2 of 38 bottles across 0.5.** Their scores sit within 0.04 of
   the threshold. Expect differences of that size between any two runtimes, and judge parity by
   confident boxes, as `parity.py` does.
3. **FP16 on the GPU (or CPU) is as close as that.** This is the app's default.
4. **FP16 on the Neural Engine drifts.** It finds 32 bottles: the worst box overlap drops to 0.51,
   one confident box goes missing and two scores cross the threshold. This is the risk ADR 002
   recorded: the exporter is experimental and RF-DETR's own docs report an AP drop in FP16 on the
   Neural Engine.
   - A mixed-precision export (`--fp32-ops layer_norm,softmax`) brought the boxes back: 36
     bottles, worst IoU 0.973. But two scores still crossed 0.5 (worst change 0.30), and it took
     47 ms instead of 8, because those ops leave the Neural Engine. It is not a fix.
5. **The resize matters as much as the precision.** RF-DETR is trained and run with a bilinear
   resize without antialiasing. Vision's `scaleFill` resize is antialiased. In PyTorch FP32 alone,
   swapping the resize changes the count:

   | resize to 384 x 384 | bottles ≥ 0.5 | frames passing | mean IoU |
   |---|---|---|---|
   | bilinear, no antialiasing (rfdetr) | 38 | 6/6 | 1.000 |
   | bilinear, antialiased | 36 | 5/6 | 0.972 |
   | OpenCV area | 34 | 5/6 | 0.983 |
   | Lanczos (PIL) | 34 | 5/6 | 0.978 |

   So the app makes the model's input itself (`ModelInputResizer`, tested against hand-computed
   bilinear values) instead of letting Vision resize. That took the Swift path from 34 bottles and
   5/6 frames to 35 and 6/6.

## What to do with it

- **The app runs the detector on CPU + GPU by default**, against ADR 001's "CPU + Neural Engine,
  so the GPU stays free for rendering". The HUD switches between the two.
- **P0-3 decides on the phone.** On an iPhone 13 Pro with ARKit and the overlays running, it should
  measure for each compute unit:
  - latency p50 and p95 (the HUD);
  - thermal state over 20 minutes;
  - this parity on frames from the phone (capture mode records them; run `parity.py`'s
    comparison on them).

  The A15's Neural Engine may not drift like the M5's.
- **Rerun this on the fine-tuned model.** A model trained on our classes may have wider score
  margins, which makes FP16 drift matter less. ADR 002 asks for 200 holdout images before release.
- The GPU's 6 ms on an M5 says nothing yet about an A15 with RealityKit rendering at 60 fps.

## On the phone, 3 October 2026

The app's detector benchmark (StockMaskAR README, "Diagnostics") on an iPhone 14 Pro Max (A16),
Debug build, ARKit off. Times are end to end (resize 11 ms, Core ML, decoding); the scores are on
the three newest commit keyframes, which stay on the phone.

| | load | p50 | p95 | detections ≥ 0.5 |
|---|---|---|---|---|
| CPU + GPU | 0.6 s | 65 ms | 67 ms | 15 |
| CPU + Neural Engine | 5.2 s (compiles once per install) | 39 ms | 41 ms | 12 |
| CPU only | 0.6 s | 57 ms | 58 ms | 15 |

- **The A16's Neural Engine drifts like the M5's.** Against it, the GPU's scores are 0.02 higher on
  average (worst 0.19), and the GPU and the CPU agree with each other.
- **The app uses the Neural Engine for now** anyway: on 2 October nothing counted on the GPU. The
  reason was the detector's period, not its scores (StockMaskAR README, "GPU or Neural Engine").
  The GPU should take over again once the in-app log shows it counting with ARKit running.

## The fine-tuned model: student 3 (`auto-r3`), 3 October 2026

**Setup:**
- Student 3 of the automatic labelling (`ml/AUTOLABEL.md`), six classes. Exported with
  `export_detector.py --weights`: FP16, 54.2 MB.
- The reference is rfdetr's `predict()` with the same checkpoint.
- 24 frames: 8 sharp frames from each of the three bay clips of the second walk. They stay on the
  Mac (git-ignored).

```sh
.venv/bin/python parity.py ../../research/walkthrough/videos/w2-bay{1,2,3}.MOV --frames 8 \
    --weights ../data/runs/auto-r3/checkpoint_best_total.pth --model out/StockMaskDetector-auto-r3.mlpackage \
    --fp32-model out/StockMaskDetector-auto-r3_fp32.mlpackage --out out/parity-auto-r3
```

The reference finds 266 detections at 0.5 or more.

| run | detections ≥ 0.5 | frames passing | mean IoU | worst IoU | worst score change | unpaired at ≥ 0.55 | crossed 0.5 | Mac ms |
|---|---|---|---|---|---|---|---|---|
| PyTorch on the same 8-bit input | 268 | 24/24 | 0.997 | 0.952 | 0.090 | 0 | 0 | – |
| Core ML FP32, CPU | 267 | 24/24 | 0.997 | 0.952 | 0.090 | 0 | 0 | 30 |
| Core ML FP16, CPU + GPU | 268 | 23/24 | 0.995 | 0.954 | 0.120 | 1 | 0 | 6 |
| Core ML FP16, CPU only | 264 | 24/24 | 0.993 | 0.912 | 0.148 | 0 | 0 | 15 |
| Core ML FP16, CPU + Neural Engine | 246 | 10/24 | 0.942 | 0.503 | 0.574 | 11 | 11 | 8 |

**By class** (boxes paired within the class; detections at 0.5 or more):

| class | reference | GPU | Neural Engine | mean IoU, GPU / NE | unpaired at ≥ 0.55 or crossed 0.5, GPU / NE |
|---|---|---|---|---|---|
| bottle | 98 | 98 | 96 | 0.997 / 0.939 | 1 / 3 |
| bottle_top | 162 | 164 | 144 | 0.994 / 0.946 | 0 / 19 |
| can | 4 | 4 | 4 | 0.998 / 0.919 | 0 / 0 |
| case | 2 | 2 | 2 | 0.998 / 0.921 | 0 / 0 |
| carton | 0 (2 boxes at 0.3–0.5) | 0 | 0 | 0.999 / 0.995 | 0 / 0 |
| bag | none at 0.3 | – | – | – | – |

- **The conversion is exact again:** FP32 Core ML gives what PyTorch gives on the same input.
- **FP16 on the GPU fails one frame of 24, on a duplicate box.** A second query on a close-up
  bottle overlaps the first at IoU 0.99. The reference scores it 0.05. On the 8-bit input,
  PyTorch and FP32 Core ML score it 0.50, and the GPU 0.57. So the input's rounding does most of
  it, and FP16 tips it over 0.55. DETR has no NMS. Neither the app's decoder nor the commit engine
  merges two bottle boxes on one object (`TopMerge` pairs tops with bottles only), so a duplicate
  at 0.5 or more would likely count twice.
- **The Neural Engine drifts as it did with the COCO weights, mostly on bottle tops:** 144 of 162.
  Ten confident tops go unpaired and 9 cross 0.5. The app asks for the Neural Engine for now
  (above).
- **Tins, cartons and bags are too rare in this model's output to judge.** Student 3 finds few of
  them (`ml/AUTOLABEL.md`).
