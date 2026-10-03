# Labelling dataset v0

Dataset v0 is the first labelled data for StockMask's detector (P0-7, [ADR 006](../docs/decisions/006-training-data.md)):
boxes on frames from the storeroom walks.

- **Who labels.** Since 3 October 2026, nobody: labels are made automatically ([AUTOLABEL.md](AUTOLABEL.md)).
  - The rules below still define a correct box.
  - The review loop below made the 15 checked frames that calibrate the automatic labels: 9 from walk 1, 6 from
    walk 2.
  - Before that, Claude labelling agents corrected OWLv2's draft boxes with `ml/review.py`, frame by frame, and the
    owner spot-checked ([LABELING-TOOL.md](LABELING-TOOL.md)).
- **Where the data lives.** Frames, labels and renders stay on this Mac, in the git-ignored `ml/data/`.
  - Never commit, upload or publish them.
  - Never write a product name or the venue into this repository.
- **Boxes, not masks** (owner, 2 October 2026).
  - Masks are looked at again only if the glass-depth test (P0-4) shows that boxes give poor LiDAR depth.
  - Masks could then be generated from the corrected boxes with SAM, with no relabelling.

## Classes

| label | what | trained in v0 |
|---|---|---|
| `bottle` | a bottle more than half visible: glass or plastic, any size, sealed or open | yes |
| `bottle_top` | every visible top of a bottle: cap, cork, stopper, pourer, pump, or the end of a foil capsule | yes |
| `can` | a drink can or a food tin, any size | yes |
| `case` | a shipping carton or shrink-wrapped tray holding several units | yes |
| `carton` | one unit packed in a carton (cream, juice) | yes, since 3 October 2026 |
| `bag` | one unit packed in a bag (sugar) | yes, since 3 October 2026 |

**How the app counts these** ([docs/mvp-test-app.md](../docs/mvp-test-app.md)):
- Every bottle the camera sees is one unit, open or sealed.
- A top that belongs to a bottle boxed in the same frame is the same unit.
- A top with no bottle box of its own is a bottle in a row behind.

So a front bottle gets two boxes, the bottle and its top; a bottle behind it often gets only its top.

## Rules

### bottle
- **More than half visible: draw a `bottle` box. Otherwise draw only its top.**
  - It doesn't matter whether the rest is hidden by other stock or cut off by the image border.
  - Partly hidden bottles in the second row usually fail this test; their tops carry them.
- **Box what you can see, cap included.**
  - The box's top edge is the top of the bottle's own cap, not a cap of a bottle standing behind it.
  - The box's sides follow the bottle's own body, not the bottle next to it.
- **Open bottles are bottles,** at any fill level, with or without a pourer.
- **A single bottle in its own gift box or retail box is a `bottle`:** it is one unit. Box the box.
  - A carton holding several bottles is a `case`.
  - Jars are `bottle`.

### bottle_top
- **Label every top you can identify, on every bottle:**
  - the front row's, which also have a bottle box;
  - the rows behind, where often only the upper rim of a cap shows above the cap in front.

  This is how the camera counts the rows behind: there is no "rows deep" multiplier (2 October 2026). A top only
  partly visible behind another cap is still labelled; box the part you can see.
- **Box the closure:** cap, cork, stopper, pourer spout or pump head, with the lip. Not the neck.
  - When a foil capsule or a long screw-cap sleeve runs down the neck, box only its top end, about as tall as it is
    wide.
- **One box per top.** The draft often slices one tall ribbed cap into two to four stacked boxes, or boxes a cap
  together with its neck band. Merge them.
- **A top cut by the image border:** label it if at least half of it is inside the frame.
- **Tops of the shelf below, at the bottom edge of the frame:** same rules.
- **Bottles lying down** (wine racks) have their top at one end. Label them, and add a note: the counting rule assumes
  upright bottles.

### can
- **Drink cans and food tins are both `can`:** fruit pulp, coconut cream, any size. Each is one sealed metal unit, and
  the bay-3 reference counts tins that way (`can=22`).
- One box per tin you can see more than half of.
- A tin whose body is hidden but whose lid is clearly visible: box the visible part as `can`, and note it in the
  frame's note. Error analysis decides whether tins need a top class.
- Stacked tins hidden behind others are not labelled: the camera can't count them.

### case
- **One box per carton,** around the face you see: the front face, not its top or side.
- Shrink-wrapped trays are a case. Same 50% rule as bottles.
- **An open case:** box the case, and box each bottle top you can see inside it.

### carton and bag
- **What they are.** A carton is one unit packed in a carton (cream, juice). A bag is one unit packed in a bag
  (sugar). In the three bays of the second walk they are about 8% of the units (RESULTS §15, §16).
- **The owner decided on 3 October 2026 that the camera counts everything**, so both are trained classes.
  - Before that they were labelled but parked, so the pilot's boxes needed no second pass.
- **One box per unit you can see,** around the face you see. The 50% rule is the same as for bottles.
- **Stacked units hidden behind others are not labelled:** the camera can't count them.

### Never label
- **Reflections** in steel, glass or mirrors. The model must learn to ignore them.
- **Pictures of bottles** on labels, posters or boxes.
- **Shelf tape labels, price tags and empty spots.** An empty spot is a 0 on the stock sheet, not a box.

Bottles behind a glass door are real: label them.

### Exclude a frame
- **When:** motion blur makes it impossible to place a box within about a quarter of an object's width, or the frame
  shows a person.
- **How:** set `"status": "excluded"` with a reason.

## The review loop (for labelling agents)

Run everything from the repository root with the ml venv (`ml/requirements.txt`):

```
PY=ml/.venv/bin/python
```

### Inputs
- **Frames:** `ml/data/frames/`, listed in `manifest.csv`.
- **Pre-labels:** `ml/data/prelabels/owlv2.json`.
- **Your work:** one JSON file per frame in `ml/data/review/labels/`.

### Per frame

1. **Render:** `$PY ml/review.py render FRAME`.
   - It draws `ml/data/review/render/FRAME/overview.jpg` with numbered boxes (`12B` is bottle 12, `7T` is top 7) and
     prints the QA summary.
   - The draft is OWLv2's boxes at the replay's commit thresholds: 0.3, and 0.2 for tops.
   - **Read coordinates from the tick labels in the margins.** They are full-resolution pixels. The overview is scaled,
     so its own pixel positions are not coordinates.
2. **Zoom** on every dense or unclear area: `$PY ml/review.py render FRAME --crop x0,y0,x1,y1`.
   - Use full-resolution pixels; 300–700 px a side works well.
   - `--candidates` also draws OWLv2's lower-scoring boxes, dashed, numbered `c1`, `c2`… Promote one instead of
     drawing a box.
   - `$PY ml/review.py show FRAME` lists every box with its coordinates.
3. **Work out the scene before editing.**
   - Which bottles are in front, and how many rows deep each file goes.
   - Which cap belongs to which bottle: trace each neck up from its label.
   - Looking down, a cap further back appears higher in the frame.
4. **Apply one edit:** `$PY ml/review.py apply FRAME --edits '{...}'`.
   - It redraws the overview and every crop that shows an edited box, and prints the QA again.
   - Look at them; fix what is off with another edit.
5. **Finish** with `{"status": "done"}`, or `{"status": "excluded", "reason": "..."}`.

### Edit format

One JSON object per apply. Every field is optional. Boxes are `[x0, y0, x1, y1]` in full-resolution pixels, origin
top left.

```json
{"delete": [5, 6, 10],
 "relabel": {"9": "bottle_top"},
 "adjust": {"7": [757, 498, 866, 565], "13": {"y0": 498}},
 "add": [{"cls": "bottle", "box": [968, 200, 1298, 1080]}],
 "promote": ["c4", {"c9": "bottle"}],
 "keep": "all",
 "status": "done",
 "note": "two rows deep: the back caps show above the front caps"}
```

- `delete`: not an object, a reflection, a duplicate, or a slice of a box that stays.
- `relabel`: the right box with the wrong class.
- `adjust`: move all four edges, or only some (`{"y0": 498}`).
- `add`: objects with no box.
- `promote`: take a candidate box, optionally with another class.
- `keep`: boxes checked and right as they are (`"all"` is every untouched box).
- `status`: `done` keeps every untouched box.

A bad edit (an unknown id, a box outside the frame) changes nothing and says why.

### What the QA lines mean
- **Counts per class, and bottle units:** bottles, plus tops with no bottle of their own. That is what the app would
  count in this frame.
- **`same unit`:** each bottle and its own top. Check that every front bottle pairs with its own cap. If a bottle pairs
  with a cap behind it, its box's top edge is probably too high.
- **Bottles with no top in their top region:** the cap is hidden, cut by the border, or missed.
- **`CHECK` lines:**
  - two boxes on one object;
  - a box inside a bigger box of the same class;
  - a "top" more than 2.5 times taller than wide (a neck?);
  - a "bottle" about as wide as tall (a top or a can?).

### What the draft gets wrong (pilot)
- **Sliced tops.** Tall ribbed caps come as two to four stacked boxes, and cap plus neck sleeve as one tall top.
- **Bottle boxes that aren't bottles.** Some sit on the neck of a bottle behind; some start at a cap behind the front
  bottle.
- **Missing front bottles.** A front bottle had no box in 9 of 14 frames.
  - In the 5 frames checked, OWLv2 had found it (IoU 0.87–0.95, score 0.36–0.46).
  - `walkthrough.clean()` then removed it as a "row box", because the necks and caps of the bottles behind lie inside
    it.
  - `prelabel.py` now keeps such boxes. Against the reviewed pilot frames, the draft's bottle recall went from 0.73 to
    0.92.
- **Objects of the shelves above and below,** at the frame edge: bases, labels, a bottle base called a can.
- **Blurred sweep frames from walk 1.** About 30% of their draft boxes were right as drawn, against 55% on walk 2's
  holds.

### Batches, export, spot-check
- **Batches:** `$PY ml/review.py batches --size 25` writes `ml/data/review/batches/batch_NN.txt`.
  - Each batch is one contiguous stretch of one clip, so an agent sees the same shelves throughout.
  - It leaves out frames already done or excluded, and walk-1 frames under half the clip's median sharpness.
  - One agent per batch. Each agent reads this file first and then labels its frames in order.
- **Export:** `$PY ml/review.py export` writes the done frames to `ml/data/labels/labels.coco.json` for `train.py` and
  `eval.py`.
- **Stats:** `$PY ml/review.py stats` gives minutes, images and draft accuracy per frame.
- **Spot-check:** `$PY ml/review.py sheet` writes `ml/data/review/spotcheck.html` for the owner.

## Pilot, 2 October 2026

**What was labelled.** 15 frames: every 12th frame of walk 1 (10), and 5 hold keyframes of walk 2 (two in bay 1, two
in bay 2, one in bay 3). One labelling agent (Claude) worked the loop above.

| | walk 1 | walk 2 | all |
|---|---|---|---|
| frames done / excluded | 9 / 1 (motion blur) | 5 / 0 | 14 / 1 |
| minutes per frame (wall clock) | 3.4 | 4.7 | 3.9 |
| draft boxes right as drawn | 30% | 55% | 38% |
| draft boxes moved | 32% | 10% | 25% |
| draft boxes deleted | 38% | 35% | 37% |
| final boxes with no draft box | 8% | 9% | 9% |

- **Time.** 68 minutes for all 15 frames, including a 9-minute break.
- **Images.** About 4 viewed per frame: an overview plus one to three crops, and one look after the fix.
  - The tool then drew 12 images per frame, because it rendered every tile by default. It now draws the overview
    only.
- **Tokens.** Roughly 15,000 per frame.
- **Blur.** The excluded frame scored 0.48 on sharpness relative to its clip's median. The slowest labelled frame
  scored 0.44.
- **The draft numbers are for the old draft** (`walkthrough.clean()`), before the front-bottle fix above.

**Against the reference counts.** For walk 2's keyframes, the boxes were checked against the per-product reference
counts behind RESULTS §16, for every product whose spot was in the frame.
- 51 of 54 reference units appear as a bottle or a top (94%).
- Seven products match exactly.
- A block of 4 files × 4 deep shows 14 caps, and a product 2 and 3 deep shows 4 of 5. The missing three are caps hidden
  behind other caps in that one view.
- So a single held keyframe, labelled by these rules, sees almost all the bottles on a shelf of rows several deep.

## Dataset v0: size and splits

**Walk 1 is train and val.**
- 119 frames: 98 train and 21 val. Each frame adds at least 20% new view (`frames.py --max-overlap-trainval 0.8`).
- Val is every fifth 10-second block, and frames within 1 s of a train/val boundary are dropped.
- About 150 diverse frames don't exist in walk 1. Getting more would mean frames that overlap 85–90%.
- 18 frames under half the clip's median sharpness are left for later. In the pilot, frames like these were the
  slowest or unusable.

**Walk 2's 54 hold keyframes are the test set.** They are what the app commits. The 19 periodic walk-2 frames are
optional.

**Proposed v0.** The 14 pilot frames plus 142 more in 7 batches: 75 train, 18 val and 49 test. About 155 frames in
all. At about 4 minutes a frame that is roughly 9.5 agent-hours, or 1.5–2 hours with 7 agents in parallel.

| batch | split | clip | frames | seconds in the clip |
|---|---|---|---|---|
| 01 | train | walk 1 | 25 | 0–41 |
| 02 | train | walk 1 | 25 | 43–93 |
| 03 | train | walk 1 | 25 | 93–150 |
| 04 | val | walk 1 | 18 | 22–128 |
| 05 | test | walk 2, bay 1 | 12 | 1–44 |
| 06 | test | walk 2, bay 2 | 22 | 1–74 |
| 07 | test | walk 2, bay 3 | 15 | 0–55 |

After labelling: `review.py export`, then `train.py --name v0`, `eval.py --run v0` on the test holds, and the count
check (`walkthrough.py --detectors rfdetr_ft`).

**Leakage limit.** Walk 2 is the same storeroom, the same products and the same phone, four days after walk 1, so the
test set is not the unseen venue ADR 006 asks for as a holdout. Walk 1's val blocks also share products with its train
blocks. The numbers measure the pipeline and the labels, not how the model does in a new venue.

## Where the files come from

| step | script | writes, in `ml/data/` |
|---|---|---|
| frames | `frames.py` | `frames/<clip>/*.jpg`, `frames/manifest.csv` |
| draft boxes | `prelabel.py` (OWLv2) | `prelabels/owlv2.json` |
| review | `review.py` | `review/labels/*.json`, `review/render/` |
| labels | `review.py export` | `labels/labels.coco.json` |
| training | `train.py` (RF-DETR Nano, MPS) | `datasets/<name>/`, `runs/<name>/` |
| metrics | `eval.py` | `runs/<name>/eval_<split>.json` |
| count check | `research/walkthrough/walkthrough.py --detectors rfdetr_ft` with `RFDETR_FT_CHECKPOINT` | `research/walkthrough/out/` |
