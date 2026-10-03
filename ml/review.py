"""Box review loop for dataset v0: a labelling agent (or a person) corrects the OWLv2 draft boxes frame by frame.

The loop, per frame (ml/LABELING.md has the label rules and the loop in full):
  1. render  draws the frame with numbered boxes and a pixel grid, as JPEGs in ml/data/review/render/<frame_id>/:
             the overview, then a zoomed crop of each dense or unclear area (--crop). The tick labels are
             full-resolution pixels.
  2. look    at the overview and the crops; work out which bottles stand in front and which caps are theirs.
  3. apply   a JSON edit (keep, delete, relabel, adjust, add, promote); it redraws the overview and the crops that
             show an edited box, and runs the QA checks, so the reviewer can verify its own fixes. Repeat 2-3.
  4. finish  with "status": "done" (or "excluded" with a reason) in the last edit.
Then `export` writes the reviewed frames as COCO for train.py, and `stats` measures time and draft accuracy.

Edit format (one JSON object per apply; every field optional; coordinates are full-resolution pixels,
[x0, y0, x1, y1], origin at the top left):
  {"frame": "w2-bay2_f00447",
   "delete": [3, 7],                                  boxes that are wrong (not an object, a reflection, a duplicate)
   "relabel": {"5": "bottle_top"},                    right box, wrong class
   "adjust": {"12": [610, 230, 655, 292], "14": {"y1": 300}},   move edges (all four, or some)
   "add": [{"cls": "bottle_top", "box": [700, 210, 742, 252]}],  objects with no box
   "promote": ["c4", {"c9": "bottle"}],               take a candidate box (render --candidates), optionally relabelled
   "keep": [1, 2, 4] or "all",                        checked and right as they are
   "status": "in_progress" | "done" | "excluded",     done keeps every box not edited; excluded needs "reason"
   "reason": "a person in view", "note": "anything a later reviewer should know"}

Commands (ml/.venv/bin/python ml/review.py ...):
  render FRAME [--candidates] [--crop x0,y0,x1,y1] [--tiles all|dense|none]
  apply EDITS.json | apply FRAME --edits '{...}'
  qa FRAME          the checks alone
  show FRAME        the box list as text: id, class, box, state, score
  export            reviewed frames -> ml/data/labels/labels.coco.json
  stats [FRAME...]  draft accuracy, minutes and images per frame
  batches --size 25 lists of frames for parallel labelling agents, in ml/data/review/batches/
  sheet             ml/data/review/spotcheck.html: every reviewed frame, for the owner to spot-check
  reset FRAME       start a frame again from the draft (keeps nothing)
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

import common

REVIEW = common.DATA / "review"
WORK = REVIEW / "labels"
RENDER = REVIEW / "render"
BATCHES = REVIEW / "batches"
iou, draft = common.iou, common.draft  # the draft: OWLv2 boxes at the commit thresholds; the rest are candidates
COLOURS = {"bottle": (235, 140, 40), "bottle_top": (0, 150, 255), "can": (60, 200, 60), "case": (200, 70, 200),
           "carton": (60, 110, 190), "bag": (190, 120, 255)}  # BGR
SHORT = {"bottle": "B", "bottle_top": "T", "can": "C", "case": "K", "carton": "R", "bag": "G"}
OVERVIEW_SIDE = 1500  # long side of the overview image
TILE_SIDE = 1100  # long side of a rendered tile
TILE_MAX = 720  # a tile covers at most this many full-resolution pixels per side


def now() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


# ---------------------------------------------------------------------------------------------
# Working state


def manifest_row(frame_id: str) -> dict:
    for r in common.read_manifest():
        if r["frame_id"] == frame_id:
            return r
    raise SystemExit(f"unknown frame {frame_id}")


def reading_order(boxes: list) -> list:
    """Top to bottom in bands of about one top's height, left to right within a band, so numbers are easy to find."""
    if not boxes:
        return boxes
    band = max(40.0, float(np.median([b[1][3] - b[1][1] for b in boxes])) * 0.5)
    return sorted(boxes, key=lambda b: (int(((b[1][1] + b[1][3]) / 2) // band), (b[1][0] + b[1][2]) / 2))


def new_state(frame_id: str, pre: dict | None = None) -> dict:
    r = manifest_row(frame_id)
    pre = common.prelabel_boxes() if pre is None else pre
    if frame_id not in pre:
        raise SystemExit(f"no pre-labels for {frame_id}: run ml/prelabel.py first")
    d, cands = draft(pre[frame_id])
    boxes = [dict(id=k + 1, cls=c, box=[round(v, 1) for v in b], src="owlv2", score=round(s, 3), state="draft")
             for k, (c, b, s) in enumerate(reading_order(d))]
    cand = [dict(id=f"c{k + 1}", cls=c, box=[round(v, 1) for v in b], score=round(s, 3))
            for k, (c, b, s) in enumerate(reading_order(cands))]
    return dict(frame_id=frame_id, file=r["file"], width=r["width"], height=r["height"], split=r["split"],
                kind=r["kind"], clip=r["clip"], t=r["t"], status="todo", reason=None, note="", boxes=boxes,
                candidates=cand, deleted=[], next_id=len(boxes) + 1, draft_count=len(boxes), log=[])


def load(frame_id: str, create=True) -> dict:
    f = WORK / f"{frame_id}.json"
    if f.exists():
        return json.loads(f.read_text())
    if not create:
        raise SystemExit(f"{frame_id} has not been started")
    st = new_state(frame_id)
    st["log"].append(dict(t=now(), event="init", draft=len(st["boxes"]), candidates=len(st["candidates"])))
    save(st)
    return st


def save(st: dict) -> None:
    common.save_json(st, WORK / f"{st['frame_id']}.json")


# ---------------------------------------------------------------------------------------------
# Rendering


def tiles(w: int, h: int) -> list:
    """Overlapping tiles of at most TILE_MAX pixels a side, 10% overlap: (name, x0, y0, x1, y1)."""
    cols, rows = math.ceil(w / TILE_MAX), math.ceil(h / TILE_MAX)
    tw, th = w / cols, h / rows
    out = []
    for r in range(rows):
        for c in range(cols):
            x0, y0 = max(0, round(c * tw - 0.05 * tw)), max(0, round(r * th - 0.05 * th))
            x1, y1 = min(w, round((c + 1) * tw + 0.05 * tw)), min(h, round((r + 1) * th + 0.05 * th))
            out.append((f"tile_r{r + 1}c{c + 1}", x0, y0, x1, y1))
    return out


def draw_view(img: np.ndarray, st: dict, region, side: int, candidates: bool) -> np.ndarray:
    """One view of the frame: region (x0, y0, x1, y1) in full-resolution pixels, scaled so its long side is about
    `side`, with a margin carrying the grid's tick labels (full-resolution pixels)."""
    x0, y0, x1, y1 = region
    s = side / max(x1 - x0, y1 - y0)
    view = cv2.resize(img[y0:y1, x0:x1], None, fx=s, fy=s, interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC)
    vh, vw = view.shape[:2]
    # grid: a line every 100 px (stronger every 500), minor ticks every 20 px in the margins
    grid = view.copy()
    for gx in range(math.ceil(x0 / 100) * 100, x1 + 1, 100):
        cv2.line(grid, (round((gx - x0) * s), 0), (round((gx - x0) * s), vh), (255, 255, 255), 2 if gx % 500 == 0 else 1)
    for gy in range(math.ceil(y0 / 100) * 100, y1 + 1, 100):
        cv2.line(grid, (0, round((gy - y0) * s)), (vw, round((gy - y0) * s)), (255, 255, 255), 2 if gy % 500 == 0 else 1)
    view = cv2.addWeighted(grid, 0.22, view, 0.78, 0)
    lw = 2 if s < 1.2 else 3
    fs = 0.42 if s < 1.2 else 0.55
    if candidates:
        for b in st["candidates"]:
            p = [round((b["box"][0] - x0) * s), round((b["box"][1] - y0) * s), round((b["box"][2] - x0) * s),
                 round((b["box"][3] - y0) * s)]
            if p[2] < 0 or p[3] < 0 or p[0] > vw or p[1] > vh:
                continue
            dashed(view, p, COLOURS[b["cls"]], 1)
            label(view, f"{b['id']}{SHORT[b['cls']]}", p, COLOURS[b["cls"]], fs * 0.9, below=True)
    for b in st["boxes"]:
        p = [round((b["box"][0] - x0) * s), round((b["box"][1] - y0) * s), round((b["box"][2] - x0) * s),
             round((b["box"][3] - y0) * s)]
        if p[2] < 0 or p[3] < 0 or p[0] > vw or p[1] > vh:
            continue
        thick = lw + 1 if b["state"] in ("added", "adjusted", "relabelled", "promoted") else lw
        cv2.rectangle(view, (p[0], p[1]), (p[2], p[3]), COLOURS[b["cls"]], thick)
        label(view, f"{b['id']}{SHORT[b['cls']]}", p, COLOURS[b["cls"]], fs)
    m = 46  # margin with tick labels, all four sides
    out = cv2.copyMakeBorder(view, m, m, m, m, cv2.BORDER_CONSTANT, value=(255, 255, 255))
    for gx in range(math.ceil(x0 / 20) * 20, x1 + 1, 20):
        px = m + round((gx - x0) * s)
        big = gx % 100 == 0
        for yb in (m, m + vh):
            cv2.line(out, (px, yb - (12 if big else 5) if yb == m else yb), (px, yb if yb == m else yb + (12 if big else 5)),
                     (0, 0, 0), 1)
        if big:
            for ty in (m - 16, m + vh + 32):
                cv2.putText(out, str(gx), (px - 14, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 0), 1, cv2.LINE_AA)
    for gy in range(math.ceil(y0 / 20) * 20, y1 + 1, 20):
        py = m + round((gy - y0) * s)
        big = gy % 100 == 0
        cv2.line(out, (m - (12 if big else 5), py), (m, py), (0, 0, 0), 1)
        cv2.line(out, (m + vw, py), (m + vw + (12 if big else 5), py), (0, 0, 0), 1)
        if big:
            cv2.putText(out, str(gy), (2, py + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 0), 1, cv2.LINE_AA)
            cv2.putText(out, str(gy), (m + vw + 6, py + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 0), 1, cv2.LINE_AA)
    return out


def dashed(img, p, colour, width, dash=6):
    x0, y0, x1, y1 = p
    for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        n = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) // dash))
        for k in range(0, n, 2):
            u, v = k / n, min(1, (k + 1) / n)
            cv2.line(img, (int(a[0] + (b[0] - a[0]) * u), int(a[1] + (b[1] - a[1]) * u)),
                     (int(a[0] + (b[0] - a[0]) * v), int(a[1] + (b[1] - a[1]) * v)), colour, width)


def label(img, text, p, colour, fs, below=False):
    (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, fs, 1)
    x = max(0, min(p[0], img.shape[1] - tw - 2))
    y = p[3] + th + 3 if below else p[1] - 3
    y = max(th + 2, min(y, img.shape[0] - 2))
    cv2.rectangle(img, (x, y - th - 2), (x + tw + 2, y + 2), (0, 0, 0), -1)
    cv2.putText(img, text, (x + 1, y), cv2.FONT_HERSHEY_SIMPLEX, fs, colour, 1, cv2.LINE_AA)


def render(st: dict, what="none", candidates=False, crop=None, only=None, overview=True) -> list:
    """Write the overview (unless overview=False), the tiles asked for (`what`: all, dense or none; `only`: tile
    names) and a crop (x0, y0, x1, y1). Every crop is remembered in the state, so `apply` can redraw the crops its
    edits touch. Returns the paths written."""
    img = cv2.imread(str(common.DATA / st["file"]))
    w, h = st["width"], st["height"]
    folder = RENDER / st["frame_id"]
    folder.mkdir(parents=True, exist_ok=True)
    suffix = "_cand" if candidates else ""
    paths = []
    if overview and crop is None:
        p = folder / f"overview{suffix}.jpg"
        cv2.imwrite(str(p), draw_view(img, st, (0, 0, w, h), OVERVIEW_SIDE, candidates), [cv2.IMWRITE_JPEG_QUALITY, 88])
        paths.append(p)
    if crop is not None:
        x0, y0, x1, y1 = (int(round(v)) for v in crop)
        x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
        p = folder / f"crop_{x0}_{y0}_{x1}_{y1}{suffix}.jpg"
        cv2.imwrite(str(p), draw_view(img, st, (x0, y0, x1, y1), TILE_SIDE, candidates), [cv2.IMWRITE_JPEG_QUALITY, 90])
        paths.append(p)
        if [x0, y0, x1, y1] not in st.setdefault("crops", []):
            st["crops"].append([x0, y0, x1, y1])
    for name, x0, y0, x1, y1 in tiles(w, h):
        inside = [b for b in st["boxes"] if x0 <= (b["box"][0] + b["box"][2]) / 2 <= x1
                  and y0 <= (b["box"][1] + b["box"][3]) / 2 <= y1]
        if not (what == "all" or (what == "dense" and len(inside) >= 6) or (only and name in only)):
            continue
        p = folder / f"{name}{suffix}.jpg"
        cv2.imwrite(str(p), draw_view(img, st, (x0, y0, x1, y1), TILE_SIDE, candidates), [cv2.IMWRITE_JPEG_QUALITY, 90])
        paths.append(p)
    st["log"].append(dict(t=now(), event="render", images=len(paths)))
    return paths


def touched_views(st: dict, boxes: list) -> tuple[list, list]:
    """The crops and the tiles already drawn for this frame that an edit of `boxes` shows up in."""
    hit = lambda r: any(not (b[2] < r[0] or b[0] > r[2] or b[3] < r[1] or b[1] > r[3]) for b in boxes)  # noqa: E731
    crops = [c for c in st.get("crops", []) if hit(c)]
    folder = RENDER / st["frame_id"]
    names = [n for n, *r in tiles(st["width"], st["height"]) if (folder / f"{n}.jpg").exists() and hit(r)]
    return crops, names


# ---------------------------------------------------------------------------------------------
# QA


def pair_tops(boxes: list) -> dict:
    """bottle id -> the id of its own top (common.pair_tops: the counting rule of docs/mvp-test-app.md)."""
    bottles = [b for b in boxes if b["cls"] == "bottle"]
    tops = [b for b in boxes if b["cls"] == "bottle_top"]
    return {bottles[i]["id"]: tops[j]["id"] for i, j in common.pair_tops([b["box"] for b in bottles],
                                                                          [t["box"] for t in tops])}


def qa(st: dict) -> dict:
    boxes, w, h = st["boxes"], st["width"], st["height"]
    issues = []
    for i, a in enumerate(boxes):
        x0, y0, x1, y1 = a["box"]
        bw, bh = x1 - x0, y1 - y0
        if bw < 8 or bh < 8:
            issues.append(f"{a['id']}: tiny box ({bw:.0f} x {bh:.0f} px)")
        if bw * bh > 0.5 * w * h:
            issues.append(f"{a['id']}: covers half the frame or more")
        if a["cls"] == "bottle_top" and bh > 2.5 * bw:
            issues.append(f"{a['id']}: a top {bh / bw:.1f} times taller than wide: a neck or a whole bottle?")
        if a["cls"] == "bottle" and bh < 1.2 * bw and min(x0, y0) > 2 and x1 < w - 2 and y1 < h - 2:
            issues.append(f"{a['id']}: a bottle about as wide as tall: a top, a can or part of a bottle?")
        for b in boxes[i + 1:]:
            same = a["cls"] == b["cls"]
            o = iou(a["box"], b["box"])
            if same and o >= (0.3 if a["cls"] == "bottle_top" else 0.5):
                issues.append(f"{a['id']} and {b['id']}: two {a['cls']} boxes on one object? (IoU {o:.2f})")
            elif same:
                small, big = (a, b) if (a["box"][2] - a["box"][0]) * (a["box"][3] - a["box"][1]) < \
                    (b["box"][2] - b["box"][0]) * (b["box"][3] - b["box"][1]) else (b, a)
                sx0, sy0, sx1, sy1 = small["box"]
                ix = max(0.0, min(sx1, big["box"][2]) - max(sx0, big["box"][0]))
                iy = max(0.0, min(sy1, big["box"][3]) - max(sy0, big["box"][1]))
                if ix * iy > 0.8 * (sx1 - sx0) * (sy1 - sy0) and small["cls"] != "bottle_top":
                    issues.append(f"{small['id']} lies inside {big['id']}: part of the same {a['cls']}, or a row box?")
            elif {a["cls"], b["cls"]} == {"bottle", "bottle_top"} and o >= 0.6:
                issues.append(f"{a['id']} and {b['id']}: a bottle box and a top box on the same object")
    pairs = pair_tops(boxes)
    no_top = [b["id"] for b in boxes if b["cls"] == "bottle" and b["id"] not in pairs and b["box"][1] > 2]
    counts = collections.Counter(b["cls"] for b in boxes)
    units = counts["bottle"] + counts["bottle_top"] - len(pairs)
    edge = [b["id"] for b in boxes if b["box"][0] <= 2 or b["box"][1] <= 2 or b["box"][2] >= w - 2 or b["box"][3] >= h - 2]
    return dict(counts={c: counts[c] for c in common.ALL_LABELS if counts[c]}, pairs=pairs, unpaired_bottles=no_top,
                bottle_units=units, cut_by_border=edge, issues=issues)


def print_qa(st: dict) -> None:
    q = qa(st)
    print(f"{st['frame_id']} [{st['status']}]: " + ", ".join(f"{c} {n}" for c, n in q["counts"].items()) +
          f"; bottle units (bottles + tops with no bottle under them) {q['bottle_units']}")
    print("  same unit (bottle: its own top): " + (", ".join(f"{b}:{t}" for b, t in sorted(q["pairs"].items()))
                                                   or "none"))
    if q["unpaired_bottles"]:
        print(f"  bottles with no top box in their top region (cap hidden, cut, or missed?): {q['unpaired_bottles']}")
    if q["cut_by_border"]:
        print(f"  touching the image border: {q['cut_by_border']}")
    for i in q["issues"]:
        print(f"  CHECK {i}")


# ---------------------------------------------------------------------------------------------
# Edits


def apply(st: dict, e: dict) -> list:
    """Apply one edit object; returns the boxes it touched (before and after), to redraw the views showing them.
    Raises SystemExit with a message on a bad edit, leaving the state unchanged."""
    w, h = st["width"], st["height"]
    new = json.loads(json.dumps(st))  # work on a copy: a bad edit changes nothing
    cands = {c["id"]: c for c in new["candidates"]}
    touched = []

    def box_ok(b, what):
        if not (isinstance(b, (list, tuple)) and len(b) == 4):
            raise SystemExit(f"{what}: a box is [x0, y0, x1, y1]")
        x0, y0, x1, y1 = (float(v) for v in b)
        if not (-2 <= x0 < x1 <= w + 2 and -2 <= y0 < y1 <= h + 2):
            raise SystemExit(f"{what}: {b} is not inside the {w} x {h} frame with x0 < x1 and y0 < y1")
        return [round(max(0.0, x0), 1), round(max(0.0, y0), 1), round(min(w, x1), 1), round(min(h, y1), 1)]

    def get(i, what):
        """The box with id i in the working copy."""
        try:
            k = int(i)
        except (TypeError, ValueError):
            raise SystemExit(f"{what}: {i!r} is not a box number") from None
        b = next((x for x in new["boxes"] if x["id"] == k), None)
        if b is None:
            raise SystemExit(f"{what}: no box {i} (deleted already?)")
        return b

    def cls_ok(c, what):
        if c not in common.ALL_LABELS:
            raise SystemExit(f"{what}: unknown class {c}; use {', '.join(common.ALL_LABELS)}")
        return c

    ops = collections.Counter()
    for i in e.get("delete", []):
        b = get(i, "delete")
        new["deleted"].append(dict(b, deleted_at=now()))
        new["boxes"] = [x for x in new["boxes"] if x["id"] != b["id"]]
        touched.append(b["box"])
        ops["delete"] += 1
    for i, c in e.get("relabel", {}).items():
        b = get(i, "relabel")
        b["cls"], b["state"] = cls_ok(c, "relabel"), "relabelled" if b["src"] == "owlv2" else b["state"]
        touched.append(b["box"])
        ops["relabel"] += 1
    for i, v in e.get("adjust", {}).items():
        b = get(i, "adjust")
        if isinstance(v, dict):
            box = list(b["box"])
            for k, val in v.items():
                box[("x0", "y0", "x1", "y1").index(k)] = float(val)
        else:
            box = v
        touched.append(b["box"])
        b["box"] = box_ok(box, f"adjust {i}")
        b["state"] = "adjusted" if b["src"] == "owlv2" and b["state"] != "relabelled" else b["state"]
        touched.append(b["box"])
        ops["adjust"] += 1
    for a in e.get("add", []):
        b = dict(id=new["next_id"], cls=cls_ok(a.get("cls"), "add"), box=box_ok(a.get("box"), "add"), src="review",
                 score=None, state="added")
        new["next_id"] += 1
        new["boxes"].append(b)
        touched.append(b["box"])
        ops["add"] += 1
    for p in e.get("promote", []):
        cid, c = (p, None) if isinstance(p, str) else next(iter(p.items()))
        if cid not in cands:
            raise SystemExit(f"promote: no candidate {cid}")
        cd = cands[cid]
        b = dict(id=new["next_id"], cls=cls_ok(c or cd["cls"], "promote"), box=cd["box"], src="owlv2_candidate",
                 score=cd["score"], state="promoted")
        new["next_id"] += 1
        new["boxes"].append(b)
        new["candidates"] = [x for x in new["candidates"] if x["id"] != cid]
        touched.append(b["box"])
        ops["promote"] += 1
    keep = e.get("keep", [])
    for b in new["boxes"]:
        if b["state"] == "draft" and (keep == "all" or b["id"] in [int(k) for k in (keep if keep != "all" else [])]):
            b["state"] = "kept"
            ops["keep"] += 1
    status = e.get("status")
    if status:
        if status not in ("todo", "in_progress", "done", "excluded"):
            raise SystemExit(f"status: {status}?")
        if status == "excluded" and not e.get("reason"):
            raise SystemExit("an excluded frame needs a reason")
        new["status"], new["reason"] = status, e.get("reason")
        if status == "done":
            for b in new["boxes"]:
                if b["state"] == "draft":
                    b["state"] = "kept"
    elif new["status"] == "todo":
        new["status"] = "in_progress"
    if e.get("note"):
        new["note"] = (new["note"] + " " if new["note"] else "") + e["note"]
    new["log"].append(dict(t=now(), event="apply", ops=dict(ops), status=new["status"], edit=e))
    st.clear()
    st.update(new)
    return touched


# ---------------------------------------------------------------------------------------------
# Export, stats, batches


def export(out: Path) -> None:
    images, anns, excluded = [], [], []
    for f in sorted(WORK.glob("*.json")):
        st = json.loads(f.read_text())
        if st["status"] == "excluded":
            excluded.append(dict(frame_id=st["frame_id"], reason=st["reason"]))
        if st["status"] != "done":
            continue
        image_id = len(images) + 1
        images.append(dict(id=image_id, file_name=st["file"], width=st["width"], height=st["height"],
                           frame_id=st["frame_id"], clip=st["clip"], t=st["t"], split=st["split"], kind=st["kind"]))
        for b in st["boxes"]:
            x0, y0, x1, y1 = b["box"]
            anns.append(dict(id=len(anns) + 1, image_id=image_id, category_id=common.ALL_LABELS.index(b["cls"]) + 1,
                             bbox=[x0, y0, round(x1 - x0, 1), round(y1 - y0, 1)], area=round((x1 - x0) * (y1 - y0), 1),
                             iscrowd=0))
    common.save_json(dict(info=dict(description="StockMask dataset v0 labels, reviewed", exported=now(),
                                    excluded=excluded),
                          images=images, annotations=anns, categories=common.categories()), out)
    per = collections.Counter(a["category_id"] for a in anns)
    print(f"{len(images)} reviewed frames, {len(anns)} boxes (" + ", ".join(
        f"{c} {per[i + 1]}" for i, c in enumerate(common.ALL_LABELS)) + f"), {len(excluded)} excluded: {out}")


def match_draft(st: dict) -> dict:
    """How the draft fared: each draft box ends kept (unchanged), adjusted (moved; IoU with its final box), relabelled
    or deleted; final boxes the draft lacked were added or promoted."""
    out = collections.Counter(b["state"] for b in st["boxes"])
    out["deleted"] = sum(1 for b in st["deleted"] if b["src"] == "owlv2")
    return out


def stats(frames: list) -> None:
    rows = []
    for f in frames:
        st = json.loads((WORK / f"{f}.json").read_text())
        m = match_draft(st)
        t = [datetime.datetime.fromisoformat(x["t"]) for x in st["log"]]
        minutes = (t[-1] - t[0]).total_seconds() / 60 if len(t) > 1 else 0.0
        images = sum(x.get("images", 0) for x in st["log"])
        q = qa(st)
        rows.append((st, m, minutes, images, q))
    print("| frame | split | status | draft | kept | adjusted | relabelled | deleted | added | promoted | final | "
          "bottle units | minutes | images |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    groups = collections.defaultdict(collections.Counter)
    for st, m, minutes, images, q in rows:
        print(f"| {st['frame_id']} | {st['split']} | {st['status']} | {st['draft_count']} | {m['kept']} | "
              f"{m['adjusted']} | {m['relabelled']} | {m['deleted']} | {m['added']} | {m['promoted']} | "
              f"{len(st['boxes']) if st['status'] != 'excluded' else '–'} | "
              f"{q['bottle_units'] if st['status'] != 'excluded' else '–'} | {minutes:.1f} | {images} |")
        for g in ("all", "walk 2 (test)" if st["split"] == "test" else "walk 1 (train, val)"):
            tot = groups[g]
            tot["frames"] += 1
            tot["minutes"] += minutes
            tot["images"] += images
            if st["status"] == "excluded":
                tot["excluded"] += 1
            elif st["status"] == "done":
                tot.update(m)
                tot["done"] += 1
                tot["draft"] += st["draft_count"]
                tot["final"] += len(st["boxes"])
    print()
    for g, tot in groups.items():
        n, d = tot["frames"], max(1, tot["draft"])
        print(f"{g}: {n} frames ({tot['done']} done, {tot['excluded']} excluded), {tot['minutes'] / n:.1f} min and "
              f"{tot['images'] / n:.1f} rendered images per frame. Of {tot['draft']} draft boxes on done frames: "
              f"{100 * tot['kept'] / d:.0f}% right as drawn, {100 * tot['adjusted'] / d:.0f}% moved, "
              f"{100 * tot['relabelled'] / d:.0f}% relabelled, {100 * tot['deleted'] / d:.0f}% deleted. Final boxes "
              f"{tot['final']}: {tot['added'] + tot['promoted']} ({100 * (tot['added'] + tot['promoted']) / max(1, tot['final']):.0f}%) "
              "had no draft box.")


def sheet(out: Path) -> None:
    """A local page for the owner to spot-check reviewed frames: each frame's overview with its counts and note. It
    shows venue footage: it stays in ml/data/ and is never published."""
    import html

    cards = []
    for f in sorted(WORK.glob("*.json")):
        st = json.loads(f.read_text())
        if st["status"] not in ("done", "excluded"):
            continue
        render(st)  # redraw the overview with the final boxes; not saved, so the frame's timing log is untouched
        q = qa(st)
        counts = ", ".join(f"{c} {n}" for c, n in q["counts"].items())
        text = (f"excluded: {html.escape(st['reason'] or '')}" if st["status"] == "excluded" else
                f"{counts}; bottle units {q['bottle_units']}")
        cards.append(f'<figure><a href="render/{st["frame_id"]}/overview.jpg"><img loading="lazy" '
                     f'src="render/{st["frame_id"]}/overview.jpg"></a><figcaption><b>{st["frame_id"]}</b> '
                     f'({st["split"]}) {text}<br>{html.escape(st["note"] or "")}</figcaption></figure>')
    out.write_text("<!doctype html><meta charset=utf-8><title>Label spot-check</title><style>body{font:14px "
                   "system-ui;margin:16px;background:#fff;color:#111}figure{display:inline-block;width:480px;"
                   "vertical-align:top;margin:0 12px 24px 0}img{width:100%}</style><h1>Reviewed frames</h1><p>Blue: "
                   "bottle (B). Orange: bottle_top (T). Green: can (C). Purple: case (K). Click a picture for full "
                   "size. Tell Claude the frame name and what looks wrong.</p>" + "".join(cards))
    print(f"{len(cards)} frames: {out}")


def batches(size: int, splits: list, kinds: list, test_kinds: list, min_sharp: float) -> None:
    """Contiguous runs of frames per clip and split, about `size` each: a labelling agent then sees the same shelves
    and products across its batch. Frames already done or excluded are left out, and so are train and val frames
    blurrier than `min_sharp` (sharpness over the clip median; in the pilot, frames under 0.5 were the slowest or
    unusable). Test frames are all kept: they are what the app commits."""
    rows = [r for r in common.read_manifest() if r["split"] in splits
            and r["kind"] in (test_kinds if r["split"] == "test" else kinds)]
    blurry = [r for r in rows if r["split"] != "test" and float(r["sharp_rel"]) < min_sharp]  # test keeps every hold
    rows = [r for r in rows if r not in blurry]
    done = {f.stem for f in WORK.glob("*.json") if json.loads(f.read_text())["status"] in ("done", "excluded")}
    rows = [r for r in rows if r["frame_id"] not in done]
    groups = collections.defaultdict(list)
    for r in rows:
        groups[(r["split"], r["clip"])].append(r)
    BATCHES.mkdir(parents=True, exist_ok=True)
    for f in BATCHES.glob("batch_*.txt"):
        f.unlink()
    out = []
    for (split, clip), rs in sorted(groups.items(), key=lambda kv: ({"train": 0, "val": 1, "test": 2}[kv[0][0]],
                                                                     kv[0][1])):
        rs.sort(key=lambda r: r["t"])
        k = max(1, round(len(rs) / size))
        for j in range(k):
            part = rs[round(j * len(rs) / k):round((j + 1) * len(rs) / k)]
            out.append((split, clip, part))
    print("| batch | split | clip | frames | seconds in the clip |")
    print("|---|---|---|---|---|")
    for n, (split, clip, part) in enumerate(out, 1):
        (BATCHES / f"batch_{n:02d}.txt").write_text("\n".join(r["frame_id"] for r in part) + "\n")
        print(f"| {n:02d} | {split} | {clip} | {len(part)} | {part[0]['t']:.0f}-{part[-1]['t']:.0f} |")
    print(f"\n{sum(len(p) for _, _, p in out)} frames to label in {len(out)} batches: {BATCHES}. Left out: "
          f"{len(done)} done or excluded, {len(blurry)} under {min_sharp:g} of the clip's median sharpness.")


# ---------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("render")
    p.add_argument("frame")
    p.add_argument("--candidates", action="store_true", help="also draw candidate boxes (dashed, c-numbers)")
    p.add_argument("--crop", help="x0,y0,x1,y1 in full-resolution pixels: one zoomed view of that region")
    p.add_argument("--tiles", default="none", choices=("all", "dense", "none"),
                   help="also draw fixed tiles: all, or those holding 6 boxes or more (default none: crop what you need)")
    p = sub.add_parser("apply")
    p.add_argument("target", help="an edits JSON file, or a frame id with --edits")
    p.add_argument("--edits", help="the edit object as a JSON string")
    p.add_argument("--no-render", action="store_true")
    for name in ("qa", "show", "reset"):
        sub.add_parser(name).add_argument("frame")
    p = sub.add_parser("export")
    p.add_argument("--out", default=str(common.LABELS))
    p = sub.add_parser("stats")
    p.add_argument("frames", nargs="*")
    sub.add_parser("sheet")
    p = sub.add_parser("batches")
    p.add_argument("--size", type=int, default=25)
    p.add_argument("--splits", default="train,val,test")
    p.add_argument("--kinds", default="hold,periodic", help="frame kinds for train and val")
    p.add_argument("--test-kinds", default="hold", help="frame kinds for test (default: the hold keyframes only)")
    p.add_argument("--min-sharp", type=float, default=0.5, help="leave out frames blurrier than this share of "
                                                                 "their clip's median sharpness")
    args = ap.parse_args()

    if args.cmd == "render":
        st = load(args.frame)
        crop = [float(v) for v in args.crop.split(",")] if args.crop else None
        paths = render(st, args.tiles, args.candidates, crop)
        save(st)
        print_qa(st)
        print("\n".join(str(p) for p in paths))
    elif args.cmd == "apply":
        if args.edits:
            e = json.loads(args.edits)
            e.setdefault("frame", args.target)
        else:
            e = json.loads(Path(args.target).read_text())
        st = load(e["frame"], create=False)
        touched = apply(st, e)
        paths = []
        if not args.no_render:  # the overview, plus the crops and tiles already drawn that show an edited box
            crops, names = touched_views(st, touched)
            paths = render(st, only=names)
            for c in crops:
                paths += render(st, crop=c)
        save(st)
        print_qa(st)
        print("\n".join(str(p) for p in paths))
    elif args.cmd == "qa":
        print_qa(load(args.frame, create=False))
    elif args.cmd == "show":
        st = load(args.frame, create=False)
        for b in sorted(st["boxes"], key=lambda b: b["id"]):
            print(f"{b['id']:4d} {b['cls']:10s} {[round(v) for v in b['box']]} {b['state']}"
                  + (f" score {b['score']}" if b["score"] is not None else ""))
    elif args.cmd == "reset":
        f = WORK / f"{args.frame}.json"
        if f.exists():
            f.unlink()
        print(f"{args.frame}: back to the draft")
    elif args.cmd == "export":
        export(Path(args.out))
    elif args.cmd == "stats":
        frames = args.frames or sorted(f.stem for f in WORK.glob("*.json"))
        stats(frames)
    elif args.cmd == "sheet":
        sheet(REVIEW / "spotcheck.html")
    elif args.cmd == "batches":
        batches(args.size, args.splits.split(","), args.kinds.split(","), args.test_kinds.split(","), args.min_sharp)


if __name__ == "__main__":
    sys.exit(main())
