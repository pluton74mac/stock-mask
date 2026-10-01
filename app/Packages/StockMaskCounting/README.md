# StockMaskCounting

The counting engine of the MVP test app ([plan and contract](../../../docs/mvp-test-app.md)). It
decides **when** to count (hold-to-count), **what** a view counts (the inner frame, bottles and
tops) and **whether it was counted before** (ADR 003's strategy S5: counted zones, local drift
refinement, 1:1 matching, possible-miss prompts, drift alarm, undo).

- Pure Swift 6 and `simd`. No ARKit and no dependencies. iOS 18, macOS 15.
- The geometry comes in as plain values (a camera pose, intrinsics, boxes, 3D points), so the whole
  package is tested on a Mac.

```sh
app/scripts/swift-test.sh app/Packages/StockMaskCounting    # 53 tests, about 1 s
```

## API

| Type | What it does |
|---|---|
| `ObjectClass`, `Detection`, `CountedItem`, `CountedZone`, `CommitResult` | The contract's value types, with a few added fields (see [Contract extensions](#contract-extensions)) |
| `DetectionStatus` | What a commit did with each detection: `new`, `matched`, `possibleMiss`, `deferred`, `mergedTop`, `lowConfidence`, `cut`, `noPosition` |
| `HoldTrigger` | FR-13. Feed it every frame; it says `.idle`, `.holding(progress:)`, `.counted` or `.commit`. `shutter()` always commits |
| `InnerFrame` | FR-14. Classifies a box as `.inner`, `.band` or `.cut` |
| `CommitView` | One commit's camera: pose, intrinsics, image size, optional scene depth. Has an initialiser from ARKit's pixel intrinsics |
| `CommitEngine` | S5. `commit`, `preview`, `undoLastCommit`, `addDetection`, `removeItems`, `setProductKey`, `setGroupKey`, `updateAnchor`, `resetDriftEstimate`; `items`, `zones`, `driftEstimate`; `init(items:zones:)` to resume |
| `TopMergeRule` | The parameters of the bottle/top rule |
| `Hungarian` | `Hungarian.assign(cost)`: minimum-cost assignment for a rectangular matrix |

### How the AR layer uses it

```swift
var trigger = HoldTrigger()
var engine = CommitEngine()          // one per spatial map (zone, FR-24)

// Every frame:
switch trigger.update(.init(timestamp: frame.timestamp, angularSpeed: speed,
                            hasStableCandidate: tracks.hasStable, trackingNormal: isNormal,
                            viewShift: shiftSinceLastFrame)) {
case .commit:
    let view = CommitView(cameraTransform: camera.transform, pixelIntrinsics: camera.intrinsics,
                          imageResolution: imageSize, sceneDepth: centreDepth)
    let result = engine.commit(detections, view: view)
    // Save result.newItems and result.zone in one transaction (FR-7), create
    // ARAnchor(transform: result.zone.transform) for the commit, draw green on result.newItems and
    // result.matched, amber "+" on result.possibleMisses; result.driftAlarm -> FR-23 banner.
case .holding(let progress): ring.progress = progress
case .counted, .idle: break
}

// Live overlays between commits, without changing anything:
let live = engine.preview(detections, view: view)

// User actions:
engine.addDetection(index, ofCommit: commitID)   // tap an amber "+" or a dashed box
engine.undoLastCommit()                          // FR-16
engine.removeItems([itemID])                     // FR-17
engine.setProductKey(sku, forItems: groupItems)  // FR-28: later matches prefer it

// ARKit moved a commit's anchor (session(_:didUpdate:)):
engine.updateAnchor(ofCommit: commitID, to: anchor.transform)

// Relaunch (FR-7): items and zones from StockMaskCore, zones in commit order.
engine = CommitEngine(items: savedItems, zones: savedZones)
```

### Conventions

- **World space** is the AR session's: metres, +y up (gravity). `Detection.position`,
  `CountedItem.position` and `CountedZone.transform` are all in it.
- **Camera** (`CommitView.cameraTransform`): camera to world, as `ARCamera.transform`. It looks
  along its −z axis, with +x to the right of the image and +y up the image.
- **Boxes** are normalised (0…1), x to the right and y down, in the same image as the
  intrinsics. With ARKit that is the captured image in sensor orientation (landscape), even with
  the phone in portrait: rotate boxes back if the detector ran on a rotated image. Gravity, not the
  image, decides what "top" means, so portrait works.
- **`Detection.size`** is the box's extent in metres along the image's x and y axes. It is used
  only to estimate where a bottle's top is.
- Times are seconds, angles degrees.

## The rules

### Hold-to-count (FR-13): `HoldTrigger`

A port of `replay` in [walkthrough.py](../../../research/walkthrough/walkthrough.py) (the hold
branch). In the second storeroom walk it committed on every stretch of 0.8 s or more under 10°/s
([walkthrough results §9](../../../research/walkthrough/RESULTS.md)).

1. **Speed.** The angular speed is filtered: the median of the last 0.1 s of samples, at least 3.
   walkthrough.py measured it from image motion, so stepping sideways counts as well as turning.
   Give it rotation speed plus translation speed over distance.
2. **Hold.** The hold timer starts at the first steady frame: under 10°/s, with tracking normal. Any
   frame that is not steady resets it.
3. **Commit.** After 0.8 s it commits, but only if a stable candidate is in view. Otherwise it waits
   at `.holding(progress: 1)` and commits as soon as one appears.
4. **Re-arm.** After a commit it is disarmed (`.counted`).
   - It re-arms once the view has moved 5° from where it committed, or after a tracking
     interruption. The hold timer then starts again.
   - "Moved" is the net shift when the frames carry `viewShift`, as in walkthrough.py. Otherwise it
     is the angle travelled (speed × time), which also counts hand tremor.
5. **Shutter.** `shutter()` always commits and disarms. `isAutoCountEnabled = false` stops hold
   commits (FR-13), but not the shutter.

### Inner frame (FR-14): `InnerFrame`

walkthrough.py's `view_status`, which matches how sim.py models views:

- **cut**: the box touches the image border, within 0.005 of the long side. Its centre is biased,
  so it isn't used at all.
- **inner**: the box is whole and its centre is inside the inner frame. The inner frame is the
  image minus a band of 0.15 of the short side on each side. This view counts it.
- **band**: the box is whole but its centre is in the band. The neighbouring view counts it.

**"Fully inside the inner frame" is read as "whole, and centre inside".** Read literally, a box
straddling the inner frame's edge with its centre inside would be counted by no view:
- this view leaves it, because its box isn't wholly inside;
- the next view finds its centre inside this view's counted zone, so only suggests it.

The counted zone is the inner frame, so the two rules must use the same point. With the band at
about half the largest object (ADR 003), a centre in the inner frame also means a whole object.

### The commit engine (ADR 003 S5, FR-21–23, FR-26): `CommitEngine.commit`

A port of `refine_and_match` and `commit_s5` in
[sim.py](../../../research/dedup_sim/sim.py), in Double precision. For every commit:

1. **Set aside** detections below the commit score (FR-18, `.lowConfidence`), cut by the border
   (`.cut`), or without a 3D position (`.noPosition`).
2. **Merge each bottle with its top**. A top with no bottle under it is a unit of its own (next
   section).
3. **Refine drift locally.**
   - **Candidates.** Each detection is paired with each nearby counted item of its class family.
     Pairs within ±4.5 cm (half a bottle) of the last estimate, along the shelf and vertically,
     give candidate offsets on a 1 cm grid. Depth is not limited, as in the simulation.
   - **Support.** For each offset, a detection whose nearest counted item lies within the gate
     scores 1, or 0.5 when the products disagree.
   - **Decision.** The best offset needs a score of at least 3 and 25% of the detections. Offsets
     within 1 of the best are ties, and the one closest to the last estimate wins. Without enough
     support, the last estimate stays.
   - **Why only locally.** Snapping a larger drift away is the trap ADR 003 measured: in rows of
     identical bottles it under-counts 15%.
4. **Match 1:1.**
   - The Hungarian assignment pairs detections with counted items, per class family (a bottle and a
     lone top are the same family).
   - The gate is anisotropic (ADR 003): 4 cm along the shelf, 8 cm vertically, 10 cm in depth.
   - "Depth" is the view direction, flattened to the horizontal. "Along the shelf" is horizontal and
     square to it, whatever the phone's roll.
   - A product mismatch adds half a gate to the cost.
5. **Classify**:
   - **matched**: green, never counted again (FR-26);
   - **possibleMiss**: unmatched inside an earlier counted zone. Amber "+", never added (FR-22) until
     tapped (`addDetection`);
   - **new**: unmatched, outside every counted zone, with its centre in the inner frame;
   - **deferred**: unmatched, outside the zones, centre in the band. Left for the next view.
6. **Store this view's zone (FR-21).** It is an oriented box with the camera's axes:
   - across and up: the inner frame's cross-section at the median depth of this view's detections
     in it;
   - in depth: from the nearest of them minus 5 cm to the farthest plus 5 cm;
   - shifted by the drift offset, like the items.
7. **Raise the drift alarm (FR-23)** when more than 30% of the detections over counted zones are
   unmatched. It needs at least 3 such detections. The commit is still applied; the AR layer shows
   the banner, pauses auto-count, and may `undoLastCommit()`.

**Undo (FR-16)** removes the last applied commit:
- its new items;
- the possible misses added from it since;
- its zone;
- its drift update.

Call it again to undo the commit before. **Anchors (FR-21):** create the commit's `ARAnchor` with
`result.zone.transform`. When ARKit moves it, `updateAnchor(ofCommit:to:)` moves that commit's items
and zone rigidly. **`preview`** classifies without changing anything, for live overlays and for
checking that the alarm has cleared. **`resetDriftEstimate()`**: call it after relocalisation or a
jump in tracking. sim.py resets it before every revisit pass.

### Bottles and tops: `TopMergeRule`

The MVP has no rows-deep multiplier: the camera counts the rows behind a front row by their tops
(product decision of 2 October 2026, PRD FR-29 removed). On the second walk, tops took the count from
about half the bottles to about seven eighths
([walkthrough results §17](../../../research/walkthrough/RESULTS.md)).

**The rule, within one view:**
- **A top that belongs to a bottle detected in the same view is the same unit.** The unit is the
  bottle, located at the bottle's centre, with the top's position kept as `CountedItem.top`.
- **A top with no bottle under it is a bottle behind, and counts as one.** It becomes a
  `CountedItem` of class `.bottleTop` at the top's position.

**When a top belongs to a bottle.** All three must hold:
1. **Position.** Either:
   - the top's box centre is in the bottle's **cap window**: horizontally within the bottle's box;
     vertically from 10% of the box height above its top edge to 25% below it, with "up" taken
     from gravity;
   - or the top is **within 5 cm of the bottle's 3D top**: its position raised by half its height
     (needs `size`).
2. **Same row.** The top is within **7 cm** of the bottle, horizontally.
   - Front bottles are found by their label, about 4 cm in front of the cap.
   - A top one row back is a bottle pitch (about 9 cm) further, so a back row's top that shows just
     above a front bottle is not absorbed by it.
3. **One top per bottle.** Tops and bottles are paired one to one (Hungarian), each bottle with the
   top nearest its cap.

**Only bottles countable in this view take part:** whole, above the commit score, with a position.
- The top of a bottle cut by the image border, or below the score, counts on its own, at the top.
- When a later view sees that bottle whole, it matches by top.

**Across views,** units compare centres when both have one, and tops otherwise. So:
- a top seen alone matches a bottle counted whole, through the bottle's detected or estimated top;
- a bottle seen whole matches a top counted alone.

**Its parameters** are in the table below. None is measured yet; they come from bottle geometry: an
8 cm wide bottle, 9 cm pitch between bottles and between rows, a cap about 10% of a bottle's height.

**Its limits:**
- **Double boxes on one neck count twice.** A detector that draws two boxes on one neck (OWLv2
  did, walkthrough results §12) leaves the second as a lone top. Non-maximum suppression in the
  detector should prevent this.
- **The gate does not separate rows.** Rows are 9 cm apart in depth, and the gate allows 10 cm in
  depth, so a back-row top can match the counted top one row in front.
  - It only does so when that row's own detection is missing from the view.
  - Then a back-row bottle seen for the first time is taken as already counted: a silent miss.
  - The drift search does not limit depth either. On a shelf seen first straight on and then from
    above, the front row (matched by its centres) anchors the offset at zero.
  - Tune the depth gate for tops in Phase 0 (P0-8) once tops are labelled.
- **The zone's depth stops 5 cm behind the deepest item it counted.** A row first seen from another
  angle is outside it and gets counted. A row within 5 cm of the deepest counted one is inside, and
  only suggested.
- **Stock hidden behind is not counted.** A bottle whose top is hidden behind another top, and
  tins or bags stacked behind, are not counted. That is the MVP's decision (walkthrough results
  §16).
- **Tops count bottles only.** There is no can or case top.
- **No open-case rule.** FR-19 (units inside an open case count instead of the case) is not here.
  Tops inside a case's box count as bottles, and the case counts too.

## Parameters

`CommitEngine.Parameters` (and `HoldTrigger.Parameters`, `InnerFrame`, `TopMergeRule`). ADR 003
starts them all as "tune in Phase 0".

| Parameter | Default | Source |
|---|---|---|
| `HoldTrigger.Parameters.holdDuration` | 0.8 s | FR-13, ADR 003 |
| `maxAngularSpeed` | 10°/s | ADR 003 |
| `rearmAngle` | 5° | walkthrough.py `REARM_DEG` |
| `speedFilter` | 0.1 s median, ≥ 3 samples | walkthrough.py |
| `InnerFrame.band` | 0.15 of the short side | walkthrough.py `BAND`, FR-14 (sim.py: 18 cm of a 0.9 m view = 0.2) |
| `InnerFrame.edge` | 0.005 of the long side | walkthrough.py `EDGE` |
| `minimumScore` | 0.5 | FR-18; walkthrough.py's counted threshold for RF-DETR (OWLv2: 0.3). Per detector |
| `metricWeights` | 1.0 / 0.5 / 0.4 (along / up / depth) | sim.py `METRIC`, ADR 003 |
| `matchGate` | 0.04 (4 / 8 / 10 cm) | sim.py `GATE`, ADR 003: half a bottle's width. sim.py applies it to every class |
| `matchGateByClass` | none | per-class overrides; a top uses the bottle's |
| `productMismatchPenalty` | 0.5 × gate | sim.py `refine_and_match` |
| `productMismatchSupport` | 0.5 | sim.py `_support` |
| `driftSearch` | ±4.5 cm, along and up | ADR 003, FR-22, sim.py |
| `driftGrid` | 1 cm | sim.py |
| `driftMinimumSupport`, `driftMinimumSupportFraction` | 3 and 25% | ADR 003, sim.py |
| `driftTieWindow` | 1 | sim.py |
| `zoneDepthMargin` | 5 cm | Added: the simulation's zones are flat and unbounded in depth. On the 15 fixtures, 5 and 10 cm give the same totals as unbounded; 3 cm does not (d = 8 cm: 4 double counts instead of 2) |
| `defaultZoneDepth` | 1.0 m | Added: an empty view's zone with no `sceneDepth` |
| `driftAlarmFraction` | 30% | FR-23, ADR 003 |
| `driftAlarmMinimumDetections` | 3 | Added: one genuine miss among two detections is not drift |
| `TopMergeRule.capWindowAbove` / `capWindowBelow` | 10% / 25% of the bottle box height | Added: box jitter; cap and neck |
| `TopMergeRule.mergeRadius` | 5 cm | Added: "within a few centimetres of its 3D top" |
| `TopMergeRule.sameRowRadius` | 7 cm | Added: between a bottle's radius plus noise and the 9 cm row pitch |
| `worldUp` | +y | ARKit, gravity-aligned |

## Parity with the simulation

[`Tests/StockMaskCountingTests/Fixtures/make_fixtures.py`](Tests/StockMaskCountingTests/Fixtures/make_fixtures.py)
writes 15 seeded scenarios from sim.py's strategy S5, 2 racks each, low noise:
- mixed shelves at revisit drift 0, 3 and 5 cm (two seeds each);
- rows of one bottle at 0, 3 and 5 cm (two seeds each);
- identical racks with tracking relocalised onto the wrong one (two seeds);
- mixed shelves at 8 cm, beyond ADR 003's safe range.

```sh
# from the repository root, with numpy and scipy (the walkthrough venv has both)
research/walkthrough/venv/bin/python \
    app/Packages/StockMaskCounting/Tests/StockMaskCountingTests/Fixtures/make_fixtures.py
```

Regenerating is deterministic: the files come out byte for byte the same.

**How a fixture stays the simulation:**
- The script calls sim.py's own functions in `run_once`'s order. Replayed without hooks, each
  scenario reproduces `sim.run_once` exactly; the script checks this.
- Hooks on `refine_and_match` and `linear_sum_assignment` record each commit's drift offset and the
  counted item each detection matched.
- The fixture replay feeds the simulation the float32 values the engine receives. That changed no
  decision in any scenario.
- The camera stands 10,000 km from the rack, so the inner frame's frustum is the simulation's flat
  zone rectangle to about 1 nm. The closest any tested point comes to a zone edge is 5.7 µm.

**What the tests assert:** for every one of 9,819 detections in 448 commits, the same decision
(matched to the same counted item, new, possible miss, or left for the next view). They also assert
the same drift offset at every commit, and the same totals. **All 15 pass.**

| Scenario (2 racks; seeds summed) | Items | Double | Missed | Prompts |
|---|---|---|---|---|
| mixed, d = 0 | 314 | 0 | 11 (3.5%) | 11 |
| mixed, d = 3 cm | 314 | 0 | 11 (3.5%) | 17 |
| mixed, d = 5 cm | 314 | 0 | 11 (3.5%) | 13 |
| mixed, d = 8 cm (one seed) | 181 | 2 (1.1%) | 6 (3.3%) | 23 |
| one bottle, d = 0, 3, 5 cm (each) | 380 | 0 | 15 (3.9%) | 16 |
| identical racks, wrong relocalisation | 316 | 0 | 161 (50.9%) | 5 |

These agree with the S5 rows of [RESULTS.md](../../../research/dedup_sim/RESULTS.md) (20 seeds,
4 racks): for d ≤ 5 cm, 0.0–0.8% double and about 3–4% missed; for wrong-rack relocalisation, about
half missed.

**What the fixtures don't cover:**
- **Product preference.** No decision in them turns on it, so dedicated unit tests cover it.
- **Tops.** The simulation has none. Tops have their own tests (`TopMergeTests`).

## Limits

- **Zones are boxes, not frustums.** The inner frame's cross-section is taken at the median item
  depth. Close up, on deep shelves, the box is slightly too wide at the front row's depth and too
  narrow at the back's. At 0.5 m with rows 36 cm deep, that is up to about a third of the zone's
  width. A frustum zone would need a field the contract doesn't have.
- **Drift is fixed by tracking and anchors.** The engine refines only ±4.5 cm. Beyond about 5 cm of
  uncorrected drift, ADR 003's numbers apply:
  - prompts rise steeply, then double counts;
  - the drift alarm is the signal.
- **Identical racks.** A relocalisation onto the wrong one silently loses about half that rack
  (S5's known gap; rack tags, S6, fix it).
- **The simulation ranks designs; it doesn't predict field accuracy.** Its detector misses are
  independent, it has no false positives, and its drift is a translation. Gates G5 and G7 measure the
  real numbers.
- **Matched items keep their first position.** sim.py does not average re-observations, and
  neither does the engine.
- **The alarm reports; it doesn't block.** It sets a flag and applies the commit anyway. Pausing
  auto-count and re-anchoring are the AR layer's job (FR-23).

## Contract extensions

The [contract](../../../docs/mvp-test-app.md) fixes the type names and lets fields grow. This package
adds, all optional or defaulted:

- **`Detection.productKey: Int?`**: the appearance model's suggestion, so matching can prefer the
  same product (S5). Nil never penalises.
- **`CountedItem`**:
  - `top: SIMD3<Float>?`: the bottle's top, for top/bottle matching across views. Persist it.
  - `productKey: Int?`: the confirmed product.
  - `confidence: Float?`: the data model's `item.confidence`.
  - `detectionIndex: Int?`: the detection that was counted.
- **`CountedItem.cls == .bottleTop`** is a bottle counted by its top. It is one unit, like
  `.bottle`. StockMaskCore should count it as a bottle in the sheet.
- **`CountedZone`** is `Codable` (the transform as 16 floats, column-major), `Equatable`, and has
  `contains(_:)`.
- **`CommitResult`** adds:
  - `statuses: [DetectionStatus]`, one per detection;
  - `mergedTops`;
  - `driftOffset`, `driftRefined`;
  - `overCountedZones`, `unmatchedOverCountedZones`.
- **New types**: `DetectionStatus`, `CommitView`, `InnerFrame`, `TopMergeRule`,
  `CommitEngine.Parameters`, `CommitEngine.UndoneCommit`, `HoldTrigger.Parameters`,
  `HoldTrigger.Frame`, `HoldTrigger.Decision`, `Hungarian`.
- **`HoldTrigger.Frame.viewShift`** is optional. It makes re-arming use the net movement, as
  walkthrough.py does.
- **`CountedZone.transform`** is also the commit's anchor transform (`updateAnchor`).
