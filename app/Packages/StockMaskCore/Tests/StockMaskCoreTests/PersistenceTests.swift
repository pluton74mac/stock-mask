import Foundation
import GRDB
import simd
import Testing
@testable import StockMaskCore

@Suite("Persistence")
struct PersistenceTests {
    @Test("Migrations create every table; the file uses WAL, synchronous FULL and foreign keys")
    func schemaAndSettings() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let world = try World.make(at: dir.appendingPathComponent("db/stock.sqlite"))
        try world.store.databaseReader.read { (db: Database) throws in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            for table in ["venue", "zone", "sku", "session", "session_zone", "commit", "counted_zone", "item",
                          "item_group", "manual_line", "possible_miss", "event"] {
                #expect(tables.contains(table), "missing table \(table)")
            }
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
            // ADR 005: no UNIQUE constraint besides primary keys.
            let uniqueIndexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%UNIQUE%'
                """)
            #expect(uniqueIndexes.isEmpty)
        }
        // Durability is set on the connection that writes.
        try world.store.writer.write { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2)  // FULL
            #expect(try Int.fetchOne(db, sql: "PRAGMA fullfsync") == 1)
            #expect(try Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") == 1)
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
        }
    }

    @Test("UUIDs are stored as lowercase text, dates as UTC text")
    func storageFormats() throws {
        let world = try World.make()
        try world.store.databaseReader.read { (db: Database) throws in
            let row = try Row.fetchOne(db, sql: "SELECT typeof(id) AS t, id, created_at FROM venue")!
            #expect(row["t"] as String == "text")
            #expect(row["id"] as String == world.venue.id.uuidString.lowercased())
            #expect(row["created_at"] as String == "2026-10-02 12:00:00.000")
        }
    }

    @Test("Venue, zones and catalog read back exactly after reopening the file")
    func catalogRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stock.sqlite")
        let world = try World.make(at: url)
        let edited = try world.store.updateSKU(id: world.malbec.id, SKUFields(
            code: "0071", name: "Malbec Muestra Reserva", brand: "Bodega Ficticia", category: "Vino", sizeML: 750,
            unitsPerCase: 6, unitBarcode: world.malbec.unitBarcode, caseGTIN: world.malbec.caseGTIN))
        let map = try world.store.setZoneMapFile(world.camara.id, path: "maps/camara.arworldmap")

        let reopened = try StockStore.open(at: url)
        #expect(try reopened.venues() == [world.venue])
        #expect(try reopened.zones(venueID: world.venue.id) == [world.deposito, map, world.seco])
        #expect(try reopened.sku(id: world.malbec.id) == edited)
        #expect(try reopened.skus(venueID: world.venue.id).count == 5)
        #expect(try reopened.events(venueID: world.venue.id).map(\.type).suffix(2) == [.skuUpdated, .zoneUpdated])
    }

    @Test("A product needs a name; sizes and units per case must be positive")
    func skuValidation() throws {
        let world = try World.make()
        #expect(throws: StoreError.self) { try world.store.createSKU(venueID: world.venue.id, SKUFields(name: "  ")) }
        #expect(throws: StoreError.self) {
            try world.store.createSKU(venueID: world.venue.id, SKUFields(name: "Agua", unitsPerCase: 0))
        }
        let sku = try world.store.createSKU(venueID: world.venue.id, SKUFields(
            code: " ", name: " Agua Muestra 500 ", brand: "", unitBarcode: "200 0000-000 107"))
        #expect(sku.name == "Agua Muestra 500")
        #expect(sku.code == nil && sku.brand == nil)
        #expect(sku.unitBarcode == "2000000000107")
    }

    @Test("Search ignores case and accents; barcodes match as GTIN-14")
    func searchAndBarcodes() throws {
        let world = try World.make()
        let store = world.store
        #expect(try store.searchSKUs(venueID: world.venue.id, matching: "tonica").map(\.id) == [world.tonica.id])
        // Both match every word; neither name starts with "cerveceria", so they come by name.
        #expect(try store.searchSKUs(venueID: world.venue.id, matching: "CERVECERIA lager").map(\.id)
            == [world.keg.id, world.lager.id])
        #expect(try store.searchSKUs(venueID: world.venue.id, matching: "lager").map(\.id)
            == [world.lager.id, world.keg.id])  // a name that starts with the word comes first
        #expect(try store.searchSKUs(venueID: world.venue.id, matching: "750").count == 2)
        let unit = try #require(try store.findSKU(venueID: world.venue.id, barcode: "0" + world.fernet.unitBarcode!))
        #expect(unit.sku.id == world.fernet.id && unit.kind == .unit)
        let carton = try #require(try store.findSKU(venueID: world.venue.id, barcode: world.lager.caseGTIN!))
        #expect(carton.sku.id == world.lager.id && carton.kind == .case)
        #expect(try store.findSKU(venueID: world.venue.id, barcode: fakeEAN(999)) == nil)
    }

    @Test("A commit saves its items, groups, zone, misses, pose and keyframe, and reads back exactly")
    func commitRoundTrip() throws {
        let world = try World.make()
        let session = try world.startSession()
        var draft = makeDraft(
            session: session, zone: world.deposito, bottles: 5, cases: 2, tops: 1,
            suggestions: [NewGroup(key: 1, suggestedSKUID: world.lager.id, suggestionSource: .caseBarcode)], misses: 2)
        draft.matchedCount = 3
        draft.createdAt = Date(timeIntervalSince1970: 1_790_942_500.123_456)  // sub-millisecond on purpose
        let saved = try world.store.saveCommit(draft)

        #expect(saved.commit.seq == 1)
        #expect(saved.commit.createdAt == Date(timeIntervalSince1970: 1_790_942_500.123))
        #expect(saved.groups.map(\.group.label) == ["A", "B"])
        #expect(saved.groups.map(\.key) == [0, 1])
        #expect(saved.groups[0].counts == [.bottle: 6], "a top counts as a bottle on the commit card")
        #expect(saved.groups[1].counts == [.case: 2])
        #expect(saved.groups[1].group.suggestedSKUID == world.lager.id)
        #expect(saved.groups[1].group.skuID == nil, "a suggestion is never an assignment (FR-31)")

        let snapshot = try world.store.snapshot(sessionID: session.id)
        #expect(snapshot.commits == [saved.commit])
        #expect(snapshot.commits[0].pose == draft.pose)
        #expect(snapshot.commits[0].keyframePath == draft.keyframePath)
        #expect(snapshot.commits[0].matchedCount == 3)
        #expect(snapshot.countedZones == [saved.countedZone])
        #expect(snapshot.countedZones[0].transform == draft.countedZone.transform)
        #expect(snapshot.items == saved.items)
        #expect(snapshot.items.map(\.position) == draft.items.map(\.position))
        #expect(snapshot.items.map(\.id) == draft.items.map(\.id))
        #expect(snapshot.items.map(\.top) == draft.items.map(\.top))
        #expect(snapshot.items.map(\.cls) == draft.items.map(\.cls))
        #expect(snapshot.items.map(\.detectionIndex) == (0..<8).map { Optional($0) })
        #expect(snapshot.items.filter { $0.cls == .case }.allSatisfy { $0.top == nil })
        #expect(snapshot.groups == saved.groups.map(\.group))
        #expect(snapshot.openPossibleMisses == saved.possibleMisses)
        #expect(snapshot.openPossibleMisses.count == 2)
        #expect(snapshot.session.currentZoneID == world.deposito.id)

        let event = try #require(world.store.events(sessionID: session.id).last)
        #expect(event.type == .commitSaved)
        #expect(event.payloadValue["items"] == 8)
        #expect(event.payloadValue["commit"] == .string(draft.id.uuidString.lowercased()))
    }

    @Test("Items without a group key are grouped by kind: bottles with tops, cans, cases")
    func autoGroups() throws {
        let world = try World.make()
        let session = try world.startSession()
        let saved = try world.store.saveCommit(
            makeDraft(session: session, zone: world.deposito, bottles: 3, cases: 1, cans: 4, tops: 2, keyed: false))
        #expect(saved.groups.map(\.key) == [nil, nil, nil])
        #expect(saved.groups.map(\.counts) == [[.bottle: 5], [.can: 4], [.case: 1]])
        #expect(saved.groups.map(\.group.label) == ["A", "B", "C"])
    }

    @Test("A failing commit writes nothing: the transaction rolls back")
    func commitIsAtomic() throws {
        let world = try World.make()
        let session = try world.startSession()
        let first = try world.store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 4))
        let before = try world.store.snapshot(sessionID: session.id)
        let eventsBefore = try world.store.events(sessionID: session.id).count

        // Fails on the third item: its id is already taken (primary key), after the commit row,
        // the zone, the groups and two items were inserted.
        var clash = makeDraft(session: session, zone: world.camara, bottles: 5, cases: 1)
        clash.items[2].id = first.items[0].id
        #expect(throws: DatabaseError.self) { try world.store.saveCommit(clash) }

        // Fails on a suggestion that isn't in the venue's catalog, after the commit row.
        let stray = makeDraft(
            session: session, zone: world.camara, bottles: 2, suggestions: [NewGroup(key: 0, suggestedSKUID: UUID())])
        #expect(throws: StoreError.self) { try world.store.saveCommit(stray) }

        // Refused before any write: a non-finite position.
        var nan = makeDraft(session: session, zone: world.camara, bottles: 2)
        nan.items[1].position.y = .nan
        #expect(throws: StoreError.self) { try world.store.saveCommit(nan) }

        #expect(try world.store.snapshot(sessionID: session.id) == before)
        #expect(try world.store.events(sessionID: session.id).count == eventsBefore)
        try world.store.databaseReader.read { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "commit""#) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") == 4)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_group") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM counted_zone") == 1)
        }
        // Saving the same commit twice is refused too, and changes nothing.
        #expect(throws: DatabaseError.self) {
            var again = makeDraft(session: session, zone: world.deposito, bottles: 1)
            again.id = first.commit.id
            try world.store.saveCommit(again)
        }
        #expect(try world.store.snapshot(sessionID: session.id) == before)
    }

    @Test("Undo takes back the last commit, then the one before; rows stay for the audit trail")
    func undo() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let c1 = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 3))
        let c2 = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, misses: 1))
        #expect(try store.stockSheet(sessionID: session.id).totalUnits == 5)

        #expect(throws: StoreError.self) { try store.undoLastCommit(sessionID: session.id, expecting: c1.commit.id) }
        let undone = try #require(try store.undoLastCommit(sessionID: session.id, expecting: c2.commit.id))
        #expect(undone.commit.id == c2.commit.id && undone.commit.undone)
        #expect(Set(undone.itemIDs) == Set(c2.items.map(\.id)))
        #expect(undone.countedZoneIDs == [c2.countedZone.id])
        #expect(undone.possibleMissIDs == c2.possibleMisses.map(\.id))

        let snapshot = try store.snapshot(sessionID: session.id)
        #expect(snapshot.commits.map(\.id) == [c1.commit.id])
        #expect(snapshot.items.count == 3 && snapshot.openPossibleMisses.isEmpty && snapshot.countedZones.count == 1)
        #expect(try store.stockSheet(sessionID: session.id).totalUnits == 3)

        // The next commit gets seq 3: undone commits keep their number.
        let c3 = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 1))
        #expect(c3.commit.seq == 3)
        #expect(try store.undoLastCommit(sessionID: session.id)?.commit.id == c3.commit.id)
        #expect(try store.undoLastCommit(sessionID: session.id)?.commit.id == c1.commit.id)
        #expect(try store.undoLastCommit(sessionID: session.id) == nil)
        #expect(try store.stockSheet(sessionID: session.id).lines.isEmpty)
        try store.databaseReader.read { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") == 6)
        }
        #expect(try store.events(sessionID: session.id).filter { $0.type == .commitUndone }.count == 3)
    }

    @Test("Locking is refused while a group is unnamed; a locked session is read-only until reopened")
    func lockAndReopen() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let saved = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 4, cases: 1))
        let manual = try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.keg.id, looseUnits: 2)

        #expect(try store.finishSession(session.id).status == .review)
        #expect(throws: StoreError.unnamedGroups(2)) { try store.lockSession(session.id) }
        try store.nameGroup(saved.groups[0].group.id, sku: world.malbec.id)
        try store.markGroupUnknown(saved.groups[1].group.id)
        let locked = try store.lockSession(session.id)
        #expect(locked.status == .locked)
        #expect(locked.finishedAt != nil)

        let lockEvent = try #require(store.events(sessionID: session.id).last)
        #expect(lockEvent.type == .sessionLocked)
        #expect(lockEvent.payloadValue["total_units"] == 6)  // 4 bottles + 2 kegs; the unknown case has no units

        let refused: [(String, () throws -> Void)] = [
            ("commit", { _ = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 1)) }),
            ("undo", { _ = try store.undoLastCommit(sessionID: session.id) }),
            ("name", { _ = try store.nameGroup(saved.groups[1].group.id, sku: world.lager.id) }),
            ("unknown", { _ = try store.markGroupUnknown(saved.groups[0].group.id) }),
            ("remove item", { _ = try store.setItemRemoved(saved.items[0].id, removed: true) }),
            ("add manual", { _ = try store.addManualLine(sessionID: session.id, zoneID: world.seco.id, skuID: world.keg.id, looseUnits: 1) }),
            ("edit manual", { _ = try store.updateManualLine(manual) }),
            ("delete manual", { try store.deleteManualLine(manual.id) }),
            ("switch zone", { _ = try store.switchZone(sessionID: session.id, to: world.seco.id) }),
            ("finish", { _ = try store.finishSession(session.id) }),
            ("move items", { _ = try store.moveItems([saved.items[0].id]) }),
            ("delete line", { _ = try store.deleteLine(.product(world.malbec.id), sessionID: session.id) }),
        ]
        for (name, action) in refused {
            #expect(throws: StoreError.sessionLocked(session.id), "\(name) on a locked session") { try action() }
        }
        // Events can still be recorded (an export of a locked session is logged).
        try store.recordEvent(.sheetExported, sessionID: session.id, payload: ["format": "xlsx"])

        let reopened = try store.reopenSession(session.id, reason: "Recount the walk-in")
        #expect(reopened.status == .review)
        let reopenEvent = try #require(store.events(sessionID: session.id).last { $0.type == .sessionReopened })
        #expect(reopenEvent.payloadValue["reason"] == "Recount the walk-in")
        try store.addManualLine(sessionID: session.id, zoneID: world.seco.id, skuID: world.keg.id, looseUnits: 1)
        #expect(throws: StoreError.self) { try store.reopenSession(session.id) }  // not locked any more
    }

    @Test("One active session per device")
    func oneActiveSession() throws {
        let world = try World.make()
        let first = try world.startSession()
        #expect(try world.store.activeSession() == first)
        #expect(throws: StoreError.activeSessionExists(first.id)) { try world.startSession() }
        try world.store.lockSession(first.id)
        #expect(try world.store.activeSession() == nil)
        let second = try world.startSession()
        #expect(throws: StoreError.activeSessionExists(second.id)) { try world.store.reopenSession(first.id) }
        #expect(try world.store.sessions(venueID: world.venue.id).map(\.id) == [second.id, first.id])
    }

    @Test("Session zones: the chosen ones, plus zones switched to")
    func sessionZones() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession(zones: [world.camara])
        #expect(session.currentZoneID == world.camara.id)
        #expect(try store.sessionZones(sessionID: session.id) == [world.camara])
        let moved = try store.switchZone(sessionID: session.id, to: world.deposito.id)
        #expect(moved.currentZoneID == world.deposito.id)
        #expect(try store.sessionZones(sessionID: session.id) == [world.camara, world.deposito])
        let event = try #require(store.events(sessionID: session.id).last)
        #expect(event.type == .zoneSwitched)
        #expect(event.payloadValue["from"] == .string(world.camara.id.uuidString.lowercased()))
    }

    @Test("The event log is append-only: the database refuses UPDATE and DELETE")
    func appendOnlyEvents() throws {
        let world = try World.make()
        let session = try world.startSession()
        let count = try world.store.events(sessionID: session.id).count
        #expect(count == 1)
        for sql in ["UPDATE event SET type = 'tampered'", "DELETE FROM event", "DELETE FROM event WHERE session_id IS NULL"] {
            let error = #expect(throws: DatabaseError.self) {
                try world.store.writer.write { db in try db.execute(sql: sql) }
            }
            #expect(error?.message?.contains("append-only") == true)
        }
        #expect(try world.store.events(sessionID: session.id).count == count)
    }

    @Test("Every change writes its event in the same transaction")
    func eventTrail() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let saved = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, misses: 2))
        try store.nameGroup(saved.groups[0].group.id, sku: world.malbec.id)
        try store.setItemRemoved(saved.items[0].id, removed: true)
        try store.setItemRemoved(saved.items[0].id, removed: false)
        try store.addPossibleMiss(saved.possibleMisses[0].id, toGroup: saved.groups[0].group.id)
        try store.dismissPossibleMiss(saved.possibleMisses[1].id)
        let line = try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.keg.id, looseUnits: 3)
        var edited = line
        edited.looseUnits = 4
        try store.updateManualLine(edited)
        try store.deleteManualLine(line.id)
        try store.switchZone(sessionID: session.id, to: world.camara.id)
        try store.finishSession(session.id)
        try store.returnToCounting(session.id)
        try store.finishSession(session.id)
        try store.lockSession(session.id)
        try store.reopenSession(session.id, reason: nil)
        try store.recordEvent(.sessionPaused, sessionID: session.id)

        #expect(try store.events(sessionID: session.id).map(\.type) == [
            .sessionStarted, .commitSaved, .groupNamed, .itemRemoved, .itemRestored, .possibleMissAdded,
            .possibleMissDismissed, .manualLineAdded, .manualLineUpdated, .manualLineDeleted, .zoneSwitched,
            .sessionFinished, .countingResumed, .sessionFinished, .sessionLocked, .sessionReopened, .sessionPaused,
        ])
        let named = try #require(store.events(sessionID: session.id).first { $0.type == .groupNamed })
        #expect(named.payloadValue["accepted_suggestion"] == false)
    }
}
