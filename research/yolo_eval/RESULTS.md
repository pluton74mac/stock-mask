# Ultralytics YOLO against RF-DETR on the storeroom walk

Run on 2 October 2026 on an Apple M5 Mac (32 GB), with no Xcode and no iPhone. How to reproduce:
[`README.md`](README.md). The venue footage stays off this repository; this file holds only aggregate
numbers.

**The question ([ADR 002](../../docs/decisions/002-detector.md)):** is Ultralytics YOLO worth an
Enterprise License for StockMask, over RF-DETR Nano (Apache-2.0)?

**Every model here has COCO or zero-shot weights.** Both families will be fine-tuned on our own storeroom
data (P0-7, ADR 006), probably with a `bottle_top` class. So this compares starting points and runtimes,
not the accuracy we will ship.

## The answer: no, not now

- **The counts don't improve.**
  - With COCO weights, YOLO26s and YOLO11s count 106 and 99 of 234 bottles; RF-DETR Nano counts 99.
  - YOLO26n, ADR 002's fallback, counts 81, which is the front row (81).
  - At a lower threshold, RF-DETR Nano counts 130, more than any whole-bottle YOLO at any threshold
    tried.
  - Every whole-bottle detector counts about the front row. The rows behind it are hidden, and no
    detector finds them.
- **The open-vocabulary YOLOs can't count caps without training.**
  - Prompted "bottle cap", YOLOE-26s, YOLOE-26n and YOLO-World v2 count 3 or 4 of 234 bottles.
  - At 640 px, most keyframes have no cap scoring even 0.05. At 1280 or 1920 px, a keyframe's best cap
    scores 0.10 at the median.
  - OWLv2 (Apache-2.0) stays the zero-shot cap counter for pre-labels: 187 of 234.
  - YOLO-World does respond to "bottle top", but counts bottle bodies, tins and pictures on cartons too.
- **On the phone, YOLO is much lighter, and RF-DETR looks light enough.**
  - On this Mac's Neural Engine, YOLO26n is 5.1 MB and takes 1.8 ms; YOLO26s 19.2 MB and 3.3 ms.
    RF-DETR Nano is 54.3 MB and takes 9.4 ms.
  - Both keep nearly every op on the Neural Engine: YOLO 284 of 286 plus Apple's NMS layer, RF-DETR
    592 of 600.
  - ADR 002's bar is p95 ≤ 60 ms on an iPhone 13 Pro with ARKit running. Nothing here suggests RF-DETR
    misses it, but only the phone can show it (P0-3).
- **So the license would buy speed we don't need yet, and no accuracy we can see.** It is a yearly cost
  for as long as the app ships, and it covers the models we train ourselves (ADR 002).
- **Keep ADR 002 as it is:** RF-DETR Nano by default, with YOLO26 as the paid fallback.
  - If the fallback is ever used, take YOLO26s. It counted like RF-DETR here; YOLO26n counted only the
    front row.
  - ADR 002's switch rule also asks RF-DETR to count within a point of YOLO26n. On these COCO weights it
    is already 7 points better (−58% against −65%).
- **What would change the answer:**
  - P0-3 measures RF-DETR Nano over 60 ms p95 on the iPhone 13 Pro, with ARKit running;
  - fine-tuned on dataset v0, YOLO counts more than a point better than RF-DETR (ADR 002's rule);
  - the app comes to need masks on the phone. Even then, see [Masks](#masks-yolo26n-seg): RF-DETR has
    Apache-2.0 segmentation models too.

## Setup

- **Footage and reference:** the second walk's three bays
  ([walkthrough RESULTS.md](../walkthrough/RESULTS.md), sections 8 and 16).
  - 82, 84 and 68 bottles, 81 of them in the front row.
  - Bay 3's 22 tins are left out. COCO has no can class, and no YOLO here was prompted for them
    (OWLv2 found 7).
- **Counting:** walkthrough.py exactly as in walkthrough RESULTS.md section 17 (`out/w2-bayN-caps`).
  - Hold-to-count, with counted items carried by tracking (`--carry track`), after the bay card.
  - 13, 30 and 15 keyframes.
  - The reference detectors' rows below reproduce sections 11 and 17 exactly.
- **Thresholds, fixed before counting:**
  - whole-bottle YOLOs count from Ultralytics' default score of 0.25, and are shown from 0.15 (the
    walkthrough's usual ratio);
  - cap and top prompts count from 0.2 and are shown from 0.15, like `owlv2_caps`;
  - the references keep theirs: RF-DETR 0.5 (its default), OWLv2 0.3, OWLv2 caps 0.2.

  [Counts at other thresholds](#all-three-bays-at-three-thresholds) are further down.
- **Input size:**
  - YOLO uses Ultralytics' default 640 px. A portrait keyframe (1080 × 1920) shrinks by a third, to
    360 × 640.
  - RF-DETR Nano squeezes it to 384 × 384. OWLv2 pads it to a 960 px square.
- **Detection head:**
  - By default, Ultralytics 8.4 predicts with YOLO26's one-to-many head and NMS (IoU 0.7). A Core ML
    export with Apple's NMS layer runs the same head.
  - YOLO26's NMS-free head found 14% fewer bottles at 0.25 on these keyframes: 269 against 311 for
    YOLO26n ([parity table](#on-the-phone)).
- **Versions:** ultralytics 8.4.171, torch 2.7.0, coremltools 9.0 and rfdetr 1.11.0. The YOLO models ran
  on the CPU.

## Prompts

| model | text encoder | prompt | counted as |
|---|---|---|---|
| YOLO26n, YOLO26s, YOLO11n, YOLO11s, YOLO26n-seg | none (COCO) | class `bottle` only | a bottle |
| YOLOE-26s (its `-seg` weights; boxes only) | MobileCLIP2-B | "bottle" | a bottle |
| YOLOE-26s and YOLOE-26n | MobileCLIP2-B | "bottle cap" | a cap is a bottle |
| YOLO-World v2 s | CLIP ViT-B/32 | "bottle", and "bottle cap" | a bottle, and a cap is a bottle |
| YOLO-World v2 s, exploratory | CLIP ViT-B/32 | "bottle top" | a top is a bottle |
| OWLv2 (reference) | its own | "a photo of a bottle" (with "a photo of a beverage can" and "a photo of a cardboard box"), and "a photo of a bottle cap" | |

- The prompts asked for were "bottle" and "bottle cap".
- "bottle top" was found afterwards: of four wordings tried on bay 2 keyframes (below), it was the only
  one that responded. Read its row as exploratory.

**Prompt against input size** (`prompt_probe.py`, every third bay 2 keyframe, 10 in all). A median
best score of 0.00 means that, in most keyframes, nothing scored 0.05.

| model | prompt | input (px) | boxes at 0.2 or more, per keyframe | median best score | median height ÷ width |
|---|---|---|---|---|---|
| YOLOE-26s | "bottle cap" | 640 / 1280 / 1920 | 0.1 / 0.1 / 0.0 | 0.00 / 0.10 / 0.10 | 1.5 / 0.9 / – |
| YOLOE-26s | "cap" | 640 / 1280 / 1920 | 0.0 / 0.0 / 0.0 | 0.00 / 0.00 / 0.00 | – |
| YOLOE-26s | "bottle top" | 640 / 1280 / 1920 | 0.0 / 0.0 / 0.0 | 0.00 / 0.08 / 0.08 | – |
| YOLOE-26s | "lid" | 640 / 1280 / 1920 | 0.0 / 0.0 / 0.0 | 0.00 / 0.00 / 0.00 | – |
| YOLOE-26s | "bottle" | 640 | 7.6 | 0.90 | 4.2 |
| YOLO-World v2 s | "bottle cap" | 640 / 1280 / 1920 | 0.1 / 0.1 / 0.0 | 0.00 / 0.00 / 0.00 | 0.5 / 0.4 / – |
| YOLO-World v2 s | "cap" | 640 / 1280 / 1920 | 0.0 / 0.0 / 0.0 | 0.00 / 0.00 / 0.00 | – |
| YOLO-World v2 s | "bottle top" | 640 / 1280 / 1920 | 12.6 / 5.9 / 3.6 | 0.68 / 0.48 / 0.35 | 1.6 / 1.6 / 1.6 |
| YOLO-World v2 s | "lid" | 640 / 1280 / 1920 | 0.0 / 0.0 / 0.0 | 0.00 / 0.00 / 0.03 | – |
| YOLO-World v2 s | "bottle" | 640 | 6.8 | 0.80 | 3.6 |

- **The cap prompts fail in the models, not at the input size.** A larger input doesn't bring the caps
  out.
- Across bay 2's keyframes, OWLv2's cap prompt finds about 13 boxes of 0.2 or more per keyframe.
- **YOLO-World's "bottle top" boxes are a mix.** Their median height is 1.6 times their width, between a
  top (about 1) and a bottle (3.6 for "bottle").

## Counts per bay

"Sum of per-view counts" adds every commit's count; "after matching" is what the app would show
(walkthrough RESULTS.md section 11). Each bay's table ends with the cap and top prompts.

### Bay 1: 82 bottles, 26 of them in the front row

| detector | sum of per-view counts | after matching | against the reference | possible-miss prompts |
|---|---|---|---|---|
| RF-DETR Nano, COCO `bottle` (ADR 002's choice) | 40 | **32** | −61% | 5 |
| the same on 2 × 3 tiles | 53 | **45** | −45% | 8 |
| OWLv2, "a photo of a bottle" | 53 | **43** | −48% | 9 |
| OWLv2, "a photo of a bottle cap", a cap is a bottle | 99 | **72** | −12% | 33 |
| YOLO26n, COCO `bottle` | 33 | **25** | −70% | 6 |
| YOLO26s, COCO `bottle` | 48 | **40** | −51% | 4 |
| YOLO11n, COCO `bottle` | 41 | **34** | −59% | 3 |
| YOLO11s, COCO `bottle` | 45 | **38** | −54% | 3 |
| YOLO26n-seg, COCO `bottle`, counted from its boxes | 38 | **30** | −63% | 6 |
| YOLOE-26s, "bottle" | 45 | **36** | −56% | 6 |
| YOLO-World v2 s, "bottle" | 44 | **38** | −54% | 3 |
| YOLOE-26s, "bottle cap" | 0 | **0** | −100% | 0 |
| YOLOE-26n, "bottle cap" | 1 | **1** | −99% | 0 |
| YOLO-World v2 s, "bottle cap" | 0 | **0** | −100% | 0 |
| YOLO-World v2 s, "bottle top" (exploratory) | 91 | **72** | −12% | 12 |

### Bay 2: 84 bottles, 30 of them in the front row

| detector | sum of per-view counts | after matching | against the reference | possible-miss prompts |
|---|---|---|---|---|
| RF-DETR Nano, COCO `bottle` (ADR 002's choice) | 100 | **35** | −58% | 38 |
| the same on 2 × 3 tiles | 120 | **37** | −56% | 59 |
| OWLv2, "a photo of a bottle" | 100 | **33** | −61% | 45 |
| OWLv2, "a photo of a bottle cap", a cap is a bottle | 227 | **73** | −13% | 82 |
| YOLO26n, COCO `bottle` | 85 | **29** | −65% | 32 |
| YOLO26s, COCO `bottle` | 101 | **35** | −58% | 42 |
| YOLO11n, COCO `bottle` | 89 | **29** | −65% | 39 |
| YOLO11s, COCO `bottle` | 99 | **35** | −58% | 42 |
| YOLO26n-seg, COCO `bottle`, counted from its boxes | 78 | **29** | −65% | 25 |
| YOLOE-26s, "bottle" | 107 | **34** | −60% | 47 |
| YOLO-World v2 s, "bottle" | 90 | **31** | −63% | 37 |
| YOLOE-26s, "bottle cap" | 4 | **3** | −96% | 1 |
| YOLOE-26n, "bottle cap" | 1 | **1** | −99% | 0 |
| YOLO-World v2 s, "bottle cap" | 1 | **0** | −100% | 1 |
| YOLO-World v2 s, "bottle top" (exploratory) | 171 | **47** | −44% | 92 |

### Bay 3: 68 bottles, 25 of them in the front row

| detector | sum of per-view counts | after matching | against the reference | possible-miss prompts |
|---|---|---|---|---|
| RF-DETR Nano, COCO `bottle` (ADR 002's choice) | 38 | **32** | −53% | 3 |
| the same on 2 × 3 tiles | 43 | **37** | −46% | 3 |
| OWLv2, "a photo of a bottle" | 34 | **28** | −59% | 4 |
| OWLv2, "a photo of a bottle cap", a cap is a bottle | 53 | **42** | −38% | 10 |
| YOLO26n, COCO `bottle` | 30 | **27** | −60% | 1 |
| YOLO26s, COCO `bottle` | 36 | **31** | −54% | 4 |
| YOLO11n, COCO `bottle` | 30 | **23** | −66% | 5 |
| YOLO11s, COCO `bottle` | 34 | **26** | −62% | 5 |
| YOLO26n-seg, COCO `bottle`, counted from its boxes | 32 | **27** | −60% | 3 |
| YOLOE-26s, "bottle" | 33 | **29** | −57% | 4 |
| YOLO-World v2 s, "bottle" | 32 | **28** | −59% | 2 |
| YOLOE-26s, "bottle cap" | 1 | **1** | −99% | 0 |
| YOLOE-26n, "bottle cap" | 1 | **1** | −99% | 0 |
| YOLO-World v2 s, "bottle cap" | 3 | **3** | −96% | 0 |
| YOLO-World v2 s, "bottle top" (exploratory) | 41 | **38** | −44% | 2 |

## All three bays, at three thresholds

234 bottles, 81 of them in the front row. Each cell gives the count after matching, its error, and the
possible-miss prompts. The thresholds of the per-bay tables are in bold. These come from `analyse.py`,
which keeps each detector's shown threshold. So walkthrough's clean-up removes the same boxes in every
column, and only the commit threshold changes.

| detector | lower | middle | higher |
|---|---|---|---|
| RF-DETR Nano | 0.3: 130 (−44%), 54 | 0.4: 114 (−51%), 52 | **0.5: 99 (−58%), 46** |
| the same on 2 × 3 tiles | 0.3: 150 (−36%), 85 | 0.4: 133 (−43%), 77 | **0.5: 119 (−49%), 70** |
| OWLv2, bottle | 0.2: 132 (−44%), 92 | **0.3: 104 (−56%), 58** | 0.4: 55 (−76%), 31 |
| OWLv2, bottle cap | 0.15: 234 (0%), 149 | **0.2: 187 (−20%), 125** | 0.3: 129 (−45%), 85 |
| YOLO26n | 0.15: 104 (−56%), 52 | **0.25: 81 (−65%), 39** | 0.4: 65 (−72%), 28 |
| YOLO26s | 0.15: 118 (−50%), 61 | **0.25: 106 (−55%), 50** | 0.4: 83 (−65%), 36 |
| YOLO11n | 0.15: 101 (−57%), 65 | **0.25: 86 (−63%), 47** | 0.4: 75 (−68%), 27 |
| YOLO11s | 0.15: 117 (−50%), 58 | **0.25: 99 (−58%), 50** | 0.4: 88 (−62%), 39 |
| YOLO26n-seg | 0.15: 100 (−57%), 52 | **0.25: 86 (−63%), 34** | 0.4: 69 (−71%), 22 |
| YOLOE-26s, "bottle" | 0.15: 121 (−48%), 79 | **0.25: 99 (−58%), 57** | 0.4: 79 (−66%), 43 |
| YOLO-World v2 s, "bottle" | 0.15: 122 (−48%), 54 | **0.25: 97 (−59%), 42** | 0.4: 70 (−70%), 18 |
| YOLO-World v2 s, "bottle top" | 0.15: 179 (−24%), 129 | **0.2: 157 (−33%), 106** | 0.3: 115 (−51%), 90 |

- **A lower threshold doesn't let YOLO catch up.** Its best whole-bottle count is 122 (YOLO-World at
  0.15). RF-DETR Nano counts 130 at 0.3, and 150 on tiles.
- **No whole-bottle detector reaches two thirds of the stock at any threshold tried.**
- **Prompts per counted bottle are the same for both families:** 0.46 for RF-DETR and 0.47 for YOLO26s.
  - Gate G7 allows 0.10.
  - Bay 2's deep rows cause most of them (walkthrough RESULTS.md section 11).
- **OWLv2's caps at 0.15 hit 234 exactly, with 149 prompts and double boxes (next section).** The errors
  cancel. Don't judge a detector by its total alone.

## Do the counts come from real objects?

What was checked:
- the contact sheets of YOLO26s (bays 2 and 3) and of YOLO-World "bottle top" (bay 3);
- single views where the detectors disagreed most (bay 1 views 7 and 13, bay 2 view 10, bay 3 views 8
  and 10), across RF-DETR, YOLO26n, YOLO26s, OWLv2 caps and YOLO-World "bottle top";
- `analyse.py`'s count of box shapes.

- **The whole-bottle detectors count real bottles, front row first.**
  - YOLO26n boxes the front row and leaves the bottles behind below its threshold.
  - YOLO26s and YOLO11s also box bottles in the rows behind, by their necks and shoulders. These are
    real bottles, not duplicates. It is where the s models gain on the n models.
  - Both families miss single front bottles, in different views. RF-DETR missed a large front bottle
    close to the camera in bay 2 view 10 and bay 3 view 8; YOLO26s found both. Over a bay, such misses
    even out.
  - Both count tins seen from above as bottles: in one bay 3 view, RF-DETR counted four and YOLO26s two.
    So bay 3's whole-bottle counts include a few tins.
- **OWLv2's caps sit on caps, but some bottles get two boxes:** one on the cap, one on the cap and neck.
  - 22 of its 187 counted boxes are tall (more than twice as high as wide).
  - 16 of those have their own counted cap inside their upper part, so about 16 bottles count twice
    (13 of them in bay 1).
  - Without them it counts 171 (−27%), not 187 (−20%).
- **YOLO-World's "bottle top" is not a top counter.**
  - 68 of its 157 counted boxes are tall: bottles or necks, not tops. About 13 of those bottles also
    count by their top.
  - In bay 3, it counts tins seen from above and pictures printed on cartons as tops.
  - Its −12% in bay 1, the same as OWLv2's caps, is errors cancelling.

## On the phone

### Core ML exports (640 × 640 image input, coremltools 9.0)

| package | size | outputs | ops on the Neural Engine | what leaves it | this Mac, CPU + Neural Engine | this Mac, CPU only | boxes matched with PyTorch (Core ML's count) |
|---|---|---|---|---|---|---|---|
| YOLO26n, Apple's NMS layer, FP16 | 5.1 MB | objects for Vision (confidence, coordinates) | 284 of 286 | image scaling (cast, mul), and the NMS stage | 1.8 ms | 8.4 ms | 305 of 311 (306) |
| YOLO26n, NMS layer, 8-bit weights | 2.7 MB | the same | 284 of 286 | the same | 1.8 ms | 8.4 ms | 302 of 311 (311) |
| YOLO26n, NMS-free head, FP16 | 5.1 MB | 300 × 6 array | 278 of 298 | the top-300 selection: topk ×2, gather_nd ×3 and 15 index and shape ops | 1.7 ms | 8.3 ms | 259 of 269 (270) |
| YOLO26s, NMS layer, FP16 | 19.2 MB | objects for Vision | 284 of 286 | as YOLO26n | 3.3 ms | 17.8 ms | 395 of 403 (401) |
| YOLO26s, NMS layer, 8-bit weights | 9.8 MB | objects for Vision | 284 of 286 | as YOLO26n | 3.3 ms | 18.7 ms | 382 of 403 (391) |
| YOLO26n-seg, NMS-free head, FP16 | 5.7 MB | 300 × 38 array, and 32 × 160 × 160 mask prototypes | 317 of 336 | the top-300 selection (19 ops) | 2.3 ms | 10.8 ms | 239 of 247 (254) |
| YOLOE-26s, "bottle" and "bottle cap" built in, FP16 | 21.0 MB | as YOLO26n-seg | 317 of 336 | the top-300 selection (19 ops) | 4.3 ms | 24.7 ms | 341 of 350 (351) |
| YOLO-World v2 s, "bottle top" built in, NMS layer, FP16 | 25.1 MB | objects for Vision | 259 of 261 | as YOLO26n | 3.6 ms | 21.7 ms | 511 of 523 (583) |
| RF-DETR Nano, FP16 (rfdetr's own exporter, for comparison) | 54.3 MB | 300 boxes and 300 × 91 class scores | 592 of 600 | topk, gather_along_axis ×2, tile ×2, expand_dims ×2, one layer_norm | 9.4 ms | 19.5 ms | – |

How these were measured:
- **Neural Engine placement:** Core ML's compute plan (`MLComputePlan`) on this Mac's Neural Engine,
  constants not counted.
  - An iPhone's Neural Engine is another generation; Xcode's performance report on the phone is the
    check.
  - For YOLO's two CPU ops (the image input's scaling), Core ML estimates 12% of the cost for YOLO26n
    and 6% for YOLO26s.
- **Latency:** the median of 50 runs after 5 warm-up runs, through coremltools' `predict`.
  - It includes Python's overhead, and the NMS stage for pipelines.
  - Allowing the GPU changes little (RF-DETR: 8.9 ms).
  - This Mac is shared with other jobs. Read the numbers as ratios, not as phone figures.
- **PyTorch parity:** the 58 keyframes as saved by walkthrough (JPEG).
  - Both sides letterboxed to 640 × 640: PyTorch in FP32 on the CPU, Core ML in FP16 on the CPU and
    Neural Engine.
  - Boxes of 0.25 or more (bottles, or tops for "bottle top"), matched one-to-one at IoU 0.5 or more.

What they show:
- **The YOLO exports are mature.** Each converts in under 30 s, and the FP16 packages keep 96–98% of
  PyTorch's boxes.
  - The Core ML NMS pipeline returns objects Vision understands directly.
  - The YOLO-World "bottle top" package finds 11% more boxes than PyTorch, probably because many of its
    boxes score near the threshold.
- **8-bit weights** (k-means palettized; Ultralytics calls them INT8) halve the package and change nothing
  in speed here. The Neural Engine computes in FP16 either way. They lost 3% of YOLO26s's bottles (391
  against 403).
- **YOLOE with fixed prompts exports.**
  - The text embeddings become constants, so no text encoder ships (MobileCLIP2-B is 254 MB). New
    prompts mean a new export.
  - Only `-seg` weights are published, so the package carries masks: see below.
- **RF-DETR keeps its deformable attention on the Neural Engine on this Mac.**
  - The `resample` ops that [`coreml_export/RESULTS.md`](../coreml_export/RESULTS.md) expected to leave
    it run on it.
  - Only the final top-300 selection and one layer norm run on the CPU: 0.15% of Core ML's cost
    estimate.
  - Its input is still a raw 384 × 384 tensor, so Swift resizes and normalises.

### Published iPhone latencies

- **YOLO26** (Ultralytics, [Core ML integration page](https://docs.ultralytics.com/integrations/coreml/)):
  - iPhone 17 Pro (A19 Pro), iOS 26.5.2, their 8-bit Core ML packages, single images;
  - YOLO26n: 3.2 ms on the CPU and Neural Engine (9.2 ms on the CPU only);
  - YOLO26n-seg: 4.8 ms (12.6 ms on the CPU only);
  - live camera: an older camera sweep measured 11.3 ms per frame for YOLO26n.
- **RF-DETR Nano:**
  - A community Core AI port ([RF-DETR-CoreAI](https://huggingface.co/coreai-community/RF-DETR-CoreAI))
    reports about 25 ms per frame live, on an iPhone 17 Pro's GPU, in FP32. Its Neural Engine support
    is pending.
  - ADR 002 quotes 44 ms on an iPhone 13 (Core ML, FP32) and 30.5 ms (Core AI, FP16), with no link in
    this repository.
- **YOLO26s against YOLO26n** ([Ultralytics model page](https://docs.ultralytics.com/models/yolo26/)):
  2.2 times slower on a CPU (ONNX: 87.2 against 38.9 ms), 1.5 times on a T4 GPU (2.5 against 1.7 ms).

**Real iPhone latency needs Xcode and the phone, and neither is available yet.**
- Everything above was measured on a Mac, or on someone else's phone.
- P0-3 is still open: an iPhone 13 Pro with ARKit running, p95 over 20 minutes. It decides ADR 002's
  speed condition.

## Masks: YOLO26n-seg

**Masks would not change the counts, and they cost speed.**
- **Counts:** counted from its boxes, YOLO26n-seg counts like the detect model: 86 of 234 bottles against
  YOLO26n's 81 (30, 29 and 27 a bay).
- **The export:** 5.7 MB against 5.1 MB.
  - It returns a 300 × 38 array: per detection, a box, a score, a class and 32 mask coefficients.
  - It also returns 32 × 160 × 160 mask prototypes.
- **Decoding in Swift:** Vision makes no objects of these outputs, so Swift has to decode them.
  - Each mask is sigmoid(coefficients · prototypes) at 160 × 160, a quarter of the 640 input.
  - In a portrait 1080 × 1920 keyframe, one mask cell covers about 12 × 12 pixels, so a cap is two or
    three cells wide.
  - Each mask is then cropped to its box, and the letterbox undone.
- **Speed against the detect model:**
  - published: 4.8 against 3.2 ms on the iPhone 17 Pro (+50%); 53.3 against 38.9 ms on a CPU in ONNX
    (+37%); 2.1 against 1.7 ms on a T4 (+24%); 9.3 against 5.5 GFLOPs;
  - on this Mac: 2.3 against 1.7 ms (+32%, both NMS-free).
- **Why the counts don't change:**
  - They are limited by bottles hidden behind the front row, which no mask sees.
  - Walkthrough matches items by box centres.
- **Later uses:** masks could help separate overlapping bottles, or draw the counted zones. RF-DETR has
  Apache-2.0 segmentation models too (`RFDETRSegNano` and up, in rfdetr 1.11), so masks don't argue for
  the license.
- **YOLOE:** the YOLOE models used here are `-seg` weights and produce masks as well.

## What this does not show

- **Fine-tuned accuracy.** Both families get fine-tuned on dataset v0 (P0-7). COCO has no can, case or
  cap class.
- **More than one storeroom.** This is three bays and 58 keyframes, with walkthrough's 2D stand-in for
  ARKit.
- **Larger inputs.** YOLO ran at 640 px only, with no tiles.
- **Tuned thresholds.** None were tuned; the threshold table shows how far they move the counts.
- **The phone.** No iPhone latency, no ARKit contention, no heat.

## License hygiene (ADR 002)

- Ultralytics ran only in its own venv (`research/yolo_eval/venv`). Weights, exports, settings and
  scratch keyframes stayed in `research/yolo_eval/work/`. Both are git-ignored.
- Only `yolo_detect.py`, `export_coreml.py` and `prompt_probe.py` import `ultralytics`.
  - `walkthrough.py` gained only the new names, their thresholds and a message, and never imports it.
  - Nor do `run.py`, `analyse.py` or `coreml_bench.py`.
- Ultralytics' usage analytics were off: settings in `work/config`, with `sync` off.
