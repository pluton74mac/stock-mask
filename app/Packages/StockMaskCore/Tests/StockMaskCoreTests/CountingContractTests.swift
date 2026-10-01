import Foundation
import Testing
@testable import StockMaskCore

/// What StockMaskCounting needs from the store (docs/mvp-test-app.md, "As built"): each item's top,
/// product key and confidence survive a relaunch, and a bottle counted by its top is a bottle.
@Suite("Counting contract")
struct CountingContractTests {
    @Test("A bottle counted by its top is one bottle unit: never its own product or class line")
    func bottleTopsAreBottles() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        // Front row: 3 bottles (group key 0). Rows behind, seen by their tops: 4 (group key 1).
        var draft = makeDraft(session: session, zone: world.deposito, bottles: 3)
        draft.items += makeDraft(session: session, zone: world.deposito, tops: 4, x: 1).items.map { item in
            var top = item
            top.groupKey = 1
            return top
        }
        let saved = try store.saveCommit(draft)
        #expect(saved.groups.map(\.counts) == [[.bottle: 3], [.bottle: 4]])
        #expect(try store.snapshot(sessionID: session.id).items.filter { $0.cls == .bottleTop }.count == 4)

        // Unnamed, the tops' group is a line of 4 units, like any group of bottles.
        var sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Unknown A", "Unknown B"])
        #expect(sheet.lines.map(\.quantity.totalUnits) == [3, 4])

        // Named as the same product, front and back rows are one line of 7 bottles.
        for group in saved.groups { try store.nameGroup(group.group.id, sku: world.malbec.id) }
        sheet = try store.stockSheet(sessionID: session.id)
        #expect(sheet.lines.map(\.name) == ["Malbec Muestra"])
        let malbec = try #require(sheet.line(world.malbec))
        #expect(malbec.quantity.countedUnits == 7 && malbec.quantity.countedCases == 0)
        #expect(malbec.quantity.totalUnits == 7 && malbec.quantity.fullCases == 1 && malbec.quantity.looseUnits == 1)
        #expect(malbec.parts.count == 1)

        // The export has the same single line.
        let rows = StockSheetExport.rows(sheet, layout: .byZoneAndSource)
        #expect(rows.count == 1)
        #expect(rows[0][13] == .integer(7))
    }

    @Test("Top, product key, confidence and detection index read back for CommitEngine(items:zones:)")
    func engineFieldsRoundTrip() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let suggested = world.fernet.productKey
        let items = [
            NewItem(id: UUID(), cls: .bottle, position: SIMD3(0.1, 1.2, -0.8), top: SIMD3(0.1, 1.34, -0.8),
                    productKey: suggested, confidence: 0.91, detectionIndex: 4, groupKey: 0),
            NewItem(id: UUID(), cls: .bottleTop, position: SIMD3(0.19, 1.34, -0.9), top: SIMD3(0.19, 1.34, -0.9),
                    confidence: 0.77, detectionIndex: 7, groupKey: 0),
            NewItem(id: UUID(), cls: .case, position: SIMD3(0.5, 0.4, -0.85), top: SIMD3(.nan, 0, 0), confidence: .nan,
                    detectionIndex: 9, groupKey: 1),
        ]
        var draft = makeDraft(session: session, zone: world.deposito)
        draft.items = items
        draft.possibleMisses = [NewPossibleMiss(
            id: UUID(), cls: .bottleTop, position: SIMD3(0.28, 1.35, -0.95), top: SIMD3(0.28, 1.35, -0.95),
            confidence: 0.66, detectionIndex: 11)]
        try store.saveCommit(draft)

        let relaunched = try store.snapshot(sessionID: session.id)
        #expect(relaunched.items.map(\.id) == items.map(\.id))
        #expect(relaunched.items.map(\.top) == [items[0].top, items[1].top, nil])  // a NaN top is no top
        #expect(relaunched.items.map(\.productKey) == [suggested, nil, nil])
        #expect(relaunched.items.map(\.confidence) == [0.91, 0.77, nil])
        #expect(relaunched.items.map(\.detectionIndex) == [4, 7, 9])
        let miss = try #require(relaunched.openPossibleMisses.first)
        #expect(miss.top == SIMD3(0.28, 1.35, -0.95) && miss.detectionIndex == 11 && miss.cls == .bottleTop)
        #expect(relaunched.countedZones.map(\.transform) == [draft.countedZone.transform])
        #expect(relaunched.countedZones.map(\.halfExtents) == [draft.countedZone.halfExtents])
    }

    @Test("Product keys follow the confirmed product; SKU.productKey is stable and distinct")
    func productKeys() throws {
        let world = try World.make()
        let store = world.store
        #expect(world.malbec.productKey == world.malbec.id.productKey)
        #expect(world.malbec.productKey >= 0)
        let keys = try store.skus(venueID: world.venue.id).map(\.productKey)
        #expect(Set(keys).count == keys.count)
        let known = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        #expect(known.productKey == 0x0123_4567_89AB_CDEF)
        #expect(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-0000-000000000000")!.productKey == Int.max)

        let session = try world.startSession()
        var draft = makeDraft(session: session, zone: world.deposito, bottles: 3)
        for i in draft.items.indices { draft.items[i].productKey = world.fernet.productKey }  // the engine's suggestion
        let saved = try store.saveCommit(draft)
        let group = saved.groups[0].group.id
        #expect(try store.items(inGroup: group).map(\.productKey) == Array(repeating: world.fernet.productKey, count: 3))

        try store.nameGroup(group, sku: world.malbec.id)
        #expect(try store.items(inGroup: group).allSatisfy { $0.productKey == world.malbec.productKey })
        try store.markGroupUnknown(group)
        #expect(try store.items(inGroup: group).allSatisfy { $0.productKey == nil })
        try store.nameGroup(group, sku: world.lager.id)

        // Items joining a named group take its product; split into a new group, they lose it.
        let tapped = try store.addItem(NewItem(id: UUID(), cls: .bottle, position: SIMD3(1, 1, 1)), toCommit: saved.commit.id,
                                       groupID: group)
        #expect(tapped.productKey == world.lager.productKey)
        let split = try store.moveItems([saved.items[0].id])
        #expect(try store.items(inGroup: split.id).map(\.productKey) == [nil])
        try store.moveItems([saved.items[0].id], toGroup: group)
        #expect(try store.items(inGroup: group).count == 4)
        #expect(try store.items(inGroup: group).allSatisfy { $0.productKey == world.lager.productKey })
    }

    @Test("A tapped amber \"+\" keeps the engine's item: same id, position and top")
    func possibleMissKeepsEngineItem() throws {
        let world = try World.make()
        let store = world.store
        let session = try world.startSession()
        let saved = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 2, misses: 2))
        try store.nameGroup(saved.groups[0].group.id, sku: world.malbec.id)

        // What CommitEngine.addDetection returned for the first miss.
        let engineItem = NewItem(
            id: UUID(), cls: .bottle, position: SIMD3(0.05, 0.5, 1.31), top: SIMD3(0.05, 0.64, 1.31), confidence: 0.41,
            detectionIndex: 3)
        let added = try store.addPossibleMiss(saved.possibleMisses[0].id, item: engineItem, toGroup: saved.groups[0].group.id)
        #expect(added.id == engineItem.id)
        #expect(added.position == engineItem.position && added.top == engineItem.top)
        #expect(added.productKey == world.malbec.productKey)
        #expect(added.cropPath == nil)  // the misses in this fixture have no crop

        // Without the engine's item (after a relaunch), it is made from the stored miss.
        let fromStore = try store.addPossibleMiss(saved.possibleMisses[1].id)
        #expect(fromStore.position == saved.possibleMisses[1].position)
        #expect(fromStore.cls == .bottle)

        let snapshot = try store.snapshot(sessionID: session.id)
        #expect(snapshot.items.contains(added))
        #expect(snapshot.openPossibleMisses.isEmpty)
        #expect(try store.stockSheet(sessionID: session.id).line(world.malbec)?.quantity.totalUnits == 3)
    }
}
