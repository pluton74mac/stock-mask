# StockMaskCore

The data and export core of the MVP test app ([plan and contract](../../../docs/mvp-test-app.md)):
the domain model, its SQLite database, the counted stock sheet, catalog import and CSV/XLSX export.

- Pure Swift 6, iOS 18 and macOS 15. No ARKit, no UIKit: positions come in as `simd` values and
  photos as file paths, so the whole package is tested on a Mac.
- Independent of StockMaskCounting. The AR layer maps between them ([below](#for-the-ar-layer)).
- **One dependency: [GRDB.swift](https://github.com/groue/GRDB.swift) 7.11.1 (MIT)**, pinned with
  `exact:` ([ADR 005](../../../docs/decisions/005-storage-backend-export.md)). The XLSX writer, its
  ZIP container and CRC-32 are written here, so nothing else is needed.

```sh
app/scripts/swift-test.sh app/Packages/StockMaskCore    # 64 tests, about 1 s once built

# Also read the XLSX back with openpyxl (otherwise those 2 tests are skipped):
STOCKMASK_OPENPYXL_PYTHON=/path/to/python-with-openpyxl app/scripts/swift-test.sh app/Packages/StockMaskCore
```

## API

Everything goes through one `StockStore`. Records are plain `Sendable` structs.

| Area | Calls |
|---|---|
| Open | `StockStore.open(at:)` (the app's file), `StockStore.inMemory()` (previews, tests), `databaseReader` (GRDBQuery) |
| Venue, zones, catalog (FR-1–3) | `createVenue`, `venues`, `addZone`, `zones(venueID:)`, `renameZone`, `setZoneMapFile`; `createSKU`, `updateSKU`, `sku(id:)`, `skus(venueID:)`, `searchSKUs(venueID:matching:)`, `findSKU(venueID:barcode:)` |
| Sessions (FR-6–9, FR-38) | `startSession`, `activeSession`, `sessions(venueID:)`, `sessionZones`, `switchZone`, `finishSession`, `returnToCounting`, `lockSession`, `reopenSession(_:reason:)` |
| Counting (FR-7, FR-16–18, FR-22) | `saveCommit(CommitDraft) -> SavedCommit`, `undoLastCommit(sessionID:expecting:)`, `addItem(_:toCommit:groupID:)`, `addPossibleMiss(_:item:toGroup:)`, `dismissPossibleMiss`, `setItemRemoved(_:removed:)` |
| Groups and lines (FR-27–34) | `nameGroup(_:sku:)`, `markGroupUnknown`, `acceptSuggestions(groupIDs:)`, `groups(sessionID:)`, `items(inGroup:)`, `moveItems(_:toGroup:)`, `deleteLine(_:sessionID:)`, `addManualLine`, `updateManualLine`, `deleteManualLine`, `manualLines(sessionID:)` |
| Resume (FR-7) | `resumeActiveSession() -> SessionSnapshot?`, `snapshot(sessionID:)` |
| Sheet and review (FR-32, FR-35) | `stockSheet(sessionID:options:)`, `observeSheet(sessionID:options:)` (an async sequence for the live list), `StockSheet.fetch(db, sessionID:)` (inside your own GRDB read) |
| Catalog import (FR-4) | `planCatalogImport(venueID:csv:mapping:) -> CatalogImportPlan`, `applyCatalogImport(_:)`, `ColumnMapping.suggested(for:)`, `CSVReader.read(_:)` |
| Export (FR-36) | `StockSheetExport.csv(_:dialect:options:)`, `.xlsx(_:options:)` (each returns an `ExportFile`: name, data, MIME type), `.rows(_:layout:)`, `.columns`; `CSVDialect.excelArgentina`, `.standard`; `Venue.defaultCSVDialect` |
| Audit | `events(sessionID:)`, `events(venueID:)`, `recordEvent(_:sessionID:payload:)` for the app's own events (pause, resume, export, drift alarm) |

**Rules every call follows:**
- **One transaction per call.** When a method returns, the change is on disk; when it throws
  (`StoreError` or GRDB's `DatabaseError`), nothing changed. Each change writes its audit event in
  the same transaction.
- **Durable.** WAL with `synchronous = FULL` and `fullfsync`: every commit is synced, so it
  survives a crash, a force-quit or a dead battery (PRD §10). That is one flush per write: on an
  Apple-silicon Mac a 20-item `saveCommit` takes 1.8 ms (median; p95 2.7 ms). Measure it on the
  phone. A 400-line sheet built from 4,000 items takes about 35 ms.
- **Synchronous.** Call from a serial background queue, not a cancellable `Task` (ADR 005), and
  don't block the AR render loop on it.
- **A locked session is read-only** (`StoreError.sessionLocked`) until `reopenSession`, which is
  logged with its reason. Only `recordEvent` still works, so exports of locked sessions are logged.
- **One active session per device** (`StoreError.activeSessionExists`).
- **Lock needs every group named** or marked unknown (`StoreError.unnamedGroups(n)`).
- **Nothing is deleted but manual lines** (`deleteManualLine`, or `deleteLine` on a product), and
  their event keeps what they held. Undo and "uncount" only set flags. The event table refuses
  `UPDATE` and `DELETE`.

## For the AR layer

### Saving a commit

`CommitDraft` is StockMaskCounting's `CommitResult` plus what only the AR layer knows. **Keep the
engine's ids** (commit, items, zone): the engine, the overlays and the database then agree.

```swift
// Write the keyframe file first: the database must never point at a missing file.
let draft = CommitDraft(
    id: result.commitID, sessionID: session.id, zoneID: zone.id,
    anchorID: anchor.identifier,                 // ARAnchor(transform: result.zone.transform)
    pose: frame.camera.transform,
    keyframePath: "sessions/\(sid)/keyframes/\(cid).heic",   // relative path
    trigger: .hold,
    items: result.newItems.map { i in
        NewItem(id: i.id, cls: ItemClass(rawValue: i.cls.rawValue)!, position: i.position, top: i.top,
                productKey: i.productKey, confidence: i.confidence, detectionIndex: i.detectionIndex,
                groupKey: i.groupKey, cropPath: cropPaths[i.id])
    },
    groups: suggestions,                         // [NewGroup(key:suggestedSKUID:suggestionSource:)]
    countedZone: NewCountedZone(id: result.zone.id, transform: result.zone.transform,
                                halfExtents: result.zone.halfExtents),
    possibleMisses: result.possibleMisses.map { d in
        NewPossibleMiss(id: missID(for: d), cls: ItemClass(rawValue: detections[d].cls.rawValue)!,
                        position: detections[d].position, confidence: detections[d].score, detectionIndex: d)
    },
    matchedCount: result.matched.count, driftAlarm: result.driftAlarm)
let saved = try store.saveCommit(draft)   // saved.groups: label "A", counts, suggestion: the commit card
```

- **Positions** stay in AR world space, as the engine gives them. The commit's `ARAnchor` is
  created at the zone's transform; store its identifier as `anchorID`. Anchor moves are not
  stored: after a relaunch, pass each restored anchor to `engine.updateAnchor(ofCommit:to:)`.
- **`top`** is stored for every item, so a top seen alone after a relaunch still matches a bottle
  counted whole.
- **A `bottle_top` item is a bottle counted by its top.** It keeps its class in the database and
  counts as one bottle unit everywhere else: `SavedGroup.counts` folds it into `.bottle`
  (`ItemClass.countsAs`), and the sheet never has a line or a column for it.
- **Groups.** Items with the same `groupKey` form a group, labelled "A", "B"… in the session.
  Without a `groupKey` (no grouping yet, M1), items are grouped by kind per commit: bottles with
  tops, cans, cases. A suggestion (`NewGroup.suggestedSKUID`) is shown, never assigned (FR-31).
- **Product keys.** `SKU.productKey` is the `Int` for StockMaskCounting (`Detection.productKey`,
  `setProductKey`): the first 63 bits of the SKU's UUID, stable everywhere, so no mapping table is
  needed. `nameGroup`, `markGroupUnknown`, `moveItems`, `addItem` and `addPossibleMiss` set the
  items' `productKey` to their group's product (nil when it has none). Mirror it into the engine
  with `store.items(inGroup:)` and `engine.setProductKey`.
- **Possible misses.** Give a miss the same id again when you recognise it in a later commit (you
  know the anchors, so you can compare positions): an open miss moves to the new commit instead of
  being counted twice in review; one the user resolved stays resolved. On a tap, call
  `engine.addDetection` and pass the item it returns: `addPossibleMiss(missID, item:)`. Without
  it (after a relaunch the engine no longer has the commit's detections), the item is made from
  the stored miss. `dismissPossibleMiss` clears one.
- **Undo** both: `engine.undoLastCommit()` and `store.undoLastCommit(sessionID:expecting:)`, which
  refuses if the store's last commit isn't the one the snackbar shows. It returns the ids of the
  items, zone and misses whose overlays go.

### Relaunch (FR-7)

```swift
if let snap = try store.resumeActiveSession(), let zone = snap.currentZone {
    // Load zone.mapFile (the zone's ARWorldMap), then rebuild the engine, zones in commit order:
    let items = snap.items(inZone: zone.id).map { i in
        CountedItem(id: i.id, cls: ObjectClass(rawValue: i.cls.rawValue)!, position: i.position,
                    commitID: i.commitID, top: i.top, productKey: i.productKey,
                    confidence: i.confidence, detectionIndex: i.detectionIndex)
    }
    let zones = snap.countedZones(inZone: zone.id).map { z in
        CountedZone(id: z.id, commitID: z.commitID, transform: z.transform, halfExtents: z.halfExtents)
    }
    engine = CommitEngine(items: items, zones: zones)
    // snap.openPossibleMisses(inZone:) → amber "+"; store.observeSheet(...) → the list.
}
```

`SessionSnapshot` has everything a relaunch needs: the session (its status and current zone), the
venue's zones, the commits that still count, their zones and items, the groups, manual lines and
open possible misses. `snap.session.status == .review` means the session was in review when the
app stopped.

### Files

The database stores **paths relative to the app's data directory** (the container's absolute path
changes between installs). Suggested layout under Application Support: `stock.sqlite`,
`maps/<zone-id>.arworldmap`, `sessions/<session-id>/keyframes/<commit-id>.heic`,
`sessions/<session-id>/crops/<item-id>.jpg`. Write a file before the call that records it; a crash
in between leaves an orphan file, never a dangling path.

## Data model

PRD §11 without `depth_multiplier`. UUID keys stored as lowercase text; the only UNIQUE
constraint is the primary key (ADR 005). Timestamps are UTC text, `yyyy-MM-dd HH:mm:ss.SSS`.

| Table | What it holds |
|---|---|
| `venue` | name, country, locale (decides the default CSV dialect) |
| `zone` | venue, name, sort, `map_file` |
| `sku` | venue, code, name, brand, category, `size_ml`, `units_per_case`, `unit_barcode`, `case_gtin` |
| `session` | venue, counter name, status (open, review, locked), current zone, started/finished |
| `session_zone` | the zones chosen for the session, plus zones switched to |
| `"commit"` | session, zone, seq, anchor id, camera pose, keyframe path, trigger, matched count, drift alarm, undone |
| `counted_zone` | the commit's oriented box: transform (16 floats, column-major, JSON) and half extents |
| `item` | commit, group, class, position, top, product key, confidence, detection index, crop, removed |
| `item_group` | session, letter ("A"), confirmed product, suggestion and its source, confirmed flag |
| `manual_line` | session, zone, product, full cases, loose units, note |
| `possible_miss` | commit, class, position, top, detection index, status (open, added, dismissed) |
| `event` | append-only audit log: venue, session, time, type, JSON payload |

`possible_miss` and `session_zone` are not in PRD §11: review needs them for "possible misses left"
and "zones with no counts" (FR-35). `commit` is an SQL keyword, so quote it in hand-written SQL.

## The stock sheet

`StockSheet` is computed from the database each time (`stockSheet`, `observeSheet`), so it always
reflects undo, removals, naming and manual lines.

- **One line per product**, across zones, camera and manual lines. **One line per unnamed group**:
  "Unknown A", "Unknown B"… (`SheetOptions.unknownName` for the Spanish word). Letters are fixed
  when a group is made: naming "Unknown A" never turns "Unknown B" into "Unknown A".
- **Quantities** (`Quantity`): `countedCases` (closed cases the camera counted, FR-19, plus manual
  full cases) and `countedUnits` (bottles, tops, cans, manual loose units).
  - `totalUnits = countedUnits + countedCases × units_per_case`;
  - `fullCases = totalUnits / units_per_case`, `looseUnits = totalUnits % units_per_case`;
  - no `units_per_case` and no cases: `totalUnits = countedUnits`, `fullCases = 0`;
  - cases but no `units_per_case`: `totalUnits` is nil (never guessed), `fullCases` = the cases
    counted, and the line is flagged.
- **Each line** also has: `parts` (by zone and source), `sources`, `zones`, `photos` (the keyframes
  and crops of the commits that counted it, oldest first), `notes` (from manual lines), `flags`,
  `countedAt`, and for an unnamed group its `suggestedSKU`.
- **Review (FR-35):** `sheet.review.issues`, blockers first.
  - Blocker: `unnamedGroup` (name it, or mark it unknown). `canLock` is false while any is left.
  - Warnings: `possibleMissesLeft` (per zone), `zoneWithoutCounts` (a session zone with no commit
    and no manual line), `unitsPerCaseMissing`.
  - The lock event keeps every line's totals as they were at lock time.

## Export format (FR-36, ADR 005)

One header row, then the ADR 005 columns (v1), in this order:

| Column | Content |
|---|---|
| `session_id` | the session's UUID |
| `venue` | venue name |
| `zone` | the zones of the line, in zone order, comma-separated (one zone in the by-zone layout) |
| `counted_at` | the line's latest count, local time: `2026-10-02 14:35` (an XLSX date cell) |
| `counted_by` | the counter's name |
| `sku_code` | product code, always text; empty for unknown groups |
| `sku_name` | product name, or "Unknown A" |
| `brand`, `category` | from the catalog |
| `size_ml`, `units_per_case` | whole numbers; empty when unknown |
| `full_cases`, `loose_units` | the stock as full cases plus loose units |
| `total_units` | all units; empty when cases can't be converted (no units per case) |
| `source` | `camera`, `manual` or `camera+manual` |
| `notes` | manual lines' notes, joined with " \| " |

**Layouts** (`ExportOptions.layout`):
- `.byProduct` (default): the stock sheet, one row per product and per unknown group.
- `.byZoneAndSource`: one row per product, zone and source, for venues that keep stock by room.

**CSV dialects:**

| | `CSVDialect.excelArgentina` | `CSVDialect.standard` |
|---|---|---|
| For | Excel set to Argentina (Spanish) | Google Sheets, imports into other systems |
| Encoding | UTF-8 with BOM | UTF-8, no BOM |
| Separator | `;` | `,` |
| Decimals | comma (`0,75`) | point (`0.75`) |
| All-digit codes | `="0071234567890"`, so Excel keeps leading zeros and doesn't show 7,79E+12 | plain text |

Both use CRLF line ends and RFC 4180 quoting; fields with `,` or `;` are quoted in both, so a file
opened with the other separator still splits right. Quantities and sizes are whole numbers.
`Venue.defaultCSVDialect` picks Excel (Argentina) where the venue's locale writes decimals with a
comma.

**Formula injection** (OWASP): text that starts with `=`, `+`, `-`, `@`, a tab or a line break (or
the full-width `＝ ＋ － ＠`) gets a leading apostrophe in CSV. In XLSX such text stays a plain
string cell, unchanged, marked `quotePrefix` so editing it or saving the sheet as CSV can't turn it
into a formula.

**XLSX:** one sheet named "Stock", header in bold and frozen. Text and codes are string cells with
the Text format ("@"), so codes keep their leading zeros even when edited. Quantities are numbers;
`counted_at` is a date cell shown as `yyyy-mm-dd hh:mm`. The file is a stored (uncompressed) ZIP
with the minimal Office Open XML parts; checked with our own ZIP reader, an XML parser, `unzip -t`,
openpyxl and macOS Quick Look.

**File name:** `stock <venue> <yyyy-mm-dd>.csv` / `.xlsx`, from the session's start date, without
characters file systems refuse.

## Catalog import (FR-4)

`planCatalogImport` reads the CSV and returns a plan without writing anything. The app shows the
flagged rows, lets the owner change the mapping or each row's action, then calls
`applyCatalogImport` (one transaction).

- **Files:** Excel's "CSV UTF-8" (BOM, `;`), Excel's plain CSV (Windows-1252 in Argentina),
  Google Sheets (`,`), tab-separated UTF-16. The separator is the most frequent of `;`, tab and `,`
  in the header line. Quoted fields may hold separators, quotes and line breaks. Blank rows are
  skipped; row numbers stay the spreadsheet's.
- **Mapping** (`ColumnMapping.suggested(for:)`) from Spanish or English headers, ignoring accents
  and case: "Código", "Artículo"/"Producto"/"Descripción", "Marca"/"Bodega", "Rubro"/"Categoría",
  "Contenido"/"ml"/"cc", "U. x caja"/"Unidades por caja", "EAN"/"Código de barras",
  "DUN-14"/"EAN caja", and so on.
- **Values:**
  - sizes: "750", "750 ml", "750 cc", "75 cl", "1 L", "1,5 lts", "0,75" (a number with decimals or
    of at most 10 is litres), "1.000 ml";
  - units per case: the first whole number ("x6", "caja x 24");
  - barcodes: spaces and hyphens removed; a wrong GS1 check digit is flagged but kept; a code Excel
    already turned into `7,79123E+12` is flagged and dropped, because its digits are lost.
- **Duplicates** are flagged against the catalog and against earlier rows, by code, unit barcode,
  case GTIN (GTIN-8/12/13/14 compared as GTIN-14), or brand + name + size when no codes tell the two
  apart. Flagged duplicates and rows without a name default to `.skip`; others to `.create`. The
  owner can switch a duplicate to `.update(skuID)`.

XLSX import is not built: export the list from Excel as "CSV UTF-8" first.

## Audit events

`venue_created`, `zone_created`, `zone_updated`, `sku_created`, `sku_updated`, `catalog_imported`,
`session_started`, `zone_switched`, `session_finished`, `counting_resumed`, `session_locked`,
`session_reopened`, `commit_saved`, `commit_undone`, `item_added`, `item_removed`, `item_restored`,
`possible_miss_added`, `possible_miss_dismissed`, `group_named` (with whether a suggestion was
accepted, for teach-once accuracy), `group_marked_unknown`, `items_moved`, `line_deleted`,
`manual_line_added`, `manual_line_updated`, `manual_line_deleted`. The app records its own with
`recordEvent`; `session_paused`, `session_resumed` and `sheet_exported` are defined for it (pilot
metrics: count time, sessions exported).

## Tests

Swift Testing, all on macOS:
- **Persistence:** schema and pragmas; storage formats; round trips of every record, including
  matrices and positions bit for bit; a failing commit writes nothing; undo; lock, read-only and
  reopen; one active session; the append-only log; one event per change.
- **Crash safety:** `CrashProbe` (a test-only executable in this package) saves commits in a loop
  and is killed with `SIGKILL` at random points, three times. Every acknowledged commit must be
  there with all its items, zone, miss and event, and `integrity_check` must pass. A second test
  copies the database and its WAL while the store still has them open (what a killed app leaves on
  disk) and resumes from the copy.
- **Sheet:** totals and full cases, sources and zones, stable "Unknown" letters, review warnings,
  photos, suggestions, split and merge, line deletion, live observation, `bottle_top` as a bottle,
  product keys.
- **Export:** both CSV dialects byte for byte, decimals, quoting round trips, formula injection,
  codes; XLSX structure, cell types and styles, `unzip -t`, openpyxl.
- **Import:** mappings, sizes, encodings, duplicates, applying a plan; GTIN check digits;
  timestamps.

The fixtures are invented: a venue "Bar Ejemplo" and products like "Malbec Muestra" with barcodes
in GS1's restricted-circulation range (prefix 20), which no real product uses.

## Not here yet

- XLSX import (CSV only; see above).
- Teach-once examples (`sku_example`, ADR 004), rack tags (FR-5, FR-25), the evidence ZIP (FR-37)
  and the diagnostic bundle (FR-39): later migrations.
- Per-commit drift diagnostics (`CommitResult.driftOffset`): add when Phase 0 needs them.
