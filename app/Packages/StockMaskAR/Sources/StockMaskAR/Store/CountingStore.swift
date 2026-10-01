import Foundation
import StockMaskCounting
import simd

// The persistence seam of the counting screens. `CoreStockStore` implements it with
// StockMaskCore's `StockStore` (SQLite, one transaction per call); the names here are StockMaskAR's
// own so they never clash with StockMaskCore's records (Commit, Item, CountedZone, ...).

/// A product (SKU) as the screens show it.
public struct ProductInfo: Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var sizeML: Int?
    public var unitsPerCase: Int?
    public var code: String
    /// StockMaskCounting's `productKey` for this product (stable: from the SKU's id).
    public var productKey: Int?

    public init(id: UUID, name: String, sizeML: Int? = nil, unitsPerCase: Int? = nil, code: String = "",
                productKey: Int? = nil) {
        self.id = id; self.name = name; self.sizeML = sizeML; self.unitsPerCase = unitsPerCase; self.code = code
        self.productKey = productKey
    }

    public var title: String { sizeML.map { "\(name) \($0) ml" } ?? name }
}

/// What the "create product" form collects (FR-3, created mid-count).
public struct ProductDraft: Sendable, Equatable {
    public var name: String
    public var sizeML: Int?
    public var unitsPerCase: Int?
    public var code: String
    public var brand: String

    public init(name: String, sizeML: Int? = nil, unitsPerCase: Int? = nil, code: String = "", brand: String = "") {
        self.name = name; self.sizeML = sizeML; self.unitsPerCase = unitsPerCase; self.code = code; self.brand = brand
    }
}

/// A group of identical-looking items from one commit (FR-27): "8 × bottle → name it".
public struct GroupInfo: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var commitID: UUID
    public var label: String          // "Unknown A" until named
    public var cls: ObjectClass       // what it counts as (a bottle counted by its top is a bottle)
    public var itemIDs: [UUID]
    public var product: ProductInfo?
    public var markedUnknown = false

    public init(id: UUID, commitID: UUID, label: String, cls: ObjectClass, itemIDs: [UUID], product: ProductInfo?,
                markedUnknown: Bool = false) {
        self.id = id; self.commitID = commitID; self.label = label; self.cls = cls; self.itemIDs = itemIDs
        self.product = product; self.markedUnknown = markedUnknown
    }

    public var count: Int { itemIDs.count }
    public var title: String { product?.title ?? label }
}

/// One counted item of a commit, as the engine counted it (the engine's id), plus its photo crop.
public struct ItemRecord: Sendable, Equatable {
    public var item: CountedItem
    public var cropPath: String?

    public init(_ item: CountedItem, cropPath: String? = nil) {
        self.item = item
        self.cropPath = cropPath
    }
}

/// An amber "+" (FR-22). `id` stays the same when a later commit sees the same miss again.
public struct MissRecord: Sendable, Equatable {
    public var id: UUID
    public var detection: Detection
    public var detectionIndex: Int

    public init(id: UUID, detection: Detection, detectionIndex: Int) {
        self.id = id
        self.detection = detection
        self.detectionIndex = detectionIndex
    }
}

/// Everything one commit writes, in one transaction (FR-7). Ids are the engine's.
public struct CommitRecord: Sendable {
    public var id: UUID
    public var zone: CountedZone
    public var anchorID: UUID?            // the ARAnchor made at zone.transform
    public var cameraTransform: simd_float4x4
    public var keyframePath: String?      // relative to the app's data directory, written first
    public var trigger: CommitTrigger
    public var items: [ItemRecord]
    public var possibleMisses: [MissRecord]
    public var matchedCount: Int

    public init(id: UUID, zone: CountedZone, anchorID: UUID?, cameraTransform: simd_float4x4, keyframePath: String?,
                trigger: CommitTrigger, items: [ItemRecord], possibleMisses: [MissRecord], matchedCount: Int) {
        self.id = id; self.zone = zone; self.anchorID = anchorID; self.cameraTransform = cameraTransform
        self.keyframePath = keyframePath; self.trigger = trigger; self.items = items
        self.possibleMisses = possibleMisses; self.matchedCount = matchedCount
    }
}

/// A line of the live list and of the export: one product, or one unnamed group.
public struct SheetLine: Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var product: ProductInfo?
    public var groupID: UUID?          // an unnamed group's line: tap to name it
    public var units: Int
    public var fullCases: Int
    public var looseUnits: Int
    public var source: String          // camera, manual, camera+manual
    public var flagged: Bool           // e.g. cases counted but no units per case

    public init(id: String, label: String, product: ProductInfo?, groupID: UUID?, units: Int, fullCases: Int,
                looseUnits: Int, source: String, flagged: Bool = false) {
        self.id = id; self.label = label; self.product = product; self.groupID = groupID; self.units = units
        self.fullCases = fullCases; self.looseUnits = looseUnits; self.source = source; self.flagged = flagged
    }

    public var needsNaming: Bool { product == nil && groupID != nil }
    /// "2 × 6 + 4" when the product has a case size, else "16".
    public var quantityText: String {
        guard let per = product?.unitsPerCase, per > 0, fullCases > 0 else { return "\(units)" }
        return looseUnits > 0 ? "\(fullCases) × \(per) + \(looseUnits)" : "\(fullCases) × \(per)"
    }
}

public struct StockSheetSummary: Sendable, Equatable {
    public var lines: [SheetLine]
    /// FR-35 blockers (groups still unnamed) and warnings (possible misses left, empty zones, ...).
    public var blockers: [String]
    public var warnings: [String]

    public init(lines: [SheetLine] = [], blockers: [String] = [], warnings: [String] = []) {
        self.lines = lines
        self.blockers = blockers
        self.warnings = warnings
    }

    public var totalUnits: Int { lines.reduce(0) { $0 + $1.units } }
    public var products: Int { lines.filter { $0.product != nil }.count }
    public var unnamed: [SheetLine] { lines.filter(\.needsNaming) }
    public var canLock: Bool { blockers.isEmpty }
}

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csvArgentina, csvStandard, xlsx

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .csvArgentina: "CSV (Excel Argentina, ;)"
        case .csvStandard: "CSV (standard, ,)"
        case .xlsx: "Excel (.xlsx)"
        }
    }
}

/// The session a relaunch continues (FR-7).
public struct ResumedSession: Sendable, Equatable {
    public var counter: String
    public var zone: String
    public var units: Int
}

/// What the counting screens need from persistence. `CoreStockStore` implements it.
public protocol CountingStore: Sendable {
    /// Continues the active session, if there is one (one per device), else nil.
    func resumeSession() async throws -> ResumedSession?
    func startSession(venue: String, zone: String, counter: String) async throws
    /// The session's id, for the data directory's layout (`sessions/<id>/...`).
    func sessionID() async -> UUID?
    /// FR-7: the commit, its items, zone, groups and possible misses in one transaction. Returns
    /// the commit card's groups, largest first.
    func saveCommit(_ commit: CommitRecord) async throws -> [GroupInfo]
    /// FR-16. Refuses unless `id` is the store's last commit.
    func undoCommit(_ id: UUID) async throws
    /// FR-22: the user tapped "+": the item `engine.addDetection` made. Returns the group it joined.
    func addPossibleMiss(_ missID: UUID, item: CountedItem) async throws -> GroupInfo
    func groups(ofCommit id: UUID) async throws -> [GroupInfo]
    /// FR-28/31: a product is assigned only here, after the user picked it. Returns the group
    /// (its items now carry the product's key, to mirror into the engine).
    func name(group id: UUID, product: UUID) async throws -> GroupInfo
    /// FR-35: leave a group deliberately unknown.
    func markUnknown(group id: UUID) async throws -> GroupInfo
    func products(matching query: String) async throws -> [ProductInfo]
    func createProduct(_ draft: ProductDraft) async throws -> ProductInfo
    func addManualLine(product: UUID, fullCases: Int, looseUnits: Int, note: String) async throws
    func sheet() async throws -> StockSheetSummary
    /// FR-9: finish, review, lock (needs every group named or marked unknown).
    func lock() async throws
    func export(_ format: ExportFormat, to directory: URL) async throws -> URL
}
