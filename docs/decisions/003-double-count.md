# ADR 003: How StockMask avoids counting the same item twice

Status: **Accepted. Thresholds are tuned and "rack tags mandatory?" is decided in Phase 0 (gates G5, G7)** · 2026-09-25

## Decision

1. **Counting happens in commits.** A commit fires on a steady hold of about 0.8 s, or on the
   shutter. It never fires per frame or per item, and never while ARKit tracking is not `normal`.
2. **A commit counts only objects fully inside the inner frame.** Objects cut by the frame edge
   are left for the next view, because their box centre is biased.
3. **Each commit stores two things, anchored locally:**
   - its **items**, as 3D points;
   - a **counted zone**: the 3D slab covered by the view's inner frame, at the items' depth.

   "Anchored locally" means a per-commit `ARAnchor`, or the frame of a rack tag when one is in
   view.
4. **On every later commit, run a local drift refinement first.** Estimate the view's offset
   against nearby counted items, searching ±4.5 cm only (half a bottle). Then match detections to
   counted items **one-to-one** (Hungarian assignment). The gate is anisotropic: about 4 cm along
   the shelf, 8 cm vertically, 10 cm in depth.
5. **Inside counted zones nothing is ever auto-added.** Matched detections render green.
   Unmatched ones become amber **"possible miss"** suggestions: one tap adds them.
   **Outside counted zones**, unmatched detections in the current view's zone are added.
6. **Drift alarm:** too many unmatched detections over counted zones (start at 30%) means the map
   is off. Pause counting and ask the user to re-anchor.
7. **Maps:**
   - one `ARWorldMap` per zone (room), saved after commits;
   - relocalisation enabled (`sessionShouldAttemptRelocalization` → `true`);
   - no counting while relocalising.
8. **Rack tags** (a printed marker per shelving unit, with a unique ID):
   - optional in the MVP;
   - **mandatory if gate G5 fails**: markerless p95 revisit error > 5 cm, or any wrong-rack
     relocalisation in 20 trials.

This is strategy **S5** in the simulation. With rack tags it is **S6**.

## Why: the simulation

[`research/dedup_sim/sim.py`](../../research/dedup_sim/sim.py) builds random storerooms and
counts them the way the app would, with overlapping hold-to-count views. Each storeroom has
4 racks × 5 shelves and about 300 visible units, in two layouts: mixed products, and worst-case
endless rows of one bottle. After counting, it revisits every rack with a pose error `d` that
tracking did not correct.

**Parameters:**
- 97% detector recall per view;
- measurement noise 0.6 cm along the shelf, 1.5 cm in depth ("high" noise: 1.0 / 2.5 cm);
- 95%-accurate product suggestions;
- 20 random storerooms per cell.

Full tables: [`RESULTS.md`](../../research/dedup_sim/RESULTS.md).

**Double-counted % of units, mixed shelves, low noise** (missed % in brackets):

| Strategy | d = 0 | 3 cm | 5 cm | 8 cm | 20 cm | Wrong-rack relocalisation |
|---|---|---|---|---|---|---|
| S1 "overlap above threshold" (v1 TR-3) | 3.9 (0.1) | 14.3 (0.1) | 31.2 (0.3) | 45.0 (0.4) | 84.9 (0.2) | 0.0 (**49.6**) |
| S2 local drift refinement + 1:1 match | 0.6 (0.1) | 1.6 (0.1) | 2.7 (0.1) | 15.1 (0.4) | 71.8 (0.3) | 0.0 (**49.8**) |
| S2wide: "snap" drift up to ±15 cm | 4.0 (3.1) | 4.3 (3.0) | 4.2 (3.0) | 4.3 (3.1) | 11.4 (3.1) | 1.0 (**50.4**) |
| S4 counted zones only | 0.9 (3.6) | 1.5 (3.6) | 2.2 (3.6) | 3.2 (3.6) | 8.1 (3.4) | 0.4 (**51.8**) |
| **S5 zones + S2 + prompts (chosen)** | **0.0** (3.6→0.1*) | **0.0** (3.6→0.1*) | **0.2** (3.6→0.1*) | 2.4 (3.5→0.7*) | 6.5 (3.4) | 0.0 (**51.9**) |
| **S6 = S5 + rack tags** | **0.1** (3.8→0.0*) | **0.1** | **0.1** | **0.1** | **0.1** | 0.0 (4.0†) |

\* After the user accepts the "possible miss" prompts that point at genuinely uncounted items.
Prompts shown: about 4–6% of units at d ≤ 5 cm, of which 0.6–2.6% of units are false alarms
(one per roughly 40–170 units).

† These are detector misses (≈ the 3–4% baseline); prompt recovery was not simulated for this
scenario.
At d = 8 cm they jump to 17%, and at 12 cm to 46%. That jump is exactly what the drift
alarm (step 6) keys on.

**What the numbers say:**

1. **v1's rule fails even with zero revisit drift.**
   - Bottles are packed about 9 cm apart, so any gate loose enough to absorb measurement noise
     also merges neighbours.
   - Any gate tight enough to keep neighbours apart lets noise through: 3.9% double at d = 0,
     and 14.7% with "high" noise.
2. **Correcting drift by "snapping" the view onto counted items is a trap.** In rows of
   identical bottles, shifting by one bottle always explains a new bottle as an old one. S2wide
   silently **under-counts 15%** on uniform rows, whatever the drift. Drift must be fixed by
   tracking and anchors; matching can only refine it locally, by less than half an item.
3. **Counted zones make double counts depend on zone *boundaries*, not on every item.** That is
   why S4/S5 degrade slowly. The price is that detector misses inside a zone are never
   auto-added, so the app must *suggest* them (prompts) instead of silently losing them.
4. **Relocalising onto the wrong, identical rack defeats every pose-based rule.** Each loses
   about half of that rack, and does so silently. Only a marker with an identity fixes it (S3,
   S6). Tags alone don't fix measurement noise, though: S3, which is S2 + tags, still
   double-counts 8.8% under high noise. Zones + tags (S6) is robust to both.

## What real drift looks like

| Source | Setup | Error on returning to a place |
|---|---|---|
| [MobileEgo 2026](https://arxiv.org/abs/2605.05945) | LiDAR iPhone Pro, ARKit | ≤ 1.5 cm at printed-marker revisits |
| [Scargill et al. 2021](https://arxiv.org/abs/2109.14757) | iPhone 11 (no LiDAR), ARKit 4, walk about 7 m away and back | 25.1 cm mean (43 cm in a larger study; 67% of cases > 25 cm) |
| [Feigl et al. 2020](https://www.scitepress.org/Papers/2020/89899/89899.pdf) | iPhone X, motion-capture ground truth | 2.5 cm standing, 8.1 cm walking |
| [Díaz-Vilariño 2022](https://isprs-archives.copernicus.org/articles/XLIII-B4-2022/303/2022/) | iPad Pro LiDAR scan across two rooms without loop closure | wall faces about 40 cm apart |

- **With LiDAR, good light and loop closure,** the S5 design has margin: it is safe up to about
  5 cm.
- **Without LiDAR, or across rooms, it doesn't.** That is why the design has:
  - one map per room;
  - anchors per commit;
  - counting paused while relocalising;
  - the drift alarm;
  - rack tags as a fallback.
- **Phase 0 (P0-5) measures our own numbers** in real storerooms, with tags as ground truth.

## Starting parameters (tune in Phase 0)

| Parameter | Start | Tuned by |
|---|---|---|
| Hold to commit | 0.8 s, angular speed < 10°/s | pilot feel + P0-8 |
| Inner frame (edge band excluded) | band ≈ half the largest object (sim: 18 cm on a 0.9 m-wide view, about 20% per side); zone = inner frame projected at item depth | P0-8 |
| Match gate (along / up / depth) | 4 / 8 / 10 cm; bottles ≈ 9 cm pitch, cans ≈ 7 cm | P0-4, P0-8 |
| Local drift search | ±4.5 cm, needs ≥ 3 and ≥ 25% of detections as support | P0-8 |
| Drift alarm | > 30% of detections over counted zones unmatched | P0-5, P0-8 |
| Stable candidate | ≥ 3 hits in the last 0.5 s | P0-3 |

## Limits of the simulation

- **It models positions, not pixels.** Detector errors are random misses: 3% of items per view.
  Real misses cluster (glare, a whole dark shelf).
- **False positives are not modelled.** Reflections are a real risk (Starbucks), handled by 3D
  plausibility and labelled negatives (ADR 006), and tested in the P0-8 room.
- **Drift is one constant offset per revisit plus a slow random walk.** Real drift can rotate,
  which at shelf scale looks like a translation that varies across the view.
- **It says which design is *robust*.** It does not predict our real error rates. Gates G5 and
  G7 do that on hardware.
