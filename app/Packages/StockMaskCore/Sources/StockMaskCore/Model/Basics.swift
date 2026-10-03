import Foundation

/// What the detector saw. Raw values match `StockMaskCounting.ObjectClass`, so the AR layer maps
/// with `ItemClass(rawValue: cls.rawValue)`.
///
/// A `case` counts as one case of its product (converted with `units_per_case`); every other class
/// counts as one unit. A `bottle_top` reaches the store only when it stands for a bottle in a row
/// behind; a top over a bottle counted in the same view is merged by the counting layer.
public enum ItemClass: String, Codable, Sendable, CaseIterable, Comparable {
    case bottle
    case can
    case `case`
    case bottleTop = "bottle_top"

    /// True for closed cases, which count as `units_per_case` units of their product.
    public var isCase: Bool { self == .case }

    /// What the item counts as: a bottle counted by its top is a bottle. Lists and commit cards
    /// show this, never "bottle_top".
    public var countsAs: ItemClass { self == .bottleTop ? .bottle : self }

    public static func < (lhs: ItemClass, rhs: ItemClass) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// FR-9: open → review → locked; "Reopen" brings a locked session back to review.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case open
    case review
    case locked
}

/// What fired a commit (FR-13): a steady hold, or the shutter.
public enum CommitTrigger: String, Codable, Sendable, CaseIterable {
    case hold
    case shutter
}

/// Where a group's product suggestion came from (ADR 004). Never an assignment by itself (FR-31).
public enum SuggestionSource: String, Codable, Sendable, CaseIterable {
    case caseBarcode = "case_barcode"
    case teachOnce = "teach_once"
    case sizeHint = "size_hint"
}

/// A possible miss is an amber "+" inside a counted zone (FR-22). It is never counted until the
/// user adds it.
public enum PossibleMissStatus: String, Codable, Sendable, CaseIterable {
    case open
    case added
    case dismissed
}

/// Where a line's quantity came from (ADR 005 `source` column).
public enum LineSource: String, Codable, Sendable, CaseIterable, Comparable {
    case camera
    case manual

    public static func < (lhs: LineSource, rhs: LineSource) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Errors thrown by `StockStore`. Every failing call leaves the database unchanged.
public enum StoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No row of that kind ("session", "zone", "sku", ...) with that id, or it belongs elsewhere.
    case notFound(String, UUID)
    /// FR-9: a locked session is read-only. Reopen it first.
    case sessionLocked(UUID)
    /// FR-6: one active (open or in review) session per device.
    case activeSessionExists(UUID)
    /// FR-35: lock refused while groups are unnamed. Name them or mark them unknown.
    case unnamedGroups(Int)
    /// The input breaks a rule: the message says which.
    case invalid(String)

    public var description: String {
        switch self {
        case let .notFound(kind, id): "No \(kind) with id \(id.uuidString.lowercased())"
        case let .sessionLocked(id): "Session \(id.uuidString.lowercased()) is locked; reopen it first"
        case let .activeSessionExists(id): "Session \(id.uuidString.lowercased()) is still active"
        case let .unnamedGroups(n): "\(n) group(s) still need a name, or to be marked unknown"
        case let .invalid(message): message
        }
    }
}

extension UUID {
    /// UUIDs are stored as lowercase text (ADR 005). Use this for every SQL argument:
    /// GRDB would otherwise bind a UUID as a 16-byte blob, which never equals the stored text.
    var dbKey: String { uuidString.lowercased() }
}

/// Spreadsheet-style letters for unnamed groups: 1 → "A", 26 → "Z", 27 → "AA".
public func groupLetters(_ sequence: Int) -> String {
    precondition(sequence >= 1, "group sequence starts at 1")
    var n = sequence
    var letters: [Character] = []
    while n > 0 {
        let r = (n - 1) % 26
        letters.append(Character(UnicodeScalar(UInt8(65 + r))))
        n = (n - 1) / 26
    }
    return String(letters.reversed())
}
