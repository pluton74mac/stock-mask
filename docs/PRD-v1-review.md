# Review of PRD v1.0: what was challenged, and why

Reviewer: Claude (acting as product/tech owner) · 25 September 2026

The v1 draft's product idea holds up: walk the storeroom, keep what's been counted visible and
persistent, leave with a list. What failed review is several claims and most of the mechanism.
Each row below states the v1 claim, what the evidence says, and what v2 does instead.

Evidence comes from five research passes (sources linked inline) and two experiments run for this
review:
- [`research/coreml_export`](../research/coreml_export/RESULTS.md): converting the candidate
  detectors to Core ML;
- [`research/dedup_sim`](../research/dedup_sim/RESULTS.md): a Monte-Carlo comparison of
  anti-double-count strategies under tracking drift.

Verdict key: ✅ holds · ⚠️ partly / needs qualifying · ❌ wrong or unsupported · 🔬 unverified; turned into a test.

## Market and problem claims

| # | v1 claim | Verdict | Evidence | v2 change |
|---|---|---|---|---|
| 1 | The storeroom walk is "the slowest part of bar inventory." | 🔬 | No source splits stocktake time between storeroom and bar; every published timing is from a vendor or service ([Bar-i](https://blog.bar-i.com/10-organization-best-practices-for-effective-bar-inventory), [StocktakeUK](https://stocktakeuk.co.uk/pub-stocktakers/)). Sealed units are already fast with barcode scanning (BinWise: 10 bottles/min on a phone camera, 150+/min with a scanner [vendor claim]). | Hypothesis H1, tested in Phase 0 week 1 (P0-1). If it fails, stop and re-scope. |
| 2 | "Tenthing … one tenth of a 1 L bottle is more than two pours." | ✅ but irrelevant | 100 ml ÷ 44 ml (1.5 oz US pour) ≈ 2.3 pours. It argues for the partial-bottle feature, which v1 itself puts out of scope. | Removed from the problem statement. Partials stay in Phase 2. |
| 3 | Bar apps (WISK, Partender, Bar Patrol, Bar-i) "do not offer a live walkthrough with persistent 'already counted' masks." | ⚠️ | True for the 11 bar apps checked and for the 2025–26 AI entrants (BarOptix, BarGuard, Lixor: single-photo AI). Not a moat: NomadGo shipped live AR count overlays to 11,000 stores, and [Scandit MatrixScan Count](https://www.scandit.com/products/matrixscan-count/) sells AR "counted" check marks as an SDK. | Positioning rests on *trust in bar storerooms* (PRD §14), not on the AR effect. |
| 4 | NomadGo "proves the walk-and-scan model works." | ❌ | Starbucks announced it for 11,000+ stores (Sep 2025) and retired it in Apr–May 2026. Reported causes: similar products confused, steel reflections doubling counts, Wi-Fi drops wiping progress, weeks of retraining for new packaging, storage rearranged for the tool, staff recounting every scan. NomadGo then laid off much of its staff ([GeekWire](https://www.geekwire.com/2026/report-starbucks-scrapped-an-ai-inventory-tool-and-left-a-seattle-area-startup-blindsided/), [Fortune](https://fortune.com/2026/05/28/starbucks-quietly-retired-ai-inventory-agent-barista-complaints-hallucinations/), [TNW](https://thenextweb.com/news/starbucks-ai-inventory-tool-nomadgo-automated-counting-failure)). | It proves demand, and it gives us a failure list. PRD §12 is a pre-mortem mapping each failure to a design response. |
| 5 | Integrations: WISK, Backbar, Bar Patrol, Toast, Square. | ⚠️ | For Argentine venues the systems that matter are Fudo (42% in one Córdoba poll), Cucina, Mr. Comanda, Maxirest, Tango. Fudo imports stock only through its own `stock.xls` template ([help](https://soporte.fu.do/es/articles/11730943-importacion-de-stock)). | XLSX/CSV first. The template for whatever pilots use is Phase 2 priority #1. |
| 6 | Markets: "Argentina / Spanish-first UI, or English first?" | ⚠️ | Argentina was 82–88% Android over 2025–Aug 2026, with iOS at 17.9% in Aug 2026 ([StatCounter](https://gs.statcounter.com/os-market-share/mobile/argentina)). LiDAR is Pro-only. Spanish-language bar tools are scarce. | Spanish (es-419) + English from day one. Pilot on devices we provide. Market/platform decision after the pilot (Q1). |
| 7 | Citation markers in text ("inconsistent.72", "masks.82", "list.90") | ❌ | Leftovers from a generated draft, with no sources behind them. | Removed; sources are now links. |

## Product and UX claims

| # | v1 claim | Verdict | Evidence | v2 change |
|---|---|---|---|---|
| 8 | Detect and count cases, bottles, cans and **kegs** ("keg = 1 unit"). | ❌ for kegs | A full keg and an empty keg look identical ([Bar-i](https://blog.bar-i.com/what-are-the-four-main-ways-to-measure-draft-beer-kegs-and-which-one-fits-your-bar)), so a camera keg count would count empties as stock. | No keg class. Kegs are manual lines (a stepper). |
| 9 | The camera can count the storeroom. | ⚠️ | It sees front facings only. Stock sits several rows deep and in stacked or closed cases. "Just because a box is closed doesn't mean it's full" ([Barmetrix](https://www.barmetrix.com/blog/liquor-inventory)). Starbucks had to rearrange storage for NomadGo. | The app counts what it sees and asks for what it can't: `×N deep` per group, case stacks, manual lines. Closed cases count as full, and exceptions are corrected. |
| 10 | Auto-commit high-confidence units; per-item yellow tap-to-confirm for uncertain ones. | ❌ | Tapping individual bottles on a dense shelf one-handed while walking isn't workable. Committing per frame is what produces double counts (claim 16). | **Hold-to-count:** a steady hold of about 1 s (or a tap) commits the whole view as one group commit. Low-confidence detections are excluded unless tapped. |
| 11 | Green masks "rounded to the detected instance silhouette" (instance segmentation). | ❌ | A per-frame silhouette exists only while the object is being detected. Persistence needs a 3D proxy anyway, and segmentation adds a model, compute and Swift mask decoding. | 3D capsules/boxes anchored at each item, rendered at 60 fps. Detector only, no segmentation. |
| 12 | Case mode: count a carton as 1 case or explode it into units (user default). | ⚠️ | Unnecessary: the export can carry both. | Always count cases as cases. Export `full_cases` and `total_units`. |
| 13 | Finish is blocked while yellow (unconfirmed) detections remain. | ❌ | Blocking on detections the model may have hallucinated trains users to dismiss everything. | Review has *blockers* (unnamed groups) and *warnings* (possible misses, seen-but-uncounted items). |
| 14 | Coverage hint: warn about "large unscanned regions in the reconstructed space." | ❌ | The app can't know what it never saw. | Warn about what it did see but didn't count, plus racks with no commits (rack tags). |
| 15 | Brand auto-ID is a stretch goal; "embedding search against venue catalog photos." | ⚠️ | Zero-shot product retrieval reaches only 35–66% top-1 even with large models ([nyris 2026](https://arxiv.org/abs/2603.17186), [Cat2Real 2026](https://arxiv.org/abs/2607.09888)). **MobileCLIP weights have been research-only since 2025-08-28** ([license](https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS)). | "Name the group once, suggest next time", using Apple's built-in FeaturePrint, with DINOv2-S (Apache) as fallback. Case barcodes (GS1 puts them on carton sides) add strong suggestions. Never silent. See [ADR 004](decisions/004-sku-identification.md). |

## Technical claims

| # | v1 claim | Verdict | Evidence | v2 change |
|---|---|---|---|---|
| 16 | **TR-3:** "When a new detection overlaps an existing instance volume above threshold, treat as the same instance." | ❌ | In our simulation this rule double-counts **3.9% with zero revisit drift** (measurement noise and normal slow drift only) and **14% at 3 cm** of revisit drift. Bottles sit about 9 cm apart, so any gate that absorbs noise also merges neighbours. | Counted zones + local drift refinement + 1:1 matching + "possible miss" prompts: **0.0% double at ≤ 3 cm, 0.2% at 5 cm** ([ADR 003](decisions/003-double-count.md)). |
| 17 | "Spatial pose — not appearance — is the source of truth" (two identical shelves). | ⚠️ | Pose is the right primary key, but only if it is right. Relocalising onto an identical rack makes *every* pose-based rule silently skip about 50% of that rack (simulation). Stored anchors are only as good as the relocalisation. | Optional **rack tags**: printed markers with a unique identity. Gate G5 decides whether they are mandatory. |
| 18 | A session-level ARKit world map persists everything; relocalise after loss. | ⚠️ | ARKit revisit drift ranges from ≤ 1.5 cm (LiDAR iPhone, [MobileEgo 2026](https://arxiv.org/abs/2605.05945)) to 25–43 cm mean (iPhone 11, walk away and back, [Scargill 2021](https://arxiv.org/abs/2109.14757)). World maps degrade beyond about 200 m² and need similar lighting ([forum](https://developer.apple.com/forums/thread/723947), [WWDC18](https://nonstrict.eu/wwdcindex/wwdc2018/610/)). Without `sessionShouldAttemptRelocalization`, ARKit resets the origin a few seconds after tracking loss. | **One map per zone (room)**, anchors per commit, relocalisation enabled, counting paused while tracking is limited, and a drift alarm. |
| 19 | iOS 17+, LiDAR preferred; support non-LiDAR "with lower confidence." | ❌ | Non-LiDAR phones have no `sceneDepth`, no mesh, and much larger revisit drift (claim 18). Our dedup tolerates about 5 cm. | LiDAR-only for the MVP; iOS 18+ (all LiDAR devices run it). See [ADR 001](decisions/001-platform.md). |
| 20 | Detector classes: bottle, can, carton/case, keg; on-device Core ML. | ⚠️ | Keg removed (claim 8). The license was not considered at all. | RF-DETR Nano, Apache-2.0 ([ADR 002](decisions/002-detector.md)). |
| 21 | (Implied) Ultralytics YOLO as the model. | ⚠️ | Ultralytics: any model trained with its code "fall[s] under the AGPL-3.0" and needs an Enterprise License for closed-source use, even when trained from scratch ([license page](https://www.ultralytics.com/license)). Price is quote-only, about $4.5–5k/yr anecdotally ([#7440](https://github.com/orgs/ultralytics/discussions/7440)). If the license lapses you must stop distributing. We converted both YOLO26n and RF-DETR-N to Core ML in this review. | YOLO26n is the fallback only if RF-DETR-N fails the device benchmark. |
| 22 | Use Roboflow `supervision` (the user's question). | ⚠️ | MIT, useful and model-agnostic, but Python-only. Its trackers assume 2D motion; our objects are static in 3D and the camera moves. | Offline tooling only: datasets, evaluation, debug visualisation. |
| 23 | "≥ 20 FPS overlay." | ⚠️ | Mixes render rate and inference rate. | Render at 60 fps (30 when hot); detector ≥ 10 Hz; commit ≤ 300 ms. |
| 24 | "Battery ≤ 15% per 20-minute count on iPhone 15-class." | ❌ | The iPhone 15 has no LiDAR. No reliable public measurement exists for ARKit + LiDAR + ML. | Target ≤ 1%/min on iPhone 13 Pro, measured in Phase 0. |
| 25 | "Works in 50–300 lux"; "in-app torch toggle required." | ⚠️ | Tracking degrades when the scene is too dark; RoomPlan guidance is ≥ 50 lux. LiDAR itself doesn't care about light. Torch during an ARKit session is **not documented by Apple** (developers report it works if set after start). Walk-ins: lens fog on exit. Freezers are outside the 0–35 °C operating range. | Torch is verified in P0-9 with a fallback. Cold-room guidance added (PRD §9). |
| 26 | FR-4/FR-32: offline + later sync; venue account, staff PIN or magic link. | ❌ for MVP | A pilot of 3–5 venues with one phone each needs no backend. NomadGo lost counts to Wi-Fi drops. | Local-only (GRDB/SQLite), share-sheet export, opt-in diagnostic bundle. Supabase + PowerSync in Phase 2 ([ADR 005](decisions/005-storage-backend-export.md)). |
| 27 | CSV export "into Excel, Google Sheets…". | ⚠️ | Excel with Argentine regional settings expects `;` and a UTF-8 BOM ([Microsoft](https://support.microsoft.com/en-us/office/import-or-export-text-txt-or-csv-files-5250ac4c-663c-47ce-937b-339e391393ba)). A comma CSV opens as one column. Barcodes lose leading zeros. | XLSX + two CSV formats; barcodes as text. |
| 28 | Acceptance test: 80 full bottles + 6 cases, "±3 units before correction." | ⚠️ | Everything visible: no depth, no identical rows, no glass glare, no reflections, no dark corners. It would pass while the real storeroom fails. | Staged-room gate G7 (≥ 150 units, identical rows, 3-deep, stacked and open cases, steel surface, kill/relaunch) and pilot audits. |
| 29 | Success metrics (50% faster, < 2% double, < 5% missed, < 15% corrections). | ⚠️ | Right direction, but no measurement protocol, no trust metric, and no kill thresholds. "< 2% double" is lax for an inventory number. | PRD §5: stopwatch protocol, audited recounts, **hand-recount rate** (the Starbucks failure metric), kill signals, willingness to pay. |
| 30 | Phase 0 "2–4 weeks … prove persistence." | ✅ direction | Correct instinct: persistence is the crux. It needs numbers, plus the detector and the problem. | Four weeks, eight quantified gates (G1–G8), three parallel tracks ([`phase-0-plan.md`](phase-0-plan.md)). |

## What v1 got right, and v2 keeps

- The job: *walk once, see what's counted, don't count twice, leave with the list.*
- Positioning honesty: full sealed units first; partial bottles later; don't lead with "AI knows
  every whisky label."
- Human-in-the-loop as a requirement, not a crutch.
- On-device processing and no video upload.
- Export first, not replacing the venue's system.
- A persistence-first Phase 0 as go/no-go.
