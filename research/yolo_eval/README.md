# YOLO evaluation: is Ultralytics worth a license?

Why this exists: [ADR 002](../../docs/decisions/002-detector.md) chose RF-DETR Nano because Ultralytics
YOLO is AGPL-3.0, and a closed-source app needs a paid Enterprise License to use it. This folder measures
what the license would buy:
- the counts on the second walk's real footage, against the reference counts;
- what the models ask of the phone: Core ML packages, Neural Engine placement and latency.

**Results: [`RESULTS.md`](RESULTS.md).**

## License hygiene (ADR 002)

- **Ultralytics stays in its own venv,** `venv/` here, which is git-ignored. Its weights, exports,
  settings and scratch keyframes go to `work/`, which is git-ignored too.
- **Only `yolo_detect.py`, `export_coreml.py` and `prompt_probe.py` import `ultralytics`.** They run only
  in that venv.
- **`walkthrough.py` never imports Ultralytics, and nor does anything the app will use.** It only knows
  the `yolo*` detector names and their thresholds. Without their cached detections it stops with "run
  research/yolo_eval/run.py first".
- **No usage analytics:** the scripts keep Ultralytics' settings in `work/config` with `sync` off.
- Venue footage and frames stay in git-ignored folders, as for the walkthrough.

## Files

| file | venv | what |
|---|---|---|
| `run.py` | walkthrough | fills walkthrough's detection cache with YOLO detections, then runs `walkthrough.py` |
| `yolo_detect.py` | Ultralytics | runs YOLO models on keyframes for `run.py` |
| `analyse.py` | walkthrough | the counts at three thresholds each, and box shapes of the cap and top detectors |
| `prompt_probe.py` | Ultralytics | text prompts against input size, for YOLOE and YOLO-World |
| `export_coreml.py` | Ultralytics | Core ML exports, and their agreement with PyTorch (`--parity`) |
| `coreml_bench.py` | any with coremltools 9 | package size, outputs, Neural Engine placement and latency on this Mac |
| `requirements.txt` | Ultralytics | the venv's pinned packages |

## How `run.py` gets YOLO into walkthrough's counts

```
walkthrough venv                                     Ultralytics venv
run.py: walkthrough.replay(same arguments)
        -> keyframes missing from the cache (.npy) -> yolo_detect.py -> .npz into the cache
run.py: walkthrough.py (same arguments)
        <- every YOLO detection cached; walkthrough never imports Ultralytics
```

- **It takes walkthrough.py's own arguments** and replays the video with them, so it gets exactly the
  keyframes walkthrough.py will use.
  - Then it runs walkthrough.py with the same arguments.
  - Only `--yolo-python`, `--device` and `--cache-only` are its own.
- **Why two processes:**
  - The replay must run on walkthrough's own OpenCV and numpy builds, or the hold trigger could pick
    other frames.
  - Ultralytics' Core ML export needs numpy 2.3; the walkthrough venv has 2.4.
  - A separate process keeps any import of Ultralytics out of the walkthrough venv.
  - They exchange the files walkthrough.py already reads: its detection cache.
- **The cache:** `research/walkthrough/out/.detcache/<video stem>-<video size in bytes>/<detector>-<shown
  threshold>/<frame>.npz`, with arrays `boxes` (x0 y0 x1 y1 in keyframe pixels), `scores` and `cls`.
  - Delete a detector's folders to run it again.
  - The thresholds live in `walkthrough.DETECTORS`; the models and prompts in `run.py`'s `YOLO_MODELS`.

## Reproduce

Needs the walkthrough setup ([`../walkthrough/README.md`](../walkthrough/README.md)) and the second walk's
clips in `research/walkthrough/videos/` (git-ignored): `w2-bay1.MOV`, `w2-bay2.MOV` and `w2-bay3.MOV`.
Run from the main checkout. A worktree has no venvs, videos or cache, and the cache is keyed by the
clips' file names.

**1. The Ultralytics venv** (Python 3.11, [uv](https://docs.astral.sh/uv/)):

```bash
cd research/yolo_eval
uv venv --python 3.11 venv
uv pip install --python venv/bin/python -r requirements.txt
```

On first use, the weights download from Ultralytics' GitHub releases into `work/weights/`. That includes
the text encoders for the prompts: MobileCLIP2-B (254 MB) for YOLOE and CLIP ViT-B/32 (354 MB) for
YOLO-World.

**2. Counts on the three bays**: about 1–2 minutes a bay the first time (on an M5), under a minute from
the cache.

```bash
cd research/walkthrough
D=rfdetr,rfdetr_tiled,owlv2,owlv2_caps,yolo26n,yolo26s,yolo11n,yolo11s,yolo26n_seg,yoloe26s,yoloe26s_caps,yoloe26n_caps,yoloworld,yoloworld_caps,yoloworld_tops
venv/bin/python ../yolo_eval/run.py videos/w2-bay1.MOV --detectors $D --start 2.4 --carry track --truth bottle=82 --out out/w2-bay1-yolo
venv/bin/python ../yolo_eval/run.py videos/w2-bay2.MOV --detectors $D --start 3.2 --carry track --truth bottle=84 --out out/w2-bay2-yolo
venv/bin/python ../yolo_eval/run.py videos/w2-bay3.MOV --detectors $D --start 2.2 --carry track --truth bottle=68,can=22 --out out/w2-bay3-yolo
```

Each writes walkthrough's usual report, contact sheets and pictures to `out/w2-bayN-yolo/`. The settings
are those of walkthrough RESULTS.md sections 16 and 17.

**3. Thresholds and box shapes** (about a minute a bay):

```bash
venv/bin/python ../yolo_eval/analyse.py w2-bay1 --start 2.4 --truth 82 --json out/w2-bay1-analysis.json
venv/bin/python ../yolo_eval/analyse.py w2-bay2 --start 3.2 --truth 84 --json out/w2-bay2-analysis.json
venv/bin/python ../yolo_eval/analyse.py w2-bay3 --start 2.2 --truth 68 --json out/w2-bay3-analysis.json
```

**4. Prompts**: are "bottle cap" and the other wordings a model problem or an input-size problem? This
runs on every third bay 2 keyframe:

```bash
cd ../yolo_eval
venv/bin/python prompt_probe.py "../walkthrough/out/w2-bay2-yolo/cvat/images/*.jpg"
```

**5. On the phone, as far as a Mac can tell** (a few minutes):

```bash
venv/bin/python export_coreml.py                    # work/exports/*.mlpackage
venv/bin/python coreml_bench.py work/exports/*.mlpackage --image ../walkthrough/out/w2-bay2-yolo/cvat/images/commit_005.jpg
venv/bin/python export_coreml.py --parity "../walkthrough/out/w2-bay*-yolo/cvat/images/*.jpg"
```

- `coreml_bench.py` reads Core ML's compute plan (`MLComputePlan`), which places each op on this Mac's
  Neural Engine, GPU or CPU, and times the package. No Xcode needed.
- **The iPhone needs Xcode and the device** (P0-3).

**RF-DETR Nano on the same footing** (Apache-2.0, in its own venv, no Ultralytics):

```bash
uv venv --python 3.11 work/rfdetr-venv
uv pip install --python work/rfdetr-venv/bin/python torch==2.7.0 torchvision==0.22.0 rfdetr==1.11.0 coremltools==9.0 numpy==2.3.5
work/rfdetr-venv/bin/python -c "from rfdetr import RFDETRNano; RFDETRNano().export(format='coreml', coreml_precision='float16', output_dir='work/exports-rfdetr')"
work/rfdetr-venv/bin/python coreml_bench.py work/exports-rfdetr/rfdetr-nano_fp16.mlpackage
```

## Adding a model

1. Add it to `YOLO_MODELS` in `run.py`: weights, and COCO classes or text prompts.
2. Add its shown and counted thresholds to `DETECTORS` in `walkthrough.py`. A `yolo` prefix gets
   walkthrough's "run research/yolo_eval/run.py first" message.
3. Run `run.py` with it in `--detectors`.
