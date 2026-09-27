"""Film a synthetic storeroom with known answers, to check walkthrough.py before real footage arrives.

Draws two racks of bottles, cans and cases (the geometry of research/dedup_sim) on a textured wall,
then films them with a virtual handheld phone: portrait, 30 fps, iPhone-style HEVC stored landscape
with a rotation flag. The script: steady holds in a snake over each rack, fast moves between them,
a 0.5 s pause that must not commit, and a revisit of rack 1 that must not add anything. Writes
VIDEO and VIDEO.truth.json (every object's box, the canvas-to-frame transform of every frame, and
the scripted holds).

--check runs walkthrough.py with the oracle detector (the true boxes, no detector errors) and
compares it with the same counting rules applied to the true geometry:
  - exactly one commit per scripted hold, 0.8 s into it, and none for the short pause;
  - per commit, the same new / already counted / possible miss / edge split;
  - the revisit adds nothing.
Any difference is an error in hold detection, video orientation, registration or matching.

    python make_test_video.py out/synth.mp4 --check
    python make_test_video.py out/photo.mp4 --image shelf.jpg   # pan over a real photo instead (no truth)
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import subprocess
import sys

import cv2
import numpy as np

W, H, FPS = 720, 1280, 30  # portrait frame
HFOV = 65.0  # across the long side, as walkthrough.py assumes
F_PX = (H / 2) / math.tan(math.radians(HFOV) / 2)
DIST = 1.2  # metres from the shelf fronts
PX_PER_M = F_PX / DIST  # canvas scale: 1 canvas px = 1 frame px at DIST
SIZES = {"bottle": (0.080, 0.30, 0.090), "can": (0.066, 0.12, 0.070), "case": (0.350, 0.30, 0.360)}  # w, h, pitch
SHELVES = (0.25, 0.65, 1.05, 1.45, 1.85)  # heights the items stand on, metres
RACK_W, RACK_GAP, MARGIN, TOP = 1.8, 0.5, 0.7, 2.5


def px(x_m: float, y_m: float) -> tuple:
    """Rack metres (x from rack 1's left edge, y up from the floor) to canvas pixels."""
    return (x_m + MARGIN) * PX_PER_M, (TOP - y_m) * PX_PER_M


def texture(rng, w, h, base) -> np.ndarray:
    """Printed-looking artwork: stripes, a logo and random letters."""
    img = np.full((h, w, 3), base, np.uint8)
    for _ in range(int(rng.integers(1, 4))):
        y, dy = int(rng.integers(0, h)), int(rng.integers(2, max(3, h // 6)))
        cv2.rectangle(img, (0, y), (w, y + dy), tuple(int(v) for v in rng.integers(0, 255, 3)), -1)
    cv2.circle(img, (int(rng.integers(w // 4, 3 * w // 4 + 1)), int(rng.integers(h // 4, 3 * h // 4 + 1))),
               int(max(3, min(w, h) * rng.uniform(0.15, 0.3))), tuple(int(v) for v in rng.integers(0, 255, 3)), -1)
    word = "".join(rng.choice(list("ABCDEFGHKLMNPRSTVXZ"), int(rng.integers(3, 7))))
    cv2.putText(img, word, (2, int(h * rng.uniform(0.3, 0.9))), cv2.FONT_HERSHEY_SIMPLEX,
                max(0.25, w / 120), tuple(int(v) for v in rng.integers(0, 255, 3)), max(1, w // 60), cv2.LINE_AA)
    return img


def sprite(rng, cls: str) -> tuple:
    """(image, mask) for one product: every unit of it looks the same."""
    w, h = (max(4, round(v * PX_PER_M)) for v in SIZES[cls][:2])
    img, mask = np.zeros((h, w, 3), np.uint8), np.zeros((h, w), np.uint8)
    if cls == "bottle":
        glass = [(40, 90, 30), (20, 70, 120), (170, 170, 160), (30, 30, 30)][int(rng.integers(0, 4))]
        neck, cap = max(3, w * 3 // 10), tuple(int(v) for v in rng.integers(0, 255, 3))
        pts = np.int32([[w // 2 - neck // 2, int(0.05 * h)], [w // 2 + neck // 2, int(0.05 * h)],
                        [w // 2 + neck // 2, int(0.25 * h)], [w - 1, int(0.38 * h)], [w - 1, h - 1],
                        [0, h - 1], [0, int(0.38 * h)], [w // 2 - neck // 2, int(0.25 * h)]])
        cv2.fillPoly(img, [pts], glass)
        cv2.fillPoly(mask, [pts], 255)
        cv2.rectangle(img, (w // 2 - neck // 2 - 1, 0), (w // 2 + neck // 2 + 1, int(0.07 * h)), cap, -1)
        cv2.rectangle(mask, (w // 2 - neck // 2 - 1, 0), (w // 2 + neck // 2 + 1, int(0.07 * h)), 255, -1)
        y0, y1 = int(0.48 * h), int(0.82 * h)
        img[y0:y1, 2:w - 2] = texture(rng, w - 4, y1 - y0, rng.integers(120, 255, 3))
        cv2.line(img, (w // 5, int(0.4 * h)), (w // 5, int(0.95 * h)), (230, 230, 230), max(1, w // 16))
    elif cls == "can":
        img[:] = texture(rng, w, h, rng.integers(60, 255, 3))
        cv2.rectangle(img, (0, 0), (w - 1, h // 12), (200, 200, 205), -1)
        cv2.rectangle(img, (0, h - h // 12), (w - 1, h - 1), (200, 200, 205), -1)
        mask[:] = 255
    else:
        img[:] = (60, 110, 165)  # cardboard, BGR
        art = texture(rng, int(0.7 * w), int(0.5 * h), (60, 110, 165))
        img[int(0.25 * h):int(0.25 * h) + art.shape[0], int(0.15 * w):int(0.15 * w) + art.shape[1]] = art
        cv2.rectangle(img, (0, 0), (w - 1, h - 1), (40, 70, 110), 2)
        mask[:] = 255
    return img, mask


def paste(canvas, img, mask, x0, y0):
    h, w = mask.shape
    roi = canvas[y0:y0 + h, x0:x0 + w]
    roi[mask > 0] = img[mask > 0]


def storeroom(rng) -> tuple:
    """Canvas with two racks, and the list of objects (class, sku, canvas box)."""
    cw, ch = round((2 * MARGIN + 2 * RACK_W + RACK_GAP) * PX_PER_M), round((TOP + 0.3) * PX_PER_M)
    noise = cv2.resize(rng.normal(0, 1, (ch // 40, cw // 40, 3)).astype(np.float32), (cw, ch),
                       interpolation=cv2.INTER_CUBIC)
    canvas = np.clip(np.array([150, 160, 170], np.float32) + 18 * noise + rng.normal(0, 6, (ch, cw, 3)),
                     0, 255).astype(np.uint8)
    for _ in range(90):  # marks on the wall and floor, so registration has something off the shelves too
        x, y = int(rng.integers(0, cw)), int(rng.integers(0, ch))
        c = tuple(int(v) for v in rng.integers(0, 255, 3))
        if rng.random() < 0.5:
            cv2.rectangle(canvas, (x, y), (x + int(rng.integers(20, 160)), y + int(rng.integers(20, 120))), c, -1)
        else:
            cv2.putText(canvas, "".join(rng.choice(list("0123456789ABCDEF"), 4)), (x, y), cv2.FONT_HERSHEY_SIMPLEX,
                        float(rng.uniform(0.6, 2.0)), c, 2, cv2.LINE_AA)
    skus = {c: [sprite(rng, c) for _ in range(n)] for c, n in (("bottle", 30), ("can", 8), ("case", 8))}
    objects = []
    for r in range(2):
        x0 = r * (RACK_W + RACK_GAP)
        for side in (x0 - 0.04, x0 + RACK_W):  # uprights
            a, b = px(side, 2.2)
            cv2.rectangle(canvas, (int(a), int(b)), (int(a + 0.04 * PX_PER_M), int(px(0, 0)[1])), (70, 70, 80), -1)
        for y in SHELVES:
            a, b = px(x0, y)
            cv2.rectangle(canvas, (int(a), int(b)), (int(px(x0 + RACK_W, 0)[0]), int(b + 0.04 * PX_PER_M)),
                          (120, 125, 130), -1)
            x = 0.03
            while x < RACK_W:
                cls = str(rng.choice(["bottle", "bottle", "bottle", "can", "case"]))
                n = int(rng.integers(1, 5) if cls == "case" else rng.integers(2, 13))
                k = int(rng.integers(0, len(skus[cls])))
                img, mask = skus[cls][k]
                w_m, h_m, pitch = SIZES[cls]
                tag = px(x0 + x + 0.01, y)  # price tag on the shelf lip
                cv2.rectangle(canvas, (int(tag[0]), int(tag[1] + 2)), (int(tag[0] + 0.05 * PX_PER_M),
                              int(tag[1] + 0.035 * PX_PER_M)), (245, 245, 245), -1)
                cv2.putText(canvas, str(int(rng.integers(10, 99))), (int(tag[0] + 3), int(tag[1] + 0.03 * PX_PER_M)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (20, 20, 20), 1, cv2.LINE_AA)
                for j in range(n):
                    left = x + j * pitch
                    if left + w_m > RACK_W:
                        break
                    a, b = px(x0 + left, y + h_m)
                    a, b = int(round(a)), int(round(b))
                    paste(canvas, img, mask, a, b)
                    objects.append(dict(id=len(objects), cls=cls, sku=f"{cls}{k}",
                                        box=[a, b, a + mask.shape[1], b + mask.shape[0]]))
                x += n * pitch + rng.uniform(0.0, 0.10)
    return canvas, objects


def rack_views(r: int) -> list:
    """View centres (metres) snaking over rack r: bottom band left to right, top band back."""
    x0 = r * (RACK_W + RACK_GAP)
    half_w = (W / 2) / PX_PER_M
    xs = list(np.arange(x0 + half_w - 0.14, x0 + RACK_W - half_w + 0.14 + 1e-6, 0.45))
    if xs[-1] < x0 + RACK_W - half_w + 0.14 - 1e-6:
        xs.append(x0 + RACK_W - half_w + 0.14)
    return [(x, 0.80) for x in xs] + [(x, 1.42) for x in xs[::-1]]


def script(rng, stops: list, start) -> list:
    """(kind, from, to, seconds) segments in canvas pixels: a move to each stop, then a hold (or a
    short pause) there. Moves take at least 0.7 s at up to 0.6 m/s: well over 10 deg/s."""
    segs, here = [], np.array(start, dtype=float)
    for kind, c in stops:
        c = np.array(c, dtype=float)
        segs.append(("move", here, c, max(0.7, np.linalg.norm(c - here) / (0.6 * PX_PER_M))))
        segs.append((kind, c, c, 0.5 if kind == "pause" else float(rng.uniform(1.3, 1.9))))
        here = c
    segs.append(("move", here, here + [0.5 * PX_PER_M, 0.0], 1.0))
    return segs


def storeroom_stops() -> list:
    stops = [("hold", px(*v)) for v in rack_views(0)]
    stops += [("pause", px(RACK_W + RACK_GAP / 2, 1.1))]  # on the way to rack 2: too short to commit
    stops += [("hold", px(*v)) for v in rack_views(1)]
    stops += [("hold", px(x + 0.1, y)) for x, y in rack_views(0)[:3]]  # the revisit
    return stops


def render(canvas, segs, rng, video_path: str, rotate=True) -> dict:
    """Film the canvas along the script. Returns the truth: per-frame canvas-to-frame affine and holds."""
    frames, holds, pause, t = [], [], None, 0.0
    offset, roll, zoom = np.zeros(2), 0.0, 1.0
    raw = video_path + ".raw.mp4"
    ff = ffmpeg()
    size = f"{H}x{W}" if rotate else f"{W}x{H}"
    proc = subprocess.Popen([ff, "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", size,
                             "-r", str(FPS), "-i", "-", "-c:v", "libx265", "-x265-params", "log-level=error",
                             "-crf", "20", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", raw], stdin=subprocess.PIPE)
    for kind, a, b, dur in segs:
        n = max(1, round(dur * FPS))
        if kind == "hold":
            holds.append([round(t, 3), round(t + n / FPS, 3)])
            zoom = float(rng.uniform(0.95, 1.05))  # step a little closer or further for each hold
        elif kind == "pause":
            pause = [round(t, 3), round(t + n / FPS, 3)]
        for f in range(n):
            subs = []
            for s in np.linspace(0, 0.5, 4) if kind == "move" else (0.0,):  # motion blur while moving
                u = (f + s) / n
                u = 3 * u * u - 2 * u * u * u if kind == "move" else 0.0
                subs.append(a + (b - a) * u)
            if kind != "move":  # hand tremor: a leaky random walk of about 1 px per frame
                offset = 0.85 * offset + rng.normal(0, 1.0, 2)
                roll = 0.9 * roll + rng.normal(0, 0.0005)
            imgs, A = [], None
            for cx, cy in subs:
                R = np.array([[math.cos(roll), -math.sin(roll)], [math.sin(roll), math.cos(roll)]]) * zoom
                A = np.hstack([R, (np.array([W / 2, H / 2]) + offset - R @ [cx, cy])[:, None]])
                imgs.append(cv2.warpAffine(canvas, A, (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE))
            img = np.mean(imgs, axis=0) if len(imgs) > 1 else imgs[0].astype(np.float32)
            img = np.clip(img + rng.normal(0, 2.0, img.shape), 0, 255).astype(np.uint8)
            frames.append(A.ravel().round(5).tolist())  # the transform at the start of the exposure
            proc.stdin.write((cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE) if rotate else img).tobytes())
            t += 1 / FPS
    proc.stdin.close()
    proc.wait()
    if rotate:  # stored landscape, displayed portrait: what an iPhone held upright writes
        subprocess.run([ff, "-loglevel", "error", "-y", "-display_rotation", "-90", "-i", raw, "-c", "copy",
                        video_path], check=True)
    else:
        os.replace(raw, video_path)
    if os.path.exists(raw):
        os.remove(raw)
    return dict(affine=frames, holds=holds, pause=pause)


def ffmpeg() -> str:
    import imageio_ffmpeg

    return imageio_ffmpeg.get_ffmpeg_exe()


def expected(truth: dict, frames: list, band: float) -> list:
    """The counting rules of walkthrough.count_2d applied to the true geometry: identities and
    zones are exact, so any difference comes from the pipeline."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from walkthrough import view_status

    A_all = np.array(truth["affine"]).reshape(-1, 2, 3)
    boxes = np.array([o["box"] for o in truth["objects"]], dtype=float)
    centre = np.stack([(boxes[:, 0] + boxes[:, 2]) / 2, (boxes[:, 1] + boxes[:, 3]) / 2], 1)
    band_px = band * min(W, H)
    counted, zones, out = set(), [], []
    for f in frames:
        A = A_all[f]
        x0, y0, x1, y1 = boxes.T
        corners = np.stack([np.stack([x, y], -1) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))], 1)
        p = corners @ A[:, :2].T + A[:, 2]
        fb = np.clip(np.concatenate([p.min(1), p.max(1)], 1), 0, [W, H, W, H])
        vis = np.nonzero((fb[:, 2] - fb[:, 0] > 2) & (fb[:, 3] - fb[:, 1] > 2))[0]
        res = collections.Counter()
        for i, st in zip(vis, view_status(fb[vis], W, H, band_px)):
            if st == "cut":
                res["cut"] += 1
            elif i in counted:
                res["seen"] += 1
            elif any(cv2.pointPolygonTest(z, (float(centre[i, 0]), float(centre[i, 1])), False) >= 0 for z in zones):
                res["miss"] += 1
            elif st == "inner":
                counted.add(i)
                res["new"] += 1
            else:
                res["edge"] += 1
        inv = cv2.invertAffineTransform(A)
        inner = np.float32([[band_px, band_px], [W - band_px, band_px], [W - band_px, H - band_px], [band_px, H - band_px]])
        zones.append((inner @ inv[:, :2].T + inv[:, 2]).astype(np.float32).reshape(-1, 1, 2))
        out.append(res)
    return out


def check(video: str, truth_path: str) -> bool:
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.splitext(video)[0] + "_check"
    subprocess.run([sys.executable, os.path.join(here, "walkthrough.py"), video, "--detectors", "oracle",
                    "--out", out], check=True)
    s = json.load(open(os.path.join(out, "summary.json")))
    truth = json.load(open(truth_path))
    ok = True
    commits, holds = s["commits"], truth["holds"]
    print(f"\nholds scripted: {len(holds)}, commits: {len(commits)}")
    fired = [c["t"] for c in commits]
    for a, b in holds:
        hit = [t for t in fired if a - 0.25 <= t <= b]
        if len(hit) != 1 or abs(hit[0] - (a + 0.8)) > 0.25:
            print(f"  FAIL hold {a:.2f}-{b:.2f} s: commits at {hit}")
            ok = False
    p = truth["pause"]
    if any(p[0] - 0.25 <= t <= p[1] + 0.5 for t in fired):
        print(f"  FAIL a commit fired during the short pause {p}")
        ok = False
    if len(commits) != len(holds):
        print(f"  FAIL {len(commits)} commits for {len(holds)} holds")
        ok = False
    if ok:
        print("  one commit per hold, none for the pause: ok")
    band = s["settings"]["band"]
    exp = expected(truth, [c["frame"] for c in commits], band)
    tot_got, tot_exp, rows = collections.Counter(), collections.Counter(), []
    for c, e in zip(commits, exp):
        g = collections.Counter(c["detections"]["oracle"])
        tot_got.update(g)
        tot_exp.update(e)
        if any(g[k] != e[k] for k in ("new", "seen", "miss", "edge", "cut")):
            rows.append(f"  commit {c['n']:2d}: got " + " ".join(f"{k}={g[k]}" for k in ("new", "seen", "miss", "edge")) +
                        " | truth " + " ".join(f"{k}={e[k]}" for k in ("new", "seen", "miss", "edge")))
    print("per-commit differences from the true geometry:" if rows else "per-commit counts match the true geometry: ok")
    print("\n".join(rows))
    print(f"totals  got: {dict(tot_got)}\n      truth: {dict(tot_exp)}")
    n = len(truth["objects"])
    if abs(tot_got["new"] - tot_exp["new"]) > 0.01 * n or abs(tot_got["miss"] - tot_exp["miss"]) > 0.01 * n:
        print("  FAIL totals differ by more than 1% of the objects")
        ok = False
    revisit = commits[-3:]
    if sum(c["detections"]["oracle"].get("new", 0) for c in revisit) > 0.01 * n:
        print("  FAIL the revisit added items")
        ok = False
    naive = sum(c["detections"]["oracle"].get("new", 0) + c["detections"]["oracle"].get("seen", 0)
                for c in commits)
    print(f"objects on the racks: {n}; counted once: {tot_got['new']}; seen again later: {tot_got['seen']}; "
          f"sightings in all (roughly what summing views would give): {naive}")
    print("CHECK PASSED" if ok else "CHECK FAILED")
    return ok


def photo_canvas(path: str) -> np.ndarray:
    img = cv2.imread(path)
    if img is None:
        raise SystemExit(f"cannot read {path}")
    s = max(3.2 * W / img.shape[1], 1.7 * H / img.shape[0])
    return cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC)


def photo_stops(canvas) -> list:
    """Two bands of five views over the photo, then a revisit of the first two."""
    ch, cw = canvas.shape[:2]
    xs = np.linspace(W / 2 + 40, cw - W / 2 - 40, 5)
    ys = (H / 2 + 20, ch - H / 2 - 20)
    views = [(x, ys[0]) for x in xs] + [(x, ys[1]) for x in xs[::-1]] + [(x + 60, ys[0]) for x in xs[:2]]
    return [("hold", v) for v in views]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video", help="output video path (.mp4 or .mov)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--image", help="pan over this photo instead of the synthetic racks (no truth, no --check)")
    ap.add_argument("--no-rotate", action="store_true", help="store the frames upright, without a rotation flag")
    ap.add_argument("--check", action="store_true", help="then run walkthrough.py with the oracle and compare")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(os.path.dirname(os.path.abspath(args.video)), exist_ok=True)
    truth_path = os.path.splitext(args.video)[0] + ".truth.json"
    if args.image:
        canvas = photo_canvas(args.image)
        stops = photo_stops(canvas)
        segs = script(rng, stops, np.array(stops[0][1]) - [200, 0])
        render(canvas, segs, rng, args.video, rotate=not args.no_rotate)
        if os.path.exists(truth_path):
            os.remove(truth_path)
        print(f"wrote {args.video} ({sum(s[3] for s in segs):.0f} s)")
        return
    canvas, objects = storeroom(rng)
    segs = script(rng, storeroom_stops(), px(-MARGIN / 2, 1.1))  # start on the wall left of rack 1
    truth = render(canvas, segs, rng, args.video, rotate=not args.no_rotate)
    truth.update(frame_size=[W, H], fps=FPS, px_per_m=PX_PER_M, objects=objects)
    json.dump(truth, open(truth_path, "w"))
    cv2.imwrite(os.path.splitext(args.video)[0] + "_canvas.jpg", cv2.resize(canvas, None, fx=0.35, fy=0.35))
    print(f"wrote {args.video}: {len(truth['affine']) / FPS:.0f} s, {len(truth['holds'])} holds, "
          f"{len(objects)} objects ({collections.Counter(o['cls'] for o in objects)})")
    if args.check:
        sys.exit(0 if check(args.video, truth_path) else 1)


if __name__ == "__main__":
    main()
