# ADR 005: Local storage, no backend for the pilot, export format

Status: **Accepted** · 2026-09-25

## Decision

1. **Local store: SQLite through GRDB 7** (MIT). Use GRDBQuery for SwiftUI views.
   - Every counting action is written straight away in its own transaction.
   - The ARWorldMap and crops are **files**; the database stores their paths.
   - Keys are UUID text, and the only UNIQUE constraint is the primary key, so sync can be added
     later without a migration.
2. **No backend, accounts or login in the MVP.** One phone per venue, data on the phone. Getting
   data out:
   - share-sheet export;
   - a "backup session" file;
   - an opt-in "diagnostic bundle" (keyframes plus corrections) that we use to retrain the
     detector.
3. **Export XLSX and CSV.**
   - The CSV defaults to what Argentine Excel expects: UTF-8 with BOM, `;` separator. Include a
     `,` option for Google Sheets and for importing into other systems.
   - Quantities are whole numbers; sizes are integer millilitres.
   - Barcodes are written as text.
   - Cells starting with `= + - @` are escaped.
4. **When multi-device, a web dashboard or Android arrive: Supabase (Postgres) + PowerSync.**
   Phase 2, not before.

## Why not SwiftData

| | SwiftData | GRDB 7 |
|---|---|---|
| Maturity for our case | Reported iOS 18/26 bugs: a `ModelActor` crash, a `save()` regression, views not refreshing. Autosaves only on `mainContext`, so a count can sit unsaved. New observation APIs need iOS 27. | Maintained since 2015. A `write {}` commits a transaction that survives an app crash. Passes Swift 6 strict concurrency. |
| Aggregates for the live list (sum by SKU) | Not pushed to SQL; computed in memory | Plain SQL `GROUP BY` |
| Sync later | CloudKit private database only (no Android, no cross-venue dashboard) | Any: PowerSync (GA SDKs for Swift/Kotlin/Web) or SQLiteData's CloudKit sync |
| Debugging | Opaque store | Open the `.sqlite` file in any tool; attach it to the diagnostic bundle |

"Never lose a count" comes from two things: SQLite's durability across app crashes, and writing
each commit synchronously rather than inside a cancellable task. GRDB makes both explicit.

## Why no backend in the MVP

- **The pilot doesn't need one.** 3–5 bars, one phone each. The job is "leave the storeroom with
  a list", and the share sheet already delivers that to WhatsApp, email, Drive or Files.
- **Everything the draft PRD lists for the cloud can wait:** auth, catalog sync, session backup,
  multi-user. Each adds work that the go/no-go question doesn't need:
  - security review;
  - privacy policy scope (photos of venues);
  - hosting;
  - an offline sync conflict model.
- **Training data still flows** through the opt-in diagnostic bundle, exported through the share
  sheet.

## Backend options for later

| | Supabase + PowerSync | Firebase Firestore | CloudKit |
|---|---|---|---|
| Offline-first sync | PowerSync: local SQLite plus an upload queue; GA on Swift, Kotlin, Web | Built-in cache, last-write-wins | Apple devices only |
| Inventory data (relational, SUM/GROUP BY) | Postgres | Document store; aggregates run online only | Per-user iCloud databases |
| Android + web dashboard | Yes | Yes | No Android; web access is awkward |
| Lock-in | Open source, self-hostable | Proprietary | Apple |

## Export columns (v1)

`session_id, venue, zone, counted_at, counted_by, sku_code, sku_name, brand, category, size_ml,
units_per_case, full_cases, loose_units, total_units, source (camera|manual), notes`

The draft had a single `qty_units, qty_cases` pair plus a "case mode" toggle. Exporting both
`full_cases` and `total_units` makes the toggle unnecessary.
