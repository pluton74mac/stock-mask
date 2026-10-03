# StockMaskAR

The iOS layer of the MVP test app ([plan and contract](../../../docs/mvp-test-app.md)):
- the AR session;
- the detector;
- box → 3D lifting from LiDAR;
- live tracks;
- the 3D overlays;
- capture mode;
- the SwiftUI screens.

It uses [StockMaskCounting](../StockMaskCounting) (when to count, what counts, what was counted
before) and [StockMaskCore](../StockMaskCore) (what is saved and exported), and maps between them.
The app target ([`app/StockMask`](../../StockMask)) only shows `StockMaskRootView`.

- **Swift 6**, strict concurrency. iOS 18, macOS 15.
- **Dependencies:** the two local packages, and through StockMaskCore, GRDB 7.11.1 (MIT, pinned in
  `Package.resolved`).

```sh
app/scripts/swift-test.sh app/Packages/StockMaskAR   # 57 tests, macOS, no Xcode needed
app/scripts/typecheck-ios.sh                         # compiles the iOS-only code too (below)
```

## What is built, tested and run

| Code | Built | Tested on macOS | Run on an iPhone |
|---|---|---|---|
| Everything outside `iOS/`: detector, decoder, input resizer, geometry, Lifter, tracks, motion, capture format, grouping, StockMaskCounting and StockMaskCore bridges, counting session, overlay state and RealityKit renderer, the SwiftUI screens | macOS | yes (57 tests) | no |
| `iOS/`: `ARFrameConversion`, `ARSessionController`, `CountingScreen` (ARKit, `ARView`, UIKit), and `app/StockMask/StockMaskApp.swift` | **Mac Catalyst only** | no | no |

**How the iOS code is compiled without Xcode.**
- The macOS SDK ships Mac Catalyst copies of ARKit, RealityKit and UIKit, and `#if os(iOS)` is
  true on Catalyst.
- `typecheck-ios.sh` builds the package graph with SwiftPM for `arm64-apple-ios18.0-macabi`
  (GRDB, StockMaskCounting, StockMaskCore, StockMaskAR), then type-checks the app target against
  it.
- A deliberate type error in an `#if os(iOS)` file makes it fail, so that code is really compiled.
- It is not an iOS build. Linking, iOS-only availability and runtime behaviour need Xcode.

### Not run yet

Only the phone can show these. Check them first:
- **`ARFrame.displayTransform`.** Do the yellow outlines sit on the bottles? The code assumes it
  maps normalised captured-image points to normalised view points, which is how Apple's Metal
  sample uses it (`DisplayMapping`).
- **Upright orientation.** Portrait is `CGImagePropertyOrientation.right` (`FrameOrientation`).
  Bottles should stand upright in the keyframes, and a capture's `--frames` export should look
  right.
- **Depth.** Is `sceneDepth` (`kCVPixelFormatType_DepthFloat32`) with its confidence map copied
  row by row (`DepthMap(depthBuffer:confidenceBuffer:)`)?
- **Anchors.** Are the overlays anchored per commit (`AnchorEntity(anchor:)`), and do they follow
  ARKit's anchor updates?
- **RealityKit.** Is the transparency right, do the amber "+" turn to face the camera
  (`BillboardComponent`), and do taps on them hit (`ARView.entity(at:)`)?
- **The torch during AR** (P0-9), through `configurableCaptureDeviceForPrimaryCamera`.
- **Device state:** thermal state, battery, haptics.
- **Detector speed:**
  - CPU + GPU against the Neural Engine, with ARKit and RealityKit running (P0-3);
  - how long `ModelInputResizer` takes on a YCbCr camera buffer in a release build.
- **Capture mode:** write speed at 2 Hz, and the size of a zipped walk.

## Data flow

```
ARFrame (ARSessionController, iOS)
  └─ FramePump.process: light snapshot every frame; depth copied only when needed
       ├─ CountingSession.frameDidUpdate → ViewMotion (speed + shift) → HoldTrigger → FrameDecision
       ├─ detector due (12 Hz; 5 Hz when hot) → CoreMLDetector (actor): ModelInputResizer → Core ML → DETRDecoder
       │     └─ detectorDidFinish → Perception.lift (Lifter) → LiveTracks → yellow outlines
       ├─ commit (hold or shutter) → CountingSession.commit
       │     stable tracks → CountingBridge (turned to ARKit's image) → CommitEngine.commit
       │     → groups (FeaturePrint + ItemGrouper) → files first (CommitFileStore) → ARAnchor
       │     → CoreStockStore.saveCommit (one transaction) → OverlayState → OverlayRenderer (RealityKit)
       │     → haptic, +N, card, list
       └─ capture due (1–2 Hz) → CaptureController → CaptureWriter (actor)
```

## Coordinates

- **Everything in StockMaskAR uses the upright image:** the image as the user sees it, normalised,
  origin top-left. That covers detector boxes, the inner frame, `CameraModel` and the `DepthMap`
  given to the Lifter. `FrameOrientation` turns ARKit's stored (landscape) image upright, with the
  camera's intrinsics and axes.
- **StockMaskCounting wants ARKit's stored image** (its README, "Conventions"). `CountingBridge`
  turns boxes, sizes and the camera back with `CameraModel.sensor(_:)`. Tests run the whole
  session in portrait to cover that path.
- **Capture mode stores what ARKit delivers:** landscape images and depth, ARKit's intrinsics and
  transform, plus the orientation.
- **World space is ARKit's:** metres, +y up. Items sit at their axis, mid-height (the Lifter
  pushes the visible front back by the class radius).

## Detector

- **The `Detector` protocol** is model-agnostic (ADR 002). `CoreMLDetector` reads everything about
  the model from its metadata: class list, output names, thresholds. A fine-tuned model with
  `bottle`, `can`, `case`, `bottle_top` replaces the COCO one without code changes. Details are in
  [`ml/coreml/README.md`](../../../ml/coreml/README.md).
- **`ModelInputResizer`** makes the model's input the way rfdetr does: upright, stretched, bilinear
  without antialiasing, ARKit's YCbCr converted with the buffer's own matrix. Vision's
  antialiased resize alone costs bottles ([`ml/coreml/RESULTS.md`](../../../ml/coreml/RESULTS.md)).
- **Compute units: CPU + GPU by default.** FP16 on the M5's Neural Engine fails parity with
  PyTorch, while the GPU's passes. This departs from ADR 001 until P0-3 measures the phone. The HUD
  switches.
- **Where the model comes from** (`DetectorModelLocator`):
  1. the newest `Documents/Models/*.mlpackage`, compiled on the phone;
  2. else `StockMaskDetector.mlmodelc` in the app bundle.

## Lifting (PRD §11, P0-4)

`Lifter` implements P0-4's four strategies, and keeps every estimate (`LiftResult.estimates`) so
they can be compared:

| | Strategy | Pixels |
|---|---|---|
| (a) | `medianAll` | median of every valid depth pixel in the box |
| (b) | `highConfidence` | median of the box's high-confidence pixels |
| (c) | `labelBand` | median of the central 40% of the box height and 60% of its width, medium or high confidence |
| (d) | `shelfPlane` | the box's bottom on a horizontal ARKit plane, raised half the item's height |

**The starting policy:**
1. (c), else (b).
2. If that is more than 10 cm behind the plane estimate, the sensor saw through glass to the wall
   behind, so (d).
3. With no depth estimate at all: (d), else (a).

Tops never use the plane. Sizes per class flag implausible boxes (`ClassPrior`), and implausible
tracks never become candidates. A synthetic glass bottle with an opaque label is in the tests.
P0-4 picks the real winner from capture walks (`research/capture_replay`).

## Live tracks, holding, committing

- **`LiveTracks`.**
  - Association is greedy and one to one: in 3D within 5 cm, same class; detections without depth
    use 2D IoU.
  - A track is a stable candidate after 3 hits in 0.5 s (ADR 003).
  - Positions are a running mean.
- **`ViewMotion`.** Rotation plus sideways travel over the scene's distance, as a speed and as a
  shift. StockMaskCounting's HoldTrigger filters the speed and re-arms on the net shift.
- **Commits.**
  - **Detections.** A commit uses the stable tracks.
  - **Inner frame.** The engine's inner frame grows to stay on screen. Aspect fill shows only about
    62% of the camera image's width on a 19.5:9 phone, and nothing off screen should be counted.
  - **Drift alarm (FR-23).** The alarm only flags in the engine, so the session undoes that commit
    and pauses. It resumes when a preview over counted shelves lines up again, or when the user
    says so.
  - **Possible misses.** They keep their id when a later commit sees them within 4 cm, so the store
    moves them instead of listing them twice. A tap adds the engine's item (`addDetection`, then
    `addPossibleMiss`).
  - **Groups (FR-27).** Groups are made per commit from FeaturePrint (revision 2) embeddings of the
    item crops: average linkage, within what items count as. Their keys go to the engine too.
    Naming a group mirrors its `SKU.productKey` into the engine.
  - **Undo** acts on both: the engine, and the store with `expecting:` the snackbar's commit.

## Saving (StockMaskCore)

- **One adapter.** `CoreStockStore` is the only file that imports StockMaskCore. Core's record
  names overlap StockMaskCounting's.
- **The seam.** It implements `CountingStore`, the persistence the screens need.
- **Threading.** Core's synchronous calls run on one serial queue, never in a cancellable `Task`.
- **Ids.** The commit, its items and its zone keep the engine's ids. `anchorID` is the commit's
  ARAnchor, made at `zone.transform` before the save.
- **Files first.** The keyframe and item crops are written before the save, under
  `sessions/<session-id>/keyframes|crops/` in the data directory (`Application Support/StockMask`
  on the phone), and stored as relative paths.
- **Export.** CSV (Excel Argentina and standard) and XLSX are Core's (`StockSheetExport`), shared
  through `ShareLink`.

## Screens

All SwiftUI, compiled on macOS. A test renders the counting screen offscreen.
- `CountingScreenLayout`: the camera, yellow outlines, the inner frame, banners, HUD, `+N` toast,
  commit card and thumb-reach controls (list badge, shutter with the hold ring, undo). Targets are
  60 pt or more.
- `CommitCardView`, `ProductPickerView` and `NewProductForm`: pick, search or create a product
  (FR-28).
- `LiveListView` and `ManualLineForm`: the list, and manual lines in full cases and units. There is
  no depth stepper anywhere: FR-29 is removed.
- `ReviewView`:
  - blockers, with "leave unknown";
  - warnings and totals;
  - lock (FR-9);
  - export.
- `StartView`: start a count, or continue the active one (one per device).
- `HUDView`:
  - tracking and mapping, FPS, detector Hz and ms (last, p50, p95), thermal state, battery, view
    speed, scene distance, track counts;
  - auto-count, GPU or Neural Engine, and capture with its share button.

## Capture mode

Keyframe JPEG, depth, confidence, smoothed depth, pose, intrinsics, light estimate and the
detector's boxes, at 1 or 2 Hz, into `Documents/Captures/`. Zipped for the share sheet when
stopped. The format and the Python reader are in
[`research/capture_replay`](../../../research/capture_replay/README.md); a test checks that the
reader reads what Swift writes.

## Parameters to tune in Phase 0

| Parameter | Start | Where |
|---|---|---|
| Label band | rows 30–70%, columns 20–80% of the box | `Lifter.bandRows`, `bandColumns` (P0-4) |
| Through-glass margin | 10 cm behind the plane estimate | `Lifter.throughGlassMargin` (P0-4) |
| Minimum depth pixels | 4 | `Lifter.minPixels` |
| Track gate | 5 cm | `LiveTracks.gate` |
| Stable candidate | 3 hits in 0.5 s | `LiveTracks.stableHits`, `stableWindow` (ADR 003) |
| Detector rate | 12 Hz; 5 Hz at `serious`; paused at `critical` | `ThermalLevel.detectorRate` (PRD §10) |
| Grouping distance | 0.6 (FeaturePrint, Euclidean) | `ItemGrouper.threshold` (P0-6). Synthetic labels: 0.08 within a kind, 0.91 across |
| Same miss again | within 4 cm | `CountingSession.missMatchRadius` |
| Capture rate | 2 Hz | `CaptureController.rateHz` |

## Not built yet

- **Map save and restore (FR-24).** After a relaunch the count and the list continue, but the
  camera doesn't know what it counted before. The app says so; don't count those shelves again.
  When the map is restored, rebuild the engine as StockMaskCore's README shows and pass the
  restored anchors to `updateAnchor`.
- **One zone per session.** There is no zone switch (FR-8), and no rack tags (FR-5, FR-25).
- **Not in the screens yet:**
  - tapping a green item to uncount it (FR-17);
  - the open-case rule (FR-19);
  - splitting, merging or deleting lines (FR-34);
  - teach-once suggestions (ADR 004);
  - the evidence and diagnostic bundles (FR-37, FR-39).
- **Spanish strings.** The UI is in English.
