import Foundation
import GRDB

extension StockStore {
    // MARK: - Start and find sessions (FR-6, FR-38)

    /// Starts a count. `zoneIDs` are the zones to count today (default: all the venue's zones);
    /// counting starts in `startZoneID` (default: the first of them).
    ///
    /// Throws `StoreError.activeSessionExists` while another session is open or in review:
    /// one active session per device.
    @discardableResult
    public func startSession(
        venueID: UUID, counterName: String, zoneIDs: [UUID]? = nil, startZoneID: UUID? = nil
    ) throws -> Session {
        let counter = counterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !counter.isEmpty else { throw StoreError.invalid("A session needs the counter's name") }
        let now = timestamp()
        return try writer.write { db in
            _ = try Self.requireVenue(db, venueID)
            if let active = try Self.activeSession(db) { throw StoreError.activeSessionExists(active.id) }
            var chosen: [Zone] = []
            if let zoneIDs {
                for id in zoneIDs where !chosen.contains(where: { $0.id == id }) {
                    chosen.append(try Self.requireZone(db, id, venue: venueID))
                }
            } else {
                chosen = try Zone.filter(Column("venue_id") == venueID.dbKey).order(Column("sort")).fetchAll(db)
            }
            let start = try startZoneID.map { try Self.requireZone(db, $0, venue: venueID) } ?? chosen.first
            if let start, !chosen.contains(where: { $0.id == start.id }) { chosen.append(start) }

            let session = Session(
                id: UUID(), venueID: venueID, counterName: counter, status: .open, currentZoneID: start?.id,
                startedAt: now, finishedAt: nil)
            try session.insert(db)
            for (i, zone) in chosen.enumerated() {
                try SessionZone(sessionID: session.id, zoneID: zone.id, sort: i).insert(db)
            }
            try Self.log(db, .sessionStarted, venue: venueID, session: session.id, at: now, [
                "counter": .string(counter), "zones": .init(chosen.map(\.id)), "start_zone": .init(start?.id),
            ])
            return try Self.requireSession(db, session.id)
        }
    }

    /// The open or in-review session, if any: what to resume after a relaunch (FR-7).
    public func activeSession() throws -> Session? {
        try writer.read { db in try Self.activeSession(db) }
    }

    static func activeSession(_ db: Database) throws -> Session? {
        try Session.filter(Column("status") != SessionStatus.locked.rawValue)
            .order(Column("started_at").desc).fetchOne(db)
    }

    public func session(id: UUID) throws -> Session? {
        try writer.read { db in try Session.fetchOne(db, key: id.dbKey) }
    }

    /// Session history, newest first (FR-38).
    public func sessions(venueID: UUID? = nil) throws -> [Session] {
        try writer.read { db in
            var request = Session.order(Column("started_at").desc)
            if let venueID { request = request.filter(Column("venue_id") == venueID.dbKey) }
            return try request.fetchAll(db)
        }
    }

    /// The zones chosen for the session, in order, including zones switched to later.
    public func sessionZones(sessionID: UUID) throws -> [Zone] {
        try writer.read { db in try Self.sessionZones(db, sessionID) }
    }

    static func sessionZones(_ db: Database, _ sessionID: UUID) throws -> [Zone] {
        try Zone.fetchAll(db, sql: """
            SELECT zone.* FROM session_zone JOIN zone ON zone.id = session_zone.zone_id
            WHERE session_zone.session_id = ? ORDER BY session_zone.sort
            """, arguments: [sessionID.dbKey])
    }

    static func addSessionZone(_ db: Database, _ sessionID: UUID, _ zoneID: UUID) throws {
        let present = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM session_zone WHERE session_id = ? AND zone_id = ?)
            """, arguments: [sessionID.dbKey, zoneID.dbKey]) ?? false
        guard !present else { return }
        let sort = (try Int.fetchOne(
            db, sql: "SELECT MAX(sort) FROM session_zone WHERE session_id = ?", arguments: [sessionID.dbKey]) ?? -1) + 1
        try SessionZone(sessionID: sessionID, zoneID: zoneID, sort: sort).insert(db)
    }

    // MARK: - During the count (FR-8)

    /// The counter moved to another zone (the app then loads that zone's map).
    @discardableResult
    public func switchZone(sessionID: UUID, to zoneID: UUID) throws -> Session {
        let now = timestamp()
        return try writer.write { db in
            var session = try Self.requireWritableSession(db, sessionID)
            _ = try Self.requireZone(db, zoneID, venue: session.venueID)
            let previous = session.currentZoneID
            try Self.addSessionZone(db, sessionID, zoneID)
            guard previous != zoneID else { return session }
            session.currentZoneID = zoneID
            try session.update(db)
            try Self.log(db, .zoneSwitched, venue: session.venueID, session: sessionID, at: now, [
                "from": .init(previous), "to": .init(zoneID),
            ])
            return session
        }
    }

    // MARK: - Finish, lock, reopen (FR-9, FR-35, FR-38)

    /// Finish → review. Counting and edits are still allowed in review.
    @discardableResult
    public func finishSession(_ sessionID: UUID) throws -> Session {
        try setStatus(sessionID, from: [.open], to: .review, event: .sessionFinished)
    }

    /// Back from review to the camera.
    @discardableResult
    public func returnToCounting(_ sessionID: UUID) throws -> Session {
        try setStatus(sessionID, from: [.review], to: .open, event: .countingResumed)
    }

    private func setStatus(
        _ sessionID: UUID, from: Set<SessionStatus>, to: SessionStatus, event: EventType
    ) throws -> Session {
        let now = timestamp()
        return try writer.write { db in
            var session = try Self.requireWritableSession(db, sessionID)
            guard session.status != to else { return session }
            guard from.contains(session.status) else {
                throw StoreError.invalid("Session is \(session.status.rawValue), not \(from.map(\.rawValue).sorted())")
            }
            session.status = to
            try session.update(db)
            try Self.log(db, event, venue: session.venueID, session: sessionID, at: now)
            return session
        }
    }

    /// Locks the session: from then on it is read-only. Refused with `StoreError.unnamedGroups`
    /// while any group is still unnamed (FR-35 blockers): name it, or mark it unknown.
    ///
    /// The lock event keeps every line's totals as they were at lock time.
    @discardableResult
    public func lockSession(_ sessionID: UUID) throws -> Session {
        let now = timestamp()
        return try writer.write { db in
            var session = try Self.requireSession(db, sessionID)
            if session.status == .locked { return session }
            let sheet = try StockSheet.fetch(db, sessionID: sessionID, options: SheetOptions())
            let blockers = sheet.review.blockers.count
            guard blockers == 0 else { throw StoreError.unnamedGroups(blockers) }
            session.status = .locked
            session.finishedAt = now
            try session.update(db)
            try Self.log(db, .sessionLocked, venue: session.venueID, session: sessionID, at: now, [
                "total_units": .int(sheet.totalUnits),
                "lines": .array(sheet.lines.map { line in
                    [
                        "sku": .init(line.sku?.id), "group": .init(line.unknownGroupID), "name": .string(line.name),
                        "total_units": .init(line.quantity.totalUnits), "full_cases": .int(line.quantity.fullCases),
                        "loose_units": .int(line.quantity.looseUnits),
                    ]
                }),
            ])
            return try Self.requireSession(db, sessionID)
        }
    }

    /// Reopens a locked session for corrections, back to review. Logged with the reason (FR-9).
    /// Refused while another session is active.
    @discardableResult
    public func reopenSession(_ sessionID: UUID, reason: String? = nil) throws -> Session {
        let now = timestamp()
        return try writer.write { db in
            var session = try Self.requireSession(db, sessionID)
            guard session.status == .locked else { throw StoreError.invalid("Only a locked session can be reopened") }
            if let active = try Self.activeSession(db) { throw StoreError.activeSessionExists(active.id) }
            session.status = .review
            try session.update(db)
            try Self.log(db, .sessionReopened, venue: session.venueID, session: sessionID, at: now, [
                "reason": .init(reason),
            ])
            return session
        }
    }
}
