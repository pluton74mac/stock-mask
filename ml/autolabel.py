"""Automatic labelling for dataset v0: teachers, the video, calibration and self-training (P0-7, ADR 006).

No person or agent checks boxes. ml/AUTOLABEL.md explains the method and the results. The labels of a frame come
from: the teachers' boxes fused per class (weighted box fusion); those boxes linked through the video by optical flow
(tracks.py), so a weak box between two kept boxes of the same track is kept, a short gap is filled and a one-frame
flicker can be dropped; then the fixes of LABELING.md (sliced tops, necks of bottles behind, partial objects at the
frame edge). Steps, each a subcommand:

  frames     walk 1 (video-1) sampled densely: the sharpest frame of every 8 video frames (about 0.27 s), blurred
             ones dropped, the 9 checked walk-1 frames always in. Plus short stretches of walk 2 around its 6 checked
             keyframes, for the final check only: walk 2 never trains.
  teach      the teachers (teachers.py: OWLv2, Grounding DINO) on every frame, cached per frame.
  calibrate  fuse, link and fix, choosing the thresholds on the 9 checked walk-1 frames (precision and recall per
             class); then score the 6 checked walk-2 frames once. --save writes ml/data/autolabel/params.json.
  export     the labels as COCO for train.py: walk 1 split into train and val by time, frames within 1 s of a
             calibration frame held out.
  student    run a trained checkpoint as a teacher, for the next self-training round.

    PY=ml/.venv/bin/python
    $PY ml/autolabel.py frames && $PY ml/autolabel.py teach --teachers owlv2,gdino
    $PY ml/autolabel.py calibrate --teachers owlv2,gdino --save && $PY ml/autolabel.py export --name auto-r1
    $PY ml/train.py --name auto-r1 --labels ml/data/autolabel/auto-r1.coco.json --epochs 15 --accum 1
    $PY ml/autolabel.py student --run auto-r1
    $PY ml/autolabel.py calibrate --teachers owlv2,gdino,auto-r1 --save && $PY ml/autolabel.py export --name auto-r2
    $PY ml/train.py --name auto-r2 --labels ml/data/autolabel/auto-r2.coco.json --epochs 8 --accum 1 \\
        --init ml/data/runs/auto-r1/checkpoint_best_total.pth
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np

import common

AUTO = common.DATA / "autolabel"
MANIFEST = AUTO / "manifest.csv"
PARAMS = AUTO / "params.json"
REVIEWED = common.DATA / "review" / "labels"


def videos_dir(arg: str | None) -> Path:
    """The clips: --videos, else research/walkthrough/videos, else the main checkout's (when ml/data links there)."""
    for p in (arg, common.VIDEOS, common.DATA.resolve().parent.parent / "research" / "walkthrough" / "videos"):
        if p and Path(p).exists():
            return Path(p)
    raise SystemExit("no clips found: pass --videos")


def checked() -> dict:
    """frame_id -> reviewed state, for frames a person or agent marked done (LABELING.md). todo, in_progress and
    excluded frames are not truth."""
    out = {}
    for f in sorted(REVIEWED.glob("*.json")):
        st = json.loads(f.read_text())
        if st["status"] == "done":
            out[st["frame_id"]] = st
    return out


def read_manifest() -> list:
    return common.read_manifest(MANIFEST)


# ---------------------------------------------------------------------------------------------
# frames


def sample(track: dict, step: int, min_sharp: float, force: set, around: set | None = None, reach=4) -> list:
    """Track rows to keep: the sharpest frame of every `step` frames (a forced frame wins its window), dropping frames
    under `min_sharp` of the median sharpness of the picks. With `around`, only windows within `reach` windows of a
    frame in `around`."""
    idx, sharp = track["index"], track["sharp"]
    picks = []
    for w0 in range(0, len(idx), step):
        window = range(w0, min(w0 + step, len(idx)))
        if around is not None and not any(abs(int(idx[w0]) - a) <= (reach + 1) * step for a in around):
            continue
        forced = [k for k in window if int(idx[k]) in force]
        picks.append((forced[0], True) if forced else (max(window, key=lambda k: sharp[k]), False))
    ref = float(np.median([sharp[k] for k, _ in picks]))
    return [(k, f, float(sharp[k]) / ref) for k, f in picks if f or sharp[k] >= min_sharp * ref]


def cmd_frames(args) -> None:
    import frames

    wt = common.walkthrough()
    videos = videos_dir(args.videos)
    done = checked()
    rows = []
    for clip in ("video-1", "w2-bay1", "w2-bay2", "w2-bay3"):
        path = next(str(p) for p in videos.glob(f"{clip}.*") if p.suffix.lower() in (".mov", ".mp4"))
        cache = common.FRAMES / ".cache" / f"{clip}-{Path(path).stat().st_size}.npz"
        z = np.load(cache)  # frames.py's motion pass over the clip
        track = dict(index=z["index"], t=z["t"], sharp=z["sharp"], full=tuple(z["full"]))
        force = {int(st["frame_id"].split("_f")[1]) for fid, st in done.items() if fid.startswith(clip + "_")}
        test = clip != "video-1"
        picks = sample(track, args.step, args.min_sharp, force, around=force if test else None)
        n_gap = 0
        for k, forced, rel in picks:
            t, f = float(track["t"][k]), int(track["index"][k])
            split = "check" if test else frames.split_of(t, "trainval", 10.0, 5, 2, 1.0)
            if split is None:  # within 1 s of a train/val boundary: neighbouring frames show the same bottles
                n_gap += 1
                continue
            fid = f"{clip}_f{f:05d}"
            rows.append(dict(frame_id=fid, clip=clip, t=round(t, 3), frame=f, split=split,
                             kind="checked" if forced else "dense", width=track["full"][0], height=track["full"][1],
                             sharp_rel=round(rel, 2), file=f"autolabel/frames/{clip}/{fid}.jpg"))
        print(f"{clip}: {sum(1 for r in rows if r['clip'] == clip)} frames ({n_gap} at a train/val boundary dropped)")
        (AUTO / "frames" / clip).mkdir(parents=True, exist_ok=True)
        todo = [r for r in rows if r["clip"] == clip and not (common.DATA / r["file"]).exists()]
        if todo:
            frames.write_frames(wt, path, clip, todo, common.FRAMES, 95)
    common.write_manifest(rows, MANIFEST)
    by = {}
    for r in rows:
        by[r["split"]] = by.get(r["split"], 0) + 1
    print(f"{len(rows)} frames {by}: {MANIFEST}")


# ---------------------------------------------------------------------------------------------
# fuse, track, fix


def fuse(outputs: dict, weights: dict, iou_thr=0.55) -> list:
    """Weighted box fusion, per class, of the teachers' boxes on one frame. outputs: teacher -> (boxes, scores,
    classes). A cluster takes at most one box per teacher; its box is the score-weighted mean, its score the
    weighted mean of the teachers' scores with 0 for a teacher that drew nothing there, n the number of teachers in
    it. With one teacher this is that teacher's boxes."""
    total = sum(weights.values())
    out = []
    for c in common.CLASSES:
        items = []
        for t, (b, s, cl) in outputs.items():
            m = cl == c
            items += [(float(sc), t, np.asarray(bb, float)) for bb, sc in zip(b[m], s[m])]
        items.sort(key=lambda x: -x[0])
        boxes, members = np.zeros((0, 4)), []
        for sc, t, bb in items:
            arg = None
            if len(boxes):
                o = np.asarray(_iou_rows(boxes, bb))
                for j in np.argsort(-o):
                    if o[j] < iou_thr:
                        break
                    if t not in members[j]:
                        arg = j
                        break
            if arg is None:
                boxes = np.vstack([boxes, bb])
                members.append({t: (sc, bb)})
            else:
                members[arg][t] = (sc, bb)
                w = np.array([v[0] * weights[k] for k, v in members[arg].items()])
                boxes[arg] = (w[:, None] * np.array([v[1] for v in members[arg].values()])).sum(0) / w.sum()
        for b, m in zip(boxes, members):
            out.append(dict(box=[float(v) for v in b], cls=c, n=len(m),
                            score=sum(weights[k] * v[0] for k, v in m.items()) / total))
    return out


def _iou_rows(boxes: np.ndarray, b: np.ndarray) -> np.ndarray:
    ix = np.clip(np.minimum(boxes[:, 2], b[2]) - np.maximum(boxes[:, 0], b[0]), 0, None)
    iy = np.clip(np.minimum(boxes[:, 3], b[3]) - np.maximum(boxes[:, 1], b[1]), 0, None)
    inter = ix * iy
    area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return inter / np.maximum(area + (b[2] - b[0]) * (b[3] - b[1]) - inter, 1e-9)


def build(rows: list, names: list, weights: dict, floor: dict, videos: Path, tag: str) -> dict:
    """Fused detections and tracks per clip, cached in ml/data/autolabel/tracks/<tag>.pkl. Returns clip -> dict(rows,
    dets, tracks)."""
    import pickle

    import teachers
    import tracks

    f = AUTO / "tracks" / f"{tag}.pkl"
    if f.exists():
        return pickle.loads(f.read_bytes())
    wt = common.walkthrough()
    out = {}
    for clip in sorted({r["clip"] for r in rows}):
        rs = sorted((r for r in rows if r["clip"] == clip), key=lambda r: r["frame"])
        dets = []
        for r in rs:
            o = {}
            for n in names:
                b, s, c = teachers.load(n, r["frame_id"])
                m = s >= floor.get(n, teachers.FLOOR)
                o[n] = (b[m], s[m], c[m])
            dets.append(fuse(o, weights))
        path = next(str(p) for p in videos.glob(f"{clip}.*") if p.suffix.lower() in (".mov", ".mp4"))
        t0 = time.time()
        tr = tracks.link(wt.read_video, path, [r["frame"] for r in rs], dets)
        for t in tr:
            t.update(tracks.track_stats(t, dets))
        out[clip] = dict(rows=rs, dets=dets, tracks=tr)
        print(f"{clip}: {len(rs)} frames, {sum(len(d) for d in dets)} detections, {len(tr)} tracks "
              f"({time.time() - t0:.0f} s)", flush=True)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_bytes(pickle.dumps(out))
    return out


# can, case, carton and bag have no (or 3) checked boxes to tune on, so they keep a fixed, cautious rule: both teachers
# drew the box (fused score 0.25 or more), or one did with a score of `solo` or more.
DEFAULTS = dict(thr={"bottle": 0.3, "bottle_top": 0.2, "can": 0.25, "case": 0.25, "carton": 0.25, "bag": 0.25},
                k=2, flicker=0.5, need=1, need_by={"can": 2, "case": 2, "carton": 2, "bag": 2}, solo=0.3, gap=2,
                merge_tops=True, top_xiou=0.85, top_aspect=1.6,
                necks=True, neck_width=0.6, neck_cover=0.6,
                partial=True, partial_frac=0.5)


def keep_track(p: dict):
    """keep(track, detection): an observation is kept on its own (fused) score, unless it is a flicker (its track
    was seen in fewer than k frames and it is not strong), or only one teacher drew it and it is not strong."""
    def keep(t, x):
        if x["score"] < p["thr"].get(t["cls"], 1.0):
            return False
        if t["n"] < p["k"] and x["score"] < p["flicker"]:
            return False
        if x.get("n", 1) < p.get("need_by", {}).get(t["cls"], p["need"]) and x["score"] < p["solo"]:
            return False
        return True
    return keep


def fix(labels: list, w: int, h: int, p: dict) -> list:
    """LABELING.md's corrections, applied automatically to one frame's labels [(box, cls, score, filled)]."""
    labels = [list(x) for x in labels]
    if p["merge_tops"]:  # one tall cap sliced into stacked boxes: same left and right edges, touching or overlapping
        merged = True
        while merged:
            merged = False
            tops = [i for i, x in enumerate(labels) if x[1] == "bottle_top"]
            for a in tops:
                for b in tops:
                    if a >= b or labels[a] is None or labels[b] is None:
                        continue
                    A, B = labels[a][0], labels[b][0]
                    xi = max(0.0, min(A[2], B[2]) - max(A[0], B[0])) / max(1e-9, max(A[2], B[2]) - min(A[0], B[0]))
                    touch = min(A[3], B[3]) - max(A[1], B[1]) >= -0.05 * min(A[3] - A[1], B[3] - B[1])
                    u = [min(A[0], B[0]), min(A[1], B[1]), max(A[2], B[2]), max(A[3], B[3])]
                    if xi >= p["top_xiou"] and touch and (u[3] - u[1]) <= p["top_aspect"] * (u[2] - u[0]):
                        labels[a] = [u, "bottle_top", max(labels[a][2], labels[b][2]), labels[a][3] and labels[b][3]]
                        labels[b] = None
                        merged = True
            labels = [x for x in labels if x is not None]
    if p["necks"]:  # a narrow "bottle" mostly covered by a wider bottle box: the neck of a bottle behind
        bottles = [i for i, x in enumerate(labels) if x[1] == "bottle"]
        drop = set()
        for i in bottles:
            bx = labels[i][0]
            bw, area = bx[2] - bx[0], max(1e-9, (bx[2] - bx[0]) * (bx[3] - bx[1]))
            for j in bottles:
                by = labels[j][0]
                if i != j and bw < p["neck_width"] * (by[2] - by[0]):
                    ix = max(0.0, min(bx[2], by[2]) - max(bx[0], by[0]))
                    iy = max(0.0, min(bx[3], by[3]) - max(bx[1], by[1]))
                    if ix * iy / area >= p["neck_cover"]:
                        drop.add(i)
                        break
        labels = [x for i, x in enumerate(labels) if i not in drop]
    if p["partial"]:  # cut by the frame edge and under half the usual size: from the shelf above or below
        typical = {}
        for c in {x[1] for x in labels}:
            whole = [x[0] for x in labels if x[1] == c and x[0][0] > 3 and x[0][1] > 3 and x[0][2] < w - 3
                     and x[0][3] < h - 3]
            if whole:
                typical[c] = (float(np.median([b[2] - b[0] for b in whole])), float(np.median([b[3] - b[1] for b in whole])))
        keep = []
        for x in labels:
            b, c = x[0], x[1]
            if c in typical:
                tw, th = typical[c]
                if (b[1] <= 3 or b[3] >= h - 3) and (b[3] - b[1]) < p["partial_frac"] * th:
                    continue
                if (b[0] <= 3 or b[2] >= w - 3) and (b[2] - b[0]) < p["partial_frac"] * tw:
                    continue
            keep.append(x)
        labels = keep
    return labels


def labels_for(built: dict, p: dict, only: set | None = None) -> dict:
    """frame_id -> final labels [(box, cls, score, filled)] under parameters p (for the frames in `only`, if given)."""
    import tracks

    out = {}
    keep = keep_track(p)
    for clip, d in built.items():
        rs = d["rows"]
        if only is not None and not any(r["frame_id"] in only for r in rs):
            continue
        w, h = rs[0]["width"], rs[0]["height"]
        per = tracks.frame_labels(d["tracks"], d["dets"], keep, gap=p["gap"], width=w, height=h)
        for r, labels in zip(rs, per):
            if only is None or r["frame_id"] in only:
                out[r["frame_id"]] = fix(labels, w, h, p)
    return out


# ---------------------------------------------------------------------------------------------
# evaluate


def score_frames(labels: dict, truth: dict, iou_thr=0.5) -> dict:
    """Per class: true positives, predicted and true boxes over the checked frames (class-aware, IoU >= 0.5, each
    truth matched once, highest score first); and the bottle-unit count error per frame."""
    stats = {c: [0, 0, 0] for c in common.CLASSES}
    unit_err = []
    for fid, st in truth.items():
        pred = labels.get(fid, [])
        gt = [(b["cls"], b["box"]) for b in st["boxes"]]
        for c in common.CLASSES:
            P = sorted([x for x in pred if x[1] == c], key=lambda x: -x[2])
            T = [b for k, b in gt if k == c]
            used = set()
            for x in P:
                best, arg = iou_thr, None
                for j, tb in enumerate(T):
                    if j not in used:
                        o = common.iou(x[0], tb)
                        if o >= best:
                            best, arg = o, j
                if arg is not None:
                    used.add(arg)
                    stats[c][0] += 1
            stats[c][1] += len(P)
            stats[c][2] += len(T)
        tu = common.bottle_units([b for k, b in gt if k == "bottle"], [b for k, b in gt if k == "bottle_top"])
        pu = common.bottle_units([x[0] for x in pred if x[1] == "bottle"], [x[0] for x in pred if x[1] == "bottle_top"])
        if tu:
            unit_err.append(abs(pu - tu) / tu)
    out = {}
    for c, (tp, np_, nt) in stats.items():
        prec = tp / np_ if np_ else None
        rec = tp / nt if nt else None
        f1 = 2 * tp / (np_ + nt) if np_ + nt else None
        out[c] = dict(tp=tp, pred=np_, true=nt, precision=prec, recall=rec, f1=f1)
    out["units"] = dict(median=float(np.median(unit_err)) if unit_err else None,
                        p90=float(np.percentile(unit_err, 90)) if unit_err else None)
    return out


def objective(s: dict) -> float:
    """Mean F1 over the classes with at least 5 true boxes in the calibration frames (bottle and bottle_top here)."""
    f = [s[c]["f1"] or 0.0 for c in common.CLASSES if s[c]["true"] >= 5]
    return float(np.mean(f)) if f else 0.0


def table(s: dict, title: str) -> str:
    lines = [f"{title}", "", "| class | true boxes | labels | precision | recall | F1 |", "|---|---|---|---|---|---|"]
    fmt = lambda v: "–" if v is None else f"{v:.2f}"  # noqa: E731
    for c in common.CLASSES:
        x = s[c]
        if x["true"] or x["pred"]:
            lines.append(f"| {c} | {x['true']} | {x['pred']} | {fmt(x['precision'])} | {fmt(x['recall'])} | "
                         f"{fmt(x['f1'])} |")
    u = s["units"]
    lines.append(f"\nBottle units per frame (bottles plus tops with no bottle of their own): count error median "
                 f"{fmt(u['median'])}, p90 {fmt(u['p90'])}.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------
# teach


def cmd_teach(args) -> None:
    import teachers

    rows = read_manifest()
    for name in args.teachers.split(","):
        t0 = time.time()
        t = teachers.OWLv2Teacher() if name == "owlv2" else teachers.GDINOTeacher() if name == "gdino" else None
        if t is None:
            raise SystemExit(f"unknown teacher {name}")
        teachers.run(t, rows)
        print(f"{name}: done in {(time.time() - t0) / 60:.1f} min", flush=True)
        del t


# ---------------------------------------------------------------------------------------------
# calibrate, export, student


def setup(args) -> tuple:
    names = args.teachers.split(",")
    w = [float(v) for v in args.weights.split(",")] if args.weights else [1.0] * len(names)
    weights = dict(zip(names, w))
    tag = "+".join(f"{n}x{weights[n]:g}" for n in names)
    built = build(read_manifest(), names, weights, {}, videos_dir(args.videos), tag)
    return names, weights, tag, built


def grid(two: bool) -> list:
    import itertools

    out = []
    for tb, tt, k, fl, gap, need in itertools.product((0.15, 0.2, 0.25, 0.3, 0.35, 0.4),
                                                      (0.08, 0.1, 0.12, 0.15, 0.2, 0.25), (1, 2, 3),
                                                      (0.35, 0.5), (0, 2), (1, 2) if two else (1,)):
        p = json.loads(json.dumps(DEFAULTS))
        p["thr"].update(bottle=tb, bottle_top=tt)
        p.update(k=k, flicker=fl, gap=gap, need=need, solo=0.3)
        out.append(p)
    return out


def cmd_calibrate(args) -> None:
    names, weights, tag, built = setup(args)
    done = checked()
    calib = {f: s for f, s in done.items() if f.startswith("video-1_")}
    final = {f: s for f, s in done.items() if not f.startswith("video-1_")}
    t0, best = time.time(), None
    for p in grid(len(names) > 1):
        s = score_frames(labels_for(built, p, set(calib)), calib)
        o = objective(s)
        if best is None or o > best[0]:
            best = (o, p, s)
    o, p, s = best
    print(f"calibrated on {len(calib)} walk-1 frames in {time.time() - t0:.0f} s: objective {o:.3f}; "
          f"thr bottle {p['thr']['bottle']}, top {p['thr']['bottle_top']}, k {p['k']}, flicker {p['flicker']}, "
          f"gap {p['gap']}, need {p['need']}")
    ablations = {"chosen": s}
    for name, change in (("no merging of sliced tops", dict(merge_tops=False)), ("no neck fix", dict(necks=False)),
                         ("no edge fix", dict(partial=False)),
                         ("no video (each frame alone)", dict(k=1, flicker=0.0, gap=0)),
                         ("no gap filling", dict(gap=0))):
        q = dict(p, **change)
        ablations[name] = score_frames(labels_for(built, q, set(calib)), calib)
    check = score_frames(labels_for(built, p, set(final)), final)
    report = dict(teachers=names, weights=weights, tag=tag, objective=o, params=p,
                  calibration={k: v for k, v in ablations.items()}, final_check=check,
                  frames=dict(calibration=sorted(calib), final_check=sorted(final)))
    out = AUTO / f"calibration-{tag}.json"
    common.save_json(report, out)
    print(table(s, f"Calibration frames (walk 1, {len(calib)}):"))
    for name, a in ablations.items():
        if name != "chosen":
            print(f"  {name}: objective {objective(a):.3f} (bottle F1 {a['bottle']['f1'] or 0:.2f}, top F1 "
                  f"{a['bottle_top']['f1'] or 0:.2f})")
    print(table(check, f"\nFinal check (walk 2, {len(final)} frames, never tuned on):"))
    if args.save:
        common.save_json(dict(teachers=names, weights=weights, tag=tag, params=p, objective=o), PARAMS)
        print(f"\nsaved: {PARAMS}")
    print(out)


def holdout(rows: list, around: set, seconds=1.0) -> set:
    """Frames within `seconds` of a calibration frame: no student trains on them, so the next round's calibration
    sees a student that never saw those shelves from there."""
    times = [(r["clip"], r["t"]) for r in rows if r["frame_id"] in around]
    return {r["frame_id"] for r in rows if any(r["clip"] == c and abs(r["t"] - t) <= seconds for c, t in times)}


def cmd_export(args) -> None:
    cfg = json.loads(PARAMS.read_text())
    rows = read_manifest()
    built = build(rows, cfg["teachers"], cfg["weights"], {}, videos_dir(args.videos), cfg["tag"])
    labels = labels_for(built, cfg["params"])
    hold = holdout(rows, {f for f in checked() if f.startswith("video-1_")})
    images, anns = [], []
    for r in rows:
        if r["clip"] != "video-1":
            continue
        image_id = len(images) + 1
        images.append(dict(id=image_id, file_name=r["file"], width=r["width"], height=r["height"],
                           frame_id=r["frame_id"], clip=r["clip"], t=r["t"], kind=r["kind"],
                           split="holdout" if r["frame_id"] in hold else r["split"]))
        for b, c, s, filled in labels[r["frame_id"]]:
            x0, y0, x1, y1 = b
            anns.append(dict(id=len(anns) + 1, image_id=image_id, category_id=common.CLASSES.index(c) + 1,
                             bbox=[round(x0, 1), round(y0, 1), round(x1 - x0, 1), round(y1 - y0, 1)],
                             area=round((x1 - x0) * (y1 - y0), 1), iscrowd=0, score=round(float(s), 3),
                             filled=bool(filled)))
    out = AUTO / f"{args.name}.coco.json"
    common.save_json(dict(info=dict(description="automatic labels", teachers=cfg["teachers"], params=cfg["params"]),
                          images=images, annotations=anns, categories=common.categories(common.CLASSES)), out)
    per = {c: sum(1 for a in anns if a["category_id"] == k + 1) for k, c in enumerate(common.CLASSES)}
    splits = {s: sum(1 for i in images if i["split"] == s) for s in ("train", "val", "holdout")}
    print(f"{len(images)} frames {splits}, {len(anns)} boxes {per}, {sum(a['filled'] for a in anns)} filled from "
          f"tracks: {out}")


def cmd_student(args) -> None:
    import teachers

    ckpt = common.DATA / "runs" / args.run / "checkpoint_best_total.pth"
    t0 = time.time()
    teachers.run(teachers.StudentTeacher(ckpt, args.run), read_manifest())
    print(f"{args.run}: done in {(time.time() - t0) / 60:.1f} min")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("frames")
    p.add_argument("--videos")
    p.add_argument("--step", type=int, default=8, help="one frame per this many video frames")
    p.add_argument("--min-sharp", type=float, default=0.5, help="drop frames under this share of the median sharpness")
    p = sub.add_parser("teach")
    p.add_argument("--teachers", default="owlv2,gdino")
    for name in ("calibrate", "export"):
        p = sub.add_parser(name)
        p.add_argument("--videos")
        if name == "calibrate":
            p.add_argument("--teachers", default="owlv2")
            p.add_argument("--weights", help="one weight per teacher, e.g. 1,0.5")
            p.add_argument("--save", action="store_true", help="make these the parameters export uses")
        else:
            p.add_argument("--name", required=True)
    p = sub.add_parser("student")
    p.add_argument("--run", required=True)
    args = ap.parse_args()
    {"frames": cmd_frames, "teach": cmd_teach, "calibrate": cmd_calibrate, "export": cmd_export,
     "student": cmd_student}[args.cmd](args)


if __name__ == "__main__":
    main()
