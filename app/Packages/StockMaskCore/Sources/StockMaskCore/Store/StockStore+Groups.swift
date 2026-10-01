import Foundation
import GRDB

extension StockStore {
    // MARK: - Naming groups (FR-28, FR-31)

    /// The user confirmed a product for the group: by tap, on the commit card, or in review.
    @discardableResult
    public func nameGroup(_ groupID: UUID, sku skuID: UUID) throws -> ItemGroup {
        let now = timestamp()
        return try writer.write { db in
            let (group, session) = try Self.requireWritableGroup(db, groupID)
            _ = try Self.requireSKU(db, skuID, venue: session.venueID)
            return try Self.setProduct(db, group, skuID, session: session, at: now)
        }
    }

    /// The user deliberately left the group unknown: it stays "Unknown A" and no longer blocks
    /// the lock (FR-35).
    @discardableResult
    public func markGroupUnknown(_ groupID: UUID) throws -> ItemGroup {
        let now = timestamp()
        return try writer.write { db in
            let (group, session) = try Self.requireWritableGroup(db, groupID)
            return try Self.setProduct(db, group, nil, session: session, at: now)
        }
    }

    /// Bulk confirmation in review (FR-31): names each listed group that is still unnamed and
    /// has a suggestion with its suggested product. Returns the groups it named.
    @discardableResult
    public func acceptSuggestions(groupIDs: [UUID]) throws -> [ItemGroup] {
        let now = timestamp()
        return try writer.write { db in
            var named: [ItemGroup] = []
            for id in groupIDs {
                let (group, session) = try Self.requireWritableGroup(db, id)
                guard group.state == .unnamed, let suggested = group.suggestedSKUID else { continue }
                named.append(try Self.setProduct(db, group, suggested, session: session, at: now))
            }
            return named
        }
    }

    /// All the session's groups, by sequence ("A", "B"…), including ones left empty by moves.
    public func groups(sessionID: UUID) throws -> [ItemGroup] {
        try writer.read { db in
            try ItemGroup.filter(Column("session_id") == sessionID.dbKey).order(Column("seq")).fetchAll(db)
        }
    }

    /// A group's counted items (not removed, in commits not undone). After naming a group or moving
    /// items, pass their `productKey`s to `CommitEngine.setProductKey`.
    public func items(inGroup groupID: UUID) throws -> [Item] {
        try writer.read { db in
            try Item.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN "commit" c ON c.id = item.commit_id
                WHERE item.group_id = ? AND item.removed = 0 AND c.undone = 0
                ORDER BY c.seq, item.rowid
                """, arguments: [groupID.dbKey])
        }
    }

    static func requireWritableGroup(_ db: Database, _ id: UUID) throws -> (ItemGroup, Session) {
        guard let group = try ItemGroup.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("group", id) }
        return (group, try requireWritableSession(db, group.sessionID))
    }

    private static func setProduct(
        _ db: Database, _ group: ItemGroup, _ skuID: UUID?, session: Session, at now: Date
    ) throws -> ItemGroup {
        var group = group
        let previous = group.skuID
        let wasConfirmed = group.confirmed
        group.skuID = skuID
        group.confirmed = true
        group.namedAt = now
        try group.update(db)
        // The counting engine's product key follows the confirmed product (nil when unknown).
        try db.execute(
            sql: "UPDATE item SET product_key = ? WHERE group_id = ?", arguments: [skuID?.productKey, group.id.dbKey])
        if let skuID {
            try log(db, .groupNamed, venue: session.venueID, session: session.id, at: now, [
                "group": .init(group.id), "sku": .init(skuID), "previous_sku": .init(previous),
                "suggested_sku": .init(group.suggestedSKUID),
                "suggestion_source": .init(group.suggestionSource?.rawValue),
                "accepted_suggestion": .bool(group.suggestedSKUID == skuID), "renamed": .bool(wasConfirmed),
            ])
        } else {
            try log(db, .groupMarkedUnknown, venue: session.venueID, session: session.id, at: now, [
                "group": .init(group.id), "previous_sku": .init(previous),
            ])
        }
        return group
    }

    // MARK: - Split and merge (FR-34)

    /// Moves items to `groupID`, or to a new unnamed group. Merge = move all of a group's items;
    /// split = move some of them to a new group. Returns the target group. The moved items take the
    /// target's product key (nil when it has no product).
    @discardableResult
    public func moveItems(_ itemIDs: [UUID], toGroup groupID: UUID? = nil) throws -> ItemGroup {
        guard !itemIDs.isEmpty else { throw StoreError.invalid("No items to move") }
        let now = timestamp()
        return try writer.write { db in
            var items: [Item] = []
            var commits: [UUID: Commit] = [:]
            for id in itemIDs {
                let item = try Self.requireItem(db, id)
                if commits[item.commitID] == nil { commits[item.commitID] = try Self.requireCommit(db, item.commitID) }
                items.append(item)
            }
            let sessionIDs = Set(commits.values.map(\.sessionID))
            guard sessionIDs.count == 1, let sessionID = sessionIDs.first else {
                throw StoreError.invalid("Items from different sessions can't share a group")
            }
            let session = try Self.requireWritableSession(db, sessionID)
            let target = try Self.groupOrNew(
                db, groupID, session: session, commitID: commits.count == 1 ? commits.keys.first : nil, at: now)
            for var item in items where item.groupID != target.id {
                item.groupID = target.id
                item.productKey = target.skuID?.productKey
                try item.update(db)
            }
            try Self.log(db, .itemsMoved, venue: session.venueID, session: sessionID, at: now, [
                "items": .init(itemIDs), "from_groups": .init(Array(Set(items.map(\.groupID))).sorted { $0.dbKey < $1.dbKey }),
                "to_group": .init(target.id), "new_group": .bool(groupID == nil),
            ])
            return target
        }
    }

    // MARK: - Deleting a line (FR-34)

    /// Deletes a sheet line: uncounts its camera items (their overlays disappear) and, for a
    /// product line, deletes its manual lines. Returns the uncounted item ids.
    @discardableResult
    public func deleteLine(_ lineID: LineKey, sessionID: UUID) throws -> [UUID] {
        let now = timestamp()
        return try writer.write { db in
            let session = try Self.requireWritableSession(db, sessionID)
            let groupFilter: String
            let argument: String
            switch lineID {
            case let .product(skuID):
                groupFilter = "g.sku_id = ?"
                argument = skuID.dbKey
            case let .unknownGroup(groupID):
                groupFilter = "g.id = ? AND g.sku_id IS NULL"
                argument = groupID.dbKey
            }
            let itemIDs = try UUID.fetchAll(db, sql: """
                SELECT i.id FROM item i
                JOIN item_group g ON g.id = i.group_id
                JOIN "commit" c ON c.id = i.commit_id
                WHERE g.session_id = ? AND \(groupFilter) AND i.removed = 0 AND c.undone = 0
                ORDER BY i.rowid
                """, arguments: [sessionID.dbKey, argument])
            for id in itemIDs {
                try db.execute(sql: "UPDATE item SET removed = 1 WHERE id = ?", arguments: [id.dbKey])
            }
            var manualLines: [ManualLine] = []
            if case let .product(skuID) = lineID {
                manualLines = try ManualLine.filter(Column("session_id") == sessionID.dbKey && Column("sku_id") == skuID.dbKey)
                    .order(Column("created_at")).fetchAll(db)
                for line in manualLines { try line.delete(db) }
            }
            guard !itemIDs.isEmpty || !manualLines.isEmpty else { return [] }
            try Self.log(db, .lineDeleted, venue: session.venueID, session: sessionID, at: now, [
                "line": lineID.json, "items": .init(itemIDs), "manual_lines": .array(manualLines.map { .object($0.json) }),
            ])
            return itemIDs
        }
    }

    // MARK: - Manual lines (FR-30)

    /// Adds a product and quantity the camera can't count (kegs, partial cases, closed cupboards).
    @discardableResult
    public func addManualLine(
        sessionID: UUID, zoneID: UUID, skuID: UUID, fullCases: Int = 0, looseUnits: Int = 0, note: String? = nil
    ) throws -> ManualLine {
        try Self.checkQuantity(fullCases, looseUnits)
        let now = timestamp()
        return try writer.write { db in
            let session = try Self.requireWritableSession(db, sessionID)
            _ = try Self.requireZone(db, zoneID, venue: session.venueID)
            _ = try Self.requireSKU(db, skuID, venue: session.venueID)
            let line = ManualLine(
                id: UUID(), sessionID: sessionID, zoneID: zoneID, skuID: skuID, fullCases: fullCases,
                looseUnits: looseUnits, note: Self.cleanNote(note), createdAt: now, updatedAt: now)
            try line.insert(db)
            try Self.addSessionZone(db, sessionID, zoneID)
            try Self.log(db, .manualLineAdded, venue: session.venueID, session: sessionID, at: now, line.json)
            return line
        }
    }

    /// Saves changes to a manual line (zone, product, quantity, note), identified by its id.
    @discardableResult
    public func updateManualLine(_ line: ManualLine) throws -> ManualLine {
        try Self.checkQuantity(line.fullCases, line.looseUnits)
        let now = timestamp()
        return try writer.write { db in
            guard var stored = try ManualLine.fetchOne(db, key: line.id.dbKey) else {
                throw StoreError.notFound("manual line", line.id)
            }
            let session = try Self.requireWritableSession(db, stored.sessionID)
            _ = try Self.requireZone(db, line.zoneID, venue: session.venueID)
            _ = try Self.requireSKU(db, line.skuID, venue: session.venueID)
            let before = stored.json
            stored.zoneID = line.zoneID
            stored.skuID = line.skuID
            stored.fullCases = line.fullCases
            stored.looseUnits = line.looseUnits
            stored.note = Self.cleanNote(line.note)
            stored.updatedAt = now
            try stored.update(db)
            try Self.addSessionZone(db, stored.sessionID, stored.zoneID)
            try Self.log(db, .manualLineUpdated, venue: session.venueID, session: session.id, at: now, [
                "before": .object(before), "after": .object(stored.json),
            ])
            return stored
        }
    }

    public func deleteManualLine(_ id: UUID) throws {
        let now = timestamp()
        try writer.write { db in
            guard let line = try ManualLine.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("manual line", id) }
            let session = try Self.requireWritableSession(db, line.sessionID)
            try line.delete(db)
            try Self.log(db, .manualLineDeleted, venue: session.venueID, session: session.id, at: now, line.json)
        }
    }

    public func manualLines(sessionID: UUID) throws -> [ManualLine] {
        try writer.read { db in
            try ManualLine.filter(Column("session_id") == sessionID.dbKey).order(Column("created_at")).fetchAll(db)
        }
    }

    static func checkQuantity(_ fullCases: Int, _ looseUnits: Int) throws {
        guard fullCases >= 0, looseUnits >= 0 else { throw StoreError.invalid("Quantities can't be negative") }
    }

    static func cleanNote(_ note: String?) -> String? {
        guard let t = note?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

extension ManualLine {
    var json: [String: JSONValue] {
        [
            "manual_line": .init(id), "zone": .init(zoneID), "sku": .init(skuID), "full_cases": .int(fullCases),
            "loose_units": .int(looseUnits), "note": .init(note),
        ]
    }
}
