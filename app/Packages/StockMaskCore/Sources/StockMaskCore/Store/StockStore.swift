import Foundation
import GRDB

/// The local database (ADR 005): venue, catalog, sessions, commits, the stock sheet and the audit
/// log, in one SQLite file through GRDB.
///
/// Every method is synchronous and runs in its own transaction: when it returns, the change is on
/// disk, and when it throws, nothing changed (FR-7). Each change writes its audit event in the
/// same transaction. Call from any thread; writes are serialised.
public final class StockStore: Sendable {
    let writer: any DatabaseWriter
    let clock: @Sendable () -> Date

    /// Opens or creates the database file and migrates it.
    ///
    /// WAL mode, `synchronous = FULL` and `fullfsync` make each transaction durable across a
    /// crash, a force-quit or a dead battery (PRD §10). The parent directory is created if needed.
    public static func open(at url: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws -> StockStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA fullfsync = ON")
            try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        // GRDB sets `synchronous = NORMAL` on the writer when it turns WAL on, after prepareDatabase.
        // In WAL mode NORMAL can lose the last commits on power loss; FULL syncs the WAL at every
        // commit. The pool keeps this one writer connection, so setting it once is enough.
        try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
        return try StockStore(writer: pool, clock: clock)
    }

    /// A throwaway in-memory database, for previews and tests.
    public static func inMemory(clock: @escaping @Sendable () -> Date = { Date() }) throws -> StockStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try StockStore(writer: try DatabaseQueue(configuration: config), clock: clock)
    }

    init(writer: any DatabaseWriter, clock: @escaping @Sendable () -> Date) throws {
        self.writer = writer
        self.clock = clock
        try Schema.migrator.migrate(writer)
    }

    /// For GRDBQuery and `ValueObservation` in the app. Writes go through the store's methods.
    public var databaseReader: any DatabaseReader { writer }

    // MARK: - Shared helpers

    /// The clock's time, rounded to the millisecond as the database stores it.
    func timestamp() -> Date { DBTime.normalize(clock()) }

    /// Appends one audit event inside the caller's transaction.
    static func log(
        _ db: Database, _ type: EventType, venue: UUID? = nil, session: UUID? = nil, at ts: Date,
        _ payload: [String: JSONValue] = [:]
    ) throws {
        try Event(
            id: UUID(), venueID: venue, sessionID: session, ts: ts, type: type,
            payload: JSONValue.object(payload).jsonText()
        ).insert(db)
    }

    static func requireVenue(_ db: Database, _ id: UUID) throws -> Venue {
        guard let venue = try Venue.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("venue", id) }
        return venue
    }

    static func requireSession(_ db: Database, _ id: UUID) throws -> Session {
        guard let session = try Session.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("session", id) }
        return session
    }

    /// FR-9: everything that changes a session's counts goes through here.
    static func requireWritableSession(_ db: Database, _ id: UUID) throws -> Session {
        let session = try requireSession(db, id)
        if session.status == .locked { throw StoreError.sessionLocked(id) }
        return session
    }

    static func requireZone(_ db: Database, _ id: UUID, venue: UUID) throws -> Zone {
        guard let zone = try Zone.fetchOne(db, key: id.dbKey), zone.venueID == venue else {
            throw StoreError.notFound("zone", id)
        }
        return zone
    }

    static func requireSKU(_ db: Database, _ id: UUID, venue: UUID) throws -> SKU {
        guard let sku = try SKU.fetchOne(db, key: id.dbKey), sku.venueID == venue else {
            throw StoreError.notFound("sku", id)
        }
        return sku
    }

    // MARK: - Venue and zones (FR-1, FR-2)

    @discardableResult
    public func createVenue(name: String, country: String, locale: String) throws -> Venue {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("A venue needs a name") }
        let now = timestamp()
        return try writer.write { db in
            let venue = Venue(id: UUID(), name: name, country: country.uppercased(), locale: locale, createdAt: now)
            try venue.insert(db)
            try Self.log(db, .venueCreated, venue: venue.id, at: now, ["name": .string(name)])
            return try Self.requireVenue(db, venue.id)
        }
    }

    public func venues() throws -> [Venue] {
        try writer.read { db in try Venue.order(Column("created_at"), Column("name")).fetchAll(db) }
    }

    public func venue(id: UUID) throws -> Venue? {
        try writer.read { db in try Venue.fetchOne(db, key: id.dbKey) }
    }

    /// Adds a zone at the end of the venue's zone list.
    @discardableResult
    public func addZone(venueID: UUID, name: String) throws -> Zone {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("A zone needs a name") }
        let now = timestamp()
        return try writer.write { db in
            _ = try Self.requireVenue(db, venueID)
            let sort = (try Int.fetchOne(
                db, sql: "SELECT MAX(sort) FROM zone WHERE venue_id = ?", arguments: [venueID.dbKey]) ?? -1) + 1
            let zone = Zone(id: UUID(), venueID: venueID, name: name, sort: sort, mapFile: nil, createdAt: now)
            try zone.insert(db)
            try Self.log(db, .zoneCreated, venue: venueID, at: now, ["zone": .init(zone.id), "name": .string(name)])
            return try Self.requireZone(db, zone.id, venue: venueID)
        }
    }

    public func zones(venueID: UUID) throws -> [Zone] {
        try writer.read { db in
            try Zone.filter(Column("venue_id") == venueID.dbKey).order(Column("sort"), Column("name")).fetchAll(db)
        }
    }

    @discardableResult
    public func renameZone(_ id: UUID, to name: String) throws -> Zone {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("A zone needs a name") }
        return try updateZone(id, ["name": .string(name)]) { $0.name = name }
    }

    /// FR-24: records where the zone's ARWorldMap was saved (relative to the app's data directory).
    @discardableResult
    public func setZoneMapFile(_ id: UUID, path: String?) throws -> Zone {
        try updateZone(id, ["map_file": .init(path)]) { $0.mapFile = path }
    }

    private func updateZone(_ id: UUID, _ payload: [String: JSONValue], _ change: (inout Zone) -> Void) throws -> Zone {
        let now = timestamp()
        return try writer.write { db in
            guard var zone = try Zone.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("zone", id) }
            change(&zone)
            try zone.update(db)
            try Self.log(db, .zoneUpdated, venue: zone.venueID, at: now, payload.merging(["zone": .init(id)]) { $1 })
            return zone
        }
    }

    // MARK: - Catalog (FR-3)

    /// Creates a product. Allowed at any time, including mid-count.
    @discardableResult
    public func createSKU(venueID: UUID, _ fields: SKUFields) throws -> SKU {
        let fields = try fields.validated()
        let now = timestamp()
        return try writer.write { db in
            _ = try Self.requireVenue(db, venueID)
            let sku = SKU(id: UUID(), venueID: venueID, fields: fields, createdAt: now, updatedAt: now)
            try sku.insert(db)
            try Self.log(db, .skuCreated, venue: venueID, at: now, ["sku": .init(sku.id), "name": .string(fields.name)])
            return try Self.requireSKU(db, sku.id, venue: venueID)
        }
    }

    /// Edits a product. Sheets are computed from the catalog, so this also changes how earlier
    /// sessions show the product; the lock event keeps the totals as they were at lock time.
    @discardableResult
    public func updateSKU(id: UUID, _ fields: SKUFields) throws -> SKU {
        let fields = try fields.validated()
        let now = timestamp()
        return try writer.write { db in
            guard var sku = try SKU.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("sku", id) }
            let before = sku.fields
            sku.fields = fields
            sku.updatedAt = now
            try sku.update(db)
            try Self.log(db, .skuUpdated, venue: sku.venueID, at: now, [
                "sku": .init(id), "before": before.json, "after": fields.json,
            ])
            return try Self.requireSKU(db, id, venue: sku.venueID)
        }
    }

    public func sku(id: UUID) throws -> SKU? {
        try writer.read { db in try SKU.fetchOne(db, key: id.dbKey) }
    }

    /// The venue's catalog, sorted by name.
    public func skus(venueID: UUID) throws -> [SKU] {
        try writer.read { db in try Self.catalog(db, venueID) }
    }

    static func catalog(_ db: Database, _ venueID: UUID) throws -> [SKU] {
        try SKU.filter(Column("venue_id") == venueID.dbKey).fetchAll(db).sorted(by: SKU.displayOrder)
    }

    /// FR-28 product search: every word of the query must appear in the name, brand, code,
    /// category, size or a barcode, ignoring case and accents. Name matches come first.
    public func searchSKUs(venueID: UUID, matching query: String, limit: Int = 50) throws -> [SKU] {
        let words = Text.fold(query).split(separator: " ").map(String.init)
        let all = try skus(venueID: venueID)
        guard !words.isEmpty else { return Array(all.prefix(limit)) }
        let scored: [(SKU, Int)] = all.compactMap { sku in
            let name = Text.fold(sku.name)
            let haystack = [
                name, Text.fold(sku.brand ?? ""), Text.fold(sku.code ?? ""), Text.fold(sku.category ?? ""),
                sku.sizeML.map { "\($0)ml \($0)" } ?? "", sku.unitBarcode ?? "", sku.caseGTIN ?? "",
            ].joined(separator: " ")
            guard words.allSatisfy(haystack.contains) else { return nil }
            let score = name.hasPrefix(words[0]) ? 0 : (words.allSatisfy(name.contains) ? 1 : 2)
            return (sku, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : SKU.displayOrder($0.0, $1.0) }
            .prefix(limit).map(\.0)
    }

    /// A barcode the camera or scanner read, matched to the catalog (ADR 004: case barcode first).
    public struct BarcodeMatch: Equatable, Sendable {
        public enum Kind: String, Sendable { case unit, `case` }
        public var sku: SKU
        public var kind: Kind
    }

    /// Finds the product with this unit barcode or case GTIN. GTIN-8/12/13/14 compare as GTIN-14,
    /// so "07791234567893" matches "7791234567893".
    public func findSKU(venueID: UUID, barcode: String) throws -> BarcodeMatch? {
        let key = GTIN.matchKey(barcode)
        guard !key.isEmpty else { return nil }
        for sku in try skus(venueID: venueID) {
            if let c = sku.caseGTIN, GTIN.matchKey(c) == key { return BarcodeMatch(sku: sku, kind: .case) }
            if let u = sku.unitBarcode, GTIN.matchKey(u) == key { return BarcodeMatch(sku: sku, kind: .unit) }
        }
        return nil
    }

    // MARK: - Events

    /// Records an app event (pause, resume, export, drift alarm...). Allowed on locked sessions.
    public func recordEvent(_ type: EventType, sessionID: UUID, payload: [String: JSONValue] = [:]) throws {
        let now = timestamp()
        try writer.write { db in
            let session = try Self.requireSession(db, sessionID)
            try Self.log(db, type, venue: session.venueID, session: sessionID, at: now, payload)
        }
    }

    /// The session's audit log, oldest first.
    public func events(sessionID: UUID) throws -> [Event] {
        try writer.read { db in
            try Event.fetchAll(
                db, sql: "SELECT * FROM event WHERE session_id = ? ORDER BY ts, rowid", arguments: [sessionID.dbKey])
        }
    }

    /// Venue-level events (catalog, zones), oldest first.
    public func events(venueID: UUID) throws -> [Event] {
        try writer.read { db in
            try Event.fetchAll(
                db, sql: "SELECT * FROM event WHERE venue_id = ? AND session_id IS NULL ORDER BY ts, rowid",
                arguments: [venueID.dbKey])
        }
    }
}

extension SKU {
    /// By name, then size, then code, ignoring case and accents.
    static func displayOrder(_ a: SKU, _ b: SKU) -> Bool {
        let na = Text.fold(a.name), nb = Text.fold(b.name)
        if na != nb { return na < nb }
        if a.sizeML != b.sizeML { return (a.sizeML ?? 0) < (b.sizeML ?? 0) }
        if a.code != b.code { return (a.code ?? "") < (b.code ?? "") }
        return a.id.dbKey < b.id.dbKey
    }
}

extension SKUFields {
    var json: JSONValue {
        [
            "code": .init(code), "name": .string(name), "brand": .init(brand), "category": .init(category),
            "size_ml": .init(sizeML), "units_per_case": .init(unitsPerCase), "unit_barcode": .init(unitBarcode),
            "case_gtin": .init(caseGTIN),
        ]
    }
}

/// Text folding for search and duplicate detection.
enum Text {
    /// Lowercase, no accents, punctuation turned into single spaces.
    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var lastWasSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
