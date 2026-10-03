"""Teachers for automatic labelling (autolabel.py): open-vocabulary detectors with Apache-2.0 code and weights, plus a
fine-tuned RF-DETR student in later rounds. No Ultralytics model (AGPL-3.0) labels training data (ADR 002).

  owlv2    google/owlv2-base-patch16-ensemble: walkthrough.py's prompts (bottle, beverage can, cardboard box, bottle
           cap) plus prompts for food tins, cartons and bags. One pass per frame; per class the maximum over its
           prompts. bottle, can, case, carton and bag compete for each box (the highest wins), as in the replay's
           owlv2 detector; bottle_top is scored on its own, like owlv2_caps. Cleaned like prelabel.py.
  gdino    IDEA-Research/grounding-dino-tiny: one pass with "bottle. bottle cap. tin can. cardboard box. carton. bag.".
           A phrase's score is the mean of its tokens' probabilities, so "bottle cap" needs both words and a whole
           bottle is not read as a cap. Per-class non-maximum suppression.
  student  an RF-DETR checkpoint from train.py (self-training rounds).

Every teacher keeps all boxes above a low floor (0.1) with their scores; autolabel.py chooses the thresholds.
Detections are cached per frame in ml/data/autolabel/teachers/<teacher>/<frame_id>.npz.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import common  # noqa: E402

FLOOR = 0.1
ROOT = common.DATA / "autolabel" / "teachers"
OWL_PROMPTS = {  # the first prompt of each of the first four classes is walkthrough.py's
    "bottle": ["a photo of a bottle"],
    "can": ["a photo of a beverage can", "a photo of a tin can"],
    "case": ["a photo of a cardboard box"],
    "carton": ["a photo of a carton", "a photo of a juice carton"],
    "bag": ["a photo of a bag", "a photo of a paper bag"],
    "bottle_top": ["a photo of a bottle cap"],
}
GDINO_PHRASES = {"bottle": "bottle", "bottle_top": "bottle cap", "can": "tin can", "case": "cardboard box",
                 "carton": "carton", "bag": "bag"}


def device():
    import torch

    return "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"


def nms(boxes: np.ndarray, scores: np.ndarray, iou=0.5) -> np.ndarray:
    """Indices kept by greedy non-maximum suppression."""
    order, keep = np.argsort(-scores), []
    while len(order):
        i = order[0]
        keep.append(i)
        rest = order[1:]
        if not len(rest):
            break
        ix = np.clip(np.minimum(boxes[i, 2], boxes[rest, 2]) - np.maximum(boxes[i, 0], boxes[rest, 0]), 0, None)
        iy = np.clip(np.minimum(boxes[i, 3], boxes[rest, 3]) - np.maximum(boxes[i, 1], boxes[rest, 1]), 0, None)
        inter = ix * iy
        a = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        b = (boxes[rest, 2] - boxes[rest, 0]) * (boxes[rest, 3] - boxes[rest, 1])
        order = rest[inter / np.maximum(a + b - inter, 1e-9) < iou]
    return np.array(keep, dtype=int)


class OWLv2Teacher:
    name = "owlv2"

    def __init__(self):
        import torch
        from transformers import Owlv2ForObjectDetection, Owlv2Processor

        self.torch, self.dev = torch, device()
        mid = "google/owlv2-base-patch16-ensemble"
        self.proc = Owlv2Processor.from_pretrained(mid)
        self.model = Owlv2ForObjectDetection.from_pretrained(mid).eval().to(self.dev)
        self.classes = list(OWL_PROMPTS)
        self.queries, self.owner = [], []
        for k, c in enumerate(self.classes):
            for p in OWL_PROMPTS[c]:
                self.queries.append(p)
                self.owner.append(k)
        import prelabel

        self.clean = prelabel.clean
        self.wt = common.walkthrough()

    def __call__(self, bgr: np.ndarray):
        from PIL import Image

        torch = self.torch
        h, w = bgr.shape[:2]
        inputs = self.proc(text=[self.queries], images=Image.fromarray(bgr[..., ::-1]), return_tensors="pt").to(self.dev)
        with torch.no_grad():
            out = self.model(**inputs)
        logits, boxes = out.logits[0].float().cpu(), out.pred_boxes[0].float().cpu()
        owner = torch.tensor(self.owner)
        per_class = torch.stack([logits[:, owner == k].max(-1).values for k in range(len(self.classes))], -1)
        prob = torch.sigmoid(per_class).numpy()  # (boxes, classes)
        side = max(h, w)  # OWLv2 pads to a square
        cx, cy, bw, bh = boxes.unbind(-1)
        xyxy = np.clip((torch.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], -1) * side).numpy(), 0,
                       [w, h, w, h])
        top = self.classes.index("bottle_top")
        whole = [k for k in range(len(self.classes)) if k != top]
        parts = []
        best = np.array(whole)[prob[:, whole].argmax(1)]  # bottle, can, case, carton and bag compete
        s = prob[np.arange(len(prob)), best]
        keep = s >= FLOOR
        parts.append(self.wt.Dets(xyxy[keep], s[keep], np.array(self.classes, dtype="<U10")[best[keep]]))
        keep = prob[:, top] >= FLOOR
        parts.append(self.wt.Dets(xyxy[keep], prob[keep, top], np.full(int(keep.sum()), "bottle_top", dtype="<U10")))
        d = self.wt.Dets.cat([self.clean(self.wt, p) for p in parts])
        return d.boxes, d.scores, d.cls.astype("<U10")


class OWLv2TilesTeacher(OWLv2Teacher):
    """OWLv2 on 2 x 2 overlapping tiles: twice the resolution for small objects such as caps (a 1080p frame reaches
    the full-frame model at 960 px). A box cut by an inner tile edge is dropped: the neighbouring tile or the
    full-frame teacher sees it whole."""

    name = "owlv2_tiles"

    def __call__(self, bgr: np.ndarray):
        h, w = bgr.shape[:2]
        tw, th = w / (2 - 0.25), h / (2 - 0.25)  # 25% overlap
        boxes, scores, cls = [], [], []
        for y0 in (0, round(h - th)):
            for x0 in (0, round(w - tw)):
                x1, y1 = min(w, round(x0 + tw)), min(h, round(y0 + th))
                b, s, c = super().__call__(bgr[y0:y1, x0:x1])
                b = b + [x0, y0, x0, y0]
                cut = ((b[:, 0] < x0 + 2) & (x0 > 0)) | ((b[:, 2] > x1 - 2) & (x1 < w)) | \
                      ((b[:, 1] < y0 + 2) & (y0 > 0)) | ((b[:, 3] > y1 - 2) & (y1 < h))
                boxes.append(b[~cut])
                scores.append(s[~cut])
                cls.append(c[~cut])
        b, s, c = np.vstack(boxes), np.concatenate(scores), np.concatenate(cls)
        keep = []
        for k in np.unique(c):  # the same object seen by two tiles
            m = np.nonzero(c == k)[0]
            keep += list(m[nms(b[m], s[m], 0.5)])
        keep = np.array(sorted(keep), dtype=int)
        return b[keep], s[keep], c[keep]


class GDINOTeacher:
    name = "gdino"

    def __init__(self, model_id="IDEA-Research/grounding-dino-tiny"):
        import torch
        from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

        self.torch, self.dev = torch, device()
        self.proc = AutoProcessor.from_pretrained(model_id)
        self.model = AutoModelForZeroShotObjectDetection.from_pretrained(model_id).eval().to(self.dev)
        self.classes = list(GDINO_PHRASES)
        self.text = ". ".join(GDINO_PHRASES[c] for c in self.classes) + "."
        ids = self.proc.tokenizer(self.text)["input_ids"]
        dot = self.proc.tokenizer.convert_tokens_to_ids(".")
        special = set(self.proc.tokenizer.all_special_ids)
        self.tokens, phrase = [[] for _ in self.classes], 0
        for pos, t in enumerate(ids):
            if t == dot:
                phrase += 1
            elif t not in special and phrase < len(self.classes):
                self.tokens[phrase].append(pos)

    def __call__(self, bgr: np.ndarray):
        from PIL import Image

        torch = self.torch
        h, w = bgr.shape[:2]
        inputs = self.proc(images=Image.fromarray(bgr[..., ::-1]), text=self.text, return_tensors="pt").to(self.dev)
        with torch.no_grad():
            out = self.model(**inputs)
        prob = torch.sigmoid(out.logits[0].float().cpu())  # (queries, text tokens)
        phrase = torch.stack([prob[:, t].mean(-1) for t in self.tokens], -1).numpy()  # (queries, classes)
        cls = phrase.argmax(1)
        s = phrase[np.arange(len(phrase)), cls]
        cx, cy, bw, bh = out.pred_boxes[0].float().cpu().unbind(-1)
        xyxy = np.clip((torch.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], -1)
                        * torch.tensor([w, h, w, h])).numpy(), 0, [w, h, w, h])
        keep = s >= FLOOR
        boxes, s, cls = xyxy[keep], s[keep], cls[keep]
        out_b, out_s, out_c = [], [], []
        for k, c in enumerate(self.classes):
            m = cls == k
            if m.any():
                i = nms(boxes[m], s[m], 0.5)
                out_b.append(boxes[m][i])
                out_s.append(s[m][i])
                out_c += [c] * len(i)
        if not out_b:
            return np.zeros((0, 4)), np.zeros(0), np.zeros(0, dtype="<U10")
        return np.vstack(out_b), np.concatenate(out_s), np.array(out_c, dtype="<U10")


class StudentTeacher:
    """A fine-tuned RF-DETR checkpoint (train.py), as a teacher for the next self-training round."""

    def __init__(self, checkpoint: Path, name: str):
        from rfdetr import RFDETR

        self.name = name
        self.model = RFDETR.from_checkpoint(str(checkpoint), trust_checkpoint=True)  # our own training output
        self.names = list(self.model.class_names)

    def __call__(self, bgr: np.ndarray):
        r = self.model.predict(np.ascontiguousarray(bgr[..., ::-1]), threshold=FLOOR)
        known = np.array([k < len(self.names) and self.names[k] in common.CLASSES for k in r.class_id], dtype=bool) \
            if len(r) else np.zeros(0, bool)
        cls = np.array([self.names[k] for k in r.class_id[known]], dtype="<U10")
        return r.xyxy[known], r.confidence[known], cls


def run(teacher, rows: list, log_every=25) -> None:
    """Run a teacher on every manifest row not cached yet."""
    import time

    import cv2

    folder = ROOT / teacher.name
    folder.mkdir(parents=True, exist_ok=True)
    todo = [r for r in rows if not (folder / f"{r['frame_id']}.npz").exists()]
    t0 = time.time()
    for n, r in enumerate(todo, 1):
        b, s, c = teacher(cv2.imread(str(common.DATA / r["file"])))
        np.savez(folder / f"{r['frame_id']}.npz", boxes=np.asarray(b, float).reshape(-1, 4), scores=np.asarray(s, float),
                 cls=np.asarray(c, dtype="<U10"))
        if n % log_every == 0 or n == len(todo):
            print(f"{teacher.name}: {n}/{len(todo)} frames, {(time.time() - t0) / n:.2f} s per frame", flush=True)


def load(name: str, frame_id: str):
    """(boxes, scores, classes) of one teacher on one frame."""
    z = np.load(ROOT / name / f"{frame_id}.npz")
    return z["boxes"], z["scores"], z["cls"]
