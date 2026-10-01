// SHIM: remove at integration (see ../../Package.swift).
// In memory: nothing survives a relaunch. The real package writes SQLite through GRDB.
import Foundation

public enum CoreShimError: Error, Equatable {
    case notFound(String)
    case xlsxNotInShim
}

public actor StockDatabase {
    public private(set) var venues: [Venue] = []
    public private(set) var zones: [Zone] = []
    public private(set) var skus: [Sku] = []
    public private(set) var sessions: [Session] = []
    public private(set) var commits: [Commit] = []
    public private(set) var countedZones: [CountedZoneRecord] = []
    public private(set) var items: [Item] = []
    public private(set) var groups: [ItemGroup] = []
    public private(set) var manualLines: [ManualLine] = []
    public private(set) var events: [Event] = []

    public init() {}

    public func insert(_ v: Venue) { venues.append(v) }
    public func insert(_ z: Zone) { zones.append(z) }
    public func insert(_ s: Sku) { skus.append(s) }
    public func insert(_ s: Session) { sessions.append(s) }
    public func insert(_ i: Item) { items.append(i) }
    public func insert(_ g: ItemGroup) { groups.append(g) }
    public func insert(_ m: ManualLine) { manualLines.append(m) }
    public func log(_ e: Event) { events.append(e) }

    /// FR-7: a commit, its counted zone, its items and its new groups are written together.
    public func saveCommit(_ commit: Commit, zone: CountedZoneRecord, items newItems: [Item], groups newGroups: [ItemGroup]) {
        commits.append(commit)
        countedZones.append(zone)
        groups += newGroups
        items += newItems
        events.append(Event(sessionID: commit.sessionID, type: "commit", payload: #"{"items":\#(newItems.count)}"#))
    }

    public func setUndone(commitID: UUID) throws {
        guard let i = commits.firstIndex(where: { $0.id == commitID }) else { throw CoreShimError.notFound("commit") }
        commits[i].undone = true
        events.append(Event(sessionID: commits[i].sessionID, type: "undo"))
    }

    public func assign(groupID: UUID, skuID: UUID?) throws {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { throw CoreShimError.notFound("group") }
        groups[i].skuID = skuID
        groups[i].confirmed = skuID != nil
    }

    /// "Unknown A", "Unknown B", ... "Unknown Z", "Unknown AA", ...
    public func nextUnknownLabel(sessionID: UUID) -> String {
        Self.unknownLabel(groups.filter { $0.sessionID == sessionID }.count)
    }

    public static func unknownLabel(_ n: Int) -> String {
        var n = n, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return "Unknown " + s
    }

    public func searchSkus(_ query: String) -> [Sku] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = skus.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.name) \($0.brand) \($0.code)".lowercased().contains(q) }
    }

    /// Items that count: not removed, in commits that were not undone.
    public func liveItems(sessionID: UUID) -> [Item] {
        let live = Set(commits.filter { $0.sessionID == sessionID && !$0.undone }.map(\.id))
        return items.filter { live.contains($0.commitID) && !$0.removed }
    }

    public func sheet(sessionID: UUID) -> StockSheet {
        StockSheet.build(items: liveItems(sessionID: sessionID), groups: groups.filter { $0.sessionID == sessionID },
                         manual: manualLines.filter { $0.sessionID == sessionID }, skus: skus)
    }
}
