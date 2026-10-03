# StockMask: Product Requirements Document

| | |
|---|---|
| **Version** | 2.0, reviewed |
| **Owner** | Franco |
| **Date** | 25 September 2026 |
| **Status** | **Ready for Phase 0** (4-week technical spike + discovery). Phase 1 scope depends on the Phase 0 gates (§13). |
| **Supersedes** | v1.0 draft. Every change and the reason for it: [`PRD-v1-review.md`](PRD-v1-review.md) |
| **Platform** | iOS 18+, **LiDAR iPhones and iPads only** for the MVP. Android is decided after the pilot. |
| **Evidence** | Decision records in [`decisions/`](decisions/), experiments in [`../research/`](../research/) |

---

## 0. The review in one screen

**Kept.** The core idea is right:
- walk the storeroom with the camera;
- counted things turn green and stay green;
- a live list builds up, and you leave with it.

**Changed, because the evidence says the v1 design would fail:**
- **Counting happens when you hold the phone still on a shelf section (about 1 s), not on
  every frame.**
  - A per-bottle yellow tap-to-confirm doesn't work one-handed on dense shelves.
  - Per-frame auto-commit is what double-counts.
- **"Already counted" = counted zones + drift-corrected 1:1 matching**, not "3D overlap above a
  threshold."
  - In our simulation, v1's rule double-counts **4% even with zero revisit drift** and **14% at
    3 cm of drift**.
  - The new design: **0% up to 3 cm, 0.2% at 5 cm**
    ([ADR 003](decisions/003-double-count.md)).
- **The camera counts what it can see, including rows several deep by their tops; the user
  supplies what it can't** (no depth stepper since 2 October 2026):
  - kegs (full and empty look identical);
  - partial cases;
  - the product name, the first time.
- **Products are named by the user once per group, then suggested next time.** Never assigned
  silently.
- **Detector: RF-DETR Nano (Apache-2.0).** Ultralytics YOLO needs a paid Enterprise License for
  a closed-source app ([ADR 002](decisions/002-detector.md)).
- **No masks from segmentation.** Green 3D shapes are anchored in the room at each item's
  position, so they render at 60 fps and stick even when the detector isn't running.

**Cut from the MVP:**
- accounts;
- cloud sync;
- the keg detector class;
- the "case mode" toggle;
- "coverage of unscanned regions";
- blocking Finish on unconfirmed detections.

**Added:**
- a pre-mortem built on NomadGo's 2026 failure at Starbucks;
- quantified Phase 0 gates;
- optional printed **rack tags**;
- a photo record of every counted shelf;
- Spanish from day one;
- Excel exports that open correctly in Argentina.

**Challenged:**
- **"The storeroom is the slowest part of the stocktake."** Unverified, so it becomes hypothesis
  H1, tested in week 1.
- **"No competitor does this."** True for bar apps, but NomadGo shipped live AR counting to
  11,000 stores, and Scandit sells AR "counted" check marks.

---

## 1. Summary

StockMask turns a storeroom walk into a stocktake.

1. The counter holds the phone on each shelf section for about a second.
2. The app counts the bottles, cans and cases it can see, paints them green in AR, and adds them
   to a live list.
3. Green stays green. Come back to a shelf later and nothing is counted twice.
4. The counter confirms only what a camera cannot know:
   - which product a new group is (once; the app remembers);
   - kegs and partial cases.
5. They leave with the list, and with a photo record of every shelf that was counted.

> **Walk the storage. Hold on each shelf. What's counted turns green and stays green.
> Leave with the list — and the photos to prove it.**

## 2. Problem

**What we know** (sources in [`PRD-v1-review.md`](PRD-v1-review.md)):
- **Manual stocktakes are slow and disliked.**
  - Stocktake services quote 4–8 h for a UK pub.
  - Vendors quote "6 labor-hours" and similar; every figure found is from a vendor or service,
    not independent.
- **Bar apps count one item at a time:** barcode, Bluetooth scale, tap-a-fill-level,
  shelf-to-sheet lists, voice. Their AI is used for invoices, not counting. None counts with a
  live camera.
- **Storerooms are hard for cameras:**
  - stock sits several rows deep and in stacked or closed cases;
  - "a closed box isn't necessarily full";
  - kegs can't be judged by eye.
- **Argentina specifics:**
  - The 1 L returnable bottle is 49% of Ambev's (Quilmes) Argentine beer sales (Ambev 20-F, FY2025).
  - Weekly paid audits exist (Sculpture Argentina), which shows people pay to get counts done.

**What we believe but have not verified.** These are the hypotheses Phase 0 tests:

| # | Hypothesis | Test | Pass mark |
|---|---|---|---|
| H1 | Storeroom full-unit counting is a large part of the pain | Time-and-motion at 5 venues (P0-1) | ≥ 45 min per count, or ≥ 30% of stocktake time, at ≥ 3 of 5 venues |
| H2 | Hold-and-name is much faster than the venue's current method | Pilot, same person, same room | Median ≤ 50% of baseline time by the 3rd count |
| H3 | Staff trust the green enough not to recount by hand | Pilot | Hand-recount rate < 10% of sessions by week 4 |
| H4 | Venues accept a 10–20 min one-time setup (catalog, rack tags) | Discovery interviews + pilot | ≥ 4 of 5 complete setup unaided |
| H5 | Bars will pay | Pilot close | ≥ 2 of 5 accept the paid offer |

If H1 fails, stop and rethink the wedge before building the MVP. Behind-bar partial bottles may
matter more, and they are a different product.

## 3. Users and jobs

| User | Situation | Job to be done |
|---|---|---|
| **Bar manager / assistant manager** (primary) | Owns ordering and the weekly or monthly count. Loses hours in the storeroom. | "When I count the storeroom, I want the phone to keep track of what's done so I finish faster and don't double-count, and leave with a list I can stand behind." |
| **Senior bartender / stock person** | Assigned to count; interrupted; dim light; cold walk-in | "Let me stop, get pulled away, come back, and see exactly where I was." |
| **Owner / multi-venue operator** | Wants consistent counts | "Give me a file I can drop into Excel or our POS, and photos if a number looks wrong." |

## 4. Product principles

1. **Trust over automation.**
   - Never add units the app can't show.
   - Never assign a product silently.
   - Every line has a photo.
   - At Starbucks, staff ended up recounting NomadGo's scans by hand, and the tool was retired
     (§12).
2. **Count what's visible; ask for what isn't.** The camera counts rows several deep by their
   tops. Kegs and partial cases come from the user, and it's quick. The goal is a walk around the
   storeroom that ends with a counted stock sheet, with no depth to type in.
3. **Commit per shelf section, not per frame.** Counting happens on a steady hold or a tap, the
   way a camera shutter works.
4. **When in doubt, suggest; don't add.**
   - Inside counted areas the app only *suggests* additions.
   - If tracking looks off, it stops counting instead of guessing.
5. **Works in a basement.** No network, no login, and no count is ever lost.
6. **Simple is king.** One phone, one person, one list, one export.

## 5. Goals, non-goals and success metrics

**Goals (MVP):**
1. A storeroom count in ≤ 50% of the venue's current time, from the venue's third count onward.
2. A count that is correct after a short review: ≤ 0.5% double-counted, ≤ 1% missed.
3. No data loss, fully offline.
4. An export that goes straight into the venue's spreadsheet or POS import.

**Non-goals (MVP):**
- telling open bottles from sealed ones, or reading fill levels: every bottle the camera sees
  counts as one unit (decided 2 October 2026);
- a "more behind?" prompt for stock hidden behind what the camera sees (decided 2 October 2026);
- kegs by camera;
- POS integration beyond file export;
- purchase orders;
- two people counting the same zone;
- brand recognition without the user naming groups;
- Android;
- accounts or cloud.

**Pilot metrics:**

| Metric | Target | Kill signal | How it's measured |
|---|---|---|---|
| Storeroom count time vs baseline | ≤ 50% of baseline (3rd count onward) | > 70% | Stopwatch: same counter, same storeroom, *including* naming and review |
| Unit accuracy after review | ≥ 99% | < 97% | Audit: we recount 3 random racks per session by hand |
| Product-line accuracy after review | ≥ 97% of lines exact | < 93% | Same audit |
| Double counts | ≤ 0.5% of units | > 2% | Audit + app log of revisited zones |
| Hand-recount rate (trust) | < 10% of sessions by week 4 | > 30% | Ask after every session; observe |
| Review time | ≤ 5 min per 300 units | > 15 min | Local app timing |
| Sessions exported | ≥ 90% | < 70% | Local app log |
| Continued use | ≥ 3 of 5 venues do ≥ 4 counts without us present | ≤ 1 of 5 | Pilot tracking |
| Willingness to pay | ≥ 2 of 5 accept the paid offer | 0 of 5 | Pilot close |

The Phase 0 engineering gates (detector, depth, revisit error, end-to-end) are in §13 and
[`phase-0-plan.md`](phase-0-plan.md).

## 6. Scope

**In the MVP:**
- venue, zones and catalog (manual entry, or CSV/XLSX import);
- optional printed rack tags;
- camera counting of **bottles, cans and closed cases** on shelves, pallets and floor stacks;
- open cases counted from above;
- hold-to-count commits;
- counted zones and a green AR overlay that persist across revisits and app restarts;
- "possible miss" suggestions;
- a drift alarm;
- groups named once, then suggested (teach-once + case barcodes);
- manual lines (kegs, partial cases, closed cupboards);
- a live list over the camera;
- review, lock, and XLSX/CSV export via the share sheet;
- a photo per counted section;
- session history;
- an opt-in diagnostic bundle;
- Spanish (es-419) and English.

**Out of the MVP:**
- open-bottle detection and fill levels (an open bottle counts as one unit);
- a "more behind?" prompt for hidden stock;
- kegs by camera;
- empties/returnables detection (the user removes them);
- multi-device merge;
- accounts, cloud, web dashboard;
- POS APIs;
- PAR levels;
- Android.

**Phase 2 candidates, in the order we expect to need them:**
1. Export templates for the pilots' systems (e.g. Fudo's `stock.xls`).
2. Session merge across devices.
3. Backend (Supabase + PowerSync) and a web view.
4. PAR / below-par flags.
5. An open-bottle counter that estimates each open bottle's liquid level.
6. An "empty bottle / crate" class.
7. Android, if the market requires it (ADR 001).

## 7. Core journey (MVP)

**One-time setup (10–20 min):**
1. Create the venue and zones: e.g. *Depósito*, *Cámara*, *Seco*.
2. Import the product list (CSV/XLSX), or start empty and add products while counting.
3. Optional, but recommended for big or repetitive rooms: print rack tags from the app and stick
   one on each shelving unit.

**Each count:**
1. **Start count** → choose zone → full-screen camera. The list button shows `0 units · 0 products`.
2. Point at a shelf section. **Yellow outlines** show what the camera sees.
3. **Hold still about 1 s**, or tap the shutter.
   - The section flashes, then turns **green**.
   - One haptic tick, and a `+14` toast.
   - A small card slides up.
4. **The card lists the groups.** Confirm each with one tap, or ignore it and fix it later. Example:
   - `8 × bottle → Jameson 700 ml ✓`
   - `6 × bottle → name it`
   - `3 × case → Quilmes 1 L ×12 ✓ (barcode)`
5. **Move on.**
   - Counted items stay green when you come back.
   - An **amber "+"** marks something inside a counted area that doesn't look counted: tap to add.
6. **Kegs, partial cases, closed cupboards:** tap **+ Add manually** (product search + stepper).
7. **Walk-in next:** switch zone. The app loads that room's map.
8. **Finish → Review.** Fix anything flagged, then lock and export:
   - groups still unnamed;
   - leftover possible misses;
   - racks or zones with no counts;
   - totals per product, with photos.

**Interruptions:**
- **Tracking lost:** counting pauses, and the app says "Point at a shelf you already counted" (or
  "a rack tag").
- **App killed or phone died:** reopen, and the session resumes with its map and list.

## 8. Functional requirements

Priority: **M** = must have for the pilot, **S** = should have, **C** = could have.

### 8.1 Venue, zones, catalog
| ID | Requirement | P |
|---|---|---|
| FR-1 | Venue: name, country (sets default language and CSV format), units (ml). | M |
| FR-2 | Zones: named storage areas; each has its own spatial map. | M |
| FR-3 | Product (SKU): code, name, brand, category, size_ml, units_per_case, unit barcode, **case GTIN**. Created or edited in app, including mid-count. | M |
| FR-4 | Import products from CSV/XLSX with column mapping; flag duplicates. | M |
| FR-5 | **Rack tags:** generate a printable PDF of unique A6 tags; each is assigned to a zone and a rack name, and detected automatically in the camera. | S (M if gate G5 fails) |

### 8.2 Sessions
| ID | Requirement | P |
|---|---|---|
| FR-6 | Start a session: venue, counter name, zones. One active session per device. | M |
| FR-7 | Every commit and edit is saved immediately, in its own transaction. Killing and relaunching the app resumes map + list with no loss. | M |
| FR-8 | Pause, resume, switch zone at any time. | M |
| FR-9 | Finish → review → lock. A locked session is read-only; "Reopen" is allowed and logged. | M |
| FR-10 | Nothing in the app requires a network connection. | M |

### 8.3 Camera and counting
| ID | Requirement | P |
|---|---|---|
| FR-11 | Full-screen camera with overlays. Thumb-reachable controls: list button (badge: units · products), shutter, torch, zone, undo. | M |
| FR-12 | Live detection of `bottle`, `can` and `case` at 0.5–2.5 m, shown as yellow outlines. An open bottle is a bottle: it counts as one unit, like a sealed one. | M |
| FR-13 | **Hold-to-count:** commit when the phone has been steady for about 0.8 s, at least one stable candidate is in view, and tracking is normal. The shutter always works. Auto-count can be switched off. | M |
| FR-14 | A commit counts only objects **fully inside the inner frame**. Objects cut by the frame edge wait for the next view. | M |
| FR-15 | One haptic, one green sweep and one `+N` toast per commit, never one per item. | M |
| FR-16 | Undo the last commit: 5 s snackbar, and also from the list. | M |
| FR-17 | Tap a green item: see its photo crop, group and product, and uncount it. Tap a group badge: edit product and quantity. | M |
| FR-18 | Low-confidence detections are dashed and excluded from auto-count; tap to include. | M |
| FR-19 | **Open case:** if units are detected inside a case's outline (seen from above), count the units, not the case. **Closed cases count as full**, and the counter corrects exceptions. | M |
| FR-20 | Counting pauses automatically, with the reason shown, when tracking is limited: relocalising, fast motion, too dark. | M |

### 8.4 "Already counted": persistence and anti-double-count
Design and evidence: [ADR 003](decisions/003-double-count.md).

| ID | Requirement | P |
|---|---|---|
| FR-21 | Each commit stores its counted items and a **counted zone**: the 3D region covered by the view's inner frame, at the items' depth. Both are anchored locally, to a per-commit ARAnchor or to a rack tag frame when one is in view. | M |
| FR-22 | **Inside counted zones nothing is auto-added.** Detections there are matched one-to-one to counted items after a local drift correction of at most half an item width. A detection with no match is shown as an amber **possible miss**; tap to add. | M |
| FR-23 | **Drift alarm:** if a view over counted zones has too many unmatched detections (start at 30%, tune in Phase 0): red banner, overlays fade, counting paused, prompt to re-anchor on a counted shelf or a rack tag. | M |
| FR-24 | One spatial map per zone. Save it after commits; restore it on zone entry and on relaunch. Relocalise after tracking loss instead of resetting. | M |
| FR-25 | Rack tags, when present, re-anchor that rack's zones and carry its identity. A relocalisation onto the wrong (identical) rack is detected and corrected as soon as the tag is in view. In tag mode, a rack's first commit waits until its tag has been seen. | S (M if G5 fails) |
| FR-26 | Revisited counted items and zones re-appear green, and quantities do not change. | M |

### 8.5 Groups, products, quantities
Design and evidence: [ADR 004](decisions/004-sku-identification.md).

| ID | Requirement | P |
|---|---|---|
| FR-27 | Each commit groups identical-looking items. Each group gets a suggestion: case barcode first, then teach-once match, else none. | M |
| FR-28 | The user confirms the suggestion, picks from the catalog (search), creates a product, or leaves "Unknown A". Naming can happen later, in the list or in review. **Every confirmation teaches the app.** | M |
| FR-29 | ~~Multipliers: `rows deep ×1…×10` per group; case stacks = visible faces × depth.~~ Removed on 2 October 2026: no depth multipliers. The camera counts the rows behind by their tops (ADR 006's `bottle_top`, [walkthrough results §17](../research/walkthrough/RESULTS.md)). | – |
| FR-30 | Manual lines: any product + quantity (cases and/or units) in a zone. Used for kegs, partial cases, closed cupboards, anything the camera can't see. | M |
| FR-31 | A product is never assigned without a user confirmation, whether by tap, by confirming the card, or by bulk-confirming in review. | M |

### 8.6 Live list
| ID | Requirement | P |
|---|---|---|
| FR-32 | A bottom sheet over the running camera. Lines by product show full cases + loose units, zone, source (camera/manual), flags and photos. | M |
| FR-33 | Search; filter by zone, "needs review" and "unknown". | M |
| FR-34 | Edit quantity; delete a line (its green overlays disappear); split or merge groups; add manually. | M |

### 8.7 Review, finish, export
| ID | Requirement | P |
|---|---|---|
| FR-35 | **Review screen:** <ul><li>Blockers: groups not yet named. Name each one, or mark it "unknown" deliberately.</li><li>Warnings: possible misses left; items seen but never counted; zones or racks with no counts.</li><li>Totals, with a photo per line.</li></ul> | M |
| FR-36 | Export **XLSX + CSV** through the share sheet, with the columns in [ADR 005](decisions/005-storage-backend-export.md). Two CSV formats: "Excel (Argentina)" (UTF-8 BOM, `;`) and "standard" (`,`). Barcodes as text; formula-injection safe. | M |
| FR-37 | Optional evidence ZIP: one photo per commit, with boxes drawn. | S |
| FR-38 | Session history. Locked sessions are read-only; reopening is logged. | M |

### 8.8 Improving the model
| ID | Requirement | P |
|---|---|---|
| FR-39 | Opt-in **diagnostic bundle** per session: keyframes, detections, user corrections, database. Faces are blurred before export. | S |
| FR-40 | Capture mode (internal builds only) for dataset collection. | C |

## 9. UX requirements

**Visual language:**

| State | Looks like | Means |
|---|---|---|
| Candidate | thin yellow outline | seen; will be counted on the next hold |
| Low confidence | dashed yellow outline | not auto-counted; tap to include |
| Counted | green fill (35–45% opacity), brighter 2–3 px edge, drawn on a 3D capsule or box anchored at the item; group badge `×8` | in the list |
| Counted zone | faint green tint over that shelf area | this area is done |
| Possible miss | amber "+" | looks uncounted inside a done area; tap to add |
| Drift | red banner, overlays fade | counting paused; re-anchor |

The green shapes are anchored in 3D and rendered every frame (60 fps), so they stay stuck to the
bottles whether or not the detector is running. This replaces v1's per-frame silhouette masks,
which would only exist while an object is being detected.

**Ergonomics:**
- One-handed. Shutter, list and undo are within thumb reach.
- Targets ≥ 60 pt; the main loop needs no precise taps (gloves, wet hands).
- High-contrast overlays that read in a dim storeroom and a bright walk-in.
- Large-text mode for the list.

**Environment:**
- **Light:** tracking needs about ≥ 50 lux. In-app torch; Phase 0 verifies it works during AR.
  Hints: "Too dark", "Move slower", "Too close / too far".
- **Walk-in coolers** (about 4 °C) are within the phone's 0–35 °C operating range, but drain
  the battery. Freezers (−18 °C) are outside it: count by manual lines.
- **Lens fog:** expect it when a chilled phone returns to a warm room. Suggest counting the
  walk-in last. Detect blur and show "Wipe the lens / wait a moment."

**Empty and error states:**
- "Point at products to start"
- "Tracking lost: point at a shelf you already counted"
- "This room looks different: choose zone / start new map"
- "Too dark: turn on torch"
- "Phone is hot: slowing down"

## 10. Non-functional requirements

| Area | Requirement |
|---|---|
| Devices | iPhone 12 Pro–18 Pro / Pro Max; iPad Pro 2020+. iOS 18+. The pilot runs on devices we provide. |
| Rendering | 60 fps AR view; 30 fps when thermal state is `serious`. |
| Detector | ≥ 10 detections per second in preview; p95 inference ≤ 60 ms with ARKit running, on iPhone 13 Pro (gate G3). |
| Commit latency | ≤ 300 ms from hold detected to green. |
| Session length | 30 min continuous without reaching `critical` thermal state. At `serious`, detector to 5 Hz and occlusion off. At `critical`, save and pause the camera. |
| Battery | Target ≤ 1% per minute of active counting on iPhone 13 Pro. Measured in Phase 0; there is no reliable public figure. (v1's "≤ 15% per 20 min on iPhone 15-class" referred to a phone without LiDAR.) |
| Durability | No lost commits across crash, force-quit or battery death. SQLite transaction per commit; map file rewritten atomically. |
| Privacy | All processing on the device. No video upload. Photos stay on the phone unless the user exports them. The diagnostic bundle is opt-in with a consent screen, and faces are blurred. |
| Localization | Spanish (es-419) and English from day one (String Catalogs). Number and CSV formats follow the venue's country, not the phone language. |
| Storage | ≤ 200 MB per session (keyframes about 300 KB each + map). Sessions older than 90 days can be archived. |
| App size | ≤ 150 MB (detector about 54 MB FP16; about 30 MB with 8-bit or 15 MB with 4-bit weight palettization if needed). |

## 11. Technical approach

Full reasoning is in the decision records. This section is what an engineer needs on day one.

```
ARSession (world tracking, sceneDepth, 1920×1440@60)
 ├─ every frame → RealityKit ARView: green proxies, zone tints, amber "+", yellow outlines
 ├─ ~10–15 Hz  → Detector (Core ML, RF-DETR-N FP16, .cpuAndNeuralEngine, one frame in flight)
 │               → Lifter: box → 3D point (high-confidence LiDAR pixels in the label band;
 │                 shelf-plane fallback for glass) → plausibility (size per class, on a support surface)
 │               → LiveTracks: 3D association across frames → stable candidates (≥ 3 hits)
 ├─ steady ~0.8 s or shutter → CommitEngine
 │     1. candidates fully inside the inner frame
 │     2. local drift refinement (±4.5 cm) + 1:1 Hungarian match against counted items
 │     3. inside counted zones: matched = green, unmatched = possible miss (never added)
 │        outside:              unmatched → new counted items
 │     4. group by FeaturePrint → SKU suggestion (case barcode > teach-once kNN)
 │     5. ARAnchor (or rack-tag frame) + counted zone + keyframe → one DB transaction → haptic
 ├─ tracking != normal → pause commits; relocalise (sessionShouldAttemptRelocalization = true)
 └─ after commits → save zone ARWorldMap (when mapping status is .extending/.mapped)
```

**Modules.** Keep `Core` free of ARKit so it is unit-testable on a Mac:

| Package | Responsibility |
|---|---|
| `StockMaskCore` | Domain model, GRDB persistence, catalog import, aggregation, XLSX/CSV export |
| `StockMaskAR` | Capture session, torch and thermal handling, Detector protocol + RF-DETR implementation, Lifter, LiveTracks, CommitEngine (port of simulation strategy S5), map store, rack tags |
| App (SwiftUI) | Screens: setup, camera HUD, commit card, list sheet, review, history, settings |
| `ml/` (Python) | Labelling pre-processing, `rfdetr` training, `supervision` eval, Core ML export + parity test |

**Data model.** SQLite via GRDB. UUID text keys; the append-only `event` table is the audit trail.

| Table | Key fields |
|---|---|
| `venue` | id, name, country, locale |
| `zone` | id, venue_id, name, sort, map_file |
| `rack_tag` | id, zone_id, name, image_id |
| `sku` | id, code, name, brand, category, size_ml, units_per_case, unit_barcode, case_gtin |
| `sku_example` | id, sku_id, featureprint_rev, embedding (blob), crop_file |
| `session` | id, venue_id, counter_name, status (open/review/locked), started_at, finished_at |
| `commit` | id, session_id, zone_id, anchor_id, rack_tag_id?, pose, keyframe_file, created_at, undone |
| `counted_zone` | id, commit_id, anchor-space bounds |
| `item` | id, commit_id, anchor-space position, class, confidence, group_id, crop_file, removed |
| `item_group` | id, session_id, sku_id?, label ("Unknown A"), confirmed |
| `manual_line` | id, session_id, zone_id, sku_id, full_cases, loose_units, note |
| `event` | id, session_id, ts, type, payload (JSON) |

**Line totals** = Σ over each product's groups of counted units, plus manual lines. Units and cases are converted with `units_per_case`, and the export carries both
`full_cases` and `total_units`.

**Tooling:**
- Xcode 26+, Swift 6, SPM.
- GRDB 7 (MIT).
- XLSX writer: libxlsxwriter (BSD) or XLKit (MIT).
- `rfdetr` (Apache-2.0).
- `supervision` (MIT).
- CVAT, self-hosted (MIT).

**License hygiene:**
- Apache/MIT only in the shipped app.
- No Ultralytics code or weights unless the Enterprise License is bought (ADR 002).
- No MobileCLIP weights (research-only; ADR 004).
- Legal check on Objects365-pretrained checkpoints before public launch.

## 12. Risks and pre-mortem

**NomadGo is the closest product ever shipped.** Starbucks announced it for 11,000+ stores in
Sept 2025 and **retired it in April–May 2026**. Staff were told to remove the shelf QR codes and
count by hand, and NomadGo laid off much of its staff ([GeekWire](https://www.geekwire.com/2026/report-starbucks-scrapped-an-ai-inventory-tool-and-left-a-seattle-area-startup-blindsided/),
[Fortune](https://fortune.com/2026/05/28/starbucks-quietly-retired-ai-inventory-agent-barista-complaints-hallucinations/),
[TNW](https://thenextweb.com/news/starbucks-ai-inventory-tool-nomadgo-automated-counting-failure)).
We treat that as our pre-mortem:

| What failed there | Why it would hit us | Our design response |
|---|---|---|
| Look-alike products miscounted or mislabelled | Bars have look-alike bottles: same brand, different size or flavour | No silent product assignment (FR-31). LiDAR size hint. A photo per line. |
| Reflections off steel fridges doubled counts (5 cartons → 10) | Walk-ins are steel; bottles are glass | 3D plausibility (objects rest on a support surface; depth consistent). Zones + 1:1 matching. Reflections labelled as negatives. Steel surface in the P0-8 test room. |
| Wi-Fi drops wiped count progress | Basements and walk-ins have no signal | No network dependency at all. One transaction per commit. Kill/relaunch test (G7). |
| Seasonal packaging needed up to 6 weeks of retraining | Labels change constantly | The detector knows only bottle / can / case. Products are taught by the user in one tap. No retraining per product. |
| Stores had to rearrange back-of-house storage | Bars won't | Count what's visible, including the tops of rows behind, plus manual lines. |
| Staff had to recount every scan | Same risk | Visible per-shelf result, undo, photos, conservative dedup. **Recount rate is a primary pilot metric.** |

**Other risks:**

| Risk | Impact | Mitigation / test |
|---|---|---|
| H1 false: the storeroom isn't where the pain is | Wrong product | Discovery week 1 (P0-1). Stop or re-scope before Phase 1. |
| Few LiDAR iPhones in Argentina (82–88% Android; iOS 17.9% in Aug 2026; LiDAR is Pro-only) | Can't scale on venues' own phones | Pilot on devices we provide. Market/platform decision after the pilot (Q1). |
| Drift on revisit larger than about 5 cm | Double counts | Drift alarm pauses counting. Rack tags. Gate G5. |
| LiDAR depth unreliable on glass | Items placed wrongly, then dedup errors | Label-band + high-confidence sampling + shelf-plane fallback. Gate G4. |
| Relocalising onto an identical rack | ~50% of that rack silently skipped (simulation) | Rack tags carry identity. Wrong-rack trials in G5. |
| RF-DETR too slow with ARKit | Laggy preview | Gate G3. Fallback: YOLO26n + Enterprise License (about $5k/yr, anecdotal). |
| Detector accuracy on real storerooms | Corrections eat the time savings | 1,500 → 4,000 → 10,000 labelled images. Unseen-venue holdout. Gate G2. |
| First count is slow (every group needs naming) | Bad first impression | Catalog import. Case barcodes. Say it plainly: the 3rd count is the benchmark. |
| Hidden units (rows deep, closed cases) | Under-count | Count the tops of the rows behind (`bottle_top`): on the second storeroom walk, tops took the count from about half the bottles to about seven eighths. Stock the camera can't see is not counted (decided 2 October 2026). Gates G2 and G7 include rows several deep. |
| Torch unavailable during ARKit | Can't count dark rooms | P0-9. Fallback: exposure bias + a clip-on light. |
| Heat and battery over 30 min | Forced stop | Thermal ladder (§10). Resume after pause. Measured in P0-3. |
| Photo sensitivity at venues | Resistance to the camera | On-device only. No upload. Opt-in bundle with face blur. |
| Objects365 in pretrained weights | Legal exposure | Legal opinion before public launch. Affects every modern detector. |

## 13. Roadmap and gates

**Phase 0: prove it (4 weeks).** Full plan: [`phase-0-plan.md`](phase-0-plan.md).

| Gate | Pass mark |
|---|---|
| G1 Problem | Storeroom counting ≥ 45 min, or ≥ 30% of stocktake time, at ≥ 3 of 5 venues |
| G2 Detector accuracy | Unseen-venue holdout: per-view count error ≤ 3% median, ≤ 8% p90; precision ≥ 98% at the commit threshold |
| G3 Detector speed | RF-DETR-N p95 ≤ 60 ms with ARKit on iPhone 13 Pro; never `critical` thermal state in 20 min |
| G4 Glass depth | Bottle lateral position error ≤ 2 cm median, ≤ 4 cm p95 |
| G5 Revisits | Markerless p95 revisit error ≤ 5 cm **and** 0 wrong-rack relocalisations in 20 trials. Else rack tags become mandatory. |
| G6-SKU | Teach-once top-3 ≥ 85% with 3 examples per product (FeaturePrint, else DINOv2-S) |
| G7 End-to-end | Staged room ≥ 150 units: double ≤ 1%, missed ≤ 1% after prompts, prompts ≤ 10%, relaunch restores in ≤ 10 s (5/5) |
| G8 Environment | Torch works in AR (or fallback documented); a 10-min walk-in session completes |

**Decision rules:**
- **G1 fails:** stop and re-scope.
- **G3 fails:** switch the detector (ADR 002).
- **G5 fails:** rack tags become mandatory.
- **G2, G4 or G7 fail:** one more 2-week iteration, then re-decide.

**Phase 1: MVP (about 8–10 weeks after Phase 0).** Everything marked M in §8, hardened:
- TestFlight external testing, with an ad hoc build kept as backup;
- Spanish + English;
- model v1 (≥ 4,000 images).

**Pilot (6–8 weeks).**
- 3–5 venues; weekly or biweekly counts; we provide the phones.
- Baseline timing at every venue before its first StockMask count.
- Metrics per §5; exit review at the end.

**Phase 2 (after a successful pilot):**
- POS/export templates;
- multi-device merge + backend;
- PAR flags;
- an open-bottle counter that estimates the liquid level;
- the market/platform decision (Android or English-speaking markets first).

**Phase 3:** variance vs sales, multi-venue dashboard, team permissions.

## 14. Competitive landscape (checked 2026-09-25)

| Product | How it counts | Relevance |
|---|---|---|
| WISK, Bar Patrol, Bar-i, Backbar, Craftable, BevSpot, MarketMan, Supy, Sculpture | Barcode, Bluetooth scale, tap, shelf-to-sheet, voice; AI only for invoices | No camera counting. They are also the export targets; don't fight them on costing. |
| BinWise / BinScan | Scan every bottle (10/min on the phone camera, 150+/min with a scanner, vendor figures) | Sealed units by barcode are already fairly fast. Our time advantage must beat *this*, not just a clipboard. |
| Partender | Tap the fill line on a bottle image | Partials only; iOS app last updated 2022 |
| BarOptix, BarGuard, Lixor (2025–26) | Photo AI: bottle ID / fill level from single photos | New AI entrants. No persistent walkthrough. |
| NomadGo | Live on-device AR scanning with count overlays; QSR, retail | Closest product; retired by Starbucks in 2026 (§12). Not in bars. |
| Scandit MatrixScan Count | AR check marks on barcodes counted in view | Proven UI pattern; needs visible barcodes, and bottle barcodes are on the back label |
| Pixoate, CountThings | Photo count → CSV | Generic still-image counters |

**Positioning.** The AR effect is not a moat; others have shipped it. What we win on is
**trust in a bar storeroom**:
- conservative counting;
- a photo record;
- offline by design;
- products taught in one tap;
- Spanish-first;
- exports that land in Argentine systems.

## 15. Open questions for Franco

| # | Question | Recommendation |
|---|---|---|
| Q1 | Pilot market: Argentina (access, Spanish, but mostly Android) or an iPhone-heavy market? | Pilot in Argentina on phones we provide. Decide the scale market after the pilot. |
| Q2 | Will venues accept printed rack tags? | Ask in P0-1. G5 decides whether tags are optional or required. |
| Q3 | Budget: 5–6 used LiDAR iPhones for the pilot; about $5k/yr if the detector fallback is needed | Approve before week 2 of Phase 0. |
| Q4 | Which system must the export feed first (Excel, Fudo, Maxirest, Tango)? | Answer from P0-1. Fudo needs its own `stock.xls` template (Phase 2). |
| Q5 | Price to test in the pilot close | Pick 2 price points before the pilot. |
| Q6 | Name: keep "StockMask"? | Keep as working name; trademark check before launch. |
| Q7 | Who counts in pilot venues: managers or staff? | Affects wording and training; ask in P0-1. |

**v1's open questions, answered by this review:**
- **Accuracy bar for v1?** Every bottle the camera sees counts as one unit, sealed or open. Fill
  levels come after the MVP, with an open-bottle counter (decided 2 October 2026).
- **Who assigns the product?** Count first, name the group once; the app suggests afterwards.
- **Case default?** Count cases as cases; the export carries both cases and units, so no toggle.
- **One phone or two?** One phone per session. Two phones can count different zones, with
  separate exports.
- **Integration?** XLSX/CSV first; system templates in Phase 2.
- **iPhone only for the pilot?** Yes, LiDAR models.
- **Language?** Spanish + English from day one.

## 16. Decision log

| # | Decision | Record |
|---|---|---|
| 001 | Native iOS, LiDAR-only, iOS 18+, RealityKit ARView; Android after the pilot | [ADR 001](decisions/001-platform.md) |
| 002 | RF-DETR Nano (Apache-2.0) as the detector; YOLO26n + license as fallback; `supervision` for offline tooling only | [ADR 002](decisions/002-detector.md) |
| 003 | Hold-to-count commits + counted zones + local drift refinement + 1:1 matching + possible-miss prompts + drift alarm; optional rack tags | [ADR 003](decisions/003-double-count.md) |
| 004 | Generic classes; the user names groups once; suggestions from case barcodes + FeaturePrint kNN; never silent | [ADR 004](decisions/004-sku-identification.md) |
| 005 | GRDB/SQLite, no backend in the MVP, XLSX + Argentina-ready CSV | [ADR 005](decisions/005-storage-backend-export.md) |
| 006 | Own data, CVAT, pre-labelling with Apache-licensed open-vocab models, unseen-venue holdout | [ADR 006](decisions/006-training-data.md) |
| – | Every bottle the camera sees counts as one unit, sealed or open. No open-bottle or fill-level detection in the MVP; an open-bottle counter that estimates the liquid level comes after it. (product owner, 2 October 2026) | [Walkthrough results §16](../research/walkthrough/RESULTS.md) |
| – | No "more behind?" prompt and no `×N deep` multiplier (FR-29 removed). The goal is a walk around the storeroom that ends with a counted stock sheet: the camera counts what it sees, including the rows behind by their tops. (product owner, 2 October 2026) | [Walkthrough results §16–17](../research/walkthrough/RESULTS.md) |
