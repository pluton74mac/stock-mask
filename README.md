# StockMask (working name)

Stocktaking for bar storerooms with the phone camera:
1. Hold the phone on each shelf section.
2. Counted bottles, cans and cases turn green in AR and stay green.
3. Leave with a list, and a photo record of every shelf.

**Status:** reviewed PRD, ready for Phase 0 (4-week technical spike + discovery). No app code
yet.

## Read in this order

1. [`docs/PRD.md`](docs/PRD.md): the product requirements (v2.0, reviewed).
2. [`docs/PRD-v1-review.md`](docs/PRD-v1-review.md): what changed from the v1 draft, and why.
   30 claims checked, with sources.
3. [`docs/phase-0-plan.md`](docs/phase-0-plan.md): what we build and measure first, and the
   go/no-go gates.
4. Decision records, each with a comparison of options:
   - [001 Platform](docs/decisions/001-platform.md): native iOS, LiDAR-only, iOS 18+.
   - [002 Detector](docs/decisions/002-detector.md): RF-DETR Nano (Apache-2.0). Where
     Ultralytics and `supervision` fit.
   - [003 Double counting](docs/decisions/003-double-count.md): counted zones + local matching +
     prompts; optional rack tags.
   - [004 Product identification](docs/decisions/004-sku-identification.md): name a group once;
     the app suggests next time.
   - [005 Storage, backend, export](docs/decisions/005-storage-backend-export.md): GRDB, no
     backend in the MVP, XLSX + Argentine CSV.
   - [006 Training data](docs/decisions/006-training-data.md): own data, CVAT, unseen-venue
     holdout.

## Experiments behind the decisions

- [`research/dedup_sim/`](research/dedup_sim/): Monte-Carlo comparison of anti-double-count
  strategies under tracking drift (`python sim.py`).
- [`research/coreml_export/`](research/coreml_export/): converting YOLO26 / YOLO11
  (Ultralytics) and RF-DETR (Roboflow) to Core ML, with an op inventory.
- [`research/walkthrough/`](research/walkthrough/): replays a phone video of a storeroom walk
  through hold-to-count, the detectors and 2D anti-double-count matching, before the iOS spike
  exists (`python walkthrough.py VIDEO`). Includes how to film one. Results on real footage are in
  [`RESULTS.md`](research/walkthrough/RESULTS.md). The first walk was continuous sweeps at
  0.4–0.7 m. On the second, filmed with holds, every hold committed, but some stock was never held.
  Against per-product reference counts, detecting whole bottles finds about half the stock in rows
  2–5 deep; counting caps finds most of it on the spirits shelves.
