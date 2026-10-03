import Foundation
import StockMaskCounting
import simd

/// The owner's decision of 2 October: **rows behind take the front bottle's product.** An item
/// standing behind another in the same row (at the same place along the shelf, within about half
/// a bottle width, but deeper) joins the group of the item in front, so naming the front bottle
/// names the whole row. It matters most for `bottle_top` items, the rows behind seen only by their
/// tops, which look nothing like a whole bottle.
///
/// Geometry, in world space (+y up): "depth" is the view direction flattened to the horizontal,
/// "along" is horizontal and square to it. Positions are the engine's: a bottle's centre, or the
/// top for a `bottle_top`, so a back item may sit higher than the front one's centre.
public struct RowGrouper: Sendable {
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var cls: ObjectClass
        public var position: SIMD3<Float>

        public init(id: UUID, cls: ObjectClass, position: SIMD3<Float>) {
            self.id = id
            self.cls = cls
            self.position = position
        }
    }

    /// Half a bottle width: how far along the shelf a back item may be from the one in front.
    public var alongTolerance: Float = 0.045
    /// At least this much deeper (less is the same row, seen twice) ...
    public var minDepthGap: Float = 0.03
    /// ... and at most this much (a deep shelf).
    public var maxDepthGap: Float = 0.6
    /// The back item's height against the front one's: a top over a centre is up to ~0.2 m higher;
    /// much higher is the shelf above.
    public var maxBelow: Float = 0.12
    public var maxAbove: Float = 0.25

    public init() {}

    /// For each of `items` that has one: the item directly in front of it in the same row (the
    /// nearest such item), as an id. `forward` is the view direction in world space.
    public func fronts(of items: [Item], among candidates: [Item], forward: SIMD3<Float>) -> [UUID: UUID] {
        let flat = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(flat) > 1e-4 else { return [:] }   // looking straight down: no rows to tell
        let depthAxis = simd_normalize(flat)
        let along = simd_normalize(simd_cross(depthAxis, SIMD3(0, 1, 0)))
        var result: [UUID: UUID] = [:]
        for n in items {
            var best: (gap: Float, id: UUID)?
            for f in candidates where f.id != n.id && Self.sameFamily(f.cls, n.cls) {
                let d = n.position - f.position
                let gap = simd_dot(d, depthAxis)
                guard gap >= minDepthGap, gap <= maxDepthGap, abs(simd_dot(d, along)) <= alongTolerance,
                      d.y >= -maxBelow, d.y <= maxAbove else { continue }
                if gap < (best?.gap ?? .infinity) { best = (gap, f.id) }
            }
            if let best { result[n.id] = best.id }
        }
        return result
    }

    /// Follows "in front of" to the front of the row.
    public static func frontOfRow(_ id: UUID, fronts: [UUID: UUID]) -> UUID {
        var current = id
        var seen: Set<UUID> = [id]
        while let next = fronts[current], seen.insert(next).inserted { current = next }
        return current
    }

    /// A top stands for a bottle; other classes only row up with their own kind.
    static func sameFamily(_ a: ObjectClass, _ b: ObjectClass) -> Bool {
        func family(_ c: ObjectClass) -> ObjectClass { c == .bottleTop ? .bottle : c }
        return family(a) == family(b)
    }
}
