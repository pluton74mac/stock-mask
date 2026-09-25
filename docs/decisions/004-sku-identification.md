# ADR 004: How a detected group becomes a product (SKU)

Status: **Accepted, thresholds calibrated in Phase 0 (P0-6)** · 2026-09-25

## Decision

**The camera counts generic units (bottle / can / case). The user names each group once.** The app
learns from that and suggests the name next time. It never assigns a product silently.

On every commit (a steady view of shelf items, see ADR 003):

1. **Group the items that look the same.** Compute an image embedding per item crop, then
   cluster within the commit.
2. **Suggest a product for each group, strongest signal first:**
   1. **Case barcode.** Vision reads ITF-14 / EAN-13 / GS1 DataBar / QR on the keyframe. If the
      code is mapped in the catalog, the case SKU is suggested with high confidence. GS1 puts case
      codes on the carton sides, so they are often visible. Bottle codes are on the back label, so
      for bottles this signal is rarely available.
   2. **Teach-once.** k-nearest neighbours between the group's embedding and the venue's saved
      examples (crops the user has already named). Top-3 suggestions.
   3. **Size hint.** Bottle height from LiDAR (label region only) separates 700 ml from 1 L.
      Used as a tie-breaker only.
3. **The user confirms or picks.** The commit card shows "8 × bottle → *Jameson 700 ml*?" with one
   tap to confirm. Unnamed groups stay "Unknown A/B/…" in the list, with their photo, until named
   in review. Confirmed names become new teach-once examples.

**Embedding model: Apple Vision FeaturePrint** (`GenerateImageFeaturePrintRequest`, revision 2,
768-d).
- It ships inside iOS, so there are no weights to license, bundle or update.
- Switch to **DINOv2 ViT-S/14** (Apache-2.0, 21 M params, Core ML FP16) if Phase 0 shows
  FeaturePrint top-3 accuracy below 85% on our crops.

## Options compared

| Option | License | On-device cost | Evidence of accuracy | Verdict |
|---|---|---|---|---|
| **Apple FeaturePrint rev 2** | Part of iOS | None to ship | No published product-retrieval benchmark | **Default.** Measure in Phase 0 |
| DINOv2 ViT-S/14 | Apache-2.0 | 21 M params | Zero-shot product retrieval with the *large* model: 50% R@1 on Products-10K ([nyris 2026](https://arxiv.org/abs/2603.17186)) | **Fallback** |
| MobileCLIP / MobileCLIP2 | **Weights research-only since 2025-08-28** ("does not include … use in any commercial product") | 1.5 ms image encoder | GroceryVision: MobileCLIP-S2 62% R@1 text→image | **Rejected on license** |
| SigLIP2 B / PE-Core S | Apache-2.0 | 86 M / about 20 M params | PE-Core-L 66% R@1 zero-shot (Products-10K) | Keep in mind for text→image zero-shot later |
| Train a brand classifier | Ours | Retrain for every new SKU or package | Needs labelled photos per SKU per venue | **Rejected.** This is the NomadGo/Starbucks failure: "up to six weeks of retraining" for seasonal packaging |
| Label OCR (Vision `RecognizeTextRequest`, es/en, `customWords` = catalog brands) | Part of iOS | Accurate mode is slower | No published label benchmark; ignores text under 1/32 of the frame height | Phase 1 stretch, only if P0-6 shows it lifts top-1 |
| Cloud vision LLM | Vendor | Needs network, costs per call, sends venue photos off the device | – | Out of MVP (offline, privacy) |

## Why teach-once instead of "recognise every liquor brand"

- **Published zero-shot SKU retrieval is weak:** 35–66% top-1 even with large models. Models
  trained on the domain reach 77–88%, and that needs the training data we don't have.
- **Our problem is far easier than those benchmarks.**
  - Same venue, same physical products, similar lighting week to week.
  - A gallery of 100–400 SKUs, of which about 20–50 move in a given week.
  - We match *this venue's shelf crops* to *this venue's earlier shelf crops*, not catalog
    photos to shelf photos.
- **It degrades gracefully.** A wrong suggestion costs one tap. A missing suggestion costs one
  search. A silent wrong assignment would corrupt the stocktake, so it is not allowed.

## Consequences

- **Catalog:** stores `case_gtin` (GTIN-14) separately from the unit barcode. The case code is
  the unit GTIN with an indicator digit and a new check digit, and it is the one the camera sees.
- **First count at a venue:** slower, because every group needs naming. Pilot metrics are
  judged from the **third** count (PRD §5).
- **Stored embeddings are tied to the FeaturePrint revision.** Pin the revision in code. Keep
  the crops so embeddings can be recomputed if the model changes.
