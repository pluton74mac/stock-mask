# Anti-double-count simulation

Why this exists: the v1 PRD's rule was "a new detection overlapping an existing instance
volume above a threshold is the same instance" (TR-3). This simulation checks that rule, and the
alternatives, against realistic shelf geometry, measurement noise and tracking drift *before* any
app code is written.

- Results: [`RESULTS.md`](RESULTS.md)
- Decision it informs: [`docs/decisions/003-double-count.md`](../../docs/decisions/003-double-count.md)

## Run

```bash
pip install numpy scipy
python sim.py --seeds 20        # about 3 minutes; rewrites RESULTS.md
```

## Model

**World:**
- Racks are 1.8 m wide with 5 shelves.
- Shelves hold groups of 2–12 identical bottles (9 cm pitch), cans (7 cm) or 1–4 cases (36 cm).
- "Uniform" layout: every shelf is one endless row of the same bottle.
- "Identical" layout: every rack is a copy of rack 1.

**Counting:**
- Portrait views of 0.9 × 1.4 m, overlapping 50%, snaking over each rack. Each view is one
  hold-to-count commit.
- Objects cut by the frame edge are ignored, as the app will do.

**Detector:**
- 97% recall per view.
- Position noise per observation: 0.6 cm along the shelf, 0.6 cm vertically, 1.5 cm in depth.
  The "high" setting is 1.0 / 1.0 / 2.5 cm.
- Product suggestion 95% accurate, and consistently wrong for the same physical item.

**Tracking:**
- Random walk of about 3 mm per view while counting.
- Revisit pass with an extra uncorrected offset `d` in a random horizontal direction.
- Rack tags (S3, S6) reset the error to about 1 cm per rack and carry the rack's identity.

**Metrics:**
- % of true items counted more than once (double);
- % never counted (missed);
- for zone strategies, how many "possible miss" prompts the user sees, and how many of them
  are real.

## Strategies

| id | idea |
|---|---|
| S1 | v1 rule: suppress if any counted item of the class is within the gate |
| S2 | estimate view drift locally (±4.5 cm), then 1:1 Hungarian match |
| S2wide | S2 with ±15 cm search, i.e. "snap" drift away |
| S3 | S2 + rack tags |
| S4 | counted zones only: never auto-add inside a zone |
| S5 | S4 + S2 + prompts: **the chosen design** |
| S6 | S5 + rack tags |

## Known limits

- **No false positives or reflections, and misses are independent.** Real errors cluster.
- **Translation-only drift.**
- **Use it to rank designs, not to predict field accuracy.** Phase 0 gates G5 and G7 measure
  field accuracy on hardware.
