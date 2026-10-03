import Foundation
import Testing
@testable import StockMaskCore

@Suite("Stock sheet")
struct StockSheetTests {
    @Test("Quantity: total units and full cases via units per case")
    func quantityMath() {
        let q = Quantity(countedCases: 3, countedUnits: 30, unitsPerCase: 12)
        #expect(q.totalUnits == 66)
        #expect(q.fullCases == 5)
        #expect(q.looseUnits == 6)

        let bottlesOnly = Quantity(countedCases: 0, countedUnits: 7, unitsPerCase: nil)
        #expect(bottlesOnly.totalUnits == 7 && bottlesOnly.fullCases == 0 && bottlesOnly.looseUnits == 7)

        // Cases without units per case: no guess. Report them as counted.
        let unknown = Quantity(countedCases: 2, countedUnits: 1, unitsPerCase: nil)
        #expect(unknown.totalUnits == nil)
        #expect(unknown.fullCases == 2 && unknown.looseUnits == 1)
        #expect(unknown.needsUnitsPerCase)

        let single = Quantity(countedCases: 0, countedUnits: 3, unitsPerCase: 1)
        #expect(single.fullCases == 3 && single.looseUnits == 0)
    }

    @Test("One line per product across zones, camera and manual sources")
    func linePerProduct() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        // Depósito: 8 Malbec bottles + 2 closed cases (6 per case); Cámara: 4 more bottles.
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 8, cases: 2))
        let b = try store.saveCommit(makeDraft(session: session, zone: world.camara, bottles: 4, x: 3))
        for group in a.groups + b.groups { try store.nameGroup(group.group.id, sku: world.malbec.id) }
        // A partial case found in a cupboard, and two kegs.
        try store.addManualLine(
            sessionID: session.id, zoneID: world.deposito.id, skuID: world.malbec.id, fullCases: 1, looseUnits: 0,
            note: "caja cerrada en el armario")
        try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.keg.id, looseUnits: 2)

        let sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Barril Lager 50 L", "Malbec Muestra"])
        let malbec = try #require(sheet.line(world.malbec))
        #expect(malbec.quantity.countedUnits == 12)
        #expect(malbec.quantity.countedCases == 3)
        #expect(malbec.quantity.totalUnits == 30)  // 12 + 3 × 6
        #expect(malbec.quantity.fullCases == 5 && malbec.quantity.looseUnits == 0)
        #expect(malbec.sources == [.camera, .manual])
        #expect(malbec.zones.map(\.name) == ["Depósito", "Cámara"])
        #expect(malbec.parts.map { "\($0.zone.name)/\($0.source.rawValue)/\($0.quantity.countedCases)/\($0.quantity.countedUnits)" }
            == ["Depósito/camera/2/8", "Depósito/manual/1/0", "Cámara/camera/0/4"])
        #expect(malbec.parts.map(\.quantity.totalUnits) == [20, 6, 4])
        #expect(malbec.notes == ["caja cerrada en el armario"])
        #expect(malbec.cameraItemCount == 14)
        #expect(malbec.groupIDs.count == 3)
        #expect(malbec.flags.isEmpty)

        let keg = try #require(sheet.line(world.keg))
        #expect(keg.sources == [.manual])
        #expect(keg.quantity.totalUnits == 2 && keg.quantity.fullCases == 0 && keg.quantity.looseUnits == 2)
        #expect(keg.photos.isEmpty)

        #expect(sheet.totalUnits == 32)
        #expect(sheet.productCount == 2)
        #expect(sheet.review.canLock)
    }

    @Test("Unnamed groups are \"Unknown A\", \"Unknown B\"…, and keep their letter when others are named")
    func unknownLabels() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let first = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 6, cases: 2))
        let second = try store.saveCommit(makeDraft(session: session, zone: world.deposito, cans: 12, x: 2))
        var sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Unknown A", "Unknown B", "Unknown C"])
        #expect(sheet.lines.map(\.unknownLabel) == ["A", "B", "C"])
        #expect(sheet.lines.allSatisfy { $0.flags == [.unnamed] || $0.flags == [.unnamed, .unitsPerCaseMissing] })
        #expect(sheet.review.blockers == sheet.lines.map { .unnamedGroup($0.id) })
        #expect(!sheet.review.canLock)

        // Unknown B is two closed cases: units can't be known until it is named.
        let cases = try #require(sheet.line(named: "Unknown B"))
        #expect(cases.quantity.totalUnits == nil && cases.quantity.fullCases == 2)

        try store.nameGroup(first.groups[1].group.id, sku: world.lager.id)
        try store.markGroupUnknown(second.groups[0].group.id)
        sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Lager Muestra 1 L", "Unknown A", "Unknown C"])
        #expect(sheet.line(world.lager)?.quantity.totalUnits == 24)
        #expect(sheet.line(world.lager)?.quantity.fullCases == 2)
        #expect(sheet.line(named: "Unknown C")?.flags == [.markedUnknown])
        #expect(sheet.review.blockers == [.unnamedGroup(.unknownGroup(first.groups[0].group.id))])

        // The Spanish UI passes its own word.
        let spanish = try store.stockSheet(sessionID: session.id, options: SheetOptions(unknownName: "Desconocido"))
        #expect(spanish.lines.map(\.name) == ["Lager Muestra 1 L", "Desconocido A", "Desconocido C"])

        // A later group continues the sequence.
        let third = try store.saveCommit(makeDraft(session: session, zone: world.camara, bottles: 1, x: 5))
        #expect(third.groups[0].group.label == "D")
    }

    @Test("Group letters run A…Z, then AA, AB…")
    func letters() {
        #expect(groupLetters(1) == "A")
        #expect(groupLetters(26) == "Z")
        #expect(groupLetters(27) == "AA")
        #expect(groupLetters(52) == "AZ")
        #expect(groupLetters(53) == "BA")
        #expect(groupLetters(703) == "AAA")
    }

    @Test("Removed items and undone commits don't count")
    func removedAndUndone() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 5))
        try store.nameGroup(a.groups[0].group.id, sku: world.fernet.id)
        try store.setItemRemoved(a.items[0].id, removed: true)
        try store.setItemRemoved(a.items[1].id, removed: true)
        let b = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 9, x: 2))
        try store.nameGroup(b.groups[0].group.id, sku: world.fernet.id)
        #expect(try store.stockSheet(sessionID: session.id).line(world.fernet)?.quantity.totalUnits == 12)
        try store.undoLastCommit(sessionID: session.id)
        let sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.line(world.fernet)?.quantity.totalUnits == 3)
        #expect(sheet.line(world.fernet)?.photos.map(\.commitID) == [a.commit.id])
        try store.setItemRemoved(a.items[0].id, removed: false)
        #expect(try store.stockSheet(sessionID: session.id).line(world.fernet)?.quantity.totalUnits == 4)
    }

    @Test("Review warns about cases without units per case, possible misses left and zones with no counts")
    func reviewWarnings() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let saved = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, cases: 3, misses: 3))
        try store.nameGroup(saved.groups[0].group.id, sku: world.malbec.id)
        try store.nameGroup(saved.groups[1].group.id, sku: world.keg.id)  // no units per case
        try store.addPossibleMiss(saved.possibleMisses[0].id, toGroup: saved.groups[0].group.id)
        try store.dismissPossibleMiss(saved.possibleMisses[1].id)
        try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.lager.id, looseUnits: 4)

        let sheet = try store.stockSheet(sessionID: session.id)
        let keg = try #require(sheet.line(world.keg))
        #expect(keg.flags == [.unitsPerCaseMissing])
        #expect(keg.quantity.totalUnits == nil && keg.quantity.fullCases == 3)
        #expect(sheet.line(world.malbec)?.quantity.totalUnits == 3)  // 2 + the added possible miss
        #expect(sheet.review.blockers.isEmpty && sheet.review.canLock)
        #expect(sheet.review.warnings == [
            .possibleMissesLeft(zoneID: world.deposito.id, count: 1),
            .zoneWithoutCounts(world.seco.id),
            .unitsPerCaseMissing(.product(world.keg.id)),
        ])
        #expect(sheet.review.possibleMissesLeft == 1)

        // A miss can't be added twice; a dismissed one stays dismissed.
        #expect(throws: StoreError.self) { try store.addPossibleMiss(saved.possibleMisses[0].id) }
        #expect(throws: StoreError.self) { try store.addPossibleMiss(saved.possibleMisses[1].id) }
    }

    @Test("A miss seen again moves to the new commit; one the user resolved stays resolved")
    func repeatedMisses() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let first = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 3, misses: 2))
        let open = first.possibleMisses[0], dismissed = first.possibleMisses[1]
        try store.dismissPossibleMiss(dismissed.id)

        // The AR layer recognises both misses on the next hold and sends their ids again.
        var again = makeDraft(session: session, zone: world.deposito, bottles: 1, x: 1)
        again.possibleMisses = [
            NewPossibleMiss(id: open.id, cls: .bottle, position: SIMD3(0.2, 0.5, 1.3)),
            NewPossibleMiss(id: dismissed.id, cls: .bottle, position: SIMD3(0.3, 0.5, 1.3)),
        ]
        let second = try store.saveCommit(again)
        #expect(second.possibleMisses.map(\.id) == [open.id])
        let snapshot = try store.snapshot(sessionID: session.id)
        #expect(snapshot.openPossibleMisses.map(\.id) == [open.id])
        #expect(snapshot.openPossibleMisses[0].commitID == second.commit.id)
        #expect(snapshot.openPossibleMisses[0].position == SIMD3(0.2, 0.5, 1.3))
        #expect(try store.stockSheet(sessionID: session.id).review.possibleMissesLeft == 1)

        // Undoing the second commit hides the miss with it; re-sending it in a third revives it.
        try store.undoLastCommit(sessionID: session.id)
        #expect(try store.stockSheet(sessionID: session.id).review.possibleMissesLeft == 0)
        var third = makeDraft(session: session, zone: world.deposito, bottles: 1, x: 2)
        third.possibleMisses = [NewPossibleMiss(id: open.id, cls: .bottle, position: SIMD3(0.2, 0.5, 1.3))]
        try store.saveCommit(third)
        #expect(try store.stockSheet(sessionID: session.id).review.possibleMissesLeft == 1)
    }

    @Test("Every camera line points at the keyframes and crops that show it")
    func photos() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, keyframe: "keyframes/a.jpg"))
        let b = try store.saveCommit(makeDraft(session: session, zone: world.camara, bottles: 3, keyframe: "keyframes/b.jpg", x: 3))
        try store.nameGroup(a.groups[0].group.id, sku: world.malbec.id)
        try store.nameGroup(b.groups[0].group.id, sku: world.malbec.id)
        let line = try #require(store.stockSheet(sessionID: session.id).line(world.malbec))
        #expect(line.photos.map(\.keyframePath) == ["keyframes/a.jpg", "keyframes/b.jpg"])
        #expect(line.photos.map(\.itemCount) == [2, 3])
        #expect(line.photos.map(\.zoneID) == [world.deposito.id, world.camara.id])
        #expect(line.photos[1].cropPaths == b.items.compactMap(\.cropPath))
    }

    @Test("A suggestion is offered, never assigned, until the user confirms it")
    func suggestions() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let saved = try store.saveCommit(makeDraft(
            session: session, zone: world.deposito, bottles: 4, cases: 1,
            suggestions: [NewGroup(key: 0, suggestedSKUID: world.fernet.id, suggestionSource: .teachOnce),
                          NewGroup(key: 1, suggestedSKUID: world.lager.id, suggestionSource: .caseBarcode)]))
        var sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Unknown A", "Unknown B"])
        #expect(sheet.lines.map(\.suggestedSKU?.id) == [world.fernet.id, world.lager.id])
        #expect(sheet.lines.allSatisfy { $0.flags.contains(.unnamed) })

        let named = try store.acceptSuggestions(groupIDs: [saved.groups[1].group.id])
        #expect(named.map(\.skuID) == [world.lager.id])
        sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Lager Muestra 1 L", "Unknown A"])
        #expect(sheet.line(world.lager)?.quantity.totalUnits == 12)

        let event = try #require(store.events(sessionID: session.id).last)
        #expect(event.type == .groupNamed)
        #expect(event.payloadValue["accepted_suggestion"] == true)
        #expect(event.payloadValue["suggestion_source"] == "case_barcode")
    }

    @Test("Split and merge groups by moving items")
    func splitAndMerge() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 6))
        let b = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, x: 2))

        // Split: two of A's bottles are a different product.
        let split = try store.moveItems(Array(a.items.prefix(2).map(\.id)))
        #expect(split.label == "C")
        try store.nameGroup(a.groups[0].group.id, sku: world.malbec.id)
        try store.nameGroup(split.id, sku: world.fernet.id)
        // Merge: B is the same product as A's group.
        try store.moveItems(b.items.map(\.id), toGroup: a.groups[0].group.id)

        let sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Fernet Imaginario", "Malbec Muestra"])
        #expect(sheet.line(world.malbec)?.quantity.totalUnits == 6)
        #expect(sheet.line(world.fernet)?.quantity.totalUnits == 2)
        #expect(try store.events(sessionID: session.id).filter { $0.type == .itemsMoved }.count == 2)
    }

    @Test("Deleting a line uncounts its items and deletes its manual lines")
    func deleteLine() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 3, cases: 1))
        try store.nameGroup(a.groups[0].group.id, sku: world.malbec.id)
        try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.malbec.id, looseUnits: 2)
        let removed = try store.deleteLine(.product(world.malbec.id), sessionID: session.id)
        #expect(Set(removed) == Set(a.items.prefix(3).map(\.id)))
        let unknownRemoved = try store.deleteLine(.unknownGroup(a.groups[1].group.id), sessionID: session.id)
        #expect(unknownRemoved == [a.items[3].id])
        #expect(try store.stockSheet(sessionID: session.id).lines.isEmpty)
        #expect(try store.manualLines(sessionID: session.id).isEmpty)
        // The audit event keeps what was deleted.
        let event = try #require(store.events(sessionID: session.id).first { $0.type == .lineDeleted })
        #expect(event.payloadValue["items"]?.arrayValue?.count == 3)
        #expect(event.payloadValue["manual_lines"]?.arrayValue?.first?["loose_units"] == 2)
    }

    @Test("Tapping a low-confidence detection adds it to a commit")
    func addItemToCommit() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 3))
        try store.nameGroup(a.groups[0].group.id, sku: world.malbec.id)
        let item = try store.addItem(
            NewItem(id: UUID(), cls: .bottle, position: SIMD3(1, 1, 1), confidence: 0.3), toCommit: a.commit.id,
            groupID: a.groups[0].group.id)
        #expect(try store.stockSheet(sessionID: session.id).line(world.malbec)?.quantity.totalUnits == 4)
        #expect(try store.snapshot(sessionID: session.id).items.last == item)
        let alone = try store.addItem(NewItem(id: UUID(), cls: .can, position: SIMD3(2, 1, 1)), toCommit: a.commit.id)
        #expect(try store.stockSheet(sessionID: session.id).lines.last?.groupIDs == [alone.groupID])
    }

    @Test("The live list observation emits a new sheet after each change")
    func observation() async throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        var iterator = store.observeSheet(sessionID: session.id).makeAsyncIterator()
        let empty = try await iterator.next()
        #expect(empty?.lines.isEmpty == true)
        let saved = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 7))
        let afterCommit = try await iterator.next()
        #expect(afterCommit?.totalUnits == 7)
        try store.nameGroup(saved.groups[0].group.id, sku: world.malbec.id)
        let afterNaming = try await iterator.next()
        #expect(afterNaming?.lines.map(\.name) == ["Malbec Muestra"])
        #expect(afterNaming?.line(world.malbec)?.quantity.fullCases == 1)
        #expect(afterNaming?.line(world.malbec)?.quantity.looseUnits == 1)
    }
}
