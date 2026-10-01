# Walkthrough replay

Why this exists: the iOS spike (P0-2) is weeks away, but an ordinary phone video of a storeroom
walk can already be replayed through the parts of StockMask's counting loop that don't need
LiDAR or ARKit. That puts real rooms in front of the design in week 1: how people hold the
phone, what the detector sees on real shelves, and how much overlapping views would double count.

- Decisions it informs: [ADR 002](../../docs/decisions/002-detector.md) (detector),
  [ADR 003](../../docs/decisions/003-double-count.md) (hold-to-count, double counting),
  [ADR 006](../../docs/decisions/006-training-data.md) (pre-labels for dataset v0).
- Phase 0 tasks: P0-1 (discovery footage), P0-3 (COCO weights first), P0-7 (first labelled images).

**Venue footage never goes into this repository: it is public.** Videos and the `out/` folder are
git-ignored. Only code and aggregate numbers get committed.

**Real footage: [`RESULTS.md`](RESULTS.md)** (one storeroom, two visits).
- **First walk (2026-09-26):** hold-to-count almost never fired, because the walks were continuous
  sweeps at 0.4–0.7 m. Keyframe registration failed on parallax, which is why `--sweep` and
  `--carry track` exist.
- **Second walk (2026-09-30), filmed with holds:** every hold of 0.8 s or more committed. But the
  moves between holds were too big, and some stock was passed without a hold, which is why
  `--fallback` exists. Filmed at 0.35–0.5 m in a 50 cm aisle, below FR-12's working range.

## Recording a walkthrough

For whoever holds the phone:

1. **Phone:** an iPhone 12 Pro or later if there is one (the pilot hardware); otherwise any phone.
   Use the 1× camera, not 0.5×.
2. **Settings:** 1080p or 4K, 30 fps. Turn **HDR Video off** (Settings → Camera → Record Video).
   HDR still works here, but the colours come out flatter.
3. **Hold it portrait**, the way the app will be held, about 1–1.5 m from the shelves. If the
   aisle is too narrow for that, film anyway and write down the aisle width.
4. **Snake over each rack:** lower half left to right, upper half right to left. On each shelf
   section, **hold still for about 2 seconds** ("one, two"), then move on by about half a screen.
   That is what the app will ask for (hold-to-count). Stop completely: in the first footage, the
   pauses were slowdowns, never more than about 1 s under 10°/s.
5. **Don't tidy up.** The hard cases are the point:
   - rows several deep; stacked cases; open cases;
   - a whole shelf of the same bottle; racks that look alike;
   - steel or glass reflections; the walk-in cooler.
6. **At the end, go back** to one or two shelves you already filmed and hold on them again (a
   revisit).
7. **Keep people out of the shot.**
8. **Write down some true counts:**
   - 3–5 shelf sections, e.g. "rack 2, middle shelf: 18 bottles, 2 cases";
   - if you know them, the totals of bottles, cans and cases in what you filmed.
9. **Note:** phone model, room (storeroom or walk-in), and the light level if you have a lux-meter
   app.

## Getting a video here

Share a link that anyone with it can open: Google Drive, Dropbox, WeTransfer or iCloud. Download
it into `videos/`, which is git-ignored. Don't upload it to GitHub, not even as a release asset.
iPhone videos record where they were filmed: strip the location before sharing (Photos → Share →
Options → Location off).

## Run

```bash
python -m venv venv && . venv/bin/activate
pip install torch==2.7.0 torchvision==0.22.0 --index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt
python walkthrough.py videos/venue1.mov --truth bottle=120,can=0,case=8
```

This writes `out/venue1/`:

| file | what |
|---|---|
| `report.md` | the summary: commits, counts per detector, flags, revisits, limits |
| `timeline.png` | view speed over time, with the holds and the commits |
| `contact_<detector>.jpg`, `commits/<detector>/NNN.jpg` | every commit, drawn in the PRD's visual language |
| `cvat/` | keyframes plus OWLv2 boxes as COCO pre-labels, ready to correct in CVAT |
| `summary.json` | everything above, machine-readable |

Options:
- **For a walk filmed without pausing:**
  - `--sweep 0.5 --sweep-speed 30`: commit each time the view has moved half a frame. The
    keyframe is the sharpest frame of the second half of that move, and only frames slower than
    30°/s qualify. This keeps ADR 003's half-view overlap at any walking speed.
  - `--every 2`: commit the sharpest frame of every 2 s instead.
- **`--fallback 0.7 --sweep-speed 30` for walks with holds that skip parts of a shelf.**
  Hold-to-count stays the trigger. When the view has moved 0.7 of a frame since the last keyframe
  without a hold, it commits anyway. Beyond 0.7, the inner frames of two views no longer meet. These
  commits are flagged "no hold". The fallback waits while a hold is under way.
- **`--carry track` for footage filmed close up while walking.** It carries counted items through
  the video by optical flow, not by keyframe homographies. Those fail on parallax at 0.4–0.7 m
  ([`RESULTS.md`](RESULTS.md)).
- `--view-truth views.csv` (columns `commit,class,count`): your counts inside the dashed frame of
  some commits. The report then gives gate G2's per-view error.
- `--detectors`: default `rfdetr,rfdetr_tiled,owlv2`.
- `--hfov`, `--hold`, `--max-speed`, `--rearm`, `--band`: the ADR 003 starting parameters.
  - `--hfov` is the field of view across the long side: 65° for the 1× camera (the default), about
    95° for 0.5×.
  - Close up, raise `--band` to at least half a bottle's height in the frame.

Detections are cached per keyframe in `out/.detcache/`, so a second run on the same video only
re-runs what changed. OWLv2 runs on the GPU when there is one (CUDA, or MPS on a Mac).

**Cost on 4 CPU cores:**
- about 0.3 s per second of 720p video to replay;
- per commit: OWLv2 about 3.5 s, RF-DETR Nano about 0.2 s (1 s tiled);
- registering every pair of commits, about 50 ms per pair (100 commits: about 4 minutes).

A 34 s clip with 12 commits took 1.4 minutes.

**On an Apple M5 (MPS):**
- per commit: RF-DETR Nano 0.6–0.8 s, tiled 2.9–3.5 s, OWLv2 4.4–5.2 s;
- 151 s of 1080p with 109 commits, `--carry track`: about 32 minutes the first time, 15 minutes
  from the cache.

## What it does

1. **Hold-to-count** (FR-13):
   - Optical flow gives the view's angular speed, using the field of view (default 65° across the
     long side, iPhone 1×).
   - A commit fires after 0.8 s under 10°/s. The next one needs the view to move 5° first.
   - It runs causally, frame by frame, like the app. The keyframe is the sharpest frame of the hold.
2. **Detection at each commit:**
   - `rfdetr`: RF-DETR Nano with COCO weights. COCO knows `bottle` but not can or case. This is
     P0-3's "COCO weights first", on the detector ADR 002 chose.
   - `rfdetr_tiled`: the same model on overlapping tiles too. Is the 384 px input the limit, or the
     model?
   - `owlv2`: OWLv2 (Apache-2.0) prompted with bottle, beverage can and cardboard box. This is the
     ADR 006 pre-labeller. Far too slow for a phone.
   - `owlv2_caps` (not in the default set): OWLv2 prompted with "a photo of a bottle cap", each cap
     counted as one bottle. Do the tops of the rows behind count the bottles a front view hides?
     This stands in for ADR 006's candidate `bottle_top` class.
   - `yolo26n`, `yolo26s`, `yoloe26s_caps` and the other `yolo*` names: Ultralytics models (AGPL-3.0),
     which this script never runs. [`../yolo_eval/run.py`](../yolo_eval/run.py) puts their detections in
     the cache first, from its own venv ([`../yolo_eval/RESULTS.md`](../yolo_eval/RESULTS.md)).
   - What counts: a box counts only if it is whole (not cut by the border), its centre is in the
     inner frame (FR-14), and its score clears the commit threshold (FR-18).
3. **Double counting between commits, in 2D.** Shelf fronts are roughly flat, so a homography
   between two keyframes carries one commit's counted items and counted zone into the other. Then
   ADR 003's strategy S5:
   - a small common-offset refinement (at most half an item);
   - 1:1 matching;
   - nothing auto-added inside a counted zone ("possible miss" instead).

   **Look-alike racks** (the same products on another rack) fool pairwise matching, exactly as they
   fool relocalisation in ADR 003. Two guards reject them:
   - the matched features must explain at least 8% of the features in the claimed overlap;
   - two earlier views that share a large part of the current one must match each other too.

   The report lists what they rejected, and every match onto a much earlier commit, for a person to
   check.

   **`--carry track`**, for cameras that move close to the shelves, follows ARKit's continuous
   tracking more closely:
   - **Counted items** are carried frame by frame. Dense optical flow moves each item by the flow
     inside its own box, so rows at different depths keep their own parallax.
   - **An item out of view** follows the frame's overall motion for up to 3 s.
   - **A counted zone** follows its own items.
   - **Revisits** still use keyframe registration.
4. **Frame conditions** per commit: dark, blurry, clipped highlights (the PRD §9 hints).

## Checking it without real footage

`make_test_video.py` films a synthetic storeroom with known answers:
- two racks with the dedup simulation's geometry, and products repeated across racks;
- a virtual handheld phone: portrait HEVC stored landscape with a rotation flag, as an iPhone writes
  it;
- hand tremor and motion blur;
- 19 scripted holds, a 0.5 s pause that must not commit, and a revisit.

`--check` replays it with the true boxes as the detector. It compares every commit with the same
rules applied to the true geometry.

```bash
python make_test_video.py out/synth.mp4 --check
python make_test_video.py out/photo.mp4 --image shelf.jpg   # pan over a real photo, to try the detectors
```

**Result on 2026-09-25:**
- 19 holds → 19 commits, each 0.8 s into its hold; none for the pause.
- Every commit's split into new, already counted, possible miss, edge band and cut matches the true
  geometry exactly.
- Of 146 objects: 142 counted once, 0 counted twice, 8 possible-miss prompts. Summing the views
  instead would have counted 319 sightings.

Before the look-alike guards, one view of rack 2 matched two views of rack 1 on shared products. It
hid 6 real items. That is the wrong-rack failure in miniature.

`check_sweep.py` checks the other triggers and both carry methods on the same synthetic video. It
follows every object by identity, because those triggers fire at moments no script knows in
advance. Results are in [`RESULTS.md`](RESULTS.md) section 2.

```bash
python check_sweep.py out/synth.mp4
```

## Known limits

- **No 3D.** Nothing here measures glass depth (G4) or revisit drift (G5).
  - The 2D matching assumes a flat shelf front per view.
  - Rows at different depths and large viewpoint changes break it. On the first real footage,
    filmed at 0.4–0.7 m while walking, keyframe registration linked under 10% of views.
  - `--carry track` handles parallax for items in view. Its zones still follow their items as one
    flat shift.
  - It is a stand-in for ADR 003, not the design.
- **A fixed edge band.** `--band` is a share of the frame. ADR 003 sizes the band in centimetres,
  at half the largest object. Close up, the default is smaller than half a bottle.
- **Not the detector we will ship.** RF-DETR Nano has COCO weights here; fine-tuning comes first
  (P0-7).
- **Rough thresholds.** The OWLv2 thresholds (0.2 shown, 0.3 counted) and the clean-up of row and
  part boxes are heuristics, tuned on two photos.
- **Filmed without the app.** People hold a phone differently when an app guides them.
- **HDR.** It is read without tone mapping.
