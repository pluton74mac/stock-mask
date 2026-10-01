import Foundation
import GRDB

/// Everything needed to rebuild a session after the app was killed (FR-7): the counting engine's
/// state (counted items and zones, per anchor), the overlays, and the list.
public struct SessionSnapshot: Equatable, Sendable {
    public var session: Session
    public var venue: Venue
    /// All the venue's zones, in order.
    public var zones: [Zone]
    /// The zones chosen for the session, in order.
    public var sessionZoneIDs: [UUID]
    /// Commits that still count (not undone), by `seq`.
    public var commits: [Commit]
    public var countedZones: [CountedZone]
    /// Counted items (not removed) of those commits.
    public var items: [Item]
    public var groups: [ItemGroup]
    public var manualLines: [ManualLine]
    public var openPossibleMisses: [PossibleMiss]

    /// The zone to reopen: the session's current zone (its map file is on the zone).
    public var currentZone: Zone? { zones.first { $0.id == session.currentZoneID } }

    public func commits(inZone zoneID: UUID) -> [Commit] { commits.filter { $0.zoneID == zoneID } }

    /// Counted items in a zone, to seed the commit engine and draw green overlays (FR-26).
    public func items(inZone zoneID: UUID) -> [Item] {
        let ids = Set(commits(inZone: zoneID).map(\.id))
        return items.filter { ids.contains($0.commitID) }
    }

    public func countedZones(inZone zoneID: UUID) -> [CountedZone] {
        let ids = Set(commits(inZone: zoneID).map(\.id))
        return countedZones.filter { ids.contains($0.commitID) }
    }

    public func openPossibleMisses(inZone zoneID: UUID) -> [PossibleMiss] {
        let ids = Set(commits(inZone: zoneID).map(\.id))
        return openPossibleMisses.filter { ids.contains($0.commitID) }
    }
}

extension StockStore {
    /// Reads a session's full state in one transaction.
    public func snapshot(sessionID: UUID) throws -> SessionSnapshot {
        try writer.read { db in try Self.snapshot(db, sessionID) }
    }

    /// On launch: the active session's state, or nil when no session is open or in review.
    public func resumeActiveSession() throws -> SessionSnapshot? {
        try writer.read { db in
            guard let session = try Self.activeSession(db) else { return nil }
            return try Self.snapshot(db, session.id)
        }
    }

    static func snapshot(_ db: Database, _ sessionID: UUID) throws -> SessionSnapshot {
        let session = try requireSession(db, sessionID)
        let sid = sessionID.dbKey
        return SessionSnapshot(
            session: session,
            venue: try requireVenue(db, session.venueID),
            zones: try Zone.filter(Column("venue_id") == session.venueID.dbKey)
                .order(Column("sort"), Column("name")).fetchAll(db),
            sessionZoneIDs: try UUID.fetchAll(
                db, sql: "SELECT zone_id FROM session_zone WHERE session_id = ? ORDER BY sort", arguments: [sid]),
            commits: try Commit.filter(Column("session_id") == sid && Column("undone") == false)
                .order(Column("seq")).fetchAll(db),
            countedZones: try CountedZone.fetchAll(db, sql: """
                SELECT z.* FROM counted_zone z JOIN "commit" c ON c.id = z.commit_id
                WHERE c.session_id = ? AND c.undone = 0 ORDER BY c.seq
                """, arguments: [sid]),
            items: try Item.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN "commit" c ON c.id = item.commit_id
                WHERE c.session_id = ? AND c.undone = 0 AND item.removed = 0
                ORDER BY c.seq, item.rowid
                """, arguments: [sid]),
            groups: try ItemGroup.filter(Column("session_id") == sid).order(Column("seq")).fetchAll(db),
            manualLines: try ManualLine.filter(Column("session_id") == sid).order(Column("created_at")).fetchAll(db),
            openPossibleMisses: try PossibleMiss.fetchAll(db, sql: """
                SELECT pm.* FROM possible_miss pm JOIN "commit" c ON c.id = pm.commit_id
                WHERE c.session_id = ? AND c.undone = 0 AND pm.status = 'open'
                ORDER BY c.seq, pm.rowid
                """, arguments: [sid]))
    }
}
