import Foundation
import GRDB

extension StockSheet {
    /// Builds the sheet inside an existing database access, e.g. a GRDBQuery request or a
    /// `ValueObservation`. All reads happen in the caller's transaction, so the sheet is consistent.
    public static func fetch(_ db: Database, sessionID: UUID, options: SheetOptions = SheetOptions()) throws -> StockSheet {
        let session = try StockStore.requireSession(db, sessionID)
        let venue = try StockStore.requireVenue(db, session.venueID)
        let sid = sessionID.dbKey
        let input = SheetInput(
            session: session,
            venue: venue,
            venueZones: try Zone.filter(Column("venue_id") == venue.id.dbKey).fetchAll(db),
            sessionZoneIDs: try UUID.fetchAll(
                db, sql: "SELECT zone_id FROM session_zone WHERE session_id = ? ORDER BY sort", arguments: [sid]),
            skus: try SKU.filter(Column("venue_id") == venue.id.dbKey).fetchAll(db),
            groups: try ItemGroup.filter(Column("session_id") == sid).fetchAll(db),
            commits: try Commit.filter(Column("session_id") == sid && Column("undone") == false)
                .order(Column("seq")).fetchAll(db),
            items: try Item.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN "commit" c ON c.id = item.commit_id
                WHERE c.session_id = ? AND c.undone = 0 AND item.removed = 0
                ORDER BY c.seq, item.rowid
                """, arguments: [sid]),
            manualLines: try ManualLine.filter(Column("session_id") == sid).order(Column("created_at")).fetchAll(db),
            openMisses: try PossibleMiss.fetchAll(db, sql: """
                SELECT pm.* FROM possible_miss pm JOIN "commit" c ON c.id = pm.commit_id
                WHERE c.session_id = ? AND c.undone = 0 AND pm.status = 'open'
                """, arguments: [sid]))
        return StockSheetBuilder.build(input, options: options)
    }
}

extension StockStore {
    /// The session's stock sheet (live list, review, export).
    public func stockSheet(sessionID: UUID, options: SheetOptions = SheetOptions()) throws -> StockSheet {
        try writer.read { db in try StockSheet.fetch(db, sessionID: sessionID, options: options) }
    }

    /// The sheet now and after every change that affects it, for the live list (FR-32):
    /// `for try await sheet in store.observeSheet(sessionID: id) { … }`.
    public func observeSheet(sessionID: UUID, options: SheetOptions = SheetOptions()) -> AsyncValueObservation<StockSheet> {
        ValueObservation
            .tracking { db in try StockSheet.fetch(db, sessionID: sessionID, options: options) }
            .removeDuplicates()
            .values(in: writer)
    }
}
