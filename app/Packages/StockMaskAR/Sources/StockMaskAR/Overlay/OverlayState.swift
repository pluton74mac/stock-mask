import Foundation
import StockMaskCounting
import simd

/// What the 3D overlays show (PRD §9), as plain values: per commit, an anchor (the counted zone's
/// transform, which becomes a per-commit ARAnchor), the zone's tint, the counted items in green
/// and the possible misses as amber "+". Positions are in the anchor's space, so everything
/// moves with the anchor when ARKit refines it. `OverlayRenderer` turns this into RealityKit
/// entities.
public struct OverlayState: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var cls: ObjectClass
        public var local: SIMD3<Float>
    }

    public struct Miss: Sendable, Equatable, Identifiable {
        /// The store's id for this miss; it stays the same when a later commit sees it again.
        public var missID: UUID
        public var commitID: UUID
        public var detection: Int
        public var cls: ObjectClass
        public var score: Float
        public var box: SIMD4<Float>
        public var world: SIMD3<Float>
        public var local: SIMD3<Float>
        public var id: String { missID.uuidString }
    }

    public struct Commit: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var anchor: simd_float4x4      // world transform of the counted zone
        public var halfExtents: SIMD3<Float>
        public var items: [Item]
        public var misses: [Miss]
    }

    public private(set) var commits: [Commit] = []
    /// Drift alarm (FR-23): overlays fade until the user re-anchors.
    public var faded = false

    public init() {}

    public var itemCount: Int { commits.reduce(0) { $0 + $1.items.count } }
    public var possibleMisses: Int { commits.reduce(0) { $0 + $1.misses.count } }

    /// Adds a commit's overlays. `missIDs` are the store's ids of `result.possibleMisses`, in order
    /// (new ones get fresh ids).
    public mutating func add(_ result: CommitResult, detections: [Detection], missIDs: [UUID]? = nil) {
        let toLocal = result.zone.transform.inverse
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> { (toLocal * SIMD4(p, 1)).xyz }
        let items = result.newItems.map { Item(id: $0.id, cls: $0.cls, local: local($0.position)) }
        let misses = result.possibleMisses.enumerated().compactMap { k, i -> Miss? in
            guard i < detections.count, let p = detections[i].position else { return nil }
            let d = detections[i]
            let id = missIDs.flatMap { k < $0.count ? $0[k] : nil } ?? UUID()
            return Miss(missID: id, commitID: result.commitID, detection: i, cls: d.cls, score: d.score, box: d.box,
                        world: p, local: local(p))
        }
        commits.removeAll { $0.id == result.commitID }
        commits.append(Commit(id: result.commitID, anchor: result.zone.transform, halfExtents: result.zone.halfExtents,
                              items: items, misses: misses))
    }

    public mutating func remove(commit id: UUID) { commits.removeAll { $0.id == id } }

    /// ARKit moved the commit's anchor: local positions stay, the anchor moves (like the engine's
    /// `updateAnchor`).
    public mutating func move(commit id: UUID, to transform: simd_float4x4) {
        guard let i = commits.firstIndex(where: { $0.id == id }) else { return }
        commits[i].anchor = transform
        for m in commits[i].misses.indices {
            commits[i].misses[m].world = (transform * SIMD4(commits[i].misses[m].local, 1)).xyz
        }
    }

    /// Takes a miss off whichever commit shows it (it was seen again in a later one).
    public mutating func removeMiss(_ missID: UUID) {
        for c in commits.indices { commits[c].misses.removeAll { $0.missID == missID } }
    }

    public func miss(_ id: String) -> Miss? {
        for c in commits { if let m = c.misses.first(where: { $0.id == id }) { return m } }
        return nil
    }

    /// The user tapped "+": the miss becomes a counted item of its commit.
    public mutating func accept(miss id: String, as item: CountedItem) {
        guard let c = commits.firstIndex(where: { $0.misses.contains { $0.id == id } }),
              let m = commits[c].misses.firstIndex(where: { $0.id == id }) else { return }
        let miss = commits[c].misses.remove(at: m)
        commits[c].items.append(Item(id: item.id, cls: item.cls, local: miss.local))
    }
}
