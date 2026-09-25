# Phase 0: Prove it before building it (4 weeks)

The goal is to answer five questions with measurements, not opinions:

1. **Problem:** is the storeroom count painful enough?
2. **Detector:** can it count our three classes reliably on a phone?
3. **3D placement:** can we place glass bottles in 3D precisely enough?
4. **Revisits:** does the anti-double-count design (ADR 003) hold up in real rooms?
5. **Endurance:** does it survive a 30-minute session?

Team assumption:
- 1 iOS/ARKit engineer, full time;
- 1 ML engineer, half time;
- Franco, for venue access and discovery.

Everything here runs in parallel tracks.

## Week-by-week

| Week | Discovery (Franco) | iOS spike | ML |
|---|---|---|---|
| 1 | Book 5 venues. Run P0-1 at the first two. | P0-2 skeleton: ARKit + depth + debug HUD + capture mode | Label rules. CVAT up. Pre-label pipeline. Capture at venues 1–2 |
| 2 | P0-1 at venues 3–5 | P0-3 detector on device. P0-4 depth on glass | 1,000 images labelled. First RF-DETR-N fine-tune |
| 3 | Interviews: tags OK? export target? price? | Commit engine + zones + list (spike quality). P0-5 revisit measurements | 1,500 images. Holdout eval. Core ML parity. P0-6 SKU bake-off |
| 4 | Write discovery memo | P0-8 staged-room end-to-end. P0-9 environment checks | Model card. Error analysis |
| End | **P0-10 decision memo: go / no-go / change course** | | |

## Tasks and how each is measured

### P0-1 Baseline time-and-motion (discovery)
- **What we record at 5 venues,** watching one full stocktake done the venue's usual way:
  - storeroom full units vs behind-bar partials, timed separately with a stopwatch;
  - SKUs and units counted;
  - interruptions;
  - how the result gets into their system (paper → Excel? app? POS?).
- **Photos of every storage area**, to see how it's arranged:
  - rows several deep; stacked cases; open cases;
  - kegs; empties and returnable crates;
  - lighting (lux, from a phone lux meter app); walk-in temperature.
- **Questions to ask:**
  - Would you stick a printed tag on each rack?
  - Where must the numbers end up (Excel, Fudo, Maxirest…)?
  - What would you pay for this?

**Gate G1:** at ≥ 3 of 5 venues, storeroom full-unit counting takes ≥ 45 min per count, or is
≥ 30% of total stocktake time. If not, stop and reconsider the wedge; partial bottles may matter more.

### P0-2 Spike app skeleton (iOS)
- **AR session:**
  - `ARWorldTrackingConfiguration` with `sceneDepth` + `smoothedSceneDepth`;
  - relocalization enabled (`sessionShouldAttemptRelocalization` → true);
  - world map save/load per zone;
  - rack-tag detection (`detectionImages`, 10 printed tags).
- **Debug HUD:**
  - tracking state and world-mapping status;
  - FPS; detector ms; thermal state; battery %.
- **Capture mode** for ML data: keyframe JPEG + depth + confidence + pose + intrinsics at 1–2 Hz.

### P0-3 Detector on device (iOS + ML)
- **Models:** RF-DETR-N (Core ML FP16) and YOLO26n (Core ML FP16, benchmark only), both on COCO
  weights first, then fine-tuned.
- **Devices:** iPhone 13 Pro, the oldest target; plus one current Pro.
- **Measure:**
  - Xcode Core ML performance report: per-op compute unit, median latency;
  - in-app p50/p95 latency *with ARKit running and overlays rendering*;
  - thermal state over a continuous 20-minute session.

**Gate G3:** RF-DETR-N p95 ≤ 60 ms with ARKit on iPhone 13 Pro, and never `critical`
thermal state in 20 min. If RF-DETR fails and YOLO26n passes, budget the Ultralytics Enterprise
License (ADR 002).

### P0-4 3D position of glass bottles (iOS)
- **Setup:** 20 bottles (clear, green, amber glass, opaque ceramic), cans and cases on a
  shelf. Ground truth measured with a tape against a rack tag.
- **Compare depth sampling strategies:**
  - (a) median of all depth pixels in the box;
  - (b) high-confidence pixels only;
  - (c) the label band (central 40% of the box height);
  - (d) the shelf plane + class radius, as a fallback.
- **Measure:** 3 distances (0.8 / 1.2 / 1.8 m), 3 angles.

**Gate G4:** the best strategy gives lateral error ≤ 2 cm median, ≤ 4 cm p95.

### P0-5 Revisit error in real rooms (iOS)
- **Rooms:** 3 real storerooms.
- **Setup:** fix 6 rack tags per room as ground-truth reference points. They are *not* used
  for tracking in the markerless runs.
- **Protocol:** count the room, walk out, come back after 2–5 minutes and re-view each tag.
  Record the offset between where the app thinks the tag is and where it is detected now.
- **Runs:**
  - 10 runs markerless (ARKit + per-commit anchors + world map);
  - 10 runs with tags used as anchors.
- **Wrong-rack test:** 20 relocalisation trials in a room with two identical racks. Cover the
  camera until tracking is lost, then resume at the other rack.

**Gate G5:**
- Markerless p95 revisit error ≤ 5 cm **and** 0 wrong-rack relocalisations → tags optional.
- Otherwise → **rack tags mandatory** in the MVP.

### P0-6 SKU suggestion bake-off (ML)
- **Data:** 50 SKUs × 10 crops each, from 2 venues and 2 lighting conditions.
- **Compare:** Apple FeaturePrint rev2 vs DINOv2-S/14, kNN top-1 / top-3, with galleries of
  1, 3 and 5 taught examples per SKU.
- **Also test:** does OCR with `customWords` lift top-1?

**Gate G6-SKU:** FeaturePrint top-3 ≥ 85% with 3 examples → keep it. Else use DINOv2-S.

### P0-7 Dataset v0 and model v0 (ML)
- **Data:** ≥ 1,500 labelled images from ≥ 5 venues plus staged shelves (see ADR 006 for
  must-include conditions). Holdout = one whole venue.
- **Training and export:** fine-tune RF-DETR-N, export to Core ML, run the parity test.

**Gate G2:**
- Holdout per-view count error ≤ 3% median, ≤ 8% p90;
- precision ≥ 98% at the commit threshold.

### P0-8 Staged-room end-to-end (iOS)
- **Room setup:** ≥ 150 units on 3 racks. Include:
  - two identical rows of the same bottle;
  - bottles 3 deep;
  - a stacked case column;
  - an open case;
  - one steel surface (reflections).
- **Runs:** 5 full runs of the spike (hold-to-count, zones, prompts). Each run includes:
  - a revisit pass;
  - an app kill + relaunch mid-session.

**Gate G7:**
- Double counts ≤ 1% of units;
- final missed ≤ 1% after accepting prompts;
- prompts ≤ 10% of units;
- relaunch restores map + list in ≤ 10 s in 5/5 runs.

### P0-9 Environment (iOS)
- **Torch:** can it be switched on during an ARKit session on each test device? Apple does not
  document this; developers report it works when set about 0.5 s after the session starts.
- **Walk-in cooler:**
  - 10-minute session in the cooler;
  - battery drop;
  - detection quality after leaving the cooler (lens fog). Measure how long until it recovers.
- **Light:** tracking quality at 50 / 100 / 300 lux.

**Gate G8:**
- Torch works, or we have a documented fallback (exposure bias + clip-on light);
- the cooler session completes.

### P0-10 Decision memo
- **For each gate:** pass / fail, with the numbers.
- **Decisions to record:**
  - detector (RF-DETR-N or YOLO26n + license);
  - rack tags optional or mandatory;
  - FeaturePrint or DINOv2;
  - any scope change from discovery.
- **Update the PRD** with the results and turn this plan's spike code into the Phase 1 backlog.

## Suggested repository layout (created in P0-2)

```
app/                    Xcode project "StockMask" (iOS 18+, Swift 6)
  StockMask/            SwiftUI app target
  Packages/
    StockMaskCore/      domain model, GRDB persistence, export (no ARKit imports; unit-testable)
    StockMaskAR/        capture session, detector, 3D lifting, commit engine, rendering
ml/                     Python: labelling tools, training (rfdetr), eval (supervision), Core ML export + parity test
research/               experiments behind the decisions (this review)
docs/                   PRD, decision records, plans
```

Keep `StockMaskCore` free of ARKit so the counting and export logic can be unit-tested on a Mac.
Port the dedup simulation's matching logic (`research/dedup_sim/sim.py`, strategy S5) into
`StockMaskAR/CommitEngine`. Replay recorded sessions from capture mode against it in unit tests.
