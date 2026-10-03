import Foundation
import GRDB
import simd

// MARK: - What the AR layer hands over

/// One commit, as the AR layer hands it over: `StockMaskCounting.CommitResult` plus the context
/// only the AR layer has (session, zone, anchor, pose, keyframe path).
///
/// Mapping from `CommitResult`: `id` = `commitID`; `items` = `newItems`; `countedZone` = `zone`;
/// `matchedCount` = `matched.count`; `possibleMisses` = the detections at `possibleMisses`, with
/// their positions; `driftAlarm` = `driftAlarm`. Positions and the zone stay in AR world space,
/// as the engine gives them.
///
/// Write the keyframe file **before** calling `saveCommit`, so the database never points at a
/// missing file. A crash in between leaves an orphan file, never a lost or partial commit.
public struct CommitDraft: Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var zoneID: UUID
    /// The identifier of the commit's ARAnchor (created at `countedZone.transform`).
    public var anchorID: UUID?
    public var pose: simd_float4x4?
    /// Relative to the app's data directory (the container path changes between installs).
    public var keyframePath: String?
    public var trigger: CommitTrigger?
    /// Defaults to the store's clock.
    public var createdAt: Date?
    /// The commit's new counted items (`CommitResult.newItems`).
    public var items: [NewItem]
    /// Optional product suggestions per `groupKey` (ADR 004). Never an assignment (FR-31).
    public var groups: [NewGroup]
    public var countedZone: NewCountedZone
    public var possibleMisses: [NewPossibleMiss]
    public var matchedCount: Int
    public var driftAlarm: Bool

    public init(
        id: UUID, sessionID: UUID, zoneID: UUID, anchorID: UUID? = nil, pose: simd_float4x4? = nil,
        keyframePath: String? = nil, trigger: CommitTrigger? = nil, createdAt: Date? = nil,
        items: [NewItem], groups: [NewGroup] = [], countedZone: NewCountedZone,
        possibleMisses: [NewPossibleMiss] = [], matchedCount: Int = 0, driftAlarm: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.zoneID = zoneID
        self.anchorID = anchorID
        self.pose = pose
        self.keyframePath = keyframePath
        self.trigger = trigger
        self.createdAt = createdAt
        self.items = items
        self.groups = groups
        self.countedZone = countedZone
        self.possibleMisses = possibleMisses
        self.matchedCount = matchedCount
        self.driftAlarm = driftAlarm
    }
}

/// A counted item: a `StockMaskCounting.CountedItem`, field for field. Keep its `id`: the engine,
/// the overlays and the database then name the item the same way.
public struct NewItem: Sendable {
    public var id: UUID
    /// `.bottleTop` is a bottle counted by its top (a row behind): one bottle unit in the sheet.
    public var cls: ItemClass
    /// Metres, AR world space: the object's centre, or the top for `.bottleTop`. Must be finite.
    public var position: SIMD3<Float>
    /// `CountedItem.top`: persisted so a top seen alone after a relaunch still matches a bottle
    /// counted whole.
    public var top: SIMD3<Float>?
    /// `CountedItem.productKey` (see `SKU.productKey`).
    public var productKey: Int?
    public var confidence: Float?
    /// `CountedItem.detectionIndex`.
    public var detectionIndex: Int?
    /// Items with the same key form one group (ADR 004). Items without a key are grouped by
    /// kind within the commit: bottles and tops together, cans, cases.
    public var groupKey: Int?
    public var cropPath: String?

    public init(
        id: UUID, cls: ItemClass, position: SIMD3<Float>, top: SIMD3<Float>? = nil, productKey: Int? = nil,
        confidence: Float? = nil, detectionIndex: Int? = nil, groupKey: Int? = nil, cropPath: String? = nil
    ) {
        self.id = id
        self.cls = cls
        self.position = position
        self.top = top
        self.productKey = productKey
        self.confidence = confidence
        self.detectionIndex = detectionIndex
        self.groupKey = groupKey
        self.cropPath = cropPath
    }
}

/// A product suggestion for one `groupKey` of a commit.
public struct NewGroup: Sendable {
    public var key: Int
    public var suggestedSKUID: UUID?
    public var suggestionSource: SuggestionSource?

    public init(key: Int, suggestedSKUID: UUID? = nil, suggestionSource: SuggestionSource? = nil) {
        self.key = key
        self.suggestedSKUID = suggestedSKUID
        self.suggestionSource = suggestionSource
    }
}

/// The commit's counted zone (`StockMaskCounting.CountedZone`): an oriented box.
public struct NewCountedZone: Sendable {
    public var id: UUID
    public var transform: simd_float4x4
    public var halfExtents: SIMD3<Float>

    public init(id: UUID, transform: simd_float4x4, halfExtents: SIMD3<Float>) {
        self.id = id
        self.transform = transform
        self.halfExtents = halfExtents
    }
}

/// An amber "+" of this commit. When the AR layer recognises an earlier miss (it knows the anchors,
/// so it can compare positions across commits), it passes that miss's id again: an open miss then
/// moves to this commit instead of being counted twice in review; one the user already added or
/// dismissed stays resolved. New ids make new rows.
public struct NewPossibleMiss: Sendable {
    public var id: UUID
    public var cls: ItemClass
    /// Metres, AR world space (`Detection.position`).
    public var position: SIMD3<Float>?
    public var top: SIMD3<Float>?
    public var confidence: Float?
    /// The detection's index in this commit (for `CommitEngine.addDetection` when tapped).
    public var detectionIndex: Int?
    public var cropPath: String?

    public init(
        id: UUID, cls: ItemClass, position: SIMD3<Float>? = nil, top: SIMD3<Float>? = nil, confidence: Float? = nil,
        detectionIndex: Int? = nil, cropPath: String? = nil
    ) {
        self.id = id
        self.cls = cls
        self.position = position
        self.top = top
        self.confidence = confidence
        self.detectionIndex = detectionIndex
        self.cropPath = cropPath
    }
}

// MARK: - What the store hands back

/// The saved commit, with the groups the commit card shows ("8 × bottle → name it").
public struct SavedCommit: Equatable, Sendable {
    public var commit: Commit
    public var countedZone: CountedZone
    public var groups: [SavedGroup]
    public var items: [Item]
    public var possibleMisses: [PossibleMiss]
}

public struct SavedGroup: Equatable, Sendable {
    /// The draft's `groupKey`, or nil for a group made from items without a key.
    public var key: Int?
    public var group: ItemGroup
    public var itemIDs: [UUID]
    /// Units by what they count as: bottles (tops included), cans, cases. Never a `.bottleTop` key.
    public var counts: [ItemClass: Int]
}

/// What "undo" took back: remove these overlays.
public struct UndoneCommit: Equatable, Sendable {
    public var commit: Commit
    public var itemIDs: [UUID]
    public var countedZoneIDs: [UUID]
    public var possibleMissIDs: [UUID]
}

// MARK: - Store methods

extension StockStore {
    /// Saves one commit with its items, groups, counted zone, possible misses and keyframe path
    /// in **one transaction** (FR-7). On return the commit is on disk; on throw nothing was saved.
    @discardableResult
    public func saveCommit(_ draft: CommitDraft) throws -> SavedCommit {
        try draft.validate()
        let now = timestamp()
        return try writer.write { db in
            let session = try Self.requireWritableSession(db, draft.sessionID)
            _ = try Self.requireZone(db, draft.zoneID, venue: session.venueID)
            let createdAt = DBTime.normalize(draft.createdAt ?? now)
            let seq = (try Int.fetchOne(
                db, sql: #"SELECT MAX(seq) FROM "commit" WHERE session_id = ?"#, arguments: [session.id.dbKey]) ?? 0) + 1

            let commit = Commit(
                id: draft.id, sessionID: session.id, zoneID: draft.zoneID, seq: seq, anchorID: draft.anchorID,
                pose: draft.pose, keyframePath: draft.keyframePath, trigger: draft.trigger,
                matchedCount: draft.matchedCount, driftAlarm: draft.driftAlarm, createdAt: createdAt,
                undone: false, undoneAt: nil)
            try commit.insert(db)
            let zone = CountedZone(
                id: draft.countedZone.id, commitID: draft.id, transform: draft.countedZone.transform,
                halfExtents: draft.countedZone.halfExtents)
            try zone.insert(db)

            // Groups: one per groupKey (ascending), then one per kind for items without a key.
            let suggestions = Dictionary(draft.groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var nextSeq = try Self.nextGroupSeq(db, session.id)
            var groupBySlot: [GroupSlot: ItemGroup] = [:]
            for slot in Set(draft.items.map(GroupSlot.init)).sorted() {
                let suggestion = slot.key.flatMap { suggestions[$0] }
                let suggested = suggestion?.suggestedSKUID
                if let suggested { _ = try Self.requireSKU(db, suggested, venue: session.venueID) }
                let group = ItemGroup(
                    id: UUID(), sessionID: session.id, commitID: draft.id, seq: nextSeq, label: groupLetters(nextSeq),
                    skuID: nil, confirmed: false, suggestedSKUID: suggested,
                    suggestionSource: suggested == nil ? nil : suggestion?.suggestionSource,
                    createdAt: createdAt, namedAt: nil)
                try group.insert(db)
                groupBySlot[slot] = group
                nextSeq += 1
            }

            var items: [Item] = []
            for new in draft.items {
                let item = Item(new, commitID: draft.id, groupID: groupBySlot[GroupSlot(new)]!.id, at: createdAt)
                try item.insert(db)
                items.append(item)
            }
            var misses: [PossibleMiss] = []
            for new in draft.possibleMisses {
                if var seen = try PossibleMiss.fetchOne(db, key: new.id.dbKey) {
                    // The same miss again: still open, it moves to this commit;
                    // added or dismissed by the user, it stays resolved.
                    guard try Self.requireCommit(db, seen.commitID).sessionID == session.id else {
                        throw StoreError.invalid("Possible miss \(new.id.dbKey) belongs to another session")
                    }
                    guard seen.status == .open else { continue }
                    seen.commitID = draft.id
                    seen.cls = new.cls
                    seen.position = finite(new.position)
                    seen.top = finite(new.top)
                    seen.confidence = finite(new.confidence)
                    seen.detectionIndex = new.detectionIndex
                    seen.cropPath = new.cropPath
                    try seen.update(db)
                    misses.append(seen)
                } else {
                    let miss = PossibleMiss(
                        id: new.id, commitID: draft.id, cls: new.cls, position: finite(new.position), top: finite(new.top),
                        confidence: finite(new.confidence), detectionIndex: new.detectionIndex, cropPath: new.cropPath,
                        status: .open, itemID: nil, resolvedAt: nil)
                    try miss.insert(db)
                    misses.append(miss)
                }
            }

            try Self.addSessionZone(db, session.id, draft.zoneID)
            if session.currentZoneID != draft.zoneID {
                try db.execute(
                    sql: "UPDATE session SET current_zone_id = ? WHERE id = ?",
                    arguments: [draft.zoneID.dbKey, session.id.dbKey])
            }
            let saved = groupBySlot.sorted { $0.key < $1.key }.map { slot, group in
                let members = items.filter { $0.groupID == group.id }
                return SavedGroup(
                    key: slot.key, group: group, itemIDs: members.map(\.id),
                    counts: Dictionary(grouping: members, by: \.cls.countsAs).mapValues(\.count))
            }
            try Self.log(db, .commitSaved, venue: session.venueID, session: session.id, at: now, [
                "commit": .init(draft.id), "seq": .int(seq), "zone": .init(draft.zoneID), "items": .int(items.count),
                "groups": .init(saved.map(\.group.id)), "possible_misses": .int(misses.count),
                "matched": .int(draft.matchedCount), "drift_alarm": .bool(draft.driftAlarm),
                "keyframe": .init(draft.keyframePath), "trigger": .init(draft.trigger?.rawValue),
            ])
            return SavedCommit(commit: commit, countedZone: zone, groups: saved, items: items, possibleMisses: misses)
        }
    }

    /// FR-16: undoes the session's last commit that is not undone yet. Its items, counted zone
    /// and possible misses stop counting; the rows stay for the audit trail. Calling it again
    /// undoes the commit before. Returns nil when there is nothing to undo.
    ///
    /// Pass `expecting` (the commit the UI shows in its snackbar) to refuse undoing a different one.
    @discardableResult
    public func undoLastCommit(sessionID: UUID, expecting: UUID? = nil) throws -> UndoneCommit? {
        let now = timestamp()
        return try writer.write { db in
            let session = try Self.requireWritableSession(db, sessionID)
            guard var commit = try Commit
                .filter(Column("session_id") == sessionID.dbKey && Column("undone") == false)
                .order(Column("seq").desc).fetchOne(db)
            else { return nil }
            if let expecting, expecting != commit.id {
                throw StoreError.invalid("The last commit is \(commit.id.dbKey), not \(expecting.dbKey)")
            }
            commit.undone = true
            commit.undoneAt = now
            try commit.update(db)
            let itemIDs = try UUID.fetchAll(
                db, sql: "SELECT id FROM item WHERE commit_id = ? AND removed = 0 ORDER BY rowid",
                arguments: [commit.id.dbKey])
            let zoneIDs = try UUID.fetchAll(
                db, sql: "SELECT id FROM counted_zone WHERE commit_id = ?", arguments: [commit.id.dbKey])
            let missIDs = try UUID.fetchAll(
                db, sql: "SELECT id FROM possible_miss WHERE commit_id = ? AND status = 'open'",
                arguments: [commit.id.dbKey])
            try Self.log(db, .commitUndone, venue: session.venueID, session: sessionID, at: now, [
                "commit": .init(commit.id), "seq": .int(commit.seq), "items": .init(itemIDs),
            ])
            return UndoneCommit(commit: commit, itemIDs: itemIDs, countedZoneIDs: zoneIDs, possibleMissIDs: missIDs)
        }
    }

    /// Adds one item to an existing commit: a low-confidence or cut detection the user tapped to
    /// include (FR-18), as `CommitEngine.addDetection` returned it. It joins `groupID`, or a new
    /// unnamed group. In a named group, its `productKey` becomes that product's.
    @discardableResult
    public func addItem(_ new: NewItem, toCommit commitID: UUID, groupID: UUID? = nil) throws -> Item {
        guard all(new.position, \.isFinite) else { throw StoreError.invalid("Item \(new.id.dbKey) has a non-finite position") }
        let now = timestamp()
        return try writer.write { db in
            let (commit, session) = try Self.requireActiveCommit(db, commitID)
            let group = try Self.groupOrNew(db, groupID, session: session, commitID: commitID, at: now)
            var item = Item(new, commitID: commitID, groupID: group.id, at: now)
            if let sku = group.skuID { item.productKey = sku.productKey }
            try item.insert(db)
            try Self.log(db, .itemAdded, venue: session.venueID, session: session.id, at: now, [
                "item": .init(item.id), "commit": .init(commit.id), "group": .init(group.id), "class": .string(new.cls.rawValue),
            ])
            return item
        }
    }

    /// The user tapped an amber "+": it becomes a counted item of the commit that last showed it,
    /// in `groupID` or a new unnamed group.
    ///
    /// Pass `item`, the `CountedItem` that `CommitEngine.addDetection` returned, so the engine and
    /// the database share its id and position. Without it (e.g. after a relaunch, when the engine
    /// no longer has the commit's detections), the item is made from the stored miss.
    @discardableResult
    public func addPossibleMiss(_ missID: UUID, item new: NewItem? = nil, toGroup groupID: UUID? = nil) throws -> Item {
        if let new, !all(new.position, \.isFinite) {
            throw StoreError.invalid("Item \(new.id.dbKey) has a non-finite position")
        }
        let now = timestamp()
        return try writer.write { db in
            guard var miss = try PossibleMiss.fetchOne(db, key: missID.dbKey) else {
                throw StoreError.notFound("possible miss", missID)
            }
            guard miss.status == .open else { throw StoreError.invalid("Possible miss \(missID.dbKey) is \(miss.status.rawValue)") }
            let (commit, session) = try Self.requireActiveCommit(db, miss.commitID)
            var made = new
            if made == nil {
                guard let at = miss.position else {
                    throw StoreError.invalid("Possible miss \(missID.dbKey) has no position to count it at")
                }
                made = NewItem(
                    id: UUID(), cls: miss.cls, position: at, top: miss.top, confidence: miss.confidence,
                    detectionIndex: miss.detectionIndex)
            }
            let group = try Self.groupOrNew(db, groupID, session: session, commitID: commit.id, at: now)
            var item = Item(made!, commitID: commit.id, groupID: group.id, at: now)
            if item.cropPath == nil { item.cropPath = miss.cropPath }
            if let sku = group.skuID { item.productKey = sku.productKey }
            try item.insert(db)
            miss.status = .added
            miss.itemID = item.id
            miss.resolvedAt = now
            try miss.update(db)
            try Self.log(db, .possibleMissAdded, venue: session.venueID, session: session.id, at: now, [
                "possible_miss": .init(missID), "item": .init(item.id), "group": .init(group.id),
            ])
            return item
        }
    }

    /// The user dismissed an amber "+" (it was already counted, or not stock).
    public func dismissPossibleMiss(_ missID: UUID) throws {
        let now = timestamp()
        try writer.write { db in
            guard var miss = try PossibleMiss.fetchOne(db, key: missID.dbKey) else {
                throw StoreError.notFound("possible miss", missID)
            }
            let (_, session) = try Self.requireActiveCommit(db, miss.commitID)
            guard miss.status == .open else { return }
            miss.status = .dismissed
            miss.resolvedAt = now
            try miss.update(db)
            try Self.log(db, .possibleMissDismissed, venue: session.venueID, session: session.id, at: now, [
                "possible_miss": .init(missID),
            ])
        }
    }

    /// FR-17: uncount an item (its overlay disappears), or count it again.
    @discardableResult
    public func setItemRemoved(_ itemID: UUID, removed: Bool) throws -> Item {
        let now = timestamp()
        return try writer.write { db in
            var item = try Self.requireItem(db, itemID)
            let (_, session) = try Self.requireActiveCommit(db, item.commitID)
            guard item.removed != removed else { return item }
            item.removed = removed
            try item.update(db)
            try Self.log(db, removed ? .itemRemoved : .itemRestored, venue: session.venueID, session: session.id, at: now, [
                "item": .init(itemID), "group": .init(item.groupID),
            ])
            return item
        }
    }

    // MARK: Helpers

    static func requireCommit(_ db: Database, _ id: UUID) throws -> Commit {
        guard let commit = try Commit.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("commit", id) }
        return commit
    }

    static func requireItem(_ db: Database, _ id: UUID) throws -> Item {
        guard let item = try Item.fetchOne(db, key: id.dbKey) else { throw StoreError.notFound("item", id) }
        return item
    }

    /// A commit that still counts, in a session that can be changed.
    static func requireActiveCommit(_ db: Database, _ id: UUID) throws -> (Commit, Session) {
        let commit = try requireCommit(db, id)
        let session = try requireWritableSession(db, commit.sessionID)
        guard !commit.undone else { throw StoreError.invalid("Commit \(id.dbKey) was undone") }
        return (commit, session)
    }

    static func nextGroupSeq(_ db: Database, _ sessionID: UUID) throws -> Int {
        (try Int.fetchOne(
            db, sql: "SELECT MAX(seq) FROM item_group WHERE session_id = ?", arguments: [sessionID.dbKey]) ?? 0) + 1
    }

    /// The given group (which must be in the session), or a new unnamed one.
    static func groupOrNew(_ db: Database, _ groupID: UUID?, session: Session, commitID: UUID?, at now: Date) throws -> ItemGroup {
        if let groupID {
            guard let group = try ItemGroup.fetchOne(db, key: groupID.dbKey), group.sessionID == session.id else {
                throw StoreError.notFound("group", groupID)
            }
            return group
        }
        let seq = try nextGroupSeq(db, session.id)
        let group = ItemGroup(
            id: UUID(), sessionID: session.id, commitID: commitID, seq: seq, label: groupLetters(seq), skuID: nil,
            confirmed: false, suggestedSKUID: nil, suggestionSource: nil, createdAt: now, namedAt: nil)
        try group.insert(db)
        return group
    }
}

/// How `saveCommit` groups a commit's items: by the AR layer's key, else by kind.
enum GroupSlot: Hashable, Comparable {
    case key(Int)
    case kind(Int)  // 0 bottles and tops, 1 cans, 2 cases, 3 cartons, 4 bags

    init(_ item: NewItem) {
        if let key = item.groupKey {
            self = .key(key)
        } else {
            switch item.cls {
            case .bottle, .bottleTop: self = .kind(0)
            case .can: self = .kind(1)
            case .case: self = .kind(2)
            case .carton: self = .kind(3)
            case .bag: self = .kind(4)
            }
        }
    }

    var key: Int? { if case let .key(k) = self { k } else { nil } }

    static func < (a: GroupSlot, b: GroupSlot) -> Bool {
        switch (a, b) {
        case let (.key(x), .key(y)), let (.kind(x), .kind(y)): x < y
        case (.key, .kind): true
        case (.kind, .key): false
        }
    }
}

func all(_ v: SIMD3<Float>, _ test: (Float) -> Bool) -> Bool { test(v.x) && test(v.y) && test(v.z) }

/// An optional point with a non-finite coordinate is no point (SQLite would store NaN as NULL).
func finite(_ v: SIMD3<Float>?) -> SIMD3<Float>? {
    guard let v, all(v, \.isFinite) else { return nil }
    return v
}

func finite(_ f: Float?) -> Float? {
    guard let f, f.isFinite else { return nil }
    return f
}

extension Item {
    /// A new counted item from what the AR layer handed over.
    init(_ new: NewItem, commitID: UUID, groupID: UUID, at createdAt: Date) {
        self.init(
            id: new.id, commitID: commitID, groupID: groupID, cls: new.cls, position: new.position, top: finite(new.top),
            productKey: new.productKey, confidence: finite(new.confidence),
            detectionIndex: new.detectionIndex, cropPath: new.cropPath, removed: false, createdAt: createdAt)
    }
}

extension CommitDraft {
    func validate() throws {
        let ids = items.map(\.id) + possibleMisses.map(\.id)
        guard Set(ids).count == ids.count else { throw StoreError.invalid("Commit \(id.dbKey) repeats an item id") }
        for item in items where !all(item.position, \.isFinite) {
            throw StoreError.invalid("Item \(item.id.dbKey) has a non-finite position")
        }
        guard all(countedZone.halfExtents, { $0.isFinite && $0 >= 0 }) else {
            throw StoreError.invalid("The counted zone needs finite, non-negative half extents")
        }
        guard matchedCount >= 0 else { throw StoreError.invalid("matchedCount can't be negative") }
    }
}
