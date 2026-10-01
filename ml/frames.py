"""Training frames for dataset v0 from the storeroom clips (P0-7, ADR 006).

Per clip:
  1. Hold keyframes: the frames the app would commit (FR-13: under 10 deg/s for 0.8 s, the sharpest frame of the
     hold), from walkthrough.replay(), the same rule as the replay.
  2. Periodic frames: the sharpest frame of every --every seconds (0.5 by default).
  3. Blurry periodic frames are dropped: sharpness (variance of the Laplacian) under --min-sharp of the clip's
     median.
  4. Near-duplicates are dropped. Optical flow follows the view through the clip, so the overlap of any two frames
     is known. Hold keyframes are kept first, then periodic frames from the sharpest down; a frame is dropped when it
     overlaps a kept frame from the last or next --window seconds by --max-overlap or more.
  5. Splits. Walk 1 (video-1) is train and val: it is cut into --block second blocks, and every --val-every-th block
     is val. Frames within --gap seconds of a train/val boundary are dropped, because neighbouring frames show the
     same bottles. Walk 2 (w2-bay1..3) is test only: it is the walk with reference counts per product.
     Leakage limit: it is the same storeroom, the same products and the same phone four days apart. The test set
     measures the pipeline and the labels, not how the model does in a venue it has never seen (ADR 006 wants one
     unseen venue as the holdout).

Writes ml/data/frames/<clip>/<clip>_f<frame>.jpg (upright, full resolution, plain JPEG with no metadata) and
ml/data/frames/manifest.csv: frame_id, clip, t (s), frame (index in the clip), split (train, val, test),
kind (hold, periodic), width, height, sharp_rel (sharpness over the clip median) and file (relative to ml/data).

    ml/.venv/bin/python ml/frames.py --videos /path/to/research/walkthrough/videos [--dry-run]

The clips carry GPS metadata. Nothing here reads it: frames are decoded with OpenCV only.
"""

from __future__ import annotations

import argparse
import collections
import math
import time
from pathlib import Path

import cv2
import numpy as np

import common


def motion_track(wt, path: str) -> dict:
    """Per frame: index, time, sharpness, and where the view is, as the cumulative median feature shift in
    motion-frame pixels (walkthrough.image_motion). A lost track adds a jump of ten frames, so that no frame
    after it counts as a duplicate of one before it."""
    idx, ts, sharp, pos = [], [], [], []
    prev, p, size = None, np.zeros(2), None
    for _, i, t, frame in wt.read_video(path):
        if prev is None:
            s = wt.MOTION_SIDE / max(frame.shape[:2])
            size = (round(frame.shape[1] * s), round(frame.shape[0] * s))
            full = frame.shape[1], frame.shape[0]
        grey = cv2.cvtColor(cv2.resize(frame, size, interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        if prev is not None:
            px, vec = wt.image_motion(prev, grey)
            p = p + (vec if math.isfinite(px) else 10 * np.array(size, float))
        idx.append(i)
        ts.append(t)
        sharp.append(cv2.Laplacian(grey, cv2.CV_64F).var())
        pos.append(p.copy())
        prev = grey
    if prev is None:
        raise SystemExit(f"no frames read from {path}")
    return dict(index=np.array(idx), t=np.array(ts), sharp=np.array(sharp), pos=np.array(pos), size=size, full=full)


def overlap(a: np.ndarray, b: np.ndarray, size) -> float:
    """Share of the frame two views have in common, from their view positions (a pure shift)."""
    d = np.abs(a - b)
    return max(0.0, 1 - d[0] / size[0]) * max(0.0, 1 - d[1] / size[1])


def select(track: dict, holds: list, every: float, min_sharp: float, max_overlap: float, window: float):
    """Indices into the track of the frames to keep, with their kind, plus counts of what was dropped."""
    t, sharp, pos, size = track["t"], track["sharp"], track["pos"], track["size"]
    at = {f: k for k, f in enumerate(track["index"])}
    hold_rows = sorted({at[f] for f in holds if f in at})
    windows = collections.defaultdict(list)
    for k in range(len(t)):
        windows[int((t[k] - t[0]) // every)].append(k)
    periodic = [k for k in (max(ks, key=lambda k: sharp[k]) for ks in windows.values()) if k not in hold_rows]
    ref = float(np.median(sharp[periodic + hold_rows]))
    sharp_ok = [k for k in periodic if sharp[k] >= min_sharp * ref]
    kept, kinds, dup = [], {}, 0
    for k in hold_rows + sorted(sharp_ok, key=lambda k: -sharp[k]):
        near = [j for j in kept if abs(t[j] - t[k]) <= window]
        if any(overlap(pos[k], pos[j], size) >= max_overlap for j in near):
            dup += 1
            continue
        kept.append(k)
        kinds[k] = "hold" if k in hold_rows else "periodic"
    kept.sort()
    return kept, kinds, dict(periodic=len(periodic), blurry=len(periodic) - len(sharp_ok), duplicates=dup,
                             ref_sharp=ref)


def split_of(t: float, role: str, block: float, val_every: int, val_offset: int, gap: float):
    """train / val / test, or None for a frame too close to a train/val boundary."""
    if role == "test":
        return "test"
    b = int(t // block)
    side = lambda k: "val" if k % val_every == val_offset else "train"  # noqa: E731
    here = side(b)
    if t - b * block < gap and b > 0 and side(b - 1) != here:
        return None
    if (b + 1) * block - t < gap and side(b + 1) != here:
        return None
    return here


def write_frames(wt, path: str, clip: str, rows: list, out: Path, quality: int) -> None:
    want = {r["frame"]: r for r in rows}
    last = max(want)
    (out / clip).mkdir(parents=True, exist_ok=True)
    for _, i, _, frame in wt.read_video(path):
        if i in want:
            cv2.imwrite(str(common.DATA / want[i]["file"]), frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
        if i >= last:
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--videos", default=str(common.VIDEOS), help="folder holding video-1.MOV and w2-bay{1,2,3}.MOV")
    ap.add_argument("--clips", default=",".join(common.CLIP_ROLES), help="comma-separated clip names")
    ap.add_argument("--every", type=float, default=0.5, help="one periodic frame per this many seconds")
    ap.add_argument("--min-sharp", type=float, default=0.35, help="drop periodic frames under this share of the "
                                                                    "clip's median sharpness")
    ap.add_argument("--max-overlap", type=float, default=0.7, help="test clips: a frame is a near-duplicate when it "
                                                                     "overlaps a kept frame this much")
    ap.add_argument("--max-overlap-trainval", type=float, default=0.8, help="the same for walk 1 (train and val)")
    ap.add_argument("--window", type=float, default=4.0, help="seconds either side to look for near-duplicates")
    ap.add_argument("--block", type=float, default=10.0, help="walk 1: train/val block length, seconds")
    ap.add_argument("--val-every", type=int, default=5, help="walk 1: every Nth block is val")
    ap.add_argument("--val-offset", type=int, default=2, help="walk 1: which block of each N is val")
    ap.add_argument("--gap", type=float, default=1.0, help="walk 1: drop frames this close to a train/val boundary")
    ap.add_argument("--quality", type=int, default=95, help="JPEG quality")
    ap.add_argument("--dry-run", action="store_true", help="count frames only; write nothing")
    args = ap.parse_args()
    wt = common.walkthrough()
    rows, report = [], []
    for clip in [c.strip() for c in args.clips.split(",") if c.strip()]:
        if clip in common.EXCLUDED_CLIPS:
            raise SystemExit(f"{clip} is excluded: {common.EXCLUDED_CLIPS[clip]}")
        role = common.CLIP_ROLES[clip]
        path = next((str(p) for p in Path(args.videos).glob(f"{clip}.*") if p.suffix.lower() in (".mov", ".mp4")),
                    None)
        if path is None:
            raise SystemExit(f"no video for {clip} in {args.videos}")
        t0 = time.time()
        cache = common.FRAMES / ".cache" / f"{clip}-{Path(path).stat().st_size}.npz"
        if cache.exists():  # the two passes over the clip don't depend on the selection settings
            z = np.load(cache)
            holds = z["holds"].tolist()
            track = dict(index=z["index"], t=z["t"], sharp=z["sharp"], pos=z["pos"], size=tuple(z["size"]),
                         full=tuple(z["full"]))
        else:
            holds = [c.frame for c in wt.replay(path)[1]]
            track = motion_track(wt, path)
            cache.parent.mkdir(parents=True, exist_ok=True)
            np.savez(cache, holds=np.array(holds, dtype=int), **{k: np.array(v) for k, v in track.items()})
        max_overlap = args.max_overlap if role == "test" else args.max_overlap_trainval
        kept, kinds, n = select(track, holds, args.every, args.min_sharp, max_overlap, args.window)
        clip_rows, gaps = [], 0
        for k in kept:
            t = float(track["t"][k])
            split = split_of(t, role, args.block, args.val_every, args.val_offset, args.gap)
            if split is None:
                gaps += 1
                continue
            f = int(track["index"][k])
            fid = f"{clip}_f{f:05d}"
            clip_rows.append(dict(frame_id=fid, clip=clip, t=round(t, 3), frame=f, split=split, kind=kinds[k],
                                  width=track["full"][0], height=track["full"][1],
                                  sharp_rel=round(float(track["sharp"][k]) / n["ref_sharp"], 2),
                                  file=f"frames/{clip}/{fid}.jpg"))
        if not args.dry_run:
            write_frames(wt, path, clip, clip_rows, common.FRAMES, args.quality)
        rows += clip_rows
        by = collections.Counter((r["split"], r["kind"]) for r in clip_rows)
        report.append((clip, track["t"][-1] - track["t"][0], len(holds), n["periodic"], n["blurry"],
                       n["duplicates"], gaps, by, time.time() - t0))
    if not args.dry_run:
        common.write_manifest(rows)
    print("| clip | seconds | hold keyframes | periodic candidates | blurry | near-duplicates | at a train/val "
          "boundary | kept: split / kind | time |")
    print("|---|---|---|---|---|---|---|---|---|")
    for clip, dur, holds, per, blur, dup, gaps, by, sec in report:
        kept = ", ".join(f"{s} {k} {v}" for (s, k), v in sorted(by.items()))
        print(f"| {clip} | {dur:.0f} | {holds} | {per} | {blur} | {dup} | {gaps} | {kept} | {sec:.0f} s |")
    total = collections.Counter(r["split"] for r in rows)
    print(f"\n{len(rows)} frames: " + ", ".join(f"{s} {total[s]}" for s in ("train", "val", "test")) +
          ("  (dry run: nothing written)" if args.dry_run else f"\nmanifest: {common.MANIFEST}"))


if __name__ == "__main__":
    main()
