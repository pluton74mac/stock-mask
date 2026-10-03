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
app/scripts/swift-test.sh app/Packages/StockMaskAR   # 72 tests, macOS
app/scripts/typecheck-ios.sh                         # compiles the iOS-only code without an iOS build (below)
```

## What is built, tested and run

| Code | Built | Tested on macOS | Run on an iPhone |
|---|---|---|---|
| Everything outside `iOS/`: detector, decoder, input resizer, geometry, Lifter, tracks, motion, capture format, grouping, rows, suggestions, diagnostics, StockMaskCounting and StockMaskCore bridges, counting session, overlay state and RealityKit renderer, the SwiftUI screens | macOS, iOS | yes (72 tests) | yes, by the owner (iPhone 14 Pro Max) |
| `iOS/`: `ARFrameConversion`, `ARSessionController`, `CountingScreen` (ARKit, `ARView`, UIKit), and `app/StockMask/StockMaskApp.swift` | iOS (Xcode, `app/StockMask.xcodeproj`) | no | yes, by the owner |

The owner's first runs (2 October) showed the yellow outlines, counted with the Neural Engine and
drew the green shapes, lying on their side (fixed since). Nothing counted on the GPU: see
[GPU or Neural Engine](#gpu-or-neural-engine).

**`typecheck-ios.sh`** compiles the iOS code without an iOS build: the macOS SDK ships Mac Catalyst
copies of ARKit, RealityKit and UIKit, and `#if os(iOS)` is true on Catalyst. It builds the package
graph for `arm64-apple-ios18.0-macabi`, then type-checks the app target against it. The real check
is the Xcode build ([`app/StockMask/README.md`](../../StockMask/README.md)).

### Still to check on the phone
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
- **Detector speed:** CPU + GPU against the Neural Engine, with ARKit and RealityKit running (P0-3):
  the diagnostic log has it now (below).
- **Capture mode:** write speed at 2 Hz, and the size of a zipped walk.
- **Upright overlays.** The green bottles stand upright whichever way the phone is held.
- **Label reading.** How often Vision's text on a group's crops picks the right catalogue product.

## Data flow

```
ARFrame (ARSessionController, iOS)
  └─ FramePump.process: light snapshot every frame; depth copied only when needed
       ├─ CountingSession.frameDidUpdate → ViewMotion (speed + shift) → HoldTrigger → FrameDecision
       ├─ detector due (12 Hz; 5 Hz when hot) → CoreMLDetector (actor): ModelInputResizer → Core ML → DETRDecoder
       │     └─ detectorDidFinish → Perception.lift (Lifter) → LiveTracks → yellow outlines
       ├─ commit (hold; "count now" in the debug panel) → CountingSession.commit
       │     stable tracks → CountingBridge (turned to ARKit's image) → CommitEngine.commit
       │     → groups (FeaturePrint + ItemGrouper) → rows behind join the front bottle (RowGrouper)
       │     → files first (CommitFileStore) → ARAnchor
       │     → CoreStockStore.saveCommit (one transaction), moveItems for rows joining earlier groups
       │     → OverlayState → OverlayRenderer (RealityKit) → haptic, +N, card, list
       │     → suggestions: teach-once, else Vision OCR on the crops matched to the catalogue
       ├─ every 0.5 s → DiagnosticsSample → Documents/diagnostics/diag-*.jsonl
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
- **World space is ARKit's:** metres, +y up (against gravity). Items sit at their axis,
  mid-height (the Lifter pushes the visible front back by the class radius).
- **Overlays hang off the counted zone's anchor, whose axes are the camera's** (the sensor's,
  landscape). The green shapes are turned upright in world space (`OverlayRenderer.upright`), with
  their front to the zone's front flattened to the horizontal. Left in the anchor's axes, a
  bottle's cylinder lay on its side whenever the phone was held in portrait.

## Detector

- **The `Detector` protocol** is model-agnostic (ADR 002). `CoreMLDetector` reads everything about
  the model from its metadata: class list, output names, thresholds. A fine-tuned model with
  `bottle`, `can`, `case`, `bottle_top` replaces the COCO one without code changes. Details are in
  [`ml/coreml/README.md`](../../../ml/coreml/README.md).
- **`ModelInputResizer`** makes the model's input the way rfdetr does: upright, stretched, bilinear
  without antialiasing, ARKit's YCbCr converted with the buffer's own matrix. Vision's
  antialiased resize alone costs bottles ([`ml/coreml/RESULTS.md`](../../../ml/coreml/RESULTS.md)).
- **Compute units: CPU + Neural Engine by default** (ADR 001's plan), because nothing counted on
  the GPU on the phone. FP16 on the M5's Neural Engine fails parity with PyTorch, while the GPU's
  passes ([`ml/coreml/RESULTS.md`](../../../ml/coreml/RESULTS.md)), so this stays under watch. The
  HUD switches.
- **Where the model comes from** (`DetectorModelLocator`):
  1. the newest `Documents/Models/*.mlpackage`, compiled on the phone;
  2. else `StockMaskDetector.mlmodelc` in the app bundle.
- **Loading** runs one detection on a synthetic camera frame before counting starts: the first
  run is slow (the chip's own compilation), and it logs the outputs' element types and strides.

### GPU or Neural Engine

**Since 3 October the GPU is the default.** The resize fix below made the GPU count. Against
PyTorch, the fine-tuned model (student 3, `ml/coreml/RESULTS.md`) gives:
- FP16 on CPU + GPU: matches on 23 of 24 frames.
- The Neural Engine: matches on 10 of 24 frames, and loses about 1 in 10 bottle tops.

The HUD switch still tries the Neural Engine. `CoreMLDetector` also drops a second box of the
same label at IoU ≥ 0.7 (`DETRDecoder.deduplicated`). The fine-tuned model drew one on a close-up
bottle, and it would have counted twice.

**History:** what happened on 2 October.

On 2 October the phone counted with the Neural Engine and never with the GPU: yellow outlines
showed, but no commit came. The cause is the stable-candidate rule meeting a slow detector:

1. **A hold needs a stable candidate:** a track with 3 hits in the last 0.5 s (ADR 003). Three
   runs span two detector periods, so that rule only works with a run every 250 ms or faster.
2. **The GPU path was slower than that on the phone.** The installed build is Debug, where
   StockMaskAR runs unoptimised. `ModelInputResizer` then took about 13 times its current time:
   64 ms per frame on the M5, and by the same ratio about 150 ms on the A16. Core ML on the GPU
   then adds 55 ms on its own (measured below), and shares the GPU with RealityKit drawing the
   camera at 60 fps. The Neural Engine needs 30 ms and runs beside the GPU. That puts the Neural
   Engine's period near 180 ms, under 250 ms, and the GPU's at 205 ms before RealityKit's share:
   over 250 ms with it, which fits what the phone did. The in-app diagnostic log measures that
   share with ARKit running.
3. **So on the GPU no track ever became stable,** the hold ring sat full, and the trigger waited
   for a candidate that never came. A yellow outline needs one detection, not three in 0.5 s, so
   the outlines still showed.

Measured on the iPhone 14 Pro Max (A16), Debug build, ARKit off (the start screen's benchmark,
3 October). The times are end to end: resize, Core ML, decoding.

| | load | first run | p50 | p95 | detections ≥ 0.5 on 3 keyframes |
|---|---|---|---|---|---|
| GPU | 0.6 s | 409 ms | 65 ms | 67 ms | 15 |
| Neural Engine | 5.2 s (compiles once per install) | 51 ms | 39 ms | 41 ms | 12 |
| CPU | 0.6 s | 61 ms | 57 ms | 58 ms | 15 |

The resize is 11 ms of each run. The output types are float32 on all three; the logits' rows are
padded to 96 (the reader follows the strides). Against the Neural Engine on the same keyframes, the
GPU's scores are 0.02 higher on average (mean |Δ| 0.03, worst 0.19, 1 of 15 pairs across 0.5). The
CPU agrees with the GPU. So the score scale is the same, and if anything the Neural Engine is the
one that loses bottles, as on the M5 (`ml/coreml/RESULTS.md`).

What changed:
- **`ModelInputResizer` is 13 times faster unoptimised** (64 → 4.8 ms on the M5; 11 ms on the
  A16) and gives byte for byte the same output: raw pointers, precomputed taps, rows in parallel.
- **The stable window stretches with the detector.** It is 3 hits within
  `max(0.5 s, 2 × period × 1.25)`, capped at 1.5 s, from the median gap between detector frames
  (`LiveTracks.detectorPeriod`). Unseen tracks live 2.5 periods (at least 1 s). The HUD shows the
  window in use.
- **Only a countable candidate makes a hold:** a stable track at or above the commit score. A hold
  on dashed outlines alone would commit an empty counted zone, where those bottles would later come
  up as possible misses.
- **The Neural Engine is the default** until the diagnostic log shows the GPU counting with ARKit
  running. With the faster resize, the GPU should now be well under 250 ms. It then deserves to be
  the default again: it found 15 countable bottles on those keyframes, against the Neural Engine's
  12.

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
  - A track is a stable candidate after 3 hits in 0.5 s (ADR 003), the window stretched for a
    slower detector (see [GPU or Neural Engine](#gpu-or-neural-engine)).
  - Positions are a running mean.
- **`ViewMotion`.** Rotation plus sideways travel over the scene's distance, as a speed and as a
  shift. StockMaskCounting's HoldTrigger filters the speed and re-arms on the net shift.
- **Counting is automatic** (the owner's decision of 2 October): the hold commits, there is no
  shutter. Only a stable candidate at or above the commit score holds. The debug panel's "count
  now" commits the next frame, for testing.
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
  - **Rows behind take the front bottle's group** (the owner's decision of 2 October;
    `RowGrouper`). An item behind another of its kind (a top counts as a bottle) joins the group of
    the one in front when it is:
    - at the same place along the shelf, within half a bottle width (4.5 cm);
    - 3 to 60 cm deeper, along the view direction flattened to the horizontal;
    - no more than 12 cm lower or 25 cm higher (a top sits above a bottle's centre; the shelf
      above is higher still).

    Chains follow to the front of the row. Within a commit the row shares the front item's key;
    an earlier front bottle's group takes the new items with `moveItems`, so the card lists that
    group as "joined". Naming the front bottle names the row.
  - **Suggestions** (the owner's decision of 2 October; FR-31: never assigned without a tap):
    - **Teach-once (ADR 004):** a group that looks like a product named before (FeaturePrint
      distance) gets it suggested. Session memory only.
    - **Label text:** unless teach-once is sure, Vision reads the text on up to three of the
      group's crops (Spanish and English, the catalogue's words as hints). `ProductMatcher` matches
      the words against the catalogue, allowing OCR slips (edit distance). The name's words count
      most, the brand's help when they show, and a matching size adds a little.
    - The more confident of the two is pre-selected on the card with its confidence. One tap on
      Confirm names the group; "Other…" opens the picker, with the suggestion first.
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
- **The catalogue (FR-4).** `importCatalog` runs Core's `planCatalogImport` with the column mapping
  it guesses from the header, then `applyCatalogImport`. Rows without a name and duplicates are
  skipped, so importing a file twice adds nothing. The test app counts in one venue,
  `CoreStockStore.defaultVenue`.

## Screens

All SwiftUI, compiled on macOS. A test renders the counting screen offscreen.
- `CountingScreenLayout`: the camera, yellow outlines, the inner frame, banners, HUD, `+N` toast,
  commit card and thumb-reach controls (list badge, the hold ring, undo). There is no shutter.
  Top left, a back button goes to the start screen: the count stays saved, and "Continue this
  count" comes back to the same AR world (the controller and its `ARView` are kept). Targets are
  60 pt or more.
- `CommitCardView`: per group, its photo crops (large, tap to zoom: `PhotoZoomView`, one page per
  photo, pinch or double-tap), the suggestion with its confidence and Confirm, "Other…". Groups
  that rows behind joined are listed too.
- `ProductPickerView` and `NewProductForm`: pick, search or create a product (FR-28), with the
  group's photos and the suggestion on top.
- `LiveListView` and `ManualLineForm`: the list, and manual lines in full cases and units. There is
  no depth stepper anywhere: FR-29 is removed.
- `ReviewView`:
  - blockers, with "leave unknown";
  - warnings and totals;
  - lock (FR-9);
  - export.
- `StartView`:
  - start a count, or continue the active one (one per device);
  - the product catalogue: its size, and an Import button per CSV in the app's Documents folder
    (the Files app and Finder show it), with what the import did;
  - "Benchmark the detector" (below).
- `HUDView`:
  - tracking and mapping, FPS, detector Hz and ms (last, p50, p95), thermal state, battery, view
    speed, scene distance, track counts and the stable window, and "now:" why nothing is counting;
  - auto-count, GPU or Neural Engine, "count now" (testing only), and capture with its share
    button.

## Diagnostics

- **The diagnostic log.** Each time the counting screen opens it starts
  `Documents/diagnostics/diag-YYYYMMDD-HHMMSS.jsonl`, one JSON object per line (`DiagnosticsLog`):
  - `sample`, twice a second: compute unit, detector ms (last, p50, p95), rate and period,
    outlines (all, dashed, bold), best score, tracks and stable tracks (and how many of those can
    count), the stable window, the hold trigger's state, view speed, tracking, pause, thermal,
    battery, commits, and `why`: why no commit is happening right now;
  - `commit`: trigger, detections, new, matched, possible misses, the engine's verdict per
    detection, drift alarm, groups, rows joined, whether it was undone, save time;
  - `event`: detector loaded (load time, first run, output types and strides, thresholds, build),
    detector failed, commit skipped, drift cleared, undo, suggestion (confidences and timings,
    never label text or product names), camera paused or resumed.
- **The benchmark.** "Benchmark the detector" on the start screen (or launching with
  `-StockMaskBenchmark`) runs the detector on the GPU, the Neural Engine and the CPU in turn,
  without ARKit: load time, first run, p50 and p95 on a synthetic camera frame, output types, and
  scores on the three newest commit keyframes. Then the GPU and the CPU against the Neural Engine
  on those keyframes (`benchmark_compare`: mean signed score difference, spread, threshold
  crossings). It writes `Documents/diagnostics/benchmark-*.jsonl` as it goes, and keeps the screen
  on.
- **Copying them off the phone:**
  ```sh
  xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
      --domain-identifier com.pluton74mac.stockmask --source Documents/diagnostics --destination <dir>
  ```
  or Finder → the iPhone → Files → StockMask → diagnostics. They hold no images.

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
| Stable candidate | 3 hits in 0.5 s, stretched to 2.5 detector periods, at most 1.5 s | `LiveTracks.stableHits`, `stableWindow`, `maxStableWindow` (ADR 003) |
| Detector rate | 12 Hz; 5 Hz at `serious`; paused at `critical` | `ThermalLevel.detectorRate` (PRD §10) |
| Grouping distance | 0.6 (FeaturePrint, Euclidean) | `ItemGrouper.threshold` (P0-6). Synthetic labels: 0.08 within a kind, 0.91 across |
| Row behind | along ±4.5 cm, 3–60 cm deeper, −12 to +25 cm in height | `RowGrouper` |
| Label-text match | 0.45 to suggest; a word counts at 0.75 similarity | `ProductMatcher.minimumConfidence` |
| Teach-once | distance under 0.6; sure from 0.6 confidence (no label reading) | `TeachOnce.threshold`, `CountingSession.suggest` |
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
  - the catalogue import's preview and column mapping (Core's plan has them; the test app takes
    the guess);
  - the evidence and diagnostic bundles (FR-37, FR-39): the diagnostic log above is a developer's
    tool, not FR-39's bundle.
- **Teach-once is session memory.** Its examples are not saved yet.
- **Spanish strings.** The UI is in English.
