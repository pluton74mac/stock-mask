import Foundation
import StockMaskCore
import StockMaskCounting
import simd

/// `CountingStore` on StockMaskCore's `StockStore` (SQLite through GRDB, one transaction per call).
///
/// Core's calls are synchronous. They run here one at a time on a serial queue, never inside a
/// cancellable `Task` (StockMaskCore README, "Threading"; ADR 005): the awaiting caller can go
/// away, the write still completes. This is the only file that imports StockMaskCore, whose
/// record names (Commit, Item, CountedZone, CommitTrigger) overlap StockMaskCounting's and ours.
public final class CoreStockStore: CountingStore, @unchecked Sendable {
    public enum Problem: Error, Equatable { case noSession }

    private let store: StockStore
    private let queue = DispatchQueue(label: "StockMask.store", qos: .userInitiated)
    private let options: SheetOptions
    // Only touched on `queue`.
    private var session: Session?

    public init(store: StockStore, unknownName: String = "Unknown") {
        self.store = store
        options = SheetOptions(unknownName: unknownName)
    }

    /// The app's database: `<data directory>/stock.sqlite` (Application Support on the phone).
    public static func open(at url: URL) throws -> CoreStockStore { CoreStockStore(store: try StockStore.open(at: url)) }

    /// An in-memory store (tests, previews).
    public static func inMemory() throws -> CoreStockStore { CoreStockStore(store: try StockStore.inMemory()) }

    /// Runs `body` on the store's serial queue.
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func current() throws -> Session {
        guard let session else { throw Problem.noSession }
        return session
    }

    // MARK: sessions

    public func resumeSession() async throws -> ResumedSession? {
        try await run { [self] in
            guard let s = try store.activeSession() else { return nil }
            session = s
            let zone = try store.zones(venueID: s.venueID).first { $0.id == s.currentZoneID }?.name ?? ""
            let units = try store.stockSheet(sessionID: s.id, options: options).totalUnits
            return ResumedSession(counter: s.counterName, zone: zone, units: units)
        }
    }

    public func startSession(venue name: String, zone zoneName: String, counter: String) async throws {
        try await run { [self] in
            let venue = try store.venues().first { $0.name == name }
                ?? store.createVenue(name: name, country: "AR", locale: "es_AR")
            let zone = try store.zones(venueID: venue.id).first { $0.name == zoneName }
                ?? store.addZone(venueID: venue.id, name: zoneName)
            session = try store.startSession(venueID: venue.id, counterName: counter, zoneIDs: [zone.id], startZoneID: zone.id)
        }
    }

    public func sessionID() async -> UUID? { try? await run { [self] in session?.id } }

    // MARK: commits

    public func saveCommit(_ c: CommitRecord) async throws -> [GroupInfo] {
        try await run { [self] in
            let s = try current()
            guard let zoneID = s.currentZoneID else { throw Problem.noSession }
            let draft = CommitDraft(
                id: c.id, sessionID: s.id, zoneID: zoneID, anchorID: c.anchorID, pose: c.cameraTransform,
                keyframePath: c.keyframePath, trigger: c.trigger == .hold ? .hold : .shutter,
                items: c.items.map { Self.newItem($0.item, cropPath: $0.cropPath) },
                countedZone: NewCountedZone(id: c.zone.id, transform: c.zone.transform, halfExtents: c.zone.halfExtents),
                possibleMisses: c.possibleMisses.map { m in
                    NewPossibleMiss(id: m.id, cls: Self.itemClass(m.detection.cls), position: m.detection.position,
                                    confidence: m.detection.score, detectionIndex: m.detectionIndex)
                },
                matchedCount: c.matchedCount)
            let saved = try store.saveCommit(draft)
            return try saved.groups.map { try info($0.group, itemIDs: $0.itemIDs, counts: $0.counts) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        }
    }

    public func undoCommit(_ id: UUID) async throws {
        try await run { [self] in _ = try store.undoLastCommit(sessionID: try current().id, expecting: id) }
    }

    public func addPossibleMiss(_ missID: UUID, item: CountedItem) async throws -> GroupInfo {
        try await run { [self] in
            let added = try store.addPossibleMiss(missID, item: Self.newItem(item, cropPath: nil))
            return try group(added.groupID)
        }
    }

    public func groups(ofCommit id: UUID) async throws -> [GroupInfo] {
        try await run { [self] in
            try store.groups(sessionID: try current().id).filter { $0.commitID == id }
                .map { try group($0.id) }
                .filter { $0.count > 0 }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        }
    }

    // MARK: naming and products

    public func name(group id: UUID, product: UUID) async throws -> GroupInfo {
        try await run { [self] in
            _ = try store.nameGroup(id, sku: product)
            return try group(id)
        }
    }

    public func markUnknown(group id: UUID) async throws -> GroupInfo {
        try await run { [self] in
            _ = try store.markGroupUnknown(id)
            return try group(id)
        }
    }

    public func products(matching query: String) async throws -> [ProductInfo] {
        try await run { [self] in try store.searchSKUs(venueID: try current().venueID, matching: query).map(Self.product) }
    }

    public func createProduct(_ d: ProductDraft) async throws -> ProductInfo {
        try await run { [self] in
            Self.product(try store.createSKU(venueID: try current().venueID,
                                             SKUFields(code: d.code, name: d.name, brand: d.brand, sizeML: d.sizeML,
                                                       unitsPerCase: d.unitsPerCase)))
        }
    }

    public func addManualLine(product: UUID, fullCases: Int, looseUnits: Int, note: String) async throws {
        try await run { [self] in
            let s = try current()
            guard let zoneID = s.currentZoneID else { throw Problem.noSession }
            _ = try store.addManualLine(sessionID: s.id, zoneID: zoneID, skuID: product, fullCases: fullCases,
                                        looseUnits: looseUnits, note: note.isEmpty ? nil : note)
        }
    }

    // MARK: the sheet, review, export

    public func sheet() async throws -> StockSheetSummary {
        try await run { [self] in
            guard let s = session else { return StockSheetSummary() }
            let sheet = try store.stockSheet(sessionID: s.id, options: options)
            let names = Dictionary(uniqueKeysWithValues: sheet.lines.map { ($0.id, $0.name) })
            var blockers: [String] = [], warnings: [String] = []
            for issue in sheet.review.issues {
                switch issue {
                case .unnamedGroup(let key): blockers.append("\(names[key] ?? "A group") has no product yet")
                case .possibleMissesLeft(_, let n): warnings.append("\(n) possible misses (amber +) not checked")
                case .zoneWithoutCounts(let z):
                    warnings.append("\(sheet.zones.first { $0.id == z }?.name ?? "A zone") has no counts")
                case .unitsPerCaseMissing(let key): warnings.append("\(names[key] ?? "A product") needs units per case")
                }
            }
            return StockSheetSummary(lines: sheet.lines.map { line in
                SheetLine(id: "\(line.id)", label: line.name, product: line.sku.map(Self.product),
                          groupID: line.unknownGroupID, units: line.quantity.totalUnits ?? 0,
                          fullCases: line.quantity.fullCases, looseUnits: line.quantity.looseUnits,
                          source: line.sources.map(\.rawValue).joined(separator: "+"),
                          flagged: line.flags.contains(.unitsPerCaseMissing))
            }, blockers: blockers, warnings: warnings)
        }
    }

    public func lock() async throws {
        try await run { [self] in session = try store.lockSession(try current().id) }
    }

    public func export(_ format: ExportFormat, to directory: URL) async throws -> URL {
        try await run { [self] in
            let s = try current()
            let sheet = try store.stockSheet(sessionID: s.id, options: options)
            let file = switch format {
            case .csvArgentina: StockSheetExport.csv(sheet, dialect: .excelArgentina)
            case .csvStandard: StockSheetExport.csv(sheet, dialect: .standard)
            case .xlsx: StockSheetExport.xlsx(sheet)
            }
            let url = directory.appendingPathComponent(file.fileName)
            try file.data.write(to: url, options: .atomic)
            try store.recordEvent(.sheetExported, sessionID: s.id, payload: ["format": .string(format.rawValue)])
            return url
        }
    }

    // MARK: mapping

    /// A group with its live items (not removed, commit not undone) and what they count as.
    private func group(_ id: UUID) throws -> GroupInfo {
        guard let g = try store.groups(sessionID: try current().id).first(where: { $0.id == id }) else {
            throw StoreError.notFound("group", id)
        }
        let items = try store.items(inGroup: id)
        var counts: [ItemClass: Int] = [:]
        for i in items { counts[i.cls.countsAs, default: 0] += 1 }
        return try info(g, itemIDs: items.map(\.id), counts: counts)
    }

    private func info(_ g: ItemGroup, itemIDs: [UUID], counts: [ItemClass: Int]) throws -> GroupInfo {
        let kind = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? .bottle
        return GroupInfo(id: g.id, commitID: g.commitID ?? UUID(), label: "\(options.unknownName) \(g.label)",
                         cls: ObjectClass(rawValue: kind.rawValue) ?? .bottle, itemIDs: itemIDs,
                         product: try g.skuID.flatMap { try store.sku(id: $0) }.map(Self.product),
                         markedUnknown: g.state == .markedUnknown)
    }

    static func product(_ s: SKU) -> ProductInfo {
        ProductInfo(id: s.id, name: s.name, sizeML: s.sizeML, unitsPerCase: s.unitsPerCase, code: s.code ?? "",
                    productKey: s.productKey)
    }

    static func itemClass(_ c: ObjectClass) -> ItemClass { ItemClass(rawValue: c.rawValue) ?? .bottle }

    static func newItem(_ i: CountedItem, cropPath: String?) -> NewItem {
        NewItem(id: i.id, cls: itemClass(i.cls), position: i.position, top: i.top, productKey: i.productKey,
                confidence: i.confidence, detectionIndex: i.detectionIndex, groupKey: i.groupKey, cropPath: cropPath)
    }
}
