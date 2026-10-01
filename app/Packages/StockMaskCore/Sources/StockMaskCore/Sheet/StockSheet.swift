import Foundation

/// The counted stock sheet of a session: one line per product, plus one line per group that has
/// no product ("Unknown A", "Unknown B"…). Built from the database each time; nothing in it is
/// stored, so it always reflects undo, removals, naming and manual lines.
public struct StockSheet: Equatable, Sendable {
    public var session: Session
    public var venue: Venue
    /// The session's zones, in order.
    public var zones: [Zone]
    /// Named products first (by name), then unknown groups (by letter).
    public var lines: [StockLine]
    public var review: ReviewSummary

    /// Units across lines whose total is known (the list badge: "units · products").
    public var totalUnits: Int { lines.reduce(0) { $0 + ($1.quantity.totalUnits ?? 0) } }
    public var productCount: Int { lines.count }
}

/// A line's identity: a product, or one group nobody has named.
public enum LineKey: Hashable, Sendable {
    case product(UUID)
    case unknownGroup(UUID)

    var json: JSONValue {
        switch self {
        case let .product(id): ["product": .init(id)]
        case let .unknownGroup(id): ["unknown_group": .init(id)]
        }
    }
}

/// One line of the sheet.
public struct StockLine: Identifiable, Equatable, Sendable {
    public var id: LineKey
    /// Nil for an unknown group.
    public var sku: SKU?
    /// The product name, or "Unknown A".
    public var name: String
    /// The letters of an unknown group ("A").
    public var unknownLabel: String?
    /// For an unnamed group with a suggestion: what to offer (ADR 004). Not an assignment.
    public var suggestedSKU: SKU?
    public var quantity: Quantity
    /// The quantity by zone and source, in zone order (camera before manual).
    public var parts: [StockLinePart]
    public var sources: [LineSource]
    public var zones: [Zone]
    public var groupIDs: [UUID]
    public var manualLineIDs: [UUID]
    /// Counted camera items on the line.
    public var cameraItemCount: Int
    /// Keyframes of the commits that counted the line, oldest first (FR-35: a photo per line).
    public var photos: [PhotoRef]
    /// Notes from manual lines.
    public var notes: [String]
    public var flags: [LineFlag]
    /// The latest count that touched the line.
    public var countedAt: Date

    public var unknownGroupID: UUID? { if case let .unknownGroup(id) = id { id } else { nil } }
}

/// Quantities as counted, and the same stock expressed as full cases plus loose units.
public struct Quantity: Equatable, Sendable {
    /// Cases as counted: closed cases seen by the camera (FR-19) plus manual full cases.
    public var countedCases: Int
    /// Loose units as counted: bottles, cans, tops standing for bottles, manual loose units.
    public var countedUnits: Int
    /// The product's units per case; nil when unknown (and always for unknown groups).
    public var unitsPerCase: Int?

    public init(countedCases: Int = 0, countedUnits: Int = 0, unitsPerCase: Int?) {
        self.countedCases = countedCases
        self.countedUnits = countedUnits
        self.unitsPerCase = unitsPerCase
    }

    /// Units including the cases converted with `unitsPerCase`. Nil when cases were counted but
    /// the product has no units per case: the sheet won't guess (review warning).
    public var totalUnits: Int? {
        if let u = unitsPerCase { return countedUnits + countedCases * u }
        return countedCases == 0 ? countedUnits : nil
    }

    /// `totalUnits / unitsPerCase`. Without units per case: the cases as counted.
    public var fullCases: Int {
        guard let u = unitsPerCase, let total = totalUnits else { return countedCases }
        return total / u
    }

    /// `totalUnits % unitsPerCase`. Without units per case: the units as counted.
    public var looseUnits: Int {
        guard let u = unitsPerCase, let total = totalUnits else { return countedUnits }
        return total % u
    }

    /// Cases that can't be converted to units.
    public var needsUnitsPerCase: Bool { unitsPerCase == nil && countedCases > 0 }

    static func + (a: Quantity, b: Quantity) -> Quantity {
        Quantity(countedCases: a.countedCases + b.countedCases, countedUnits: a.countedUnits + b.countedUnits,
                 unitsPerCase: a.unitsPerCase ?? b.unitsPerCase)
    }
}

/// A line's quantity in one zone from one source.
public struct StockLinePart: Equatable, Sendable {
    public var zone: Zone
    public var source: LineSource
    public var quantity: Quantity
    public var countedAt: Date
    public var notes: [String]
}

/// A commit's keyframe that shows (some of) a line's items.
public struct PhotoRef: Equatable, Sendable {
    public var commitID: UUID
    public var zoneID: UUID
    /// Relative to the app's data directory.
    public var keyframePath: String?
    /// Crops of the line's items in that commit.
    public var cropPaths: [String]
    public var itemCount: Int
    public var takenAt: Date
}

public enum LineFlag: String, Sendable, CaseIterable {
    /// An unknown group nobody named or marked unknown: blocks the lock (FR-35).
    case unnamed
    /// The user chose to leave the group unknown.
    case markedUnknown = "marked_unknown"
    /// Cases counted, but the product has no units per case, so `totalUnits` is unknown.
    case unitsPerCaseMissing = "units_per_case_missing"
}

/// FR-35 review: blockers must be fixed before locking; warnings are for the counter to check.
public enum ReviewIssue: Equatable, Sendable {
    /// Blocker: name the group, or mark it unknown.
    case unnamedGroup(LineKey)
    /// Warning: amber "+" the user neither added nor dismissed, per zone.
    case possibleMissesLeft(zoneID: UUID, count: Int)
    /// Warning: a session zone with no commits and no manual lines.
    case zoneWithoutCounts(UUID)
    /// Warning: cases on a product without units per case.
    case unitsPerCaseMissing(LineKey)

    public var isBlocker: Bool { if case .unnamedGroup = self { true } else { false } }
}

public struct ReviewSummary: Equatable, Sendable {
    public var issues: [ReviewIssue]

    public var blockers: [ReviewIssue] { issues.filter(\.isBlocker) }
    public var warnings: [ReviewIssue] { issues.filter { !$0.isBlocker } }
    public var canLock: Bool { blockers.isEmpty }

    public var possibleMissesLeft: Int {
        issues.reduce(0) { sum, issue in
            if case let .possibleMissesLeft(_, count) = issue { sum + count } else { sum }
        }
    }
}

public struct SheetOptions: Equatable, Sendable {
    /// The word before an unknown group's letters: "Unknown A". The Spanish UI passes its own.
    public var unknownName: String

    public init(unknownName: String = "Unknown") {
        self.unknownName = unknownName
    }
}

// MARK: - Building

/// Everything the sheet is computed from, read in one database transaction.
struct SheetInput {
    var session: Session
    var venue: Venue
    var venueZones: [Zone]
    var sessionZoneIDs: [UUID]
    var skus: [SKU]
    var groups: [ItemGroup]
    /// Commits not undone.
    var commits: [Commit]
    /// Items of those commits, not removed.
    var items: [Item]
    var manualLines: [ManualLine]
    /// Open possible misses of those commits.
    var openMisses: [PossibleMiss]
}

enum StockSheetBuilder {
    static func build(_ input: SheetInput, options: SheetOptions) -> StockSheet {
        let zoneByID = Dictionary(uniqueKeysWithValues: input.venueZones.map { ($0.id, $0) })
        let zoneRank = Dictionary(uniqueKeysWithValues: input.venueZones.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
            .enumerated().map { ($1.id, $0) })
        let skuByID = Dictionary(uniqueKeysWithValues: input.skus.map { ($0.id, $0) })
        let groupByID = Dictionary(uniqueKeysWithValues: input.groups.map { ($0.id, $0) })
        let commitByID = Dictionary(uniqueKeysWithValues: input.commits.map { ($0.id, $0) })

        struct PartKey: Hashable { var zone: UUID; var source: LineSource }
        struct PartAcc {
            var quantity = Quantity(unitsPerCase: nil)
            var countedAt: Date
            var notes: [String] = []
        }
        struct Acc {
            var parts: [PartKey: PartAcc] = [:]
            var groupIDs: [UUID] = []
            var manualIDs: [UUID] = []
            var items = 0
            var photos: [UUID: PhotoRef] = [:]
        }
        var lines: [LineKey: Acc] = [:]

        for item in input.items {
            guard let group = groupByID[item.groupID], let commit = commitByID[item.commitID] else { continue }
            let key: LineKey = group.skuID.map { .product($0) } ?? .unknownGroup(group.id)
            var acc = lines[key, default: Acc()]
            let partKey = PartKey(zone: commit.zoneID, source: .camera)
            var part = acc.parts[partKey] ?? PartAcc(countedAt: commit.createdAt)
            if item.cls.isCase { part.quantity.countedCases += 1 } else { part.quantity.countedUnits += 1 }
            part.countedAt = max(part.countedAt, commit.createdAt)
            acc.parts[partKey] = part
            if !acc.groupIDs.contains(group.id) { acc.groupIDs.append(group.id) }
            acc.items += 1
            var photo = acc.photos[commit.id] ?? PhotoRef(
                commitID: commit.id, zoneID: commit.zoneID, keyframePath: commit.keyframePath, cropPaths: [],
                itemCount: 0, takenAt: commit.createdAt)
            photo.itemCount += 1
            if let crop = item.cropPath { photo.cropPaths.append(crop) }
            acc.photos[commit.id] = photo
            lines[key] = acc
        }

        for line in input.manualLines {
            let key = LineKey.product(line.skuID)
            var acc = lines[key, default: Acc()]
            let partKey = PartKey(zone: line.zoneID, source: .manual)
            var part = acc.parts[partKey] ?? PartAcc(countedAt: line.updatedAt)
            part.quantity.countedCases += line.fullCases
            part.quantity.countedUnits += line.looseUnits
            if let note = line.note { part.notes.append(note) }
            part.countedAt = max(part.countedAt, line.updatedAt)
            acc.parts[partKey] = part
            acc.manualIDs.append(line.id)
            lines[key] = acc
        }

        var built: [StockLine] = []
        for (key, acc) in lines {
            let sku: SKU?
            let group: ItemGroup?
            switch key {
            case let .product(id):
                guard let s = skuByID[id] else { continue }
                sku = s
                group = nil
            case let .unknownGroup(id):
                sku = nil
                group = groupByID[id]
            }
            let unitsPerCase = sku?.unitsPerCase
            let parts = acc.parts.compactMap { partKey, value -> StockLinePart? in
                guard let zone = zoneByID[partKey.zone] else { return nil }
                var q = value.quantity
                q.unitsPerCase = unitsPerCase
                return StockLinePart(
                    zone: zone, source: partKey.source, quantity: q, countedAt: value.countedAt, notes: value.notes)
            }.sorted { a, b in
                let ra = zoneRank[a.zone.id] ?? .max, rb = zoneRank[b.zone.id] ?? .max
                return ra != rb ? ra < rb : a.source < b.source
            }
            var quantity = parts.reduce(Quantity(unitsPerCase: unitsPerCase)) { $0 + $1.quantity }
            quantity.unitsPerCase = unitsPerCase

            var flags: [LineFlag] = []
            if let group {
                flags.append(group.state == .unnamed ? .unnamed : .markedUnknown)
            }
            if quantity.needsUnitsPerCase { flags.append(.unitsPerCaseMissing) }

            var zones: [Zone] = []
            for part in parts where !zones.contains(part.zone) { zones.append(part.zone) }
            built.append(StockLine(
                id: key, sku: sku,
                name: sku?.name ?? "\(options.unknownName) \(group?.label ?? "?")",
                unknownLabel: group?.label,
                suggestedSKU: group.flatMap { $0.state == .unnamed ? $0.suggestedSKUID.flatMap { skuByID[$0] } : nil },
                quantity: quantity, parts: parts,
                sources: Array(Set(parts.map(\.source))).sorted(),
                zones: zones, groupIDs: acc.groupIDs, manualLineIDs: acc.manualIDs, cameraItemCount: acc.items,
                photos: acc.photos.values.sorted { ($0.takenAt, $0.commitID.dbKey) < ($1.takenAt, $1.commitID.dbKey) },
                notes: parts.flatMap(\.notes), flags: flags,
                countedAt: parts.map(\.countedAt).max() ?? input.session.startedAt))
        }
        built.sort(by: lineOrder(groupByID))

        // Review (FR-35)
        var issues: [ReviewIssue] = built.filter { $0.flags.contains(.unnamed) }.map { .unnamedGroup($0.id) }
        let missZone = Dictionary(grouping: input.openMisses) { commitByID[$0.commitID]?.zoneID }
        let sessionZones = input.sessionZoneIDs.compactMap { zoneByID[$0] }
        for zone in sessionZones {
            if let count = missZone[zone.id]?.count, count > 0 {
                issues.append(.possibleMissesLeft(zoneID: zone.id, count: count))
            }
        }
        let countedZones = Set(input.commits.map(\.zoneID)).union(input.manualLines.map(\.zoneID))
        for zone in sessionZones where !countedZones.contains(zone.id) {
            issues.append(.zoneWithoutCounts(zone.id))
        }
        issues += built.filter { $0.flags.contains(.unitsPerCaseMissing) }.map { .unitsPerCaseMissing($0.id) }

        return StockSheet(
            session: input.session, venue: input.venue, zones: sessionZones, lines: built,
            review: ReviewSummary(issues: issues))
    }

    /// Products by name (then size and code); unknown groups after them, by letter.
    static func lineOrder(_ groups: [UUID: ItemGroup]) -> (StockLine, StockLine) -> Bool {
        { a, b in
            switch (a.sku, b.sku) {
            case let (x?, y?): return SKU.displayOrder(x, y)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                let sa = a.unknownGroupID.flatMap { groups[$0]?.seq } ?? 0
                let sb = b.unknownGroupID.flatMap { groups[$0]?.seq } ?? 0
                return sa < sb
            }
        }
    }
}
