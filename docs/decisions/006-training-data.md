# ADR 006: Training data, labelling and ML tooling

Status: **Accepted** · 2026-09-25 · Amendment 1 (`bottle_top`, labelling without CVAT) **Proposed** · 2026-10-02,
[below](#amendment-1-bottle_top-and-labelling-without-cvat)

## Decision

- **Train on our own storeroom images.** Use public datasets only where the license allows
  commercial use, and only as a supplement.
- **Classes: `bottle`, `can`, `case`.** Add a class only when error analysis on real sessions
  shows it is needed.
  - No `keg` class: full and empty kegs look identical.
  - Candidate additions: `bottle_top` (caps seen in an open case), `rack_bottle` (bottle
    ends in wine racks).
- **Pipeline:**
  1. **Capture:** in-app capture mode records keyframes + depth + pose at 1–2 Hz during counts,
     plus handheld video.
  2. **Pre-label:** Grounding DINO (original, Apache-2.0) or OWLv2 (Apache-2.0) with prompts
     "bottle / can / cardboard box", on a rented GPU. SAM 3 is also allowed: its license has no
     non-commercial clause and does not restrict outputs.
  3. **Correct:** human review in **self-hosted CVAT** (MIT, free, supports model-assisted
     labelling), exported as COCO.
  4. **Train:** RF-DETR Nano with `rfdetr` (Apache-2.0), starting from the COCO checkpoint.
     Holdout = every image from one venue the model never saw.
  5. **Evaluate:** `supervision` (MIT) for mAP and the confusion matrix, plus our own count
     metric: per-view |predicted − true| / true.
  6. **Export:** Core ML FP16. A parity test compares Core ML counts with PyTorch counts before
     the model can ship.
- **Data flywheel in the pilot:** an opt-in diagnostic bundle carries keyframes plus the user's
  corrections. Removed items are false positives; accepted "possible miss" prompts are false
  negatives. These become new labelled examples.

## Dataset targets

| | Phase 0 (go/no-go) | Pilot start | After pilot |
|---|---|---|---|
| Labelled images | ≥ 1,500 from ≥ 5 venues (+ staged shelves) | ≥ 4,000 | ≥ 10,000 |
| Must include | glass glare, 50–100 lux, torch on, cold-room fog, identical rows, stacked cases, open cases from above, steel reflections | all of these at pilot venues | – |
| Holdout | 1 unseen venue | 1 unseen venue | 2 unseen venues |

## Public data: what we may use

| Dataset | Relevant classes | Commercial use |
|---|---|---|
| COCO | bottle | Annotations CC BY 4.0. Image copyright stays with Flickr authors, "full responsibility" on the user. **Pretraining is already in the checkpoint; don't add more.** |
| Open Images V7 | Bottle, Tin can, Box, Beer, Wine, Wine rack | Annotations CC BY 4.0; images "listed as" CC BY 2.0 with no warranty. **Usable with attribution and per-image checks** |
| LVIS | beer bottle, beer can, box, carton, crate, keg | License unverified; don't use until checked |
| Objects365 | Bottle, Canned, Storage box | **Academic only.** Already inside the YOLO26 and RF-DETR checkpoints: legal check before launch (ADR 002) |
| SKU-110K, Products-10K | Dense shelves / product IDs | **Non-commercial.** Don't train on them |
| Roboflow Universe | Many bottle and can sets | License set per dataset; check each one |

## Labelling tool

| | CVAT self-hosted (chosen) | Label Studio CE | Roboflow |
|---|---|---|---|
| License / cost | MIT, free | Apache-2.0, free; cloud from $99/mo | Free tier makes **data public** (venue photos: no); Core $79–99/mo |
| Model-assisted labelling | Yes (serverless functions, HF / Roboflow models) | Yes (ML backend: Grounding DINO, SAM 2) | Yes (SAM 3, etc.; credits) |
| Export | COCO, YOLO, VOC | COCO, YOLO, VOC | COCO, YOLO, … |

**Roboflow Core is an acceptable paid shortcut** if self-hosting CVAT costs more time than
$99/month. What rules out the free tier is keeping venue photos private.

## Guardrails

- **Label rules, written down before labelling starts:**
  - Box the visible object. A partly visible object counts if more than 50% of it is visible.
  - Cases are one box per carton face. Shrink-wrapped trays are a case.
  - Reflections are **not** labelled (the model must learn to ignore them).
- **No personal data in images:** blur faces in any frame kept for training. Storerooms rarely
  have people, but check.
- **Model card per release:** data version, holdout results, the Core ML parity result, and the
  licenses of everything in it.

## Amendment 1: `bottle_top`, and labelling without CVAT

Status: **Proposed** · 2026-10-02. Context: P0-7 dataset v0, built in `ml/` from the two storeroom walks.

### `bottle_top` becomes a class
The classes become `bottle`, `can`, `case` and `bottle_top`, in the order of `ObjectClass` in
[mvp-test-app.md](../mvp-test-app.md).

**Why:**
- The MVP has no `×N deep` multiplier (FR-29 removed) and no "more behind?" prompt (2 October 2026). The camera counts
  the rows behind the front row by their tops.
- On the second walk, counting caps took bays 1 and 2 from about half the bottles to about seven eighths (walkthrough
  [RESULTS §12, §17](../../research/walkthrough/RESULTS.md)).
- In the labelling pilot, five held keyframes labelled with tops showed 51 of the 54 reference units of the products in
  view ([ml/LABELING.md](../../ml/LABELING.md)).

**Rule.** Every visible top gets a box, on front and back rows alike. So a front bottle has a `bottle` box and a
`bottle_top` box. Counting merges them: a top in the top region of a bottle counted in the same view is that bottle;
any other top is a bottle in a row behind.

**Risk.** Tops are small. At Nano's 384 px input, a cap from a 1080 × 1920 frame is about 10–40 px. Dataset v0's test
set measures this; a larger input (512 or 576) costs latency (ADR 002).

### Labelling
- **Boxes, not masks** (owner, 2026-10-02). Masks are revisited only if P0-4 shows that boxes give poor LiDAR depth.
  They could then be generated from the corrected boxes with SAM, with no relabelling.
- **CVAT needs Docker, which the development Mac lacks** (no Docker, no Homebrew).
  - For v0, Claude labelling agents correct OWLv2's draft boxes with `ml/review.py`: renders with numbered boxes and a
    pixel grid, JSON edits, re-renders and QA checks. The owner spot-checks on a local page.
  - In the pilot this took about 4 minutes and 4 image views per frame. 38% of the draft boxes were right as drawn,
    25% needed moving and 37% deleting.
  - Label Studio Community Edition (Apache-2.0) was the planned stand-in for CVAT. It was set aside when the agents
    took over the corrections.
  - CVAT stays the choice for human labelling once there is a Docker host.
- **The label rules are written down in [ml/LABELING.md](../../ml/LABELING.md)** (the guardrail above). Additions to
  the rules above:
  - The 50% rule also covers objects cut by the image border.
  - Tops are labelled whenever they can be identified, even when mostly hidden behind a front cap: that is what they
    are for.
  - Open bottles are bottles. A single bottle in its own gift box is a `bottle`. Food tins are `can`.
  - Frames that show a person are excluded rather than blurred.
- **Cartons and bags** are boxed as `carton` and `bag` but not trained in v0. They are about 8% of the units in the
  three filmed bays. Whether the app counts them is the owner's decision; without a class they stay manual lines.
- **The pre-labeller keeps front bottles.** `walkthrough.clean()` can remove a front bottle as a "row box" when the
  neck and cap boxes of the bottles behind lie inside it. In the pilot it did so in every one of the five frames
  checked. `ml/prelabel.py` counts a box as a row only when it holds whole-height objects.

### Data and training for v0
- **Splits.** Walk 1 is train and val, in 10 s blocks with a 1 s gap at each boundary. Walk 2's hold keyframes are the
  test set, because only walk 2 has reference counts per product.
- **Leakage limit.** It is the same venue, the same products and the same phone, four days apart. That is not the
  unseen-venue holdout this ADR requires; that holdout still needs a second venue.
- **Training on the development Mac.** RF-DETR Nano trains on MPS in full fp32: about a minute per epoch of 100 frames
  on an Apple M5. torch 2.7's fp16 GradScaler fails on MPS, so mixed precision is for CUDA only.
- **Evaluation.** Besides mAP, `ml/eval.py` reports the per-view count error for bottle units: bottles plus tops with
  no bottle of their own.
