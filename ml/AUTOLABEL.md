# Automatic labelling

Since 3 October 2026 nobody checks boxes. `ml/autolabel.py` labels walk 1 by itself, and RF-DETR Nano
trains on those labels. The 15 frames checked earlier with the review loop ([LABELING.md](LABELING.md))
measure the labels:
- the 9 from walk 1 tune the thresholds;
- the 6 from walk 2 are a final check that never tunes anything.

Everything it writes stays in the git-ignored `ml/data/autolabel/` and `ml/data/runs/`. This file holds only
aggregate numbers: the repository is public.

## How it works

1. **Frames.** Walk 1 is sampled densely.
   - The sharpest frame of every 8 video frames (about 0.27 s), minus frames under half the median sharpness.
   - That gives 381 frames, against 119 in the earlier frame set (`frames.py`).
   - Train and val are split by 10 s blocks, as in `frames.py`.
   - The 53 frames within 1 s of a calibration frame are held out of training. So when a student becomes a
     teacher, its calibration frames are views it never trained on.
   - Walk 2 is the test set and never trains. Only short stretches around its 6 checked frames are labelled, for
     the final check.
2. **Teachers.** Two open-vocabulary detectors, Apache-2.0 code and weights. No Ultralytics output (AGPL-3.0)
   goes into training data.
   - **OWLv2** (base): the replay's prompts, plus prompts for food tins, cartons and bags. One pass per frame.
   - **Grounding DINO** (tiny): one pass with "bottle. bottle cap. tin can. cardboard box. carton. bag.". A
     phrase scores the mean of its tokens' probabilities, so a whole bottle doesn't read as a "bottle cap".
   - **Weighted box fusion** per class (IoU 0.55). A box's score is the mean of the teachers' scores, with 0 for a
     teacher that drew nothing there. Where the agreement rule is on, a box needs two teachers or a high score.
3. **The video.** `tracks.py` links boxes through the walk.
   - Optical flow (DIS) runs between consecutive video frames. Every track's box moves by the median flow inside
     it, so each row keeps its own parallax.
   - At each sampled frame, boxes are matched to tracks by IoU (Hungarian).
   - **What the video can't do:** remove the teachers' false boxes. They are as steady through the walk as the true
     ones (median track length 6 frames, against 6–9). A track's score separates true from false boxes no better
     than a box's own score (AUC 0.86 against 0.85 for bottles, worse for tops). So thresholds apply to each box.
   - **What it does:**
     - A weak box between two kept boxes of the same track, at most 2 frames apart, is kept.
     - Where the track has no box in between, its flow-carried box fills the gap.
     - One-frame flickers can be dropped. Calibration found no gain in that.
4. **Fixes** from [LABELING.md](LABELING.md), done automatically:
   - **Sliced tops:** stacked top boxes with the same left and right edges are merged.
   - **Necks of bottles behind:** a bottle box is dropped when it is under 0.6 times as wide as another bottle box
     that covers 60% of it.
   - **Partial objects at the frame edge** (the shelves above and below): a box cut by the edge and under half the
     usual size of its class in that frame is dropped.
5. **Calibration.**
   - A grid search on the 9 checked walk-1 frames chooses the bottle and top thresholds, the flicker rule, gap
     filling and teacher agreement.
   - The objective is the mean F1 of `bottle` and `bottle_top`, the classes with 5 or more checked boxes.
   - `can`, `case`, `carton` and `bag` have no checked boxes (3 cases), so they keep a fixed, cautious rule: both
     teachers drew the box, or one did with a high score.
6. **Self-training.**
   - Round 1: RF-DETR Nano from its COCO weights, on the round-1 labels, 15 epochs on MPS.
   - Rounds 2 and 3: the previous student joins the two teachers. The labels are recalibrated and remade, and the
     round trains from the previous student's weights for 8 epochs.
   - Each round keeps its checkpoint in `ml/data/runs/auto-r1/`, `auto-r2/` and `auto-r3/`. Student 3 is the one
     to use.

## Run it

From the repository root, with the ml venv (`ml/requirements.txt`). Grounding DINO downloads on first use (about
700 MB).

```
PY=ml/.venv/bin/python
$PY ml/autolabel.py frames                                   # dense walk-1 frames, walk-2 check stretches
$PY ml/autolabel.py teach --teachers owlv2,gdino             # cached per frame
$PY ml/autolabel.py calibrate --teachers owlv2,gdino --save  # tune on 9 walk-1 frames, check on 6 walk-2 frames
$PY ml/autolabel.py export --name auto-r1                    # COCO for train.py
$PY ml/train.py --name auto-r1 --labels ml/data/autolabel/auto-r1.coco.json --epochs 15 --accum 1
$PY ml/autolabel.py student --run auto-r1                    # the student as a third teacher
$PY ml/autolabel.py calibrate --teachers owlv2,gdino,auto-r1 --save
$PY ml/autolabel.py export --name auto-r2
$PY ml/train.py --name auto-r2 --labels ml/data/autolabel/auto-r2.coco.json --epochs 8 --accum 1 \
    --init ml/data/runs/auto-r1/checkpoint_best_total.pth
# round 3: the same four steps with auto-r2 as the third teacher, writing auto-r3
```

Then `ml/eval.py --run auto-r3` (`--split train,val --kinds hold,periodic` for the walk-1 frames, `--sweep` for the
commit threshold). Then the replay's count check: `walkthrough.py --detectors rfdetr_ft` with
`RFDETR_FT_CHECKPOINT` set.

## Results, 3 October 2026

### The automatic labels against the checked frames

Precision and recall at IoU 0.5, class-aware.
- **Walk 1:** the 9 checked frames that chose the thresholds (44 bottles, 95 tops, 3 cases).
- **Walk 2:** the 6 checked frames that never tuned anything (22 bottles, 66 tops).

| labels | walk 1: bottle P / R | top P / R | walk 2: bottle P / R | top P / R | walk 2: bottle units, median error |
|---|---|---|---|---|---|
| OWLv2 alone | 0.55 / 0.82 | 0.71 / 0.71 | 0.53 / 0.91 | 0.74 / 0.74 | 10% |
| OWLv2 + Grounding DINO, with the video and fixes | 0.66 / 0.89 | 0.69 / 0.66 | 0.61 / 1.00 | 0.74 / 0.68 | 24% |
| + student 1 as a third teacher (round-2 labels) | 0.73 / 0.82 | 0.57 / 0.76 | 0.73 / 1.00 | 0.72 / 0.83 | 15% |
| student 2 instead (round-3 labels, the final ones) | **0.78 / 0.82** | **0.61 / 0.75** | **0.79 / 1.00** | **0.83 / 0.79** | **10%** |

**Each round's labels were better on walk 2, the frames nothing tuned on.**
- Bottle precision rose from 0.53 to 0.79 at full recall.
- Tops went from 0.74 / 0.74 to 0.83 / 0.79.

**Other classes.**
- `case`: all 3 checked cases found, and no false ones on the walk-1 frames.
- `can`, `carton`, `bag`: none in the checked frames, so their recall is unknown.
- On the 6 walk-2 frames the final labels hold one false can and two false cases.

**What each part adds.** The calibration objective is the mean F1 of bottles and tops on the 9 walk-1 frames.

| change | objective |
|---|---|
| OWLv2 alone, each frame on its own | 0.683 |
| + Grounding DINO, fused, each frame on its own | 0.691 |
| + the video: weak boxes between kept ones, gap filling | 0.717 |
| the same without merging sliced tops | 0.708 |
| the same without the neck fix | 0.702 |
| the same without the edge fix | 0.722 |
| OWLv2 on 2 × 2 tiles added (tried, dropped) | 0.648 per frame, against 0.701 without |
| student 1 as a third teacher (round 2) | 0.713 |
| student 2 as the third teacher (round 3), two teachers must agree | 0.736 |

- **The thresholds the grid chose.**
  - Round 1: bottle 0.25 and top 0.15 on the fused score, no minimum track length, gaps of up to 2 frames filled.
  - Round 3: bottle 0.4 and top 0.2, and two of the three teachers must agree. The video then adds nothing:
    agreement does that filtering.
- **The fixes help most early on.**
  - The edge fix costs a little in round 1 and helps in round 3.
  - The neck fix helps in round 1 and costs a little once a student is a teacher.
  - Both stay, as LABELING.md's rules, and the differences are within the noise of 9 frames.
- **With OWLv2 alone the video changes nothing.** Its weak boxes are about as often false as true.

### The students

RF-DETR Nano at 384 px (the app's input), on MPS.
- **Student 1:** 15 epochs from COCO weights on 263 frames of round-1 labels (5,237 boxes), 31 minutes.
- **Student 2:** 8 more epochs from student 1 on the round-2 labels (5,684 training boxes), 17 minutes.
- **The smoke model, for comparison:** 20 epochs on the raw OWLv2 drafts of the 98 earlier training frames.

`eval.py` at the replay's commit threshold (0.5):

| model | walk 2: mAP50 | bottle P / R | top P / R | bottle units, median / p90 error | walk 1: mAP50 | bottle units |
|---|---|---|---|---|---|---|
| smoke model (raw drafts) | 0.855 | 0.54 / 1.00 | 0.84 / 0.56 | 22% / 49% | (trained on them) | |
| student 1 | 0.813 | 0.67 / 1.00 | 0.88 / 0.58 | 25% / 38% | 0.790 | 24% / 43% |
| student 2 | 0.848 | 0.73 / 1.00 | 0.85 / 0.70 | 14% / 27% | 0.815 | 22% / 26% |
| student 3 | 0.842 | 0.75 / 0.95 | 0.79 / 0.70 | **11% / 24%** | 0.815 | **12% / 24%** |

- **Student 3:** 8 more epochs from student 2 on the round-3 labels (5,140 training boxes), 16 minutes.
- **The per-frame count error halved** from the smoke model to student 3: 22% to 11% median, 49% to 24% p90.
- **Self-training has plateaued.** mAP is level from student 2 on, so round 3 is the last.
- **Walk 2 is the fair test for every model.** The walk-1 frames are fair only for the students, which never trained
  within 1 s of them.
- **The commit threshold.** On the walk-1 frames, 0.5 gives student 1 a mean signed count error of +4%, and 0.45
  would barely do better. So the replay keeps 0.5 for every model.

### The count check: walk 2's bays against the owner's counts

The replay as in RESULTS §16–18: hold-to-count, tracked carry, after the bay card. Bottles after matching, with the
possible-miss prompts the replay raised on bottles.

| model | bay 1 (82) | bay 2 (84) | bay 3 (68) | all bottles (234) | prompts | bay 3 tins (22) | cartons (11) | bags (11) |
|---|---|---|---|---|---|---|---|---|
| RF-DETR Nano, COCO weights | 34 (−59%) | 35 (−58%) | 33 (−51%) | 102 (−56%) | 44 | – | – | – |
| smoke model (raw drafts) | 50 (−39%) | 47 (−44%) | 40 (−41%) | 137 (−41%) | 74 | 0 | – | – |
| student 1 | 43 (−48%) | 39 (−54%) | 39 (−43%) | 121 (−48%) | 67 | 1 | 1 | 0 |
| student 2 | 55 (−33%) | 47 (−44%) | 34 (−50%) | 136 (−42%) | 76 | 2 | 1 | 0 |
| student 3 | 50 (−39%) | 46 (−45%) | 34 (−50%) | 130 (−44%) | 73 | 2 | 1 | 0 |

- **The students count about a quarter to a third more bottles than the COCO model.** Students 2 and 3 are level
  with the smoke model (130–136 against 137).
- **The bay totals stay about 40% low, and the detector is not the main reason.**
  - In single checked frames, student 3's bottle units are within 11% (median) of the truth.
  - The replay's 2D counting turns many sightings into possible-miss prompts, which are never counted (RESULTS §17).
  - Some stock was never in a committed view (RESULTS §10).
- **Tins, cartons and bags are barely found** (2 of 22, 1 of 11, 0 of 11). Walk 1, the only training walk, hardly
  shows them.

### Time, on the Apple M5

| step | time |
|---|---|
| dense frames (381 from walk 1, 48 from walk 2) | 16 s |
| OWLv2, 429 frames | 8 min |
| Grounding DINO, 429 frames | 17.5 min |
| tiled OWLv2, tried on the 15 checked frames | 1 min |
| linking through the video, per set of teachers | about 1 min |
| calibration grid | 5–20 s |
| student 1: training, then running it as a teacher | 31 min + 0.5 min |
| student 2: training, then running it as a teacher | 17 min + 0.5 min |
| student 3: training | 16 min |
| evaluation and replay, per model | about 2–3 min |
| all of it | about 2 h of wall time |

## Limits

- **The calibration set is tiny.**
  - 9 frames (44 bottles, 95 tops) choose the thresholds.
  - The 6 walk-2 frames (22 bottles, 66 tops) are the only untouched check.
  - Differences of a few points are noise.
- **The teachers' systematic errors pass through.** Boxes on partly hidden bottles behind the front row, necks, and
  caps split in two look the same in every frame. The video can't remove them; only the rule-based fixes and the
  teachers' agreement do.
- **`can`, `carton` and `bag` are unverified.**
  - No checked frame holds one.
  - Walk 1 holds few: across 381 frames the labels have 25 cans, 31 cartons and no bag.
  - Looking at two frames showed a shrink-wrapped multipack labelled `carton`. By the rules it is a `case`.
- **One venue.** Walk 2 is the same storeroom, the same products and the same phone as walk 1. These numbers are
  not the unseen-venue holdout ADR 006 asks for.
- **Self-training can confirm its own mistakes.**
  - Rounds 2 and 3 still improved the labels on the untouched walk-2 frames.
  - A student is never trained within 1 s of a calibration frame, so its calibration views are new to it.
  - Students 2 and 3 are about level, so more rounds would not help.
- **The smoke model trained on the walk-1 checked frames.** Its walk-1 numbers are left out.

## What would improve the labels next

1. **A training walk past tins, cartons and bags,** such as bay 3's shelves. Walk 2 is the test set and must stay
   unseen. Without such a walk the three classes can't be learned or checked.
2. **Depth from the app's capture mode** (P0-2). LiDAR depth tells a front bottle from the partly hidden ones behind
   it, which is the teachers' biggest error. It also lets tracks link in 3D.
3. **More checked frames: 30 more, about 2 hours of agent time with the review loop.** They would let each class be
   tuned on its own, measure the minor classes, and serve as exemplars for OWLv2's image-guided detection of this
   venue's caps and bottles.
4. **Counting in 3D.** The bay totals are now limited by the replay's 2D counting more than by the detector. The
   app's ARKit anchors (P0-5, P0-8) are the real test.
