import Foundation

/// The kind of an audit event. The store writes the ones listed here, in the same transaction as
/// the change they describe. The app can record its own kinds with `StockStore.recordEvent`.
public struct EventType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    // Venue and catalog
    public static let venueCreated: EventType = "venue_created"
    public static let zoneCreated: EventType = "zone_created"
    public static let zoneUpdated: EventType = "zone_updated"
    public static let skuCreated: EventType = "sku_created"
    public static let skuUpdated: EventType = "sku_updated"
    public static let catalogImported: EventType = "catalog_imported"

    // Session lifecycle (FR-6, FR-8, FR-9, FR-38)
    public static let sessionStarted: EventType = "session_started"
    public static let zoneSwitched: EventType = "zone_switched"
    public static let sessionFinished: EventType = "session_finished"
    public static let countingResumed: EventType = "counting_resumed"
    public static let sessionLocked: EventType = "session_locked"
    public static let sessionReopened: EventType = "session_reopened"

    // Counting (FR-7, FR-16, FR-17, FR-22)
    public static let commitSaved: EventType = "commit_saved"
    public static let commitUndone: EventType = "commit_undone"
    public static let itemAdded: EventType = "item_added"
    public static let itemRemoved: EventType = "item_removed"
    public static let itemRestored: EventType = "item_restored"
    public static let possibleMissAdded: EventType = "possible_miss_added"
    public static let possibleMissDismissed: EventType = "possible_miss_dismissed"

    // Groups, lines (FR-28, FR-30, FR-34)
    public static let groupNamed: EventType = "group_named"
    public static let groupMarkedUnknown: EventType = "group_marked_unknown"
    public static let itemsMoved: EventType = "items_moved"
    public static let lineDeleted: EventType = "line_deleted"
    public static let manualLineAdded: EventType = "manual_line_added"
    public static let manualLineUpdated: EventType = "manual_line_updated"
    public static let manualLineDeleted: EventType = "manual_line_deleted"

    // Recorded by the app (suggested kinds; the store does not write these itself)
    public static let sessionPaused: EventType = "session_paused"
    public static let sessionResumed: EventType = "session_resumed"
    public static let sheetExported: EventType = "sheet_exported"
}
