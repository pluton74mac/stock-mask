import simd

/// Bottles and tops (product decision of 2 October 2026: no ×N deep multiplier, the camera counts
/// the rows behind a front row by their tops).
///
/// Within one view:
/// - a `bottle_top` that belongs to a bottle detected in the same view is the same unit as that
///   bottle;
/// - a `bottle_top` with no bottle under it is a bottle in a row behind, and counts as one.
///
/// A top belongs to a bottle when all of these hold:
/// 1. **Position**: its box centre is in the bottle's cap window (horizontally within the bottle's
///    box, vertically from `capWindowAbove` above the box's top edge to `capWindowBelow` below it,
///    as fractions of the box height, with "up" taken from gravity), **or** it lies within
///    `mergeRadius` of the bottle's 3D top (the bottle's position raised by half its height; needs
///    the detection's `size`).
/// 2. **Same row**: it is within `sameRowRadius` of the bottle horizontally. A top one row behind is
///    a bottle pitch, about 9 cm, further back, so this keeps a back row's top that shows just above
///    a front bottle from being absorbed by it.
/// 3. **One top per bottle**: tops and bottles are paired one to one (Hungarian), each bottle with
///    the top nearest its cap.
///
/// Only bottles that can be counted in this view take part: whole, above the commit score, with a
/// position. The top of a bottle cut by the image border, or below the score, counts on its own, at
/// the top. When a later view sees that bottle whole, the engine matches the two by their tops.
public struct TopMergeRule: Sendable, Equatable {
    /// Cap window above the bottle box's top edge, as a fraction of the box height: box jitter.
    public var capWindowAbove: Double = 0.10
    /// Cap window below the bottle box's top edge, as a fraction of the box height: cap and neck.
    public var capWindowBelow: Double = 0.25
    /// Metres: a top this close to a bottle's 3D top is its top, wherever the boxes are.
    public var mergeRadius: Double = 0.05
    /// Metres, horizontal: a top further than this from the bottle is in another row.
    public var sameRowRadius: Double = 0.07

    public init(capWindowAbove: Double = 0.10, capWindowBelow: Double = 0.25, mergeRadius: Double = 0.05,
                sameRowRadius: Double = 0.07) {
        self.capWindowAbove = capWindowAbove
        self.capWindowBelow = capWindowBelow
        self.mergeRadius = mergeRadius
        self.sameRowRadius = sameRowRadius
    }
}

/// One countable unit of a view: a bottle, can or case, a bottle with its top, or a top alone.
struct Unit: Sendable {
    var index: Int  // detection index: the bottle's for a merged pair
    var cls: ObjectClass  // `.bottleTop` for a top counted alone
    var body: SIMD3<Double>?  // the centre of a bottle, can or case
    var top: SIMD3<Double>?  // the bottle's top: detected with it, alone, or estimated from its size
    var boxCentre: SIMD2<Double>
    var productKey: Int?
    var score: Float
    var mergedTop: Int?

    /// The point that stands for the unit in zones and the inner frame: its centre, else its top.
    var point: SIMD3<Double> { body ?? top! }
}

enum TopMerge {
    /// The units of a view's live detections, in detection order, and the merged pairs.
    static func units(_ detections: [Detection], live: [Int], frame: ViewFrame,
                      rule: TopMergeRule) -> (units: [Unit], merged: [(top: Int, bottle: Int)]) {
        func pos(_ i: Int) -> SIMD3<Double> { SIMD3<Double>(detections[i].position!) }
        func estimatedTop(_ i: Int) -> SIMD3<Double>? {
            guard let size = detections[i].size else { return nil }
            return pos(i) + frame.worldUp * (frame.verticalExtent(of: size) / 2)
        }
        let bottles = live.filter { detections[$0].cls == .bottle }
        let tops = live.filter { detections[$0].cls == .bottleTop }
        var topOf: [Int: Int] = [:]  // bottle -> top
        if !bottles.isEmpty && !tops.isEmpty {
            let forbidden = 1e3
            var cost = Array(repeating: Array(repeating: forbidden, count: bottles.count), count: tops.count)
            for (r, t) in tops.enumerated() {
                let c = frame.upright(InnerFrame.centre(of: detections[t].box))
                for (k, b) in bottles.enumerated() {
                    let box = frame.upright(box: detections[b].box)
                    let w = box.z - box.x, h = box.w - box.y
                    let inWindow = c.x >= box.x && c.x <= box.z
                        && c.y >= box.y - rule.capWindowAbove * h && c.y <= box.y + rule.capWindowBelow * h
                    let near3D = estimatedTop(b).map { Geometry.length(pos(t) - $0) <= rule.mergeRadius } ?? false
                    let d = frame.metric(pos(t) - pos(b))
                    let sameRow = (d.x * d.x + d.z * d.z).squareRoot() <= rule.sameRowRadius
                    if (inWindow || near3D) && sameRow {
                        let cap = SIMD2((box.x + box.z) / 2, box.y)
                        cost[r][k] = ((c.x - cap.x) * (c.x - cap.x) + (c.y - cap.y) * (c.y - cap.y)).squareRoot()
                            / max(w, .leastNonzeroMagnitude)
                    }
                }
            }
            for (r, k) in Hungarian.assign(cost).enumerated() {
                if let k, cost[r][k] < forbidden { topOf[bottles[k]] = tops[r] }
            }
        }
        let mergedTops = Set(topOf.values)
        var units: [Unit] = []
        for i in live where !mergedTops.contains(i) {
            let d = detections[i]
            var unit = Unit(index: i, cls: d.cls, body: pos(i), top: nil, boxCentre: InnerFrame.centre(of: d.box),
                            productKey: d.productKey, score: d.score, mergedTop: nil)
            switch d.cls {
            case .bottle:
                if let t = topOf[i] {
                    unit.top = pos(t)
                    unit.mergedTop = t
                    unit.productKey = d.productKey ?? detections[t].productKey
                } else {
                    unit.top = estimatedTop(i)
                }
            case .bottleTop:
                unit.body = nil
                unit.top = pos(i)
            case .can, .case, .carton, .bag:
                break
            }
            units.append(unit)
        }
        let merged = topOf.map { (top: $0.value, bottle: $0.key) }.sorted { $0.top < $1.top }
        return (units, merged)
    }

    /// A unit for one detection on its own (a tap on a low-confidence or cut detection).
    static func single(_ d: Detection, index: Int, frame: ViewFrame) -> Unit? {
        guard let q = d.position, q.x.isFinite, q.y.isFinite, q.z.isFinite else { return nil }
        let p = SIMD3<Double>(q)
        var unit = Unit(index: index, cls: d.cls, body: p, top: nil, boxCentre: InnerFrame.centre(of: d.box),
                        productKey: d.productKey, score: d.score, mergedTop: nil)
        if d.cls == .bottleTop {
            unit.body = nil
            unit.top = p
        } else if d.cls == .bottle, let size = d.size {
            unit.top = p + frame.worldUp * (frame.verticalExtent(of: size) / 2)
        }
        return unit
    }
}
