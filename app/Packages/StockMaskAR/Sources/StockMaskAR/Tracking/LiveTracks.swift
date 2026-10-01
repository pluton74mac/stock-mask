import Foundation
import StockMaskCounting
import simd

/// One object followed across detector frames.
public struct LiveTrack: Sendable, Identifiable, Equatable {
    public let id: Int
    public var cls: ObjectClass
    public var label: String
    public var box: SIMD4<Float>            // latest box, upright image, normalised
    public var score: Float                 // latest score
    public var position: SIMD3<Float>?      // fused world position (running mean of the lifts)
    public var size: SIMD2<Float>?
    public var plausible: Bool
    public var hitTimes: [TimeInterval]     // recent detector frames that saw it
    public var lastSeen: TimeInterval
    var positionHits = 0

    public func hits(within window: Double, at now: TimeInterval) -> Int {
        hitTimes.reduce(0) { $0 + ($1 >= now - window - 1e-6 ? 1 : 0) }
    }

    /// The contract's `Detection` for this track: latest box and score, fused position.
    public var detection: Detection { Detection(cls: cls, score: score, box: box, position: position, size: size) }
}

/// Live tracks (PRD §11): detections associated across frames in 3D, using ARKit's world
/// positions, because the objects stand still and the camera moves (ADR 002). A track with at least
/// `stableHits` hits in the last `stableWindow` seconds is a stable candidate (ADR 003: 3 in 0.5 s).
///
/// Association is greedy nearest-first, one to one, within `gate` metres and the same class.
/// Detections the Lifter could not place (no depth) are associated in 2D by IoU instead.
public struct LiveTracks: Sendable {
    public struct Observation: Sendable, Equatable {
        public var cls: ObjectClass
        public var label: String
        public var score: Float
        public var box: SIMD4<Float>
        public var position: SIMD3<Float>?
        public var size: SIMD2<Float>?
        public var plausible: Bool

        public init(cls: ObjectClass, label: String? = nil, score: Float, box: SIMD4<Float>,
                    position: SIMD3<Float>? = nil, size: SIMD2<Float>? = nil, plausible: Bool = true) {
            self.cls = cls; self.label = label ?? cls.rawValue; self.score = score; self.box = box
            self.position = position; self.size = size; self.plausible = plausible
        }
    }

    public var gate: Float = 0.05             // metres; bottles stand about 9 cm apart
    public var iouGate: Float = 0.3
    public var maxAge: Double = 1.0           // seconds unseen before a track is dropped
    public var stableHits = 3
    public var stableWindow: Double = 0.5
    public var minFusionWeight: Float = 0.2   // a running mean that never stops listening entirely
    public private(set) var tracks: [LiveTrack] = []
    private var nextID = 1

    public init() {}

    /// Associates one detector frame's observations. Returns the track ID of each observation.
    @discardableResult
    public mutating func update(_ observations: [Observation], at time: TimeInterval) -> [Int] {
        tracks.removeAll { $0.lastSeen < time - maxAge }
        var assigned = [Int?](repeating: nil, count: observations.count)
        var used = Set<Int>()   // track indices

        // 1. In 3D, closest pairs first.
        var pairs: [(cost: Float, obs: Int, track: Int)] = []
        for (o, ob) in observations.enumerated() {
            guard let p = ob.position else { continue }
            for (t, tr) in tracks.enumerated() where tr.cls == ob.cls {
                guard let q = tr.position else { continue }
                let d = simd_distance(p, q)
                if d <= gate { pairs.append((d, o, t)) }
            }
        }
        for pair in pairs.sorted(by: { $0.cost < $1.cost }) where assigned[pair.obs] == nil && !used.contains(pair.track) {
            assigned[pair.obs] = pair.track
            used.insert(pair.track)
        }
        // 2. In 2D for what has no depth on either side, best overlap first.
        var flat: [(iou: Float, obs: Int, track: Int)] = []
        for (o, ob) in observations.enumerated() where assigned[o] == nil {
            for (t, tr) in tracks.enumerated() where !used.contains(t) && tr.cls == ob.cls
                && (ob.position == nil || tr.position == nil) {
                let v = Self.iou(ob.box, tr.box)
                if v >= iouGate { flat.append((v, o, t)) }
            }
        }
        for pair in flat.sorted(by: { $0.iou > $1.iou }) where assigned[pair.obs] == nil && !used.contains(pair.track) {
            assigned[pair.obs] = pair.track
            used.insert(pair.track)
        }

        var ids: [Int] = []
        for (o, ob) in observations.enumerated() {
            if let t = assigned[o] {
                var tr = tracks[t]
                tr.box = ob.box
                tr.score = ob.score
                tr.label = ob.label
                tr.size = ob.size ?? tr.size
                tr.plausible = ob.plausible
                if let p = ob.position {
                    tr.positionHits += 1
                    let w = max(minFusionWeight, 1 / Float(tr.positionHits))
                    tr.position = tr.position.map { $0 + w * (p - $0) } ?? p
                }
                tr.hitTimes = tr.hitTimes.filter { $0 >= time - stableWindow * 2 } + [time]
                tr.lastSeen = time
                tracks[t] = tr
                ids.append(tr.id)
            } else {
                let tr = LiveTrack(id: nextID, cls: ob.cls, label: ob.label, box: ob.box, score: ob.score,
                                   position: ob.position, size: ob.size, plausible: ob.plausible, hitTimes: [time],
                                   lastSeen: time, positionHits: ob.position == nil ? 0 : 1)
                nextID += 1
                tracks.append(tr)
                ids.append(tr.id)
            }
        }
        return ids
    }

    public func isStable(_ track: LiveTrack, at now: TimeInterval) -> Bool {
        track.plausible && track.hits(within: stableWindow, at: now) >= stableHits
    }

    /// Stable candidates: what a commit counts, and what the hold trigger waits for.
    public func stable(at now: TimeInterval) -> [LiveTrack] { tracks.filter { isStable($0, at: now) } }

    public mutating func removeAll() { tracks.removeAll() }

    static func iou(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let w = max(0, min(a.z, b.z) - max(a.x, b.x)), h = max(0, min(a.w, b.w) - max(a.y, b.y))
        let inter = w * h
        let union = (a.z - a.x) * (a.w - a.y) + (b.z - b.x) * (b.w - b.y) - inter
        return union > 0 ? inter / union : 0
    }
}
