"""Simulation-parity fixtures for StockMaskCounting's CommitEngine.

Replays strategy S5 of research/dedup_sim/sim.py (ADR 003) on seeded storerooms and writes, per
commit, what the Swift engine is given (a camera and the detections) and what the simulation
decided (its drift offset, and for every detection: matched to which counted item, counted as new,
shown as a possible miss, or left for the next view). SimulationParityTests replays each file
through CommitEngine and asserts the same outcome for every detection.

    research/walkthrough/venv/bin/python <this file>        # rewrites sim-*.json next to it

How the replay stays the simulation:
- It calls sim.py's own functions (make_world, rack_views, detect, commit_s5) in run_once's order,
  so the random streams are identical. It first replays every scenario as is and checks the result
  against sim.run_once.
- Hooks on sim.refine_and_match and sim.linear_sum_assignment record the drift offset and which
  counted item each detection was matched to. The decisions themselves are sim.py's.
- The Swift engine takes Float positions (the contract's SIMD3<Float>), so the fixture replay feeds
  the simulation the same float32 values: detections, and a camera position from which the view's
  drift is re-derived. Both sides then compute in float64/Double on identical inputs.

The camera is a pinhole 10,000 km from the rack, looking along -z, so its inner frame projects to the
simulation's zone rectangle at any item depth (the simulation's zones are flat rectangles). The
image is 900 x 1400, the simulation's 0.9 x 1.4 m view, so its 18 cm zone band is an inner-frame
band of 0.2 of the short side. Boxes have zero size and sit at the projected detection: the
simulation drops objects cut by the view edge before detection, and the fixture carries only the
detections it kept.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = next(p for p in HERE.parents if (p / "research" / "dedup_sim" / "sim.py").exists())
sys.path.insert(0, str(ROOT / "research" / "dedup_sim"))
import sim  # noqa: E402

DISTANCE = 1.0e7  # camera to rack plane (m): far enough that the frustum is a prism to ~1e-9 m
RACKS = 2  # sim.run_once's default is 4; two keep the files small and still have a revisit pass
SEEDS = (1000, 1001)
SCENARIOS = (
    [("mixed", d, seed, False) for d in (0, 3, 5) for seed in SEEDS]
    + [("uniform", d, seed, False) for d in (0, 3, 5) for seed in SEEDS]
    + [("identical", 0, seed, True) for seed in SEEDS]  # count rack 1, relocalise rack 2 onto it
    + [("mixed", 8, 1000, False)]  # beyond ADR 003's safe range: double counts and alarms occur
)
NEW, MATCHED, MISS, LEFT = "new", "matched", "miss", "left"


def f32(a) -> np.ndarray:
    return np.asarray(a, dtype=np.float32).astype(np.float64)


def num(x: float) -> float:
    """A float32 value as the shortest decimal that reads back as the same float32."""
    return float(str(np.float32(x)))


class Hooks:
    """Spies on sim.py's matching so the fixture can say which counted item a detection matched."""

    def __init__(self):
        self.refine, self.lsa = [], []
        self._refine, self._lsa = sim.refine_and_match, sim.linear_sum_assignment

    def __enter__(self):
        def refine(*a, **k):
            out = self._refine(*a, **k)
            self.refine.append(out)
            return out

        def lsa(cost):
            r, k = self._lsa(cost)
            self.lsa.append((cost.copy(), r, k))
            return r, k

        sim.refine_and_match, sim.linear_sum_assignment = refine, lsa
        return self

    def __exit__(self, *exc):
        sim.refine_and_match, sim.linear_sum_assignment = self._refine, self._lsa


def commit(cnt: sim.Counted, world: sim.World, view, drift, rng, quantise: bool, hooks: Hooks) -> dict:
    """One S5 commit, exactly as sim.commit does it, with every decision recorded."""
    ids, est, cls, sku = sim.detect(world, view, drift, rng)
    conf = world.sku[ids]
    x1, y1, x2, y2 = view
    centre = np.array([(x1 + x2) / 2, (y1 + y2) / 2, DISTANCE])
    cam = f32(centre + drift) if quantise else centre + drift
    if quantise:  # what the Swift engine receives: float32 positions and camera
        est, drift = f32(est), cam - centre
    before_cls, before_n, regions = cnt.cls.copy(), len(cnt.truth), list(cnt.regions)
    hooks.refine.clear(), hooks.lsa.clear()
    sim.commit_s5(cnt, ids, est, cls, sku, conf, view, drift)
    (shifted, matched, offset), = hooks.refine
    pair = -np.ones(len(ids), dtype=int)  # counted item each detection was matched to
    for c in np.unique(cls):
        sel, m = np.nonzero(cls == c)[0], np.nonzero(before_cls == c)[0]
        if not len(m):
            continue
        cost, r, k = hooks.lsa.pop(0)
        ok = cost[r, k] < 1e3  # the simulation's gate: dist <= GATE, else cost 1e3
        pair[sel[r[ok]]] = m[k[ok]]
    assert not hooks.lsa and np.array_equal(pair >= 0, matched)
    done = np.zeros(len(ids), dtype=bool)
    for r in regions:
        done |= sim._inside(shifted, r)
    new = ~matched & ~done & sim._inside(shifted, cnt.regions[-1])
    assert new.sum() == len(cnt.truth) - before_n
    status = np.where(matched, MATCHED, np.where(done, MISS, np.where(new, NEW, LEFT)))
    ref = np.where(matched, pair, -1)
    ref[new] = before_n + np.arange(new.sum())
    # How close any tested point came to a zone edge: the Swift side recomputes zones from the
    # camera, so a margin far above float32 rounding means no decision can flip.
    margin = np.inf
    for r in regions + [cnt.regions[-1]]:
        if len(shifted):
            margin = min(margin, np.abs(shifted[:, [0, 0, 1, 1]] - np.array([r[0], r[2], r[1], r[3]])).min())
    u = 0.5 + (est[:, 0] - cam[0]) / (x2 - x1)  # zero-size box at the detection, normalised image
    v = 0.5 - (est[:, 1] - cam[1]) / (y2 - y1)  # coordinates: x right, y down
    return dict(ids=ids, est=est, cls=cls, sku=sku, conf=conf, cam=cam, view=view, offset=offset,
                status=status, ref=ref, u=u, v=v, margin=margin)


def replay(seed: int, d: float, layout: str, n_racks: int, mislocalize: bool, quantise: bool) -> tuple:
    """sim.run_once for strategy S5, step by step: returns its metrics and every commit."""
    rng = np.random.default_rng(seed)
    world = sim.make_world(rng, n_racks, layout)
    cnt = sim.Counted()
    pass1 = [r for r in range(n_racks) if not mislocalize or r % 2 == 0]
    pass2 = [r for r in range(n_racks) if not mislocalize or r % 2 == 1]
    drift, d1, commits = np.zeros(3), {}, []
    with Hooks() as hooks:
        for r in pass1:
            for v in sim.rack_views(world.rack_x0[r]):
                drift = drift + rng.normal(0, sim.WALK)
                d1[(r, v)] = drift.copy()
                commits.append(dict(commit(cnt, world, v, drift, rng, quantise, hooks), pass_=1, rack=r, reset=False))
        ang = rng.uniform(0, 2 * np.pi)
        delta = np.array([np.cos(ang), 0.0, np.sin(ang)]) * d
        delta[1] = rng.normal(0, 0.2 * d + 1e-9)
        if mislocalize:
            delta = np.array([sim.RACK_WIDTH + sim.RACK_GAP, 0.0, 0.0])
        cnt.prior = np.zeros(3)  # the app does not know how far it has drifted
        walk, reset = np.zeros(3), True
        for r in pass2:
            for v in sim.rack_views(world.rack_x0[r]):
                walk = walk + rng.normal(0, sim.WALK)
                drift_now = d1.get((r, v), drift) - delta + walk
                commits.append(dict(commit(cnt, world, v, drift_now, rng, quantise, hooks), pass_=2, rack=r, reset=reset))
                reset = False
    n = len(world.pos)
    counts = np.bincount(cnt.truth, minlength=n)
    prompted = np.array(sorted(cnt.prompted), dtype=int)
    useful = int((counts[prompted] == 0).sum()) if len(prompted) else 0
    metrics = dict(true=n, counted=len(cnt.truth), double=int(np.clip(counts - 1, 0, None).sum()),
                   missed=int((counts == 0).sum()), prompts=len(prompted), prompts_useful=useful)
    return metrics, commits


def main():
    sha = hashlib.sha256((ROOT / "research" / "dedup_sim" / "sim.py").read_bytes()).hexdigest()
    for old in HERE.glob("sim-*.json"):
        old.unlink()
    total = dict(commits=0, detections=0)
    for layout, d_cm, seed, mis in SCENARIOS:
        d = d_cm / 100
        reference = sim.run_once(seed, "S5", d, layout, n_racks=RACKS, mislocalize=mis)
        plain, plain_commits = replay(seed, d, layout, RACKS, mis, quantise=False)
        assert plain == reference, (layout, d_cm, seed, plain, reference)  # the replay is run_once
        metrics, commits = replay(seed, d, layout, RACKS, mis, quantise=True)
        flips = sum(int((a["status"] != b["status"]).sum() + (a["ref"] != b["ref"]).sum())
                    for a, b in zip(commits, plain_commits))
        margin = min(c["margin"] for c in commits)
        name = f"sim-{layout}-d{d_cm}-seed{seed}"
        out = dict(
            name=name, generator="Tests/StockMaskCountingTests/Fixtures/make_fixtures.py",
            simulation="research/dedup_sim/sim.py", simulation_sha256=sha, strategy="S5",
            layout=layout, revisit_drift_cm=d_cm, seed=seed, racks=RACKS, mislocalize=mis,
            noise=sim.NOISE_LEVEL, classes=sim.CLASS_NAMES,
            camera=dict(distance=DISTANCE, image=[900, 1400],
                        intrinsics=[DISTANCE / sim.VIEW_W, DISTANCE / sim.VIEW_H, 0.5, 0.5],
                        band=sim.REGION_SHRINK / min(sim.VIEW_W, sim.VIEW_H)),
            parameters=dict(gate=sim.GATE, metric=sim.METRIC.tolist(), search=0.045, grid=0.01),
            expected=metrics, run_once=reference,
            float32_changed_decisions=flips, closest_zone_edge_m=margin,
            detection_fields=["class", "suggested_sku", "confirmed_sku", "truth", "x", "y", "z", "u", "v",
                              "status", "ref"],
            commits=[dict(
                pass_=c["pass_"], rack=c["rack"], reset_drift=c["reset"],
                view=[round(x, 6) for x in c["view"]], camera=[num(x) for x in c["cam"]],
                offset=[float(x) for x in c["offset"]],
                detections=[[int(c["cls"][i]), int(c["sku"][i]), int(c["conf"][i]), int(c["ids"][i]),
                             num(c["est"][i, 0]), num(c["est"][i, 1]), num(c["est"][i, 2]),
                             num(c["u"][i]), num(c["v"][i]), str(c["status"][i]), int(c["ref"][i])]
                            for i in range(len(c["ids"]))])
                for c in commits])
        text = json.dumps(out, separators=(",", ":"))
        (HERE / f"{name}.json").write_text(text + "\n")
        total["commits"] += len(commits)
        total["detections"] += sum(len(c["ids"]) for c in commits)
        print(f"{name}: {metrics}  float32 changed {flips} decisions, closest zone edge {margin:.2e} m, "
              f"{len(text) / 1024:.0f} KB")
    print(f"{len(SCENARIOS)} scenarios, {total['commits']} commits, {total['detections']} detections")


if __name__ == "__main__":
    main()
