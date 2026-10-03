import Foundation
import GRDB
import simd

// The domain model (PRD §11, without `depth_multiplier`). Each type is also a GRDB record with an
// explicit column mapping: UUIDs as lowercase text, dates as GRDB's UTC text, positions as REAL
// columns, 4×4 matrices as a JSON array of 16 floats in column-major order.

// MARK: - Venue

/// FR-1. `country` (ISO 3166-1 alpha-2, "AR") and `locale` (BCP 47, "es-AR") set the default
/// language and CSV format. Sizes are always millilitres.
public struct Venue: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var country: String
    public var locale: String
    public var createdAt: Date

    /// "Excel (Argentina)" where the venue's locale writes decimals with a comma, else standard.
    public var defaultCSVDialect: CSVDialect {
        Locale(identifier: locale).decimalSeparator == "," ? .excelArgentina : .standard
    }
}

extension Venue: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "venue"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        name = try row.decode(forColumn: "name")
        country = try row.decode(forColumn: "country")
        locale = try row.decode(forColumn: "locale")
        createdAt = try row.time("created_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["name"] = name
        container["country"] = country
        container["locale"] = locale
        container["created_at"] = DBTime.text(createdAt)
    }
}

// MARK: - Zone

/// FR-2: a named storage area with its own spatial map. `mapFile` is the zone's ARWorldMap,
/// as a path relative to the app's data directory.
public struct Zone: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var venueID: UUID
    public var name: String
    public var sort: Int
    public var mapFile: String?
    public var createdAt: Date
}

extension Zone: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "zone"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        venueID = try row.decode(forColumn: "venue_id")
        name = try row.decode(forColumn: "name")
        sort = try row.decode(forColumn: "sort")
        mapFile = try row.decode(forColumn: "map_file")
        createdAt = try row.time("created_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["venue_id"] = venueID.dbKey
        container["name"] = name
        container["sort"] = sort
        container["map_file"] = mapFile
        container["created_at"] = DBTime.text(createdAt)
    }
}

// MARK: - SKU

/// The editable fields of a product (FR-3). Used to create, edit and import products.
public struct SKUFields: Hashable, Sendable {
    public var code: String?
    public var name: String
    public var brand: String?
    public var category: String?
    public var sizeML: Int?
    public var unitsPerCase: Int?
    public var unitBarcode: String?
    /// GTIN-14 of the case (ADR 004): the code the camera can read on a carton.
    public var caseGTIN: String?

    public init(
        code: String? = nil, name: String, brand: String? = nil, category: String? = nil,
        sizeML: Int? = nil, unitsPerCase: Int? = nil, unitBarcode: String? = nil, caseGTIN: String? = nil
    ) {
        self.code = code
        self.name = name
        self.brand = brand
        self.category = category
        self.sizeML = sizeML
        self.unitsPerCase = unitsPerCase
        self.unitBarcode = unitBarcode
        self.caseGTIN = caseGTIN
    }

    /// Trims text, turns blanks into nil and checks the numbers. Throws `StoreError.invalid`.
    func validated() throws -> SKUFields {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        var f = self
        f.code = clean(code)
        f.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        f.brand = clean(brand)
        f.category = clean(category)
        f.unitBarcode = clean(unitBarcode).map(GTIN.stripSeparators)
        f.caseGTIN = clean(caseGTIN).map(GTIN.stripSeparators)
        guard !f.name.isEmpty else { throw StoreError.invalid("A product needs a name") }
        if let s = f.sizeML, s <= 0 { throw StoreError.invalid("size_ml must be positive, got \(s)") }
        if let u = f.unitsPerCase, u < 1 { throw StoreError.invalid("units_per_case must be at least 1, got \(u)") }
        return f
    }
}

/// A product in the venue's catalog (FR-3).
public struct SKU: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var venueID: UUID
    public var fields: SKUFields
    public var createdAt: Date
    public var updatedAt: Date

    public var code: String? { fields.code }
    public var name: String { fields.name }
    public var brand: String? { fields.brand }
    public var category: String? { fields.category }
    public var sizeML: Int? { fields.sizeML }
    public var unitsPerCase: Int? { fields.unitsPerCase }
    public var unitBarcode: String? { fields.unitBarcode }
    public var caseGTIN: String? { fields.caseGTIN }

    /// The product as StockMaskCounting's `productKey` (`Detection.productKey`,
    /// `CommitEngine.setProductKey`): the first 63 bits of the id. Stable across launches and
    /// devices, so the AR layer needs no mapping table.
    public var productKey: Int { id.productKey }
}

extension UUID {
    /// A non-negative Int from the UUID's first 8 bytes (see `SKU.productKey`).
    public var productKey: Int {
        withUnsafeBytes(of: uuid) { raw in
            Int(truncatingIfNeeded: raw.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & 0x7FFF_FFFF_FFFF_FFFF)
        }
    }
}

extension SKU: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sku"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        venueID = try row.decode(forColumn: "venue_id")
        fields = SKUFields(
            code: try row.decode(forColumn: "code"),
            name: try row.decode(forColumn: "name"),
            brand: try row.decode(forColumn: "brand"),
            category: try row.decode(forColumn: "category"),
            sizeML: try row.decode(forColumn: "size_ml"),
            unitsPerCase: try row.decode(forColumn: "units_per_case"),
            unitBarcode: try row.decode(forColumn: "unit_barcode"),
            caseGTIN: try row.decode(forColumn: "case_gtin"))
        createdAt = try row.time("created_at")
        updatedAt = try row.time("updated_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["venue_id"] = venueID.dbKey
        container["code"] = fields.code
        container["name"] = fields.name
        container["brand"] = fields.brand
        container["category"] = fields.category
        container["size_ml"] = fields.sizeML
        container["units_per_case"] = fields.unitsPerCase
        container["unit_barcode"] = fields.unitBarcode
        container["case_gtin"] = fields.caseGTIN
        container["created_at"] = DBTime.text(createdAt)
        container["updated_at"] = DBTime.text(updatedAt)
    }
}

// MARK: - Session

/// A count (FR-6). One active (open or review) session per device.
public struct Session: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var venueID: UUID
    public var counterName: String
    public var status: SessionStatus
    /// The zone the counter is in; resume reopens this zone's map.
    public var currentZoneID: UUID?
    public var startedAt: Date
    /// Set when the session is locked.
    public var finishedAt: Date?

    public var isLocked: Bool { status == .locked }
}

extension Session: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        venueID = try row.decode(forColumn: "venue_id")
        counterName = try row.decode(forColumn: "counter_name")
        let rawStatus: String = try row.decode(forColumn: "status")
        guard let status = SessionStatus(rawValue: rawStatus) else {
            throw StoreError.invalid("Unknown session status \(rawStatus)")
        }
        self.status = status
        currentZoneID = try row.decode(forColumn: "current_zone_id")
        startedAt = try row.time("started_at")
        finishedAt = try row.optionalTime("finished_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["venue_id"] = venueID.dbKey
        container["counter_name"] = counterName
        container["status"] = status.rawValue
        container["current_zone_id"] = currentZoneID?.dbKey
        container["started_at"] = DBTime.text(startedAt)
        container["finished_at"] = finishedAt.map(DBTime.text)
    }
}

/// The zones chosen for a session (FR-6). Zones the counter switches to are added.
struct SessionZone: FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "session_zone"
    var id: UUID
    var sessionID: UUID
    var zoneID: UUID
    var sort: Int

    init(id: UUID = UUID(), sessionID: UUID, zoneID: UUID, sort: Int) {
        self.id = id
        self.sessionID = sessionID
        self.zoneID = zoneID
        self.sort = sort
    }

    init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        sessionID = try row.decode(forColumn: "session_id")
        zoneID = try row.decode(forColumn: "zone_id")
        sort = try row.decode(forColumn: "sort")
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["session_id"] = sessionID.dbKey
        container["zone_id"] = zoneID.dbKey
        container["sort"] = sort
    }
}

// MARK: - Commit

/// One hold-to-count commit (FR-13, FR-21), saved with its items, counted zone and keyframe path
/// in one transaction (FR-7).
public struct Commit: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var zoneID: UUID
    /// 1, 2, 3… within the session. "Undo" takes the highest one not yet undone.
    public var seq: Int
    /// The identifier of the commit's ARAnchor, created at the counted zone's transform. After a
    /// relaunch, the restored anchor's transform goes to `CommitEngine.updateAnchor`.
    public var anchorID: UUID?
    /// Camera transform when the keyframe was taken.
    public var pose: simd_float4x4?
    /// The keyframe photo, as a path relative to the app's data directory.
    public var keyframePath: String?
    public var trigger: CommitTrigger?
    /// Detections matched one-to-one to items counted earlier (revisits; not added again).
    public var matchedCount: Int
    public var driftAlarm: Bool
    public var createdAt: Date
    public var undone: Bool
    public var undoneAt: Date?
}

extension Commit: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commit"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        sessionID = try row.decode(forColumn: "session_id")
        zoneID = try row.decode(forColumn: "zone_id")
        seq = try row.decode(forColumn: "seq")
        anchorID = try row.decode(forColumn: "anchor_id")
        let poseText: String? = try row.decode(forColumn: "pose")
        pose = try poseText.map(MatrixText.decode)
        keyframePath = try row.decode(forColumn: "keyframe_file")
        let triggerText: String? = try row.decode(forColumn: "fired_by")
        trigger = triggerText.flatMap(CommitTrigger.init(rawValue:))
        matchedCount = try row.decode(forColumn: "matched_count")
        driftAlarm = try row.decode(forColumn: "drift_alarm")
        createdAt = try row.time("created_at")
        undone = try row.decode(forColumn: "undone")
        undoneAt = try row.optionalTime("undone_at")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.dbKey
        container["session_id"] = sessionID.dbKey
        container["zone_id"] = zoneID.dbKey
        container["seq"] = seq
        container["anchor_id"] = anchorID?.dbKey
        container["pose"] = try pose.map(MatrixText.encode)
        container["keyframe_file"] = keyframePath
        container["fired_by"] = trigger?.rawValue
        container["matched_count"] = matchedCount
        container["drift_alarm"] = driftAlarm
        container["created_at"] = DBTime.text(createdAt)
        container["undone"] = undone
        container["undone_at"] = undoneAt.map(DBTime.text)
    }
}

// MARK: - CountedZone

/// The 3D region a commit covered (FR-21): an oriented box. Mirrors `StockMaskCounting.CountedZone`.
public struct CountedZone: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var commitID: UUID
    /// World from box, at commit time. The commit's ARAnchor is created with this transform.
    public var transform: simd_float4x4
    /// Half the box's size along its own axes, metres.
    public var halfExtents: SIMD3<Float>

    public init(id: UUID, commitID: UUID, transform: simd_float4x4, halfExtents: SIMD3<Float>) {
        self.id = id
        self.commitID = commitID
        self.transform = transform
        self.halfExtents = halfExtents
    }
}

extension CountedZone: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "counted_zone"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        commitID = try row.decode(forColumn: "commit_id")
        transform = try MatrixText.decode(try row.decode(forColumn: "transform"))
        halfExtents = SIMD3(
            try row.decode(Float.self, forColumn: "half_x"),
            try row.decode(Float.self, forColumn: "half_y"),
            try row.decode(Float.self, forColumn: "half_z"))
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.dbKey
        container["commit_id"] = commitID.dbKey
        container["transform"] = try MatrixText.encode(transform)
        container["half_x"] = halfExtents.x
        container["half_y"] = halfExtents.y
        container["half_z"] = halfExtents.z
    }
}

// MARK: - Item

/// One counted unit: a bottle, can or case, or a bottle counted by its top (`.bottleTop`, a row
/// behind). Mirrors `StockMaskCounting.CountedItem`, so the AR layer can rebuild the counting
/// engine from these after a relaunch.
public struct Item: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var commitID: UUID
    public var groupID: UUID
    public var cls: ItemClass
    /// Metres, AR world space at commit time: the object's centre, or the top for `.bottleTop`.
    public var position: SIMD3<Float>
    /// The bottle's top (detected or estimated), so a top seen alone later can match a bottle
    /// counted whole. Nil for cans and cases.
    public var top: SIMD3<Float>?
    /// The counting engine's product key: `SKU.productKey` once the group is named, else whatever
    /// the engine suggested at commit time.
    public var productKey: Int?
    public var confidence: Float?
    /// Index of the counted detection in its commit's detections.
    public var detectionIndex: Int?
    /// The item's photo crop, relative to the app's data directory.
    public var cropPath: String?
    /// Uncounted by the user (FR-17). Removed items stay for the audit trail.
    public var removed: Bool
    public var createdAt: Date
}

extension Item: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        commitID = try row.decode(forColumn: "commit_id")
        groupID = try row.decode(forColumn: "group_id")
        cls = try ItemClass.decode(row, "class")
        position = SIMD3(
            try row.decode(Float.self, forColumn: "pos_x"),
            try row.decode(Float.self, forColumn: "pos_y"),
            try row.decode(Float.self, forColumn: "pos_z"))
        top = try row.optionalPoint("top")
        productKey = try row.decode(forColumn: "product_key")
        confidence = try row.decode(forColumn: "confidence")
        detectionIndex = try row.decode(forColumn: "detection_index")
        cropPath = try row.decode(forColumn: "crop_file")
        removed = try row.decode(forColumn: "removed")
        createdAt = try row.time("created_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["commit_id"] = commitID.dbKey
        container["group_id"] = groupID.dbKey
        container["class"] = cls.rawValue
        container["pos_x"] = position.x
        container["pos_y"] = position.y
        container["pos_z"] = position.z
        container["top_x"] = top?.x
        container["top_y"] = top?.y
        container["top_z"] = top?.z
        container["product_key"] = productKey
        container["confidence"] = confidence.flatMap { $0.isFinite ? $0 : nil }
        container["detection_index"] = detectionIndex
        container["crop_file"] = cropPath
        container["removed"] = removed
        container["created_at"] = DBTime.text(createdAt)
    }
}

// MARK: - ItemGroup

/// Items that look the same (ADR 004). Each commit makes its own groups; the user names a group
/// once (FR-28). A group is never assigned a product without a confirmation (FR-31): a suggestion
/// stays in `suggestedSKUID` until the user confirms it.
public struct ItemGroup: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Waiting for a name: a review blocker (FR-35).
        case unnamed
        /// The user chose to leave it unknown; exported as "Unknown A".
        case markedUnknown
        case named(UUID)
    }

    public var id: UUID
    public var sessionID: UUID
    /// The commit that made the group; nil for groups made by splitting.
    public var commitID: UUID?
    /// 1, 2, 3… within the session, fixed when the group is made.
    public var seq: Int
    /// "A", "B"… ("Unknown A" in the list). Stable: naming one group never relabels another.
    public var label: String
    public var skuID: UUID?
    public var confirmed: Bool
    public var suggestedSKUID: UUID?
    public var suggestionSource: SuggestionSource?
    public var createdAt: Date
    public var namedAt: Date?

    public var state: State {
        if let skuID { return .named(skuID) }
        return confirmed ? .markedUnknown : .unnamed
    }
}

extension ItemGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item_group"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        sessionID = try row.decode(forColumn: "session_id")
        commitID = try row.decode(forColumn: "commit_id")
        seq = try row.decode(forColumn: "seq")
        label = try row.decode(forColumn: "label")
        skuID = try row.decode(forColumn: "sku_id")
        confirmed = try row.decode(forColumn: "confirmed")
        suggestedSKUID = try row.decode(forColumn: "suggested_sku_id")
        let source: String? = try row.decode(forColumn: "suggestion_source")
        suggestionSource = source.flatMap(SuggestionSource.init(rawValue:))
        createdAt = try row.time("created_at")
        namedAt = try row.optionalTime("named_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["session_id"] = sessionID.dbKey
        container["commit_id"] = commitID?.dbKey
        container["seq"] = seq
        container["label"] = label
        container["sku_id"] = skuID?.dbKey
        container["confirmed"] = confirmed
        container["suggested_sku_id"] = suggestedSKUID?.dbKey
        container["suggestion_source"] = suggestionSource?.rawValue
        container["created_at"] = DBTime.text(createdAt)
        container["named_at"] = namedAt.map(DBTime.text)
    }
}

// MARK: - ManualLine

/// FR-30: a product and quantity the camera can't count (kegs, partial cases, closed cupboards).
public struct ManualLine: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var zoneID: UUID
    public var skuID: UUID
    public var fullCases: Int
    public var looseUnits: Int
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
}

extension ManualLine: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "manual_line"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        sessionID = try row.decode(forColumn: "session_id")
        zoneID = try row.decode(forColumn: "zone_id")
        skuID = try row.decode(forColumn: "sku_id")
        fullCases = try row.decode(forColumn: "full_cases")
        looseUnits = try row.decode(forColumn: "loose_units")
        note = try row.decode(forColumn: "note")
        createdAt = try row.time("created_at")
        updatedAt = try row.time("updated_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["session_id"] = sessionID.dbKey
        container["zone_id"] = zoneID.dbKey
        container["sku_id"] = skuID.dbKey
        container["full_cases"] = fullCases
        container["loose_units"] = looseUnits
        container["note"] = note
        container["created_at"] = DBTime.text(createdAt)
        container["updated_at"] = DBTime.text(updatedAt)
    }
}

// MARK: - PossibleMiss

/// An amber "+" (FR-22): a detection inside a counted zone with no counted item to match. Never
/// counted until the user adds it. Open ones are a review warning (FR-35).
public struct PossibleMiss: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var commitID: UUID
    public var cls: ItemClass
    /// Metres, AR world space at the commit that (last) showed it.
    public var position: SIMD3<Float>?
    public var top: SIMD3<Float>?
    public var confidence: Float?
    /// Index of the detection in that commit's detections (for `CommitEngine.addDetection`).
    public var detectionIndex: Int?
    public var cropPath: String?
    public var status: PossibleMissStatus
    /// The item made when the user added it.
    public var itemID: UUID?
    public var resolvedAt: Date?
}

extension PossibleMiss: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "possible_miss"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        commitID = try row.decode(forColumn: "commit_id")
        cls = try ItemClass.decode(row, "class")
        position = try row.optionalPoint("pos")
        top = try row.optionalPoint("top")
        confidence = try row.decode(forColumn: "confidence")
        detectionIndex = try row.decode(forColumn: "detection_index")
        cropPath = try row.decode(forColumn: "crop_file")
        let rawStatus: String = try row.decode(forColumn: "status")
        guard let status = PossibleMissStatus(rawValue: rawStatus) else {
            throw StoreError.invalid("Unknown possible-miss status \(rawStatus)")
        }
        self.status = status
        itemID = try row.decode(forColumn: "item_id")
        resolvedAt = try row.optionalTime("resolved_at")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["commit_id"] = commitID.dbKey
        container["class"] = cls.rawValue
        container["pos_x"] = position?.x
        container["pos_y"] = position?.y
        container["pos_z"] = position?.z
        container["top_x"] = top?.x
        container["top_y"] = top?.y
        container["top_z"] = top?.z
        container["confidence"] = confidence.flatMap { $0.isFinite ? $0 : nil }
        container["detection_index"] = detectionIndex
        container["crop_file"] = cropPath
        container["status"] = status.rawValue
        container["item_id"] = itemID?.dbKey
        container["resolved_at"] = resolvedAt.map(DBTime.text)
    }
}

// MARK: - Event

/// One row of the append-only audit log. The database refuses UPDATE and DELETE on it.
public struct Event: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var venueID: UUID?
    public var sessionID: UUID?
    public var ts: Date
    public var type: EventType
    /// A JSON object as text.
    public var payload: String

    public var payloadValue: JSONValue { JSONValue.parse(payload) ?? .null }
}

extension Event: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "event"

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        venueID = try row.decode(forColumn: "venue_id")
        sessionID = try row.decode(forColumn: "session_id")
        ts = try row.time("ts")
        type = EventType(rawValue: try row.decode(forColumn: "type"))
        payload = try row.decode(forColumn: "payload")
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.dbKey
        container["venue_id"] = venueID?.dbKey
        container["session_id"] = sessionID?.dbKey
        container["ts"] = DBTime.text(ts)
        container["type"] = type.rawValue
        container["payload"] = payload
    }
}

// MARK: - Helpers

extension Row {
    /// A nullable point stored as `<prefix>_x`, `<prefix>_y`, `<prefix>_z`.
    func optionalPoint(_ prefix: String) throws -> SIMD3<Float>? {
        let x: Float? = try decode(forColumn: "\(prefix)_x")
        let y: Float? = try decode(forColumn: "\(prefix)_y")
        let z: Float? = try decode(forColumn: "\(prefix)_z")
        guard let x, let y, let z else { return nil }
        return SIMD3(x, y, z)
    }
}

extension ItemClass {
    static func decode(_ row: Row, _ column: String) throws -> ItemClass {
        let raw: String = try row.decode(forColumn: column)
        guard let cls = ItemClass(rawValue: raw) else { throw StoreError.invalid("Unknown item class \(raw)") }
        return cls
    }
}

/// 4×4 matrices as a JSON array of 16 numbers, column-major (columns.0 first). Float's
/// `description` is the shortest text that reads back to the same Float, so the round trip is exact.
enum MatrixText {
    static func encode(_ m: simd_float4x4) throws -> String {
        let values = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        guard values.allSatisfy(\.isFinite) else { throw StoreError.invalid("A matrix has a non-finite value") }
        return "[" + values.map { "\($0)" }.joined(separator: ",") + "]"
    }

    static func decode(_ text: String) throws -> simd_float4x4 {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n"))
        let values = body.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 16 else { throw StoreError.invalid("A stored matrix does not have 16 numbers") }
        func col(_ i: Int) -> SIMD4<Float> { SIMD4(values[i * 4], values[i * 4 + 1], values[i * 4 + 2], values[i * 4 + 3]) }
        return simd_float4x4(col(0), col(1), col(2), col(3))
    }
}
