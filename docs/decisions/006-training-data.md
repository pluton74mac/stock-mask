# ADR 006: Training data, labelling and ML tooling

Status: **Accepted** · 2026-09-25

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
