"""Monte-Carlo comparison of anti-double-count strategies for StockMask.

Question: once every counted item has a 3D position from ARKit + LiDAR, how should a new
detection be judged "already counted" when the user pans back or returns later, given that
the tracked pose drifts?

The simulation builds storeroom racks, commits overlapping camera views the way the app would
(hold-to-count), then revisits every rack after the pose has drifted by `d` and reports:

  double  items counted more than once, % of true items
  missed  items never counted, % of true items

Strategies
  S1       naive: suppress a detection if any counted item of the same class lies within the
           gate (what "overlap above threshold" in the draft PRD implies).
  S2       1:1 matching (Hungarian, prefers same suggested product) after a local drift
           refinement: drift is common to every item in a view, so vote over detection->counted
           offsets within +/-4.5 cm (half a bottle) of the last estimate.
  S2wide   S2 with a +/-15 cm search, i.e. trying to "snap" large drift away.
  S3       S2 after re-anchoring on a printed marker fixed to each rack (residual ~1 cm, unique ID).
  S4       counted zones: a commit marks the inner part of the view as done; detections inside a
           done zone are never auto-added. Detections there with no counted item nearby are shown
           as "possible miss" suggestions (reported as prompts).
  S5       recommended hybrid = S4 zones + S2 local drift refinement and 1:1 matching: inside a
           zone, unexplained detections become prompts; elsewhere only unmatched detections inside
           the current view's zone are added.
  S6       S5 + printed rack tags (re-anchoring and rack identity), i.e. the full recommendation.

Gates use an anisotropic metric: tight along the shelf, looser vertically and in depth,
because LiDAR depth on round glass is noisier than image position and neighbours sit side by
side. Everything is deterministic given the seed.

    python sim.py --seeds 20     # ~2-3 minutes on a laptop, writes RESULTS.md
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass

import numpy as np
from scipy.optimize import linear_sum_assignment
from scipy.spatial import cKDTree

# Physical sizes in metres. Spacing = centre-to-centre distance when packed in a row.
CLASSES = {
    "bottle": dict(width=0.080, spacing=0.090, height=0.30, skus=30),
    "can": dict(width=0.066, spacing=0.070, height=0.12, skus=8),
    "case": dict(width=0.350, spacing=0.360, height=0.30, skus=8),
}
CLASS_NAMES = list(CLASSES)
SHELF_HEIGHTS = (0.25, 0.65, 1.05, 1.45, 1.85)
RACK_WIDTH, RACK_GAP = 1.8, 0.5
VIEW_W, VIEW_H = 0.9, 1.4  # what a portrait phone sees of a rack from ~1.2 m
VIEW_X0, VIEW_STEP_X, VIEW_BANDS_Y = -0.15, 0.45, (0.0, 0.85)  # 50% horizontal overlap
REGION_SHRINK = 0.18  # S4: the outer band of a view, where objects are cut, is left to the neighbour
METRIC = np.array([1.0, 0.5, 0.4])  # x (along shelf) : y (up) : z (depth) weighting for gates
GATE = 0.040  # metres in the weighted metric: 4 cm along the shelf, 8 cm up, 10 cm in depth
SKU_ACCURACY = 0.95  # appearance-based SKU suggestion accuracy assumed for S2
DETECT_RECALL = 0.97  # per committed view, for items fully inside the frame
# Items cut by the frame edge are ignored at commit (their box centre is biased); the next view
# counts them. Position noise per observation (x along shelf, y up, z depth), metres:
NOISE = {"low": (0.006, 0.006, 0.015), "high": (0.010, 0.010, 0.025)}
NOISE_LEVEL = "low"
WALK = (0.003, 0.001, 0.003)  # pose random walk per committed view (x, y, z)


@dataclass
class World:
    pos: np.ndarray  # (N, 3) true positions
    cls: np.ndarray  # (N,) class index
    sku: np.ndarray  # (N,) product id (unique across classes)
    rack_x0: list
    suggested: np.ndarray = None  # (N,) SKU the appearance model suggests for that item (wrong ~5%)


def make_world(rng: np.random.Generator, n_racks: int, layout: str) -> World:
    pos, cls, sku, x0s, template = [], [], [], [], None
    sku_base = {c: 1000 * i for i, c in enumerate(CLASS_NAMES)}
    for r in range(n_racks):
        x0 = r * (RACK_WIDTH + RACK_GAP)
        x0s.append(x0)
        if layout == "identical" and template is not None:
            items = template  # an exact copy of rack 0: same products in the same places
        else:
            items = []
            for y in SHELF_HEIGHTS:
                x = 0.03
                while x < RACK_WIDTH:
                    if layout == "uniform":  # one endless row of the same bottle on every shelf
                        c, n, s = "bottle", 100, sku_base["bottle"]
                    else:
                        c = str(rng.choice(["bottle", "bottle", "bottle", "can", "case"]))
                        n = int(rng.integers(1, 5) if c == "case" else rng.integers(2, 13))
                        s = sku_base[c] + int(rng.integers(0, CLASSES[c]["skus"]))
                    spec = CLASSES[c]
                    for k in range(n):
                        cx = x + spec["width"] / 2 + k * spec["spacing"]
                        if cx + spec["width"] / 2 > RACK_WIDTH:
                            break
                        items.append((cx + rng.normal(0, 0.004), y + spec["height"] / 2,
                                      rng.normal(0, 0.005), CLASS_NAMES.index(c), s))
                    x += n * spec["spacing"] + rng.uniform(0.0, 0.10)
            if template is None:
                template = items
        for cx, cy, cz, c, s in items:
            pos.append((x0 + cx, cy, cz))
            cls.append(c)
            sku.append(s)
    world = World(np.array(pos), np.array(cls), np.array(sku), x0s)
    world.suggested = world.sku.copy()
    for i in np.nonzero(rng.random(len(world.sku)) > SKU_ACCURACY)[0]:
        n = CLASSES[CLASS_NAMES[world.cls[i]]]["skus"]
        base = 1000 * world.cls[i]
        world.suggested[i] = base + (world.sku[i] - base + 1 + int(rng.integers(0, n - 1))) % n
    return world


def rack_views(x0: float) -> list:
    """Snake order over a rack: bottom band left->right, top band right->left."""
    last = RACK_WIDTH - VIEW_W - VIEW_X0
    xs = list(np.arange(VIEW_X0, last + 1e-6, VIEW_STEP_X))
    if xs[-1] < last - 1e-6:
        xs.append(last)
    views = []
    for band, y0 in enumerate(VIEW_BANDS_Y):
        order = xs if band % 2 == 0 else xs[::-1]
        views += [(x0 + x, y0, x0 + x + VIEW_W, y0 + VIEW_H) for x in order]
    return views


def detect(world: World, view, drift, rng):
    """Detections of one committed view: true ids, estimated positions, class, suggested SKU."""
    x1, y1, x2, y2 = view
    p = world.pos
    ids = np.nonzero((p[:, 0] >= x1) & (p[:, 0] <= x2) & (p[:, 1] >= y1) & (p[:, 1] <= y2))[0]
    half_w = np.array([CLASSES[CLASS_NAMES[c]]["width"] / 2 for c in world.cls[ids]])
    half_h = np.array([CLASSES[CLASS_NAMES[c]]["height"] / 2 for c in world.cls[ids]])
    full = (np.minimum(p[ids, 0] - x1, x2 - p[ids, 0]) >= half_w) & \
           (np.minimum(p[ids, 1] - y1, y2 - p[ids, 1]) >= half_h)
    ids = ids[full & (rng.random(len(ids)) < DETECT_RECALL)]
    est = p[ids] + drift + rng.normal(0, 1, (len(ids), 3)) * np.array(NOISE[NOISE_LEVEL])
    return ids, est, world.cls[ids], world.suggested[ids]


class Counted:
    """Counted items, stored in the session frame the app believed in when it counted them."""

    def __init__(self):
        self.pos = np.zeros((0, 3))
        self.cls = np.zeros(0, dtype=int)
        self.sku = np.zeros(0, dtype=int)
        self.truth = np.zeros(0, dtype=int)  # scoring only: which real item each entry is
        self.regions = []
        self.prior = np.zeros(3)
        self.prompted = set()  # S4: true ids shown as "detected here but not counted - add?"

    def add(self, est, cls, sku, ids, confirmed_sku=None):
        self.pos = np.vstack([self.pos, est])
        self.cls = np.concatenate([self.cls, cls])
        # At commit the user confirms each group's product, so stored SKUs are the confirmed ones.
        self.sku = np.concatenate([self.sku, sku if confirmed_sku is None else confirmed_sku])
        self.truth = np.concatenate([self.truth, ids])


def commit_s1(cnt: Counted, ids, est, cls, sku, conf):
    new = np.ones(len(ids), dtype=bool)
    for c in np.unique(cls):
        m = cnt.cls == c
        if m.any():
            d, _ = cKDTree(cnt.pos[m] * METRIC).query(est[cls == c] * METRIC, distance_upper_bound=GATE)
            new[np.nonzero(cls == c)[0]] = ~np.isfinite(d)
    cnt.add(est[new], cls[new], sku[new], ids[new], conf[new])


def _support(cp, ccls, csku, est, cls, sku, cands):
    """Score each candidate offset: detections that land on a counted item of the same class,
    weighted 1.0 when the suggested product also agrees and 0.5 when it does not."""
    score = np.zeros(len(cands))
    for c in np.unique(cls):
        b, bk = cp[ccls == c], csku[ccls == c]
        a, ak = est[cls == c], sku[cls == c]
        if len(a) and len(b):
            pts = ((a[None] + cands[:, None]) * METRIC).reshape(-1, 3)
            d, j = cKDTree(b * METRIC).query(pts, distance_upper_bound=GATE)
            hit = np.isfinite(d)
            agree = np.zeros(len(pts), dtype=bool)
            agree[hit] = bk[j[hit]] == np.tile(ak, len(cands))[hit]
            score += np.where(hit, np.where(agree, 1.0, 0.5), 0.0).reshape(len(cands), len(a)).sum(1)
    return score


def refine_and_match(cnt: Counted, est, cls, sku, register=True, search=0.045):
    """Estimate the view's drift (local search only) and 1:1-match detections to counted items.
    Returns the drift-corrected positions and a mask of detections matched to a counted item."""
    offset = cnt.prior.copy() if register else np.zeros(3)
    if register and len(cnt.pos) >= 3 and len(est) >= 3:
        lo, hi = est.min(0) + offset - search, est.max(0) + offset + search
        near = np.all((cnt.pos >= lo) & (cnt.pos <= hi), axis=1)
        if near.sum() >= 3:
            cp, cc, ck = cnt.pos[near], cnt.cls[near], cnt.sku[near]
            diffs = [(cp[cc == c][None] - est[cls == c][:, None]).reshape(-1, 3) for c in np.unique(cls)]
            cands = np.vstack(diffs + [offset[None]])
            cands = cands[np.linalg.norm((cands - offset)[:, [0, 1]], axis=1) <= search]
            cands = np.unique(np.round(cands / 0.01) * 0.01, axis=0)
            support = _support(cp, cc, ck, est, cls, sku, cands)
            best = support.max()
            if best >= max(3, 0.25 * len(est)):
                tied = cands[support >= best - 1.0]  # near-ties: keep the one closest to the last estimate
                offset = tied[np.argmin(np.linalg.norm(tied - cnt.prior, axis=1))]
                cnt.prior = offset
    shifted = est + offset
    matched = np.zeros(len(est), dtype=bool)
    for c in np.unique(cls):
        sel, m = np.nonzero(cls == c)[0], cnt.cls == c
        if not m.any():
            continue
        dist = np.linalg.norm((shifted[sel][:, None] - cnt.pos[m][None]) * METRIC, axis=2)
        cost = dist + 0.5 * GATE * (sku[sel][:, None] != cnt.sku[m][None])  # prefer same product
        cost = np.where(dist <= GATE, cost, 1e3)
        r, k = linear_sum_assignment(cost)
        matched[sel[r[dist[r, k] <= GATE]]] = True
    return shifted, matched, offset


def commit_s2(cnt: Counted, ids, est, cls, sku, conf, register=True, search=0.045):
    shifted, matched, _ = refine_and_match(cnt, est, cls, sku, register, search)
    new = ~matched
    cnt.add(shifted[new], cls[new], sku[new], ids[new], conf[new])


def _zone(view, drift, offset):
    x1, y1, x2, y2 = view
    return (x1 + REGION_SHRINK + drift[0] + offset[0], y1 + REGION_SHRINK + drift[1] + offset[1],
            x2 - REGION_SHRINK + drift[0] + offset[0], y2 - REGION_SHRINK + drift[1] + offset[1])


def _inside(p, r):
    return (p[:, 0] >= r[0]) & (p[:, 0] <= r[2]) & (p[:, 1] >= r[1]) & (p[:, 1] <= r[3])


def commit_s5(cnt: Counted, ids, est, cls, sku, conf, view, drift):
    """Recommended hybrid: counted zones + local drift refinement + 1:1 matching + prompts."""
    shifted, matched, offset = refine_and_match(cnt, est, cls, sku)
    reg = _zone(view, drift, offset)  # this view's zone, in the counted map's frame
    done = np.zeros(len(ids), dtype=bool)
    for r in cnt.regions:
        done |= _inside(shifted, r)
    prompt = ~matched & done  # inside a counted zone but unexplained: suggest, never auto-add
    cnt.prompted.update(ids[prompt].tolist())
    new = ~matched & ~done & _inside(shifted, reg)
    cnt.add(shifted[new], cls[new], sku[new], ids[new], conf[new])
    cnt.regions.append(reg)


def commit_s4(cnt: Counted, ids, est, cls, sku, conf, view, drift, margin=0.0):
    # The app knows the view footprint only in its own (drifted) frame.
    x1, y1, x2, y2 = view
    reg = (x1 + REGION_SHRINK + drift[0], y1 + REGION_SHRINK + drift[1],
           x2 - REGION_SHRINK + drift[0], y2 - REGION_SHRINK + drift[1])

    def inside(r, m=0.0):
        return (est[:, 0] >= r[0] - m) & (est[:, 0] <= r[2] + m) & (est[:, 1] >= r[1] - m) & (est[:, 1] <= r[3] + m)

    done = np.zeros(len(ids), dtype=bool)
    for r in cnt.regions:
        done |= inside(r, margin)
    new = inside(reg) & ~done
    # Inside a done zone nothing is auto-added; a detection with no counted item nearby is only
    # suggested to the user (yellow "possible miss").
    for c in np.unique(cls):
        sel = np.nonzero(done & (cls == c))[0]
        m = cnt.cls == c
        if len(sel) and m.any():
            d, _ = cKDTree(cnt.pos[m] * METRIC).query(est[sel] * METRIC, distance_upper_bound=GATE)
            cnt.prompted.update(ids[sel[~np.isfinite(d)]].tolist())
    cnt.add(est[new], cls[new], sku[new], ids[new], conf[new])
    cnt.regions.append(reg)


def commit(strategy, cnt, world, ids, est, cls, sku, view, drift):
    conf = world.sku[ids]  # what the user confirms for these items at commit time
    if strategy == "S1":
        commit_s1(cnt, ids, est, cls, sku, conf)
    elif strategy in ("S2", "S3"):
        commit_s2(cnt, ids, est, cls, sku, conf)
    elif strategy == "S2wide":
        commit_s2(cnt, ids, est, cls, sku, conf, search=0.15)
    elif strategy == "S4":
        commit_s4(cnt, ids, est, cls, sku, conf, view, drift)
    elif strategy in ("S5", "S6"):
        commit_s5(cnt, ids, est, cls, sku, conf, view, drift)
    else:
        raise ValueError(strategy)


def run_once(seed: int, strategy: str, d_revisit: float, layout: str, n_racks: int = 4,
             mislocalize: bool = False) -> dict:
    rng = np.random.default_rng(seed)
    world = make_world(rng, n_racks, layout)
    cnt = Counted()
    markers = strategy in ("S3", "S6")
    # Mislocalisation scenario: count the even racks, walk to the odd (identical, uncounted) racks,
    # and tracking relocalises onto the rack next door.
    pass1 = [r for r in range(n_racks) if not mislocalize or r % 2 == 0]
    pass2 = [r for r in range(n_racks) if not mislocalize or r % 2 == 1]
    drift, d1 = np.zeros(3), {}
    for r in pass1:
        if markers:
            drift = rng.normal(0, 0.01, 3)  # each rack's marker re-anchors the frame
        for v in rack_views(world.rack_x0[r]):
            drift = drift + rng.normal(0, WALK)
            d1[(r, v)] = drift.copy()
            commit(strategy, cnt, world, *detect(world, v, drift, rng), v, drift)
    ang = rng.uniform(0, 2 * np.pi)
    delta = np.array([np.cos(ang), 0.0, np.sin(ang)]) * d_revisit
    delta[1] = rng.normal(0, 0.2 * d_revisit + 1e-9)
    if mislocalize:
        delta = np.array([RACK_WIDTH + RACK_GAP, 0.0, 0.0])
    cnt.prior = np.zeros(3)  # the app does not know how far it has drifted
    walk = np.zeros(3)
    for r in pass2:
        if markers:  # marker seen again: only its detection residual remains, and the marker has an ID
            base, walk = world_marker_frame(rng, d1, r, drift), np.zeros(3)
        else:
            base = None
        for v in rack_views(world.rack_x0[r]):
            walk = walk + rng.normal(0, WALK)
            if markers:
                drift_now = base + walk
            else:
                drift_now = d1.get((r, v), drift) - delta + walk
            commit(strategy, cnt, world, *detect(world, v, drift_now, rng), v, drift_now)
    n = len(world.pos)
    counts = np.bincount(cnt.truth, minlength=n)
    prompted = np.array(sorted(cnt.prompted), dtype=int)
    useful = int((counts[prompted] == 0).sum()) if len(prompted) else 0
    return dict(true=n, counted=len(cnt.truth), double=int(np.clip(counts - 1, 0, None).sum()),
                missed=int((counts == 0).sum()), prompts=len(prompted), prompts_useful=useful)


def world_marker_frame(rng, d1, r, drift):
    """Frame offset after re-detecting rack r's marker: first-pass frame of that rack + ~1 cm error."""
    first = [v for (rr, v) in d1 if rr == r]
    ref = d1[(r, first[0])] if first else drift
    return ref + rng.normal(0, 0.01, 3)


def cell(seeds, strategy, d, layout, full=False, **kw):
    rows = [run_once(1000 + k, strategy, d, layout, **kw) for k in range(seeds)]
    t = np.array([r["true"] for r in rows], float)
    pct = lambda key: 100 * np.array([r[key] for r in rows]) / t
    if full:
        return {k: pct(k).mean() for k in ("double", "missed", "prompts", "prompts_useful")}
    return pct("double").mean(), pct("missed").mean()


def main():
    global NOISE_LEVEL
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--out", default="RESULTS.md")
    args = ap.parse_args()
    strategies = ["S1", "S2", "S2wide", "S3", "S4", "S5", "S6"]
    drifts_cm = [0, 1, 2, 3, 5, 8, 12, 20]
    out = ["# Dedup simulation results", "",
           f"Generated by `python sim.py --seeds {args.seeds}`. Each cell averages {args.seeds} random storerooms "
           "(4 racks x 5 shelves x 1.8 m, ~300 visible items). One full counting pass, then one full revisit pass.",
           "", "`d` = pose error on the revisit that tracking did not correct (random horizontal direction). "
           "Cells are `double% / missed%` of true items. S3 and S6 (rack tags) do not depend on `d`.", ""]
    for noise in ("low", "high"):
        NOISE_LEVEL = noise
        sx, sy, sz = (100 * v for v in NOISE[noise])
        out += [f"## Measurement noise: {noise} (per observation {sx:.1f} / {sy:.1f} / {sz:.1f} cm along shelf / "
                "vertical / depth)", ""]
        for layout, title in [("mixed", "Mixed shelves: groups of 2-12 identical items, several products per shelf"),
                              ("uniform", "Worst case: every shelf is one long row of the same bottle")]:
            out += [f"### {title}", "", "| strategy | " + " | ".join(f"d={d} cm" for d in drifts_cm) + " |",
                    "|" + "---|" * (len(drifts_cm) + 1)]
            for s in strategies:
                cells = [cell(args.seeds, s, d / 100, layout) for d in drifts_cm]
                out.append(f"| {s} | " + " | ".join(f"{a:.1f} / {b:.1f}" for a, b in cells) + " |")
                print(out[-1], flush=True)
            out.append("")
    NOISE_LEVEL = "low"
    out += ["## Zones (S4, S5, S6): what the user has to tap", "",
            "Items the detector missed inside a counted zone are never auto-added; the app shows them as "
            "\"possible miss\" suggestions. `useful` = suggested items that really were uncounted; the rest are "
            "false alarms the user dismisses. Low noise.", "",
            "| strategy | layout | d | double% | missed% | prompts% | useful% | missed% after accepting useful prompts |",
            "|---|---|---|---|---|---|---|---|"]
    for s in ("S4", "S5", "S6"):
        for layout in ("mixed", "uniform"):
            for d in (0, 3, 5, 8, 12):
                m = cell(args.seeds, s, d / 100, layout, full=True)
                out.append(f"| {s} | {layout} | {d} cm | {m['double']:.1f} | {m['missed']:.1f} | {m['prompts']:.1f} | "
                           f"{m['prompts_useful']:.1f} | {m['missed'] - m['prompts_useful']:.1f} |")
    out += ["", "## Identical racks, tracking relocalises onto the wrong rack", "",
            "Count racks 1 and 3, then walk to the identical racks 2 and 4; tracking snaps one rack-pitch off.", "",
            "| strategy | double% | missed% |", "|---|---|---|"]
    for s in strategies:
        a, b = cell(args.seeds, s, 0.0, "identical", mislocalize=True)
        out.append(f"| {s} | {a:.1f} | {b:.1f} |")
        print(out[-1], flush=True)
    open(args.out, "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
