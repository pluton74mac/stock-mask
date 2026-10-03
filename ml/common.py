"""Shared paths, classes and COCO helpers for the ml/ scripts (dataset v0, P0-7, ADR 006).

Everything these scripts write goes under ml/data/, which is git-ignored: frames, pre-labels, labels,
Label Studio's database, datasets and training runs are all venue data, and this repository is public.
"""

from __future__ import annotations

import csv
import importlib
import json
import os
import sys
from pathlib import Path

ML = Path(__file__).resolve().parent
REPO = ML.parent
DATA = ML / "data"
FRAMES = DATA / "frames"
MANIFEST = FRAMES / "manifest.csv"
PRELABELS = DATA / "prelabels" / "owlv2.json"
LABELS = DATA / "labels" / "labels.coco.json"
WALKTHROUGH = REPO / "research" / "walkthrough"
VIDEOS = WALKTHROUGH / "videos"  # git-ignored; the clips live only in the main checkout

# The detector's classes, in the order of ObjectClass in docs/mvp-test-app.md. COCO category id = index + 1.
# carton and bag joined on 3 October 2026 (the owner: the camera counts everything). COCO ids: bottle 1, can 2,
# case 3, bottle_top 4, carton 5, bag 6, the same ids they had while parked.
CLASSES = ("bottle", "can", "case", "bottle_top", "carton", "bag")
PARKED: tuple[str, ...] = ()  # labelled but not trained: none now
ALL_LABELS = CLASSES + PARKED

# Which clip goes where. Walk 1 trains and validates; walk 2 tests, because only walk 2 has reference counts
# per product (research/walkthrough/RESULTS.md section 16). video-2 is left out: it was filmed on the 0.5x
# ultra-wide lens, and ARKit and LiDAR use the 1x camera (RESULTS section 6).
CLIP_ROLES = {"video-1": "trainval", "w2-bay1": "test", "w2-bay2": "test", "w2-bay3": "test"}
EXCLUDED_CLIPS = {"video-2": "0.5x ultra-wide lens; the app uses the 1x lens"}

MANIFEST_FIELDS = ("frame_id", "clip", "t", "frame", "split", "kind", "width", "height", "sharp_rel", "file")


def walkthrough():
    """The replay script research/walkthrough/walkthrough.py, imported as a module (OWLv2, read_video,
    image_motion, replay, clean)."""
    if str(WALKTHROUGH) not in sys.path:
        sys.path.insert(0, str(WALKTHROUGH))
    wt = importlib.import_module("walkthrough")
    # Never let ffmpeg print the clips' container metadata: they carry GPS. replay() only needs the codec name.
    wt.stream_info = lambda path: ""
    return wt


def read_manifest(path: Path = MANIFEST) -> list[dict]:
    if not path.exists():
        raise SystemExit(f"no frame manifest at {path}: run ml/frames.py first")
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["t"], r["frame"] = float(r["t"]), int(r["frame"])
        r["width"], r["height"] = int(r["width"]), int(r["height"])
    return rows


def write_manifest(rows: list[dict], path: Path = MANIFEST) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in MANIFEST_FIELDS})


def categories(names=ALL_LABELS) -> list[dict]:
    """COCO categories with fixed ids: bottle 1, can 2, case 3, bottle_top 4, carton 5, bag 6. Flat (no
    supercategory), so rfdetr keeps every class even when one has no boxes in a split."""
    return [dict(id=ALL_LABELS.index(n) + 1, name=n, supercategory="none") for n in names]


def load_coco(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def save_json(obj, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def boxes_by_image(coco: dict) -> dict:
    """image id -> list of (category name, [x, y, w, h], score or None)."""
    names = {c["id"]: c["name"] for c in coco["categories"]}
    out = {im["id"]: [] for im in coco["images"]}
    for a in coco["annotations"]:
        out.setdefault(a["image_id"], []).append((names[a["category_id"]], a["bbox"], a.get("score")))
    return out


# The draft a reviewer starts from: OWLv2 boxes at the replay's commit thresholds (walkthrough.py: owlv2 0.3,
# owlv2_caps 0.2). Boxes between the pre-labeller's floor (0.2 / 0.15) and these are candidates.
DRAFT_SCORE = {"bottle": 0.3, "can": 0.3, "case": 0.3, "bottle_top": 0.2}


def iou(a, b) -> float:
    """IoU of two [x0, y0, x1, y1] boxes."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def draft(boxes: list, score=DRAFT_SCORE) -> tuple[list, list]:
    """Split pre-label boxes, (class, [x0, y0, x1, y1], score), into (draft, candidates). The draft holds boxes at or
    above the commit thresholds. Where OWLv2 drew both a bottle and a bottle cap on one object (IoU 0.6 or more), a
    tall box (height at least 1.8 widths) stays a bottle and anything squatter stays a top."""
    keep = [b for b in boxes if b[2] >= score.get(b[0], 1.0)]
    rest = [b for b in boxes if b[2] < score.get(b[0], 1.0)]
    drop = set()
    for i, (ci, bi, _) in enumerate(keep):
        for j, (cj, bj, _) in enumerate(keep):
            if ci == "bottle" and cj == "bottle_top" and iou(bi, bj) >= 0.6:
                tall = (bi[3] - bi[1]) >= 1.8 * (bi[2] - bi[0])
                drop.add(j if tall else i)
    return [b for k, b in enumerate(keep) if k not in drop], rest


def pair_tops(bottles: list, tops: list) -> list:
    """(bottle index, top index) for each bottle's own top: the counting rule of docs/mvp-test-app.md, "a top that
    belongs to a bottle counted in the same view is the same unit; a top with no bottle under them counts as a
    bottle". A bottle's own top has its centre across the bottle box and from 5% of the bottle's height above the box
    to 25% below its top edge; the one nearest to where a cap sits (centred, 6% of the height below the top edge)
    wins, one top per bottle. Every other top is a bottle in a row behind. Which top pairs doesn't change the count.
    Boxes are [x0, y0, x1, y1]. Upright bottles only: a bottle lying in a rack has its top at one end."""
    cand = []
    for i, (x0, y0, x1, y1) in enumerate(bottles):
        h, cx, cy = y1 - y0, (x0 + x1) / 2, y0 + 0.06 * (y1 - y0)
        for j, t in enumerate(tops):
            tx, ty = (t[0] + t[2]) / 2, (t[1] + t[3]) / 2
            if x0 <= tx <= x1 and y0 - 0.05 * h <= ty <= y0 + 0.25 * h:
                cand.append((((tx - cx) ** 2 + (ty - cy) ** 2) ** 0.5 / max(1.0, x1 - x0), i, j))
    pairs, used_b, used_t = [], set(), set()
    for _, i, j in sorted(cand):
        if i not in used_b and j not in used_t:
            pairs.append((i, j))
            used_b.add(i)
            used_t.add(j)
    return pairs


def bottle_units(bottles: list, tops: list) -> int:
    """Bottles in view: every bottle box, plus every top with no bottle of its own (a row behind)."""
    return len(bottles) + len(tops) - len(pair_tops(bottles, tops))


def prelabel_boxes(path: Path = PRELABELS) -> dict:
    """frame_id -> list of (class, [x0, y0, x1, y1], score) from the OWLv2 pre-labels."""
    coco = load_coco(path)
    by_image = boxes_by_image(coco)
    return {im["frame_id"]: [(c, [b[0], b[1], b[0] + b[2], b[1] + b[3]], s) for c, b, s in by_image[im["id"]]]
            for im in coco["images"]}
