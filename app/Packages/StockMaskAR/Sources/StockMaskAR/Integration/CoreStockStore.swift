import Foundation
import StockMaskCore
import StockMaskCounting
import simd

// INTEGRATION: this file is written against the StockMaskCore *shim* (Shims/StockMaskCore). When
// the real package (claude/app-core) merges, rewrite these method bodies against its API; the
// `StockStore` protocol above it stays as it is, so nothing else in StockMaskAR changes.

/// `StockStore` on top of StockMaskCore: venue, zone, session, commits, items, groups, products,
/// manual lines, the stock sheet and the export.
public actor CoreStockStore: StockStore {
    private let db: StockDatabase
    private var venue: Venue?
    private var zone: Zone?
    private var session: Session?

    public init(database: StockDatabase = StockDatabase()) { db = database }

    public enum Problem: Error, Equatable { case noSession, unknownGroup }

    public func startSession(venue name: String, zone zoneName: String, counter: String) async throws {
        let v = Venue(name: name, country: "AR")
        let z = Zone(venueID: v.id, name: zoneName)
        let s = Session(venueID: v.id, counterName: counter)
        await db.insert(v)
        await db.insert(z)
        await db.insert(s)
        venue = v
        zone = z
        session = s
    }

    public func saveCommit(_ c: CommitRecord) async throws -> [GroupInfo] {
        guard let session, let zone else { throw Problem.noSession }
        // One group per distinct key, labelled "Unknown A", "Unknown B", ... in key order.
        let keys = Array(Set(c.items.map(\.groupKey))).sorted()
        var byKey: [Int: ItemGroup] = [:]
        let already = await db.groups.filter { $0.sessionID == session.id }.count
        for (n, key) in keys.enumerated() {
            byKey[key] = ItemGroup(sessionID: session.id, label: StockDatabase.unknownLabel(already + n))
        }
        let commit = Commit(id: c.id, sessionID: session.id, zoneID: zone.id, anchorID: c.id,
                            pose: Self.flat(c.cameraTransform), keyframeFile: c.keyframePath)
        let zoneRecord = CountedZoneRecord(id: UUID(), commitID: c.id, transform: Self.flat(c.zoneTransform),
                                           halfExtents: [c.zoneHalfExtents.x, c.zoneHalfExtents.y, c.zoneHalfExtents.z])
        let items = c.items.map {
            Item(id: $0.id, commitID: c.id, position: [$0.position.x, $0.position.y, $0.position.z], cls: $0.cls.rawValue,
                 confidence: $0.score, groupID: byKey[$0.groupKey]?.id)
        }
        await db.saveCommit(commit, zone: zoneRecord, items: items, groups: keys.compactMap { byKey[$0] })
        return try await groups(ofCommit: c.id)
    }

    public func undoCommit(_ id: UUID) async throws { try await db.setUndone(commitID: id) }

    public func addItem(_ r: ItemRecord, toCommit id: UUID) async throws -> GroupInfo {
        guard let session else { throw Problem.noSession }
        let group = ItemGroup(sessionID: session.id, label: await db.nextUnknownLabel(sessionID: session.id))
        await db.insert(group)
        await db.insert(Item(id: r.id, commitID: id, position: [r.position.x, r.position.y, r.position.z], cls: r.cls.rawValue,
                             confidence: r.score, groupID: group.id))
        guard let info = try await groups(ofCommit: id).first(where: { $0.id == group.id }) else { throw Problem.unknownGroup }
        return info
    }

    public func groups(ofCommit id: UUID) async throws -> [GroupInfo] {
        let items = await db.items.filter { $0.commitID == id && !$0.removed }
        let all = await db.groups
        let skus = await db.skus
        var members: [UUID: (ids: [UUID], cls: String)] = [:]
        for i in items { if let g = i.groupID { members[g, default: ([], i.cls)].ids.append(i.id) } }
        var out: [GroupInfo] = []
        for (gid, m) in members {
            guard let g = all.first(where: { $0.id == gid }) else { continue }
            let product = g.skuID.flatMap { s in skus.first { $0.id == s } }.map(Self.info)
            out.append(GroupInfo(id: gid, commitID: id, key: 0, label: g.label, cls: ObjectClass(rawValue: m.cls) ?? .bottle,
                                 itemIDs: m.ids, product: product))
        }
        out.sort { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        for k in out.indices { out[k].key = k }
        return out
    }

    public func name(group id: UUID, product: UUID?) async throws { try await db.assign(groupID: id, skuID: product) }

    public func products(matching query: String) async throws -> [ProductInfo] {
        await db.searchSkus(query).map(Self.info)
    }

    public func createProduct(_ d: ProductDraft) async throws -> ProductInfo {
        let sku = Sku(code: d.code, name: d.name, brand: d.brand, sizeML: d.sizeML, unitsPerCase: d.unitsPerCase)
        await db.insert(sku)
        return Self.info(sku)
    }

    public func addManualLine(product: UUID, fullCases: Int, looseUnits: Int, note: String) async throws {
        guard let session, let zone else { throw Problem.noSession }
        await db.insert(ManualLine(sessionID: session.id, zoneID: zone.id, skuID: product, fullCases: fullCases,
                                   looseUnits: looseUnits, note: note))
    }

    public func sheet() async throws -> StockSheetSummary {
        guard let session else { return StockSheetSummary() }
        let sheet = await db.sheet(sessionID: session.id)
        let skus = await db.skus
        return StockSheetSummary(lines: sheet.lines.map { l in
            SheetLine(id: l.id, label: l.label, product: l.skuID.flatMap { s in skus.first { $0.id == s } }.map(Self.info),
                      groupID: l.groupID, units: l.totalUnits, fullCases: l.fullCases, looseUnits: l.looseUnits,
                      source: l.source)
        })
    }

    public func export(_ format: ExportFormat, to directory: URL) async throws -> URL {
        guard let session, let venue, let zone else { throw Problem.noSession }
        guard format != .xlsx else { throw CoreShimError.xlsxNotInShim }   // the real StockMaskCore writes XLSX
        let sheet = await db.sheet(sessionID: session.id)
        let csv = CSVExport.csv(sheet, session: session, venue: venue, zone: zone.name, skus: await db.skus,
                                argentina: format == .csvArgentina)
        let stamp = ISO8601DateFormatter.string(from: session.startedAt, timeZone: .current,
                                                formatOptions: [.withFullDate])
        let url = directory.appendingPathComponent("stock-\(stamp)-\(format == .csvArgentina ? "excel" : "standard").csv")
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    static func info(_ s: Sku) -> ProductInfo {
        ProductInfo(id: s.id, name: s.name, sizeML: s.sizeML, unitsPerCase: s.unitsPerCase, code: s.code)
    }

    static func flat(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
