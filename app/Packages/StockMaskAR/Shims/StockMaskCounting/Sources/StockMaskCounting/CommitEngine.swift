// SHIM: remove at integration (see ../../Package.swift).
// A deliberately small version of ADR 003's strategy S5 so the app runs end to end before the real
// engine (claude/app-counting) is merged. It has no local drift refinement and matches greedily
// rather than with the Hungarian method.
import Foundation
import simd

/// What the engine needs to know about the view a commit was taken from.
/// All of it is in the upright image the user sees (see StockMaskAR's README, "Coordinates").
public struct ViewGeometry: Sendable {
    public var cameraTransform: simd_float4x4   // camera to world; the camera looks along -z, +y is image up
    public var intrinsics: simd_float3x3        // pinhole, pixels; ARKit layout (columns): fx, fy, then cx, cy
    public var imageSize: SIMD2<Float>          // pixels
    public var innerFrame: SIMD4<Float>         // normalised x0, y0, x1, y1

    public init(cameraTransform: simd_float4x4, intrinsics: simd_float3x3, imageSize: SIMD2<Float>,
                innerFrame: SIMD4<Float>) {
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.imageSize = imageSize
        self.innerFrame = innerFrame
    }
}

public struct CommitEngine: Sendable {
    public var commitScore: Float = 0.5
    public var gate = SIMD3<Float>(0.04, 0.08, 0.10)  // along the shelf, vertical, depth (ADR 003)
    public var zoneHalfDepth: Float = 0.2
    public var driftAlarmShare: Float = 0.3
    public var driftAlarmMinimum = 4

    public private(set) var items: [CountedItem] = []
    public private(set) var zones: [CountedZone] = []
    private var history: [UUID] = []

    public init() {}

    public mutating func commit(_ detections: [Detection], view: ViewGeometry) -> CommitResult {
        let commitID = UUID()
        let eligible = detections.indices.filter { i in
            let d = detections[i]
            return d.score >= commitScore && d.position != nil && Self.inside(d.box, view.innerFrame)
        }
        // Bottles and tops: a top inside a bottle's box in the same view is that bottle. A top with
        // no bottle under it (a row behind) counts as one unit on its own.
        let units = eligible.filter { i in
            guard detections[i].cls == .bottleTop else { return true }
            let c = Self.centre(detections[i].box)
            return !eligible.contains { j in detections[j].cls == .bottle && Self.contains(detections[j].box, c) }
        }

        var matched: [(detection: Int, item: UUID)] = []
        var fresh: [Int] = []
        var inZoneCount = 0
        var taken = Set<UUID>()
        // Greedy 1:1 matching inside counted zones, closest pairs first.
        var candidates: [(cost: Float, det: Int, item: UUID)] = []
        var inZone = Set<Int>()
        for i in units {
            let p = detections[i].position!
            guard let zone = zones.first(where: { Self.zoneContains($0, p) }) else { fresh.append(i); continue }
            inZone.insert(i)
            inZoneCount += 1
            let toZone = zone.transform.inverse
            for item in items where Self.sameUnit(item.cls, detections[i].cls) {
                let d = abs(Self.apply(toZone, p) - Self.apply(toZone, item.position)) / gate
                if d.max() <= 1 { candidates.append((simd_length(d), i, item.id)) }
            }
        }
        var done = Set<Int>()
        for c in candidates.sorted(by: { $0.cost < $1.cost }) where !done.contains(c.det) && !taken.contains(c.item) {
            matched.append((c.det, c.item))
            done.insert(c.det)
            taken.insert(c.item)
        }
        let misses = inZone.filter { !done.contains($0) }.sorted()

        let zone = Self.zone(for: units.compactMap { detections[$0].position }, view: view, commitID: commitID,
                             halfDepth: zoneHalfDepth)
        let alarm = inZoneCount >= driftAlarmMinimum && Float(misses.count) / Float(inZoneCount) > driftAlarmShare
        if alarm {  // the map looks off: count nothing until the user re-anchors
            return CommitResult(commitID: commitID, newItems: [], matched: matched, possibleMisses: misses,
                                zone: zone, driftAlarm: true)
        }
        let newItems = fresh.map { CountedItem(cls: detections[$0].cls, position: detections[$0].position!, commitID: commitID) }
        items += newItems
        zones.append(zone)
        history.append(commitID)
        return CommitResult(commitID: commitID, newItems: newItems, matched: matched, possibleMisses: misses,
                            zone: zone, driftAlarm: false)
    }

    /// Undo the last commit: its items and its zone. Returns its ID.
    @discardableResult
    public mutating func undoLastCommit() -> UUID? {
        guard let last = history.popLast() else { return nil }
        items.removeAll { $0.commitID == last }
        zones.removeAll { $0.commitID == last }
        return last
    }

    /// The user tapped a possible miss: count it in that commit.
    public mutating func addPossibleMiss(_ detection: Detection, commitID: UUID) -> CountedItem? {
        guard let p = detection.position, history.contains(commitID) else { return nil }
        let item = CountedItem(cls: detection.cls, position: p, commitID: commitID)
        items.append(item)
        return item
    }

    // MARK: geometry

    static func inside(_ b: SIMD4<Float>, _ f: SIMD4<Float>) -> Bool {
        b.x >= f.x && b.y >= f.y && b.z <= f.z && b.w <= f.w
    }
    static func centre(_ b: SIMD4<Float>) -> SIMD2<Float> { SIMD2((b.x + b.z) / 2, (b.y + b.w) / 2) }
    static func contains(_ b: SIMD4<Float>, _ p: SIMD2<Float>) -> Bool { p.x >= b.x && p.x <= b.z && p.y >= b.y && p.y <= b.w }
    static func sameUnit(_ a: ObjectClass, _ b: ObjectClass) -> Bool {
        a == b || Set([a, b]) == [.bottle, .bottleTop]
    }
    static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    static func zoneContains(_ z: CountedZone, _ p: SIMD3<Float>) -> Bool {
        let local = apply(z.transform.inverse, p)
        return all(abs(local) .<= z.halfExtents)
    }

    /// The counted zone: the inner frame projected at the items' median depth, as an oriented box
    /// aligned with the camera.
    static func zone(for points: [SIMD3<Float>], view: ViewGeometry, commitID: UUID, halfDepth: Float) -> CountedZone {
        let toCamera = view.cameraTransform.inverse
        let depths = points.map { -apply(toCamera, $0).z }.filter { $0 > 0 }.sorted()
        let depth = depths.isEmpty ? 1 : depths[depths.count / 2]
        let k = view.intrinsics
        let f = view.innerFrame
        let px0 = f.x * view.imageSize.x, px1 = f.z * view.imageSize.x
        let py0 = f.y * view.imageSize.y, py1 = f.w * view.imageSize.y
        let x0 = (px0 - k[2][0]) / k[0][0] * depth, x1 = (px1 - k[2][0]) / k[0][0] * depth
        let y0 = -(py0 - k[2][1]) / k[1][1] * depth, y1 = -(py1 - k[2][1]) / k[1][1] * depth
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4((x0 + x1) / 2, (y0 + y1) / 2, -depth, 1)
        return CountedZone(commitID: commitID, transform: view.cameraTransform * local,
                           halfExtents: SIMD3(abs(x1 - x0) / 2, abs(y1 - y0) / 2, halfDepth))
    }
}
