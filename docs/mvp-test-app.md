# MVP test app: plan and module contract

**Goal.** Walk around the storeroom, hold on each shelf section, and leave with a counted stock
sheet (CSV/XLSX). This is the PRD v2 MVP, minus everything a test with one venue does not need yet.

**Product decisions (2 October 2026) the app must follow:**
- **Every bottle the camera sees counts as one unit, sealed or open.** No open-bottle or
  fill-level detection.
- **No depth to type in.** There is no `×N deep` multiplier (FR-29 removed) and no "more behind?"
  prompt. The camera counts the rows behind a front row by their **tops** (`bottle_top`): on the
  second storeroom walk, tops took the count from about half the bottles to about seven eighths
  ([walkthrough results §17](../research/walkthrough/RESULTS.md)).
- **Stock the camera can't see is not counted.** Manual lines (FR-30) stay, for kegs and closed
  cupboards.

## Milestones

| | What works | PRD |
|---|---|---|
| **M0: see** | AR session with LiDAR depth; live detector boxes; debug HUD; capture mode that records keyframes, depth, pose and intrinsics for offline replay | P0-2, P0-3, FR-11, FR-12 |
| **M1: count** | Hold-to-count commits; inner-frame rule; green overlays anchored in 3D; counted zones; 1:1 matching; possible-miss "+"; undo | FR-13–16, FR-18, FR-21, FR-22, FR-26 |
| **M2: name and export** | Groups per commit, named by the user (pick, search or create a product); live list; review; CSV/XLSX export through the share sheet; manual lines | FR-27, FR-28, FR-30–36 |
| Later | Teach-once suggestions (FeaturePrint), case barcodes, rack tags, map save and restore, drift alarm tuning, Spanish | FR-24, FR-25, ADR 004 |

## Build environment

- **The development Mac has no Xcode yet,** only the Swift 6.3 command line tools.
  - Pure-Swift packages build and test on macOS now: `app/scripts/swift-test.sh <package dir>`.
  - iOS-only code (ARKit, RealityKit, UIKit) is written behind `#if os(iOS)` and compiled once Xcode
    is installed.
- **Tests:** Swift Testing (`import Testing`).
- **Swift 6** language mode, strict concurrency. Platforms iOS 18 and macOS 15.
- **Dependencies:** GRDB (MIT) is the only third-party package so far. Add another only with a note
  here: name, license, and why.

## Layout

```
app/
  Packages/
    StockMaskCounting/  hold-to-count trigger, inner-frame rule, commit engine (ADR 003 S5),
                        top/bottle merge, drift alarm. Pure Swift + simd, no ARKit. Tested on macOS.
    StockMaskCore/      domain model, GRDB persistence, stock sheet aggregation, catalog import,
                        CSV/XLSX export. No ARKit. Tested on macOS.
    StockMaskAR/        AR session, Detector protocol + Core ML detector, 3D lifting, live tracks,
                        overlays, capture mode, and the SwiftUI screens. iOS; its non-AR parts are
                        tested on macOS.
  StockMask/            the thin app target (App entry point, Info.plist keys, assets)
  scripts/swift-test.sh
ml/                     dataset, labelling, training, Core ML export (separate track)
```

Dependencies point one way: `StockMaskCounting` and `StockMaskCore` don't know about each other;
`StockMaskAR` uses both and maps between them; the app target uses `StockMaskAR`.

**The Xcode project.** It can't be generated or checked without Xcode, so it is created when Xcode
is installed. Keep the app target thin (entry point, Info.plist, assets) so that takes minutes.

## Contract between the packages

`StockMaskCounting` owns these value types. The names are fixed; the fields can grow.

```swift
public enum ObjectClass: String, Codable, Sendable { case bottle, can, `case`, bottleTop = "bottle_top" }

public struct Detection: Sendable {          // one detector box, lifted to 3D when depth allows
    public var cls: ObjectClass
    public var score: Float
    public var box: SIMD4<Float>              // normalised image coordinates: x0, y0, x1, y1
    public var position: SIMD3<Float>?        // metres, world (or anchor) space
    public var size: SIMD2<Float>?            // metres, width and height in the image plane
}

public struct CountedItem: Sendable, Identifiable { public let id: UUID; public var cls: ObjectClass
    public var position: SIMD3<Float>; public var commitID: UUID; public var groupKey: Int? }

public struct CountedZone: Sendable, Identifiable { public let id: UUID; public var commitID: UUID
    public var transform: simd_float4x4; public var halfExtents: SIMD3<Float> }  // an oriented box

public struct CommitResult: Sendable {
    public var commitID: UUID
    public var newItems: [CountedItem]        // added to the count
    public var matched: [(detection: Int, item: UUID)]
    public var possibleMisses: [Int]          // detection indices: shown as amber "+", never added
    public var zone: CountedZone
    public var driftAlarm: Bool
}
```

- **`HoldTrigger`** is fed per frame: angular speed (deg/s), timestamp, whether a stable candidate
  is in view, and whether tracking is normal. It returns "commit now" (FR-13: 0.8 s under 10°/s;
  re-arms after 5° of movement). The shutter always commits.
- **`CommitEngine`** takes a commit's detections and the view geometry, and returns a
  `CommitResult` (FR-14, FR-21–23, S5). It supports undo of the last commit.
- **Bottles and tops.** A top that belongs to a bottle counted in the same view is the same unit.
  A top with no bottle under it (a row behind) counts as a bottle. The rule and its limits are
  documented in the package README.

`StockMaskCore` owns persistence and the sheet: venue, zone, sku, session, commit, counted_zone,
item, item_group, manual_line and event, as in PRD §11 without `depth_multiplier`. Every commit is
one database transaction (FR-7). The exported sheet has one line per product, with units and full
cases (ADR 005 columns). Unnamed groups appear as "Unknown A", "Unknown B" and so on.

## Data flow (M0–M2)

```
ARFrame ─► Detector (Core ML) ─► [Detection: box, cls, score]
        ─► Lifter (LiDAR depth: label band, high-confidence pixels, shelf-plane fallback) ─► position
        ─► LiveTracks (3D association, ≥ 3 hits = stable candidate)
        ─► HoldTrigger ─► CommitEngine.commit ─► CommitResult
        ─► StockMaskCore: save commit, items, zone, keyframe (one transaction)
        ─► overlays: green on counted items, tint on zones, amber "+" on possible misses
        ─► live list ─► review ─► export
```

**Detector.** RF-DETR Nano with COCO weights first (it knows only `bottle`). Then the fine-tuned
model from `ml/`, with classes `bottle`, `can`, `case`, `bottle_top`. The app reads the class list
from the model's metadata. Ultralytics YOLO is under evaluation (`research/yolo_eval/`), so keep
`Detector` model-agnostic.

## Rules for everyone working here

- **This repository is public.** No venue footage, frames, product names or locations in it. Venue
  data lives in git-ignored folders.
- **Each track works on its own branch** and commits there. Integration happens on
  `claude/mvp-test-app`.
