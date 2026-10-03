# Walkthrough replay: real footage

Two visits to one bar storeroom, replayed with `walkthrough.py`. The videos stay off this repository
(venue footage); this file holds only aggregate numbers.

- **First walk** (filmed 2026-09-26, sections 1–7): two continuous sweeps. **No true counts were
  written down**, so nothing there measures accuracy against the truth.
- **Second walk** (filmed 2026-09-30, sections 8–17): three bays filmed with holds, as the app will
  ask. Section 16 has the reference counts per product, checked by the counter. Section 17 counts
  caps instead of whole bottles.

## The footage

| | video 1 | video 2 |
|---|---|---|
| phone and camera | iPhone 14 Pro Max, 1× (24 mm equivalent) | iPhone 14 Pro Max, 0.5× ultra-wide (14 mm equivalent) |
| held | landscape | portrait |
| length | 151 s | 88 s |
| format | 1080p, 30 fps, H.264, HDR off | 1080p, 28.6 fps on average (the low-light frame rate), H.264, HDR off |
| distance to the front row (median, quartiles) | 0.66 m (0.55–0.83) | 0.43 m (0.34–0.59) |
| shelf area in one view at that distance | 0.84 × 0.47 m | 0.53 × 0.94 m |
| a front bottle, as a share of the frame height | 64% | 32% |

- Distances come from the widths of whole bottles in the keyframes, assuming bottles 8 cm wide. Rough.
- Field of view: 65° across the long side for 1× (the script's default) and 95° for 0.5× (the same
  video crop, scaled by the 35 mm equivalents).
- Both walks are a continuous sweep along each shelf with quick vertical moves between shelves, at
  0.4–0.8 m. The aisle probably leaves no room for the 1–1.5 m the recording guide asks for.

## 1. Hold-to-count almost never fired

| | video 1 | video 2 |
|---|---|---|
| view speed, median | 25°/s | 35°/s |
| time under 10°/s | 9% | 3% |
| longest stretch under 10°/s | 1.1 s | 0.6 s |
| commits with ADR 003's rule (under 10°/s for 0.8 s) | **3 in 151 s** | **0** |
| stretches of 0.8 s or more under 20°/s | 21 | 2 |

- **The motion is real, not noise.** Three estimates agree within about 1°/s: median feature
  motion, median motion vector, and a RANSAC similarity fit. Tracking was lost in only 0.2–0.3% of
  frames.
- **Close up, walking reads as turning.** At 0.6 m, stepping sideways at 0.3 m/s moves the image as
  fast as turning at about 25°/s.
- **The pauses were slowdowns, not stops.** Whether an on-screen progress ring makes people
  actually hold still is a question for the spike (P0-2, P0-8).

## 2. A trigger for sweeps: `--sweep 0.5 --sweep-speed 30`

- **How it fires:** commit each time the view has moved half a frame since the last keyframe.
- **Which frame it keeps:** the sharpest frame of the second half of that move. Only frames slower
  than 30°/s qualify.

On the synthetic walk (`check_sweep.py`), with the true boxes as the detector, every object is
followed by identity. There are 146 objects.

| trigger | carry | commits | counted once | counted twice | never counted | possible-miss prompts |
|---|---|---|---|---|---|---|
| hold-to-count (ADR 003) | keyframe homography | 19 | 142 | 0 | 4 | 8 |
| hold-to-count | tracked (`--carry track`) | 19 | 142 | 0 | 4 | 8 |
| every 2 s | homography | 26 | 140 | 0 | 6 | 13 |
| every 2 s | tracked | 26 | 140 | 0 | 6 | 13 |
| sweep 0.5, any speed | homography | 38 | 115 | **28** | 3 | 38 |
| sweep 0.5, any speed | tracked | 38 | 142 | 0 | 4 | 47 |
| sweep 0.5, keyframes under 20°/s | either | 22 | 144 | 0 | 2 | 4 |
| sweep 0.5, keyframes under 30°/s | either | 25 | 145 | 0 | 1 | 1 |
| hold-to-count, fallback 0.7 under 30°/s (section 10) | homography | 24 | 142 | 0 | 4 | 9 |
| hold-to-count, fallback 0.7 under 30°/s | tracked | 24 | 141 | 0 | 5 | 10 |

The uncapped sweep rows vary a little from run to run (28–38 prompts with homographies). Their
blurred keyframes register only just, or just fail, and FLANN matching is randomised.

- **Without the speed cap, sweep commits land in the middle of fast moves.** Keyframe registration
  can't match those blurred frames, so objects are counted twice. The cap fixes that. Tracked carry
  (section 3) also avoids the double counts, but raises more prompts.
- **On the real walks:**
  - 109 commits for video 1 and 52 for video 2: a commit every 1.2 s and 1.6 s (median);
  - the longest gap is 5.4 s and 6.8 s;
  - consecutive views overlap 65% and 75% (median), with one gap with no overlap in each walk.

## 3. Keyframe registration fails at this range, because of parallax

- **Few views link to the previous one.** 3–8% of consecutive commits registered for video 1, 0–1%
  for video 2, whatever the trigger or speed cap.
- **Blur is not the cause.** Keyframes slower than 20°/s have 2–3 times more SIFT features and still
  don't register.
- **Parallax is.** Where features do match, a fundamental matrix explains about twice as many of
  them as a homography does. The front row is 0.4–0.7 m away and the back rows 20–30 cm further.
  Moving sideways by half a view shifts the two by different amounts: at video 1's distance,
  about 1.4 bottle widths apart.

So the replay's planar stand-in for ARKit can't be used on close, walking footage.

Section 13 revises "blur is not the cause". On the second walk, keyframes from real holds registered
far more often at the same overlap.

**`--carry track`** carries counted items through the video instead:
- **Items:** dense optical flow moves each counted item by the flow inside its own box, so each
  row keeps its own parallax.
- **Counted zones** follow their own items.
- **Revisits** still use keyframe registration.

On the synthetic walk it reproduces the reference for hold-to-count exactly, and counts nothing
twice under any trigger (table above).

## 4. Counts on the real walks

Sweep 0.5, keyframes under 30°/s, tracked carry. Bottles only: COCO has no can or case.

| walk | detector | sum of per-view counts | after matching | possible-miss prompts |
|---|---|---|---|---|
| video 1 | RF-DETR Nano, COCO weights | 285 | 125 | 119 |
| | the same on 2 × 3 tiles | 476 | 191 | 224 |
| | OWLv2 | 416 | 173 | 194 |
| video 2 | RF-DETR Nano, COCO weights | 206 | 73 | 124 |
| | the same on 2 × 3 tiles | 246 | 100 | 138 |
| | OWLv2 | 243 | 96 | 144 |
| video 2, `--band 0.35` | RF-DETR Nano, COCO weights | 92 | 60 | 53 |
| | the same on 2 × 3 tiles | 108 | 78 | 62 |
| | OWLv2 | 111 | 74 | 59 |

OWLv2 also found cans (6 and 12, food-service tins) and cases (2 and 1).

What this says:
- **Summing views overcounts by 2.3–2.8 times** the matched count. With consecutive views
  overlapping 65–75%, most bottles appear in two or three views.
- **Prompts are about as many as counted items.** ADR 003's simulation expected 4–6% of units, and
  gate G7 allows 10%. Most prompts are not near misses of the matching: for RF-DETR on video 2, 80%
  have no counted item within two box widths. Without true counts the replay can't separate two
  causes:
  - **The detector changes its mind between views.** With COCO weights, 137–491 detections per walk
    sit between the shown and the commit thresholds. A bottle skipped in one view becomes a prompt
    in the next, which is what S5 is designed to do.
  - **The replay's zones can't follow depth.** A zone follows its items as one flat shift, while at
    this range the front and back rows move differently. ARKit's 3D anchors don't have this
    problem.
- **The edge band matters at this range** (section 5). `--band 0.35` more than halves the prompts on
  video 2, and also counts about 20% fewer bottles.

## 5. At 0.4–0.7 m, whole-object framing breaks down

- **The edge band is smaller than half a bottle.** ADR 003 sizes the band at about half the largest
  object. The replay's default, 15% of the short side, is less than half a bottle here. A bottle
  cut by the image border can then have its centre inside the counted zone. It is never counted,
  and every later view flags it as a possible miss.
- **In the app, the band must be set in centimetres from LiDAR depth**, as ADR 003 intends. At
  video 1's distance, in landscape, that leaves an inner frame about 12–17 cm tall, so each view
  counts a thin strip.
- **Dense stock several rows deep shows mostly bottle tops** when filmed from 0.4–0.7 m and
  slightly above. The front row runs off the bottom of the frame and the back rows show only their
  tops. Hand counts on four views of video 1 (Claude, from the keyframes, approximate):

| view | tops visible in the inner frame | whole bottles (strict rule) | RF-DETR Nano | on tiles | OWLv2 |
|---|---|---|---|---|---|
| soft drinks in glass, 4 rows deep | 19 | 0 | 4 | 6 | 14 |
| liqueurs, 2–3 rows deep | about 13 | 0 | 7 | 8 | 13 |
| wine, loose group | 4–5 | about 5 | 5 | 6 | 7 |
| mixed spirits | 4–6 | about 4 | 5 | 6 | 6 |

- **The COCO detectors land between the two definitions.** They count a changing mix of whole
  bottles, necks and tops. What counts as a "bottle" in such views is a labelling decision (ADR 006
  counts objects more than 50% visible), and it decides what gate G2 measures.
- **The top is the unit a camera can count here.** ADR 006 lists `bottle_top` as a candidate class.
  This footage argues for trying it in Phase 0. On shelves below eye level, tops seen from above
  also count rows several deep directly. (The MVP then planned a "×N deep" multiplier; it was
  dropped on 2 October 2026, section 17.)

## 6. The 1× or the 0.5× camera?

- **The 0.5× camera sees more.** It covers about 3 times the shelf area per view at the same
  distance, and whole bottles fit: a bottle is 32% of the frame height instead of 64%.
- **But ARKit tracking and LiDAR use the 1× camera.** Apple's
  [WWDC22 camera session](https://developer.apple.com/videos/play/wwdc2022/110429/) says the LiDAR
  Depth Camera uses the rear wide-angle camera. Apple
  [DTS (2022)](https://developer.apple.com/forums/thread/712533) says there is no supported way to
  run world tracking on the ultra-wide.
- **So the app sees what video 1 shows.** If narrow aisles are common, that is a risk for ADR 001
  and FR-14. P0-1 should measure aisle widths.

## 7. Cost on an Apple M5 (Python, not the phone)

| detector | per commit |
|---|---|
| RF-DETR Nano (MPS) | 0.6–0.8 s |
| RF-DETR Nano on 2 × 3 tiles plus the full frame | 2.9–3.5 s |
| OWLv2 (MPS) | 4.4–5.2 s |

On the GPU, OWLv2 was about 13 times faster than on the CPU for the same boxes: 42 of 42 matched, and
the scores were within 1e-4.

## What to record next

Recorded on the second walk (sections 8–14), except the counts and the 1 m rack, which the 50 cm
aisle ruled out.


- **One pass with real holds:** portrait, 1×, about 2 s still on each shelf section. It tests
  whether people hold when asked.
- **The aisle width.** If there is room, one rack filmed from 1 m.
- **True counts for 3–5 sections,** including one block several rows deep: count its tops and its
  rows.
- **Strip the location before sharing.** iPhone videos carry where they were recorded in their
  metadata.

## 8. The second walk

Filmed on 2026-09-30 with the same iPhone 14 Pro Max, 1× lens, portrait, 1080p at 30 fps, HDR off.
The protocol asked, per bay:
- a bay card in view for 2 s;
- a snake from the top left, holding still for about 2 s on each view ("one, two");
- about half a screen's move between holds.

| | bay 1 | bay 2 | bay 3 |
|---|---|---|---|
| stock | spirits, mostly single rows | spirits and liqueurs, several rows deep | tins, cartons, syrup and purée bottles |
| clip length | 45 s | 78 s | 56 s |
| distance to the front row, from bottle widths (median, quartiles) | 0.79 m (0.60–1.05) | 0.46 m (0.42–0.71) | 0.38 m (0.36–0.50) |

- **The aisle is 50 cm**, and the counter filmed from 35 cm to the front bottles. The bottle-width
  estimates agree in bays 2 and 3. In bay 1, many bottles stood far back on deep shelves.
- **So bays 2 and 3 were filmed below FR-12's working range of 0.5–2.5 m.** At 0.4 m, the 1× view
  is about 0.3 × 0.5 m: three or four bottles across.
- **Only one clip per bay was filmed, with holds.** There was no sweep clip, no farther clip (the
  aisle rules it out) and no full walk with a revisit.
- **The hand counts have not reached the count sheet**, so nothing below measures accuracy.

Sections 10 and 11 skip the bay-card hold at the start of each clip (`--start` 2.2–3.2 s), because
the app will have no card. Section 11 shows what the card changed. Sections 9, 12 and 13 use the
whole clips.

## 9. People hold still when asked

| | walk 1, video 1 | walk 1, video 2 | walk 2, bay 1 | bay 2 | bay 3 |
|---|---|---|---|---|---|
| view speed, median | 25°/s | 35°/s | 7°/s | 7°/s | 9.5°/s |
| time under 10°/s | 9% | 3% | 60% | 67% | 52% |
| longest stretch under 10°/s | 1.1 s | 0.6 s | 3.7 s | 2.9 s | 2.1 s |
| commits with ADR 003's rule (under 10°/s for 0.8 s) | 3 in 151 s | 0 in 88 s | 14 in 45 s | 32 in 78 s | 16 in 56 s |
| stretch under 10°/s, median of those of 0.8 s or more | – | – | 1.8 s | 1.4 s | 1.1 s |

Whole clips, card included.

- **Every stretch of 0.8 s or more under 10°/s committed.** FR-13's rule works on real holds as
  specified.
- **The holds got shorter bay by bay**: 1.8, then 1.4, then 1.1 s at the median, against the 2 s
  asked for.
  - Stretches of 1.5 s or more were 11 of 14 in bay 1 and 4 of 16 in bay 3.
  - The 0.8 s rule still had margin after three bays. Whether it has after twenty is a question for
    the spike's progress ring (P0-2, P0-8).

## 10. Steps between holds were too big, and some stock was never held

Camera moves between consecutive commits, measured by optical flow, as a share of the frame.

| | bay 1 | bay 2 | bay 3 |
|---|---|---|---|
| moves along a shelf | 9 | 27 | 11 |
| move along a shelf, median | 0.73 of a frame | 0.30 | 0.78 |
| moves over 0.7 (the inner frames no longer meet) | 5 | 3 | 6 |
| moves over a whole frame | 0 | 1 | 3 |

- **Asked for half a screen, the counter moved about three quarters in bays 1 and 3.** With FR-14's
  15% band, consecutive inner frames touch only up to a move of 0.7. Beyond that, a strip between two
  views is in neither inner frame.
- **The four moves of over a frame (1.1–2.1 frames) passed stock without a hold**, all in the
  last two bays:
  - two bottles and a boxed bottle in bay 2;
  - three stretches of bottles and bagged goods in bay 3.

  Part of what they passed is in the video but in no committed view, so hold-to-count never counts
  it.
- **The MVP has no cue for this.** ADR 003 assumes half-view steps. The counted-zone tint shows
  what is done, but "coverage of unscanned regions" is cut from the MVP (PRD section 0).

**A fallback, tried: `--fallback 0.7 --sweep-speed 30`.**
- **How it works:**
  - Hold-to-count stays the trigger.
  - When the view has moved 0.7 of a frame since the last keyframe without a hold, it commits the
    sharpest frame slower than 30°/s from the second half of that move.
  - It waits while a hold is under way, and never disarms the hold rule.
- **Synthetic walk (section 2):** all 19 holds still commit. It adds 5 commits and counts nothing
  twice.
- **Real bays:**
  - It adds 7, 8 and 15 commits, and covers the skipped stock.
  - The counts barely move: −3 to +4 bottles per bay and detector.
  - Possible-miss prompts rise:
    - bay 1: from 5–9 to 11–17;
    - bay 2: from 38–59 to 51–69;
    - bay 3: from 3–4 to 16–22.

    Many fallback keyframes are mid-move frames: 1 of 7, 4 of 8 and 6 of 15 are flagged blurry.
- **Whether its counts are closer to the truth needs the hand counts.** Showing the counter the
  uncovered strip may beat committing it blind.

## 11. Counts per bay

Hold-to-count, counted items carried by tracking (`--carry track`), after the bay card. Bottles,
except where noted.

| bay | detector | sum of per-view counts | after matching | possible-miss prompts |
|---|---|---|---|---|
| 1 | RF-DETR Nano, COCO weights | 40 | 32 | 5 |
| | the same on 2 × 3 tiles | 53 | 45 | 8 |
| | OWLv2 | 53 | 43 | 9 |
| 2 | RF-DETR Nano, COCO weights | 100 | 35 | 38 |
| | the same on 2 × 3 tiles | 120 | 37 | 59 |
| | OWLv2 | 100 | 33 | 45 |
| 3 | RF-DETR Nano, COCO weights | 38 | 32 | 3 |
| | the same on 2 × 3 tiles | 43 | 37 | 3 |
| | OWLv2 | 34 | 28 | 4 |
| | OWLv2, cans (tins) | 12 | 7 | 5 |

- **In bays 1 and 3, prompts are much rarer than on the first walk.**
  - Prompts are 8–21% of counted items. On the first walk they were as many as counted items, or
    more. That is still above the 10% that gate G7 allows.
  - Summing views overcounts by only 1.2 times, because the views overlap little.
- **Bay 2, several rows deep, looks like the first walk.**
  - Summing views overcounts by 3 times.
  - Prompts outnumber counted items: 38–59 against 33–37.
  - Many prompts sit on back-row tops that show above the front row (section 12).
- **OWLv2 found no cases in any bay.** Bay 3's cartons, sauce boxes and bagged goods are not brown
  shipping boxes, and bay 2's boxed bottle fits none of the three classes.
- **The bay card changed the totals.** The 2 s hold on the card commits a view too:
  - Bays 1 and 2: +5 to +9 bottles per detector.
    - In bay 2, the card view shows bottles that the snake films again 30 s later. The 2D replay
      can't link the two views, so it counts them twice.
  - Bay 3: tins go from 7 to 15, and bottles fall by 2–4. The card view, from further back, counted
    a lower shelf that was filmed close up later.
  - ARKit anchors should link such views in the app.
- **With keyframe homographies instead of tracking** (card included), the counts are 45–59 (bay 1),
  61–76 (bay 2) and 33–43 (bay 3), against 38–52, 41–46 and 26–35 tracked.

## 12. In rows several deep, count tops (bay 2)

Six views of bay 2 (blocks two to five rows deep), with the tops inside the inner frame counted by
eye: 57 tops.

| detector | count in the six views | against the tops |
|---|---|---|
| RF-DETR Nano, bottles | 21 | −63% |
| the same on 2 × 3 tiles | 32 | −44% |
| OWLv2, bottles | 27 | −53% |
| OWLv2 prompted "a photo of a bottle cap", score 0.2 or more | 64 | +12% (per view: median error 12%, worst +40%) |
| the same, score 0.3 or more | 40 | −30% |
| OWLv2 prompted "a photo of the top of a bottle", 0.2 or more | 35 | −39% |

- **From 0.4 m, the caps of the back rows are in view.** The bottle detectors count about the front
  row.
- **A cap prompt finds most tops with no training, but it depends heavily on the threshold.** It
  also draws two boxes on some necks, as on the worst view, which has printed neck labels.
- **This supports trying ADR 006's candidate `bottle_top` class in Phase 0.** Tops in view are
  not all the bottles on a shelf, so the hand counts' "all" and "rows" columns are the check.

## 13. Holds make keyframe registration work where views overlap

| overlap of consecutive views | registered (second walk, all bays) |
|---|---|
| under 30% | 1 of 13 |
| 30–50% | 6 of 13 |
| 50–70% | 7 of 16 |
| 70% or more | 12 of 17 |

- **Registration now depends on the overlap.** By bay, 3 of 13, 19 of 31 and 4 of 15 consecutive
  commits registered. Bay 2 moved in small steps.
- **The first walk registered 0–8% of consecutive commits at 65–75% overlap.** Keyframes from a
  real hold (under 10°/s for 0.8 s) register where keyframes under 20°/s did not. So motion blur and
  rolling shutter probably matter more than section 3 concluded. The shelves differ too, so this is
  not a controlled comparison.
- **Parallax still limits registration.** Even in bay 2, homographies leave many items unlinked
  (section 11), and tracked carry stays the better stand-in for ARKit.

## 14. Still open after the second walk

- ~~Count error per product and per bay.~~ Answered in section 16.
- **Double counting over a whole walk, with a revisit.** No full-walk clip was filmed.
- **Holds against a sweep on the same shelves.** No sweep clips were filmed.
- **Guiding the step size, or showing uncovered strips.** Section 10 is the case for testing one of
  them in the spike (P0-2, P0-8).

## 15. A stocktake counts products, not bottles

The count sheet for the second walk asked for totals per shelf: front row, all bottles, rows,
cans, cases. The counter could not use it. A stocktake answers how many of each product there are,
and a shelf total doesn't. The second walk's videos show how this storeroom is organised:

- **Every product has its own spot, with a tape label on the shelf edge under it.** The labels are
  handwritten or printed. The three bays hold about 62 products.
- **A labelled spot can be empty.** That is a 0 on the stock sheet, not a missing line.
- **Many products differ only in their label:** one syrup brand in about ten flavours, two cordial
  flavours and three purée flavours, each in identical bottles.
- **The units vary:** bottles, tins, cartons, bags, boxed sauces, and closed cases on the floor
  under a bay.

What it means:
- **The app's output and the reference counts must both be per product.** Gate G2's per-view count
  error is a detector metric. The stocktake's metric is the count error per product.
- **The tape labels are a product catalogue already in the room.** Reading them could name a group
  without teaching (ADR 004), and the app could count what stands above each label. P0-6 already
  plans to test OCR with `customWords`.
- **Look-alike flavours need the label text.** Shape and visual similarity alone are unlikely to
  separate them. They belong in P0-6's bake-off.
- **Bay 3 is mostly not `bottle`, `can` or `case` (ADR 006).** It holds tins, cartons and bags.
  Either the MVP adds classes for them, or they stay manual lines (the PRD's `manual_line`).
- **Reporting zero stock needs the venue's catalogue.** The camera cannot see what isn't there.

The count sheet is now one line per product per bay. It is pre-filled with the 62 products read
from the videos, each with a count, a unit, and closed cases with their size.

## 16. Reference counts per product, and how far the counts fall short

**How the reference was made.**
- Claude counted every product in the three clips, frame by frame. The count used the views from
  above and below, and the parallax as the camera moves.
- Each count went on the count sheet with a picture and a time in the clip.
- The counter then checked all 58 products against the same clips and corrected 7.
- Closed cases are left out of this trial: they are stored elsewhere.
- Open bottles are not stock, by the counter's rule.

| bay | products | reference units | careful video count | products off | units off |
|---|---|---|---|---|---|
| 1 | 17 | 81 | 82 | 1 | +1, an open bottle |
| 2 | 19 | 83 | 84 | 1 | +1, an open bottle |
| 3 | 22 | 112 | 99 | 5 | −13 |
| all | 58 | 276 | 265 | 7 | 15 |

- **On open shelves of bottles, all the stock was in the video.**
  - Bays 1 and 2: all 166 bottles were found, in rows up to five deep.
  - The two differences are half-full open bottles.
- **Stock stacked out of sight was not in the video.** Bay 3 is missing 13 units:
  - 11 are tins and bags stacked two high behind the front ones;
  - 2 are a bottle at the back of each of two syrup rows.
- **The careful count flagged where it was unsure.**
  - Of the 8 products it marked unsure, 4 were wrong. They hold 12 of the 13 missing units.
  - Of the 50 it was sure of, 1 was a counting error, plus the two open bottles.
- **The flavours read from the labels held.** The counter renamed no product.
- **It is far too slow for the app.** Three agents in parallel took 2 to 4.7 hours per bay, about a
  million tokens in all. It shows what the video holds, not a way to count in the app.

**The counting pipeline against the reference.**
- These are section 11's runs: hold-to-count, tracked carry, after the bay card. Saved with `--truth`
  in `out/w2-bayN-truth/`.
- Bays 1 and 2 are compared with physical bottles, open ones included, since a detector can't tell:
  82 and 84.
- Bay 3 is compared with its 68 bottles (6 of them boxed singly) and 22 tins. Its cartons and bags
  have no class.

| bay | reference | front row | RF-DETR Nano | the same, 2 × 3 tiles | OWLv2 |
|---|---|---|---|---|---|
| 1 | 82 bottles | 26 | 32 (−61%) | 45 (−45%) | 43 (−48%) |
| 2 | 84 bottles | 30 | 35 (−58%) | 37 (−56%) | 33 (−61%) |
| 3 | 68 bottles | 25 | 32 (−53%) | 37 (−46%) | 28 (−59%) |
| 3 | 22 tins | | | | 7 (−68%) |

- **The pipeline counts about the front row, so it finds about half the stock or less.**
  - The front row comes from the careful count's notes on each product (rows across, and how deep).
  - The front row holds about a third of the bottles: rows are 2 to 5 deep.
- **No better whole-bottle detector closes this gap.** The depth has to come from elsewhere:
  - tops counted from above (section 12: a zero-shot cap prompt came within 12% of the tops in view);
  - units revealed as the camera passes (the careful count relied on this on shelves filmed
    straight on);
  - the LiDAR depth of each row against one bottle's depth;
  - asking how many deep.
- **Open bottles count as units in the MVP** (product owner, 2 October 2026).
  - The app counts every bottle it sees, so its reference is physical bottles: 82 and 84 above.
  - An open-bottle counter that estimates the liquid level comes after the MVP.
- **Stacked tins and bags hidden behind can't be seen at all.** The MVP has neither a "more behind?"
  prompt nor a `×N deep` multiplier (product owner, 2 October 2026). The goal is a walk around the
  storeroom that ends with a counted stock sheet.

## 17. Counting caps finds most of the rows behind

The same runs as section 16 (`out/w2-bayN-caps/`), with `--detectors rfdetr_tiled,owlv2,owlv2_caps`.
`owlv2_caps` is OWLv2 prompted with "a photo of a bottle cap" at a score of 0.2, and each cap counts as
one bottle (section 12).

| bay | reference | best whole-bottle count | caps | possible-miss prompts on caps |
|---|---|---|---|---|
| 1 | 82 bottles | 45 (−45%) | 72 (−12%) | 33 |
| 2 | 84 bottles | 37 (−56%) | 73 (−13%) | 82 |
| 3 | 68 bottles | 37 (−46%) | 42 (−38%) | 10 |

- **On the spirits shelves, the tops carry most of the depth.** Counting caps instead of whole bottles
  takes bays 1 and 2 from about half the stock to about seven eighths.
  - The camera looks down on the top and bottom shelves, so it sees the tops of rows up to five deep.
  - On the middle shelves, filmed straight on, it sees the tops that stand out between and above the
    front bottles.
- **Bay 3 gains less.** It holds pump-top purées, boxed sauces and flat-topped syrups. Its tins,
  cartons and bags have no tops to count.
- **Read the −12% and −13% as a direction, not an accuracy.**
  - Errors run both ways. Some caps get two boxes, which overcounts some rows. Others sit behind a
    front cap or in the edge band, which undercounts other rows.
  - Prompts are far above gate G7's 10%: 46% of counted caps in bay 1 and 112% in bay 2. Small, dense
    tops sit inside the 2D counted zones carried over from the shelf above, and the 1:1 gate of half
    a box width is tight for a cap.
  - ARKit's 3D zones should separate the shelves; tracking quality on tops is a spike question.
- **What it means:**
  - Label tops (ADR 006's candidate `bottle_top`) from the start of the dataset.
  - The spike should test a commit that counts tops as well as bottles.
  - The MVP has no `×N deep` multiplier (PRD FR-29, removed on 2 October 2026), so tops are how the
    app counts the rows behind.

