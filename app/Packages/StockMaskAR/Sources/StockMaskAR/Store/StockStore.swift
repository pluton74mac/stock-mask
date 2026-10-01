import Foundation
import StockMaskCounting
import simd

/// A product (SKU) as the screens show it.
public struct ProductInfo: Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var sizeML: Int?
    public var unitsPerCase: Int?
    public var code: String

    public init(id: UUID, name: String, sizeML: Int? = nil, unitsPerCase: Int? = nil, code: String = "") {
        self.id = id; self.name = name; self.sizeML = sizeML; self.unitsPerCase = unitsPerCase; self.code = code
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

/// A group of identical-looking items from one commit (FR-27): "8 x bottle -> name it".
public struct GroupInfo: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var commitID: UUID
    public var key: Int
    public var label: String          // "Unknown A" until named
    public var cls: ObjectClass
    public var itemIDs: [UUID]
    public var product: ProductInfo?

    public init(id: UUID, commitID: UUID, key: Int, label: String, cls: ObjectClass, itemIDs: [UUID], product: ProductInfo?) {
        self.id = id; self.commitID = commitID; self.key = key; self.label = label; self.cls = cls; self.itemIDs = itemIDs
        self.product = product
    }

    public var count: Int { itemIDs.count }

    public var title: String { product?.title ?? label }
}

public struct ItemRecord: Sendable, Equatable {
    public var id: UUID
    public var cls: ObjectClass         // .bottleTop is a bottle counted by its top: one unit
    public var position: SIMD3<Float>   // world
    public var top: SIMD3<Float>?       // the bottle's top (StockMaskCounting asks for it to be kept)
    public var score: Float
    public var groupKey: Int

    public init(id: UUID, cls: ObjectClass, position: SIMD3<Float>, top: SIMD3<Float>? = nil, score: Float, groupKey: Int) {
        self.id = id; self.cls = cls; self.position = position; self.top = top; self.score = score; self.groupKey = groupKey
    }

    public init(_ item: CountedItem, groupKey: Int) {
        self.init(id: item.id, cls: item.cls, position: item.position, top: item.top, score: item.confidence ?? 1,
                  groupKey: groupKey)
    }
}

/// Everything one commit writes, in one transaction (FR-7).
public struct CommitRecord: Sendable {
    public var id: UUID
    public var zoneTransform: simd_float4x4
    public var zoneHalfExtents: SIMD3<Float>
    public var cameraTransform: simd_float4x4
    public var keyframePath: String?
    public var items: [ItemRecord]

    public init(id: UUID, zoneTransform: simd_float4x4, zoneHalfExtents: SIMD3<Float>, cameraTransform: simd_float4x4,
                keyframePath: String?, items: [ItemRecord]) {
        self.id = id; self.zoneTransform = zoneTransform; self.zoneHalfExtents = zoneHalfExtents
        self.cameraTransform = cameraTransform; self.keyframePath = keyframePath; self.items = items
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

    public init(id: String, label: String, product: ProductInfo?, groupID: UUID?, units: Int, fullCases: Int,
                looseUnits: Int, source: String) {
        self.id = id; self.label = label; self.product = product; self.groupID = groupID; self.units = units
        self.fullCases = fullCases; self.looseUnits = looseUnits; self.source = source
    }

    public var needsNaming: Bool { product == nil }
    /// "2 cases + 4" when the product has a case size, else "16".
    public var quantityText: String {
        guard let per = product?.unitsPerCase, per > 0, fullCases > 0 else { return "\(units)" }
        return looseUnits > 0 ? "\(fullCases) × \(per) + \(looseUnits)" : "\(fullCases) × \(per)"
    }
}

public struct StockSheetSummary: Sendable, Equatable {
    public var lines: [SheetLine]

    public init(lines: [SheetLine] = []) { self.lines = lines }

    public var totalUnits: Int { lines.reduce(0) { $0 + $1.units } }
    public var products: Int { lines.filter { !$0.needsNaming }.count }
    public var unnamed: [SheetLine] { lines.filter(\.needsNaming) }
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
    public var fileExtension: String { self == .xlsx ? "xlsx" : "csv" }
}

/// What the counting screens need from persistence. `CoreStockStore` implements it on top of
/// StockMaskCore; tests use the same.
public protocol StockStore: Sendable {
    func startSession(venue: String, zone: String, counter: String) async throws
    /// Saves a commit with its items and creates one group per distinct group key (FR-7: one
    /// transaction). Returns the groups, largest first.
    func saveCommit(_ commit: CommitRecord) async throws -> [GroupInfo]
    func undoCommit(_ id: UUID) async throws
    /// Adds an item to an existing commit (an accepted possible miss) in a new group of its own.
    func addItem(_ item: ItemRecord, toCommit id: UUID) async throws -> GroupInfo
    func groups(ofCommit id: UUID) async throws -> [GroupInfo]
    /// FR-28/31: a product is assigned only here, after the user picked it. nil un-names.
    func name(group id: UUID, product: UUID?) async throws
    func products(matching query: String) async throws -> [ProductInfo]
    func createProduct(_ draft: ProductDraft) async throws -> ProductInfo
    func addManualLine(product: UUID, fullCases: Int, looseUnits: Int, note: String) async throws
    func sheet() async throws -> StockSheetSummary
    func export(_ format: ExportFormat, to directory: URL) async throws -> URL
}
