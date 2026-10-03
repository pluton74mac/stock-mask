import Foundation
import simd

/// The commit engine: ADR 003's strategy S5 (counted zones + local drift refinement + 1:1 matching +
/// possible-miss prompts), a port of `refine_and_match` and `commit_s5` in
/// research/dedup_sim/sim.py, with PRD FR-14, FR-21–23 and FR-26.
///
/// Each commit:
/// 1. **Inner frame (FR-14).** Detections below the commit score (FR-18), cut by the image border,
///    or without a 3D position are set aside.
/// 2. **Bottles and tops.** A top that belongs to a bottle in the view is the same unit; a top with
///    no bottle under it counts as one bottle (`TopMergeRule`).
/// 3. **Local drift refinement.** The view's offset against nearby counted items, searched only
///    within ±4.5 cm along the shelf and vertically (half a bottle), voted on a 1 cm grid, and kept
///    only with support from at least 3 and 25% of the detections. Otherwise the last estimate
///    stands. Drift is fixed by tracking and anchors; matching only refines it (ADR 003).
/// 4. **1:1 matching (Hungarian)** to counted items of the same class family, with ADR 003's
///    anisotropic gate (4 cm along the shelf, 8 cm up, 10 cm in depth), preferring the same product.
/// 5. **Zones (FR-22).** An unmatched detection inside a counted zone is a possible miss, never
///    added. Outside counted zones, an unmatched detection whose centre is in the inner frame is a
///    new item; one in the edge band is left for the next view.
/// 6. **This view's zone (FR-21)**: the inner frame at the items' depth, shifted by the drift offset.
/// 7. **Drift alarm (FR-23)**: more than 30% of the detections over counted zones are unmatched.
///
/// One engine per spatial map (zone, FR-24): positions from different maps don't mix. It is a value
/// type; run it wherever the AR layer serialises commits.
public struct CommitEngine: Sendable {
    /// Every tunable number, with its source. Defaults are the app's; ADR 003 marks them "tune in
    /// Phase 0".
    public struct Parameters: Sendable, Equatable {
        /// FR-14 inner frame: band 0.15 of the short side, cut margin 0.005 of the long side
        /// (walkthrough.py `BAND`, `EDGE`).
        public var innerFrame = InnerFrame()
        /// FR-18: detections below this score are excluded from auto-count. walkthrough.py's counted
        /// threshold for RF-DETR; it is detector-specific (OWLv2 used 0.3).
        public var minimumScore: Float = 0.5
        /// ADR 003 / sim.py `METRIC`: weights along the shelf, up, and in depth.
        public var metricWeights = SIMD3<Double>(1.0, 0.5, 0.4)
        /// ADR 003 / sim.py `GATE`, metres in the weighted metric: half a bottle's width, so 4 cm along
        /// the shelf, 8 cm up and 10 cm in depth. The simulation used it for every class.
        public var matchGate = 0.04
        /// Per-class gates, overriding `matchGate` (a top uses the bottle's).
        public var matchGateByClass: [ObjectClass: Double] = [:]
        /// sim.py: a product mismatch adds this times the gate to a match's cost.
        public var productMismatchPenalty = 0.5
        /// sim.py `_support`: a hit whose product disagrees counts this much (agreeing counts 1).
        public var productMismatchSupport = 0.5
        /// ADR 003 / FR-22: the drift search radius along the shelf and vertically, metres (half a
        /// bottle). Depth is not limited, as in sim.py.
        public var driftSearch = 0.045
        /// sim.py: candidate offsets are rounded to this grid, metres.
        public var driftGrid = 0.01
        /// ADR 003: the refinement needs at least this many supporting detections ...
        public var driftMinimumSupport = 3.0
        /// ... and this share of the view's detections.
        public var driftMinimumSupportFraction = 0.25
        /// sim.py: offsets within this much support of the best are ties; the one nearest the last
        /// estimate wins.
        public var driftTieWindow = 1.0
        /// Metres added in front of and behind the counted items' depths to make the zone's depth.
        /// More than LiDAR noise and the drift the gate tolerates; less than the 9 cm between rows,
        /// so a row first seen from another angle is outside it and gets counted. The simulation's
        /// zones are flat and unbounded in depth.
        public var zoneDepthMargin = 0.05
        /// Metres: the zone's depth when no detection in the inner frame has a position and the view
        /// gives no `sceneDepth`.
        public var defaultZoneDepth = 1.0
        /// FR-23 / ADR 003: the alarm fires above this share of unmatched detections over zones.
        public var driftAlarmFraction = 0.30
        /// The alarm needs at least this many detections over counted zones (not in the PRD: one
        /// genuine miss among two detections is not drift).
        public var driftAlarmMinimumDetections = 3
        /// Bottles and tops.
        public var topMerge = TopMergeRule()
        /// World up (ARKit: +y, gravity-aligned).
        public var worldUp = SIMD3<Double>(0, 1, 0)

        public init() {}

        func gate(_ cls: ObjectClass) -> Double {
            matchGateByClass[cls == .bottleTop ? .bottle : cls] ?? matchGateByClass[cls] ?? matchGate
        }
    }

    /// What `undoLastCommit()` removed.
    public struct UndoneCommit: Sendable, Equatable {
        public var commitID: UUID
        public var removedItems: [UUID]
        public var removedZone: UUID
    }

    public var parameters: Parameters

    /// Every counted item, in the order counted.
    public var items: [CountedItem] { store.map(\.item) }
    /// Every counted zone, in commit order.
    public var zones: [CountedZone] { zoneStore.map(\.zone) }
    /// The current drift estimate, metres, world: added to every detection before matching.
    public var driftEstimate: SIMD3<Float> { SIMD3<Float>(prior) }
    /// The commit `undoLastCommit()` would undo.
    public var lastCommitID: UUID? { records.last?.id }

    private var store: [Stored] = []
    private var zoneStore: [StoredZone] = []
    private var records: [Record] = []
    private var prior = SIMD3<Double>.zero  // sim.py `Counted.prior`

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// Resume from saved items and zones (FR-7). Zones must be in commit order: `undoLastCommit()`
    /// removes the last one with its items. The drift estimate starts at zero.
    public init(parameters: Parameters = Parameters(), items: [CountedItem], zones: [CountedZone]) {
        self.parameters = parameters
        store = items.map(Stored.init(restoring:))
        for zone in zones {
            let box = Box3(zone)
            zoneStore.append(StoredZone(zone: zone, box: box))
            let anchor = Pose(rotation: box.rotation, translation: box.centre)
            records.append(Record(id: zone.commitID, zoneID: zone.id, anchorAtCommit: anchor, anchor: anchor,
                                  priorBefore: nil, frame: nil, detections: [], units: [], unitOf: [:],
                                  statuses: [], offset: .zero))
        }
    }

    // MARK: Commits

    /// Count one view: classify every detection, add the new items and the view's zone, and remember
    /// the commit for undo and for taps on its detections.
    @discardableResult
    public mutating func commit(_ detections: [Detection], view: CommitView, id: UUID = UUID()) -> CommitResult {
        let plan = evaluate(detections, view: view, commitID: id)
        for item in plan.newItems {
            let u = plan.units[plan.unitOf[item.detectionIndex!]!]
            store.append(Stored(item: item, body: u.body.map { $0 + plan.offset }, top: u.top.map { $0 + plan.offset }))
        }
        zoneStore.append(StoredZone(zone: plan.zone, box: plan.box))
        let anchor = Pose(rotation: plan.box.rotation, translation: plan.box.centre)
        records.append(Record(id: id, zoneID: plan.zone.id, anchorAtCommit: anchor, anchor: anchor,
                              priorBefore: prior, frame: plan.frame, detections: detections, units: plan.units,
                              unitOf: plan.unitOf, statuses: plan.statuses, offset: plan.offset))
        if plan.refined { prior = plan.offset }  // sim.py: cnt.prior = offset
        return plan.result
    }

    /// What `commit` would do, without changing anything: for live overlays (green on counted items,
    /// amber on possible misses) and for checking that the drift alarm has cleared. The new items'
    /// IDs are throwaway.
    public func preview(_ detections: [Detection], view: CommitView) -> CommitResult {
        evaluate(detections, view: view, commitID: UUID()).result
    }

    /// FR-16: undo the most recent commit that is still applied: its items (including possible misses
    /// added since), its zone, and its drift update. Call again to undo the one before.
    @discardableResult
    public mutating func undoLastCommit() -> UndoneCommit? {
        guard let record = records.popLast() else { return nil }
        let removed = store.filter { $0.item.commitID == record.id }.map(\.item.id)
        store.removeAll { $0.item.commitID == record.id }
        zoneStore.removeAll { $0.zone.id == record.zoneID }
        if let before = record.priorBefore { prior = before }
        return UndoneCommit(commitID: record.id, removedItems: removed, removedZone: record.zoneID)
    }

    /// FR-22 and FR-18: add one of a commit's detections when the user taps it: a possible miss, one
    /// left for the next view, a low-confidence one or a cut one. Returns the new item, or nil when
    /// the detection is already counted, part of a bottle, has no position, or the commit is gone.
    @discardableResult
    public mutating func addDetection(_ index: Int, ofCommit commitID: UUID) -> CountedItem? {
        guard let r = records.lastIndex(where: { $0.id == commitID }),
              records[r].statuses.indices.contains(index) else { return nil }
        let record = records[r]
        let unit: Unit
        switch record.statuses[index] {
        case .possibleMiss, .deferred:
            guard let u = record.unitOf[index] else { return nil }
            unit = record.units[u]
        case .lowConfidence, .cut:
            guard let frame = record.frame,
                  let u = TopMerge.single(record.detections[index], index: index, frame: frame) else { return nil }
            unit = u
        case .new, .matched, .mergedTop, .noPosition:
            return nil
        }
        let move = record.anchor.composed(with: record.anchorAtCommit.inverse)
        let body = unit.body.map { move.apply($0 + record.offset) }
        let top = unit.top.map { move.apply($0 + record.offset) }
        let item = CountedItem(cls: unit.cls, position: SIMD3<Float>(body ?? top!), commitID: commitID,
                               top: top.map(SIMD3<Float>.init), productKey: unit.productKey,
                               confidence: unit.score, detectionIndex: index)
        store.append(Stored(item: item, body: body, top: top))
        records[r].statuses[index] = .new(item: item.id)
        return item
    }

    /// FR-17 / FR-34: uncount items.
    public mutating func removeItems(_ ids: some Sequence<UUID>) {
        let ids = Set(ids)
        store.removeAll { ids.contains($0.item.id) }
    }

    /// The product of counted items, once confirmed (FR-28): later matches prefer the same product.
    public mutating func setProductKey(_ key: Int?, forItems ids: some Sequence<UUID>) {
        let ids = Set(ids)
        for i in store.indices where ids.contains(store[i].item.id) {
            store[i].item.productKey = key
        }
    }

    /// The AR layer's group of counted items (FR-27). The engine doesn't use it.
    public mutating func setGroupKey(_ key: Int?, forItems ids: some Sequence<UUID>) {
        let ids = Set(ids)
        for i in store.indices where ids.contains(store[i].item.id) {
            store[i].item.groupKey = key
        }
    }

    /// FR-21: a commit's items and zone are anchored to a per-commit anchor created with the zone's
    /// transform. When ARKit moves that anchor (map optimisation, relocalisation), pass its new
    /// transform: the commit's items and zone move with it, rigidly.
    public mutating func updateAnchor(ofCommit commitID: UUID, to transform: simd_float4x4) {
        guard let r = records.lastIndex(where: { $0.id == commitID }) else { return }
        let target = Pose(Geometry.rigid(transform))
        let move = target.composed(with: records[r].anchor.inverse)
        records[r].anchor = target
        for i in store.indices where store[i].item.commitID == commitID {
            store[i].body = store[i].body.map(move.apply)
            store[i].top = store[i].top.map(move.apply)
            store[i].syncItem()
        }
        for i in zoneStore.indices where zoneStore[i].zone.commitID == commitID {
            zoneStore[i].box.rotation = move.rotation * zoneStore[i].box.rotation
            zoneStore[i].box.centre = move.apply(zoneStore[i].box.centre)
            zoneStore[i].zone.transform = zoneStore[i].box.transform
        }
    }

    /// Forget the drift estimate: after relocalisation, a rack-tag re-anchor, or a jump in tracking.
    /// (sim.py resets it before the revisit pass: "the app does not know how far it has drifted".)
    public mutating func resetDriftEstimate() {
        prior = .zero
    }

    // MARK: S5

    private func evaluate(_ detections: [Detection], view: CommitView, commitID: UUID) -> Plan {
        let p = parameters
        let frame = ViewFrame(view, innerFrame: p.innerFrame, worldUp: p.worldUp)
        var statuses = [DetectionStatus](repeating: .noPosition, count: detections.count)
        var live: [Int] = []
        for (i, d) in detections.enumerated() {
            if d.score < p.minimumScore {
                statuses[i] = .lowConfidence
            } else if frame.isCut(d.box) {
                statuses[i] = .cut
            } else if let q = d.position, q.x.isFinite, q.y.isFinite, q.z.isFinite {
                live.append(i)
            }
        }
        let (units, merged) = TopMerge.units(detections, live: live, frame: frame, rule: p.topMerge)
        for pair in merged { statuses[pair.top] = .mergedTop(bottle: pair.bottle) }
        var unitOf: [Int: Int] = [:]
        for (k, u) in units.enumerated() { unitOf[u.index] = k }

        let (offset, refined) = refineDrift(units, frame: frame)
        let matches = match(units, offset: offset, frame: frame)

        var newItems: [CountedItem] = [], matched: [(detection: Int, item: UUID)] = [], misses: [Int] = []
        var over = 0, unmatchedOver = 0
        for (k, u) in units.enumerated() {
            let shifted = u.point + offset
            let done = zoneStore.contains { $0.box.contains(shifted) }  // sim.py: _inside(shifted, r)
            if done { over += 1 }
            if let j = matches[k] {
                statuses[u.index] = .matched(item: store[j].item.id)
                matched.append((u.index, store[j].item.id))
            } else if done {
                statuses[u.index] = .possibleMiss  // inside a counted zone, unexplained: never added
                misses.append(u.index)
                unmatchedOver += 1
            } else if frame.isInner(u.boxCentre) {  // sim.py: _inside(shifted, reg)
                let item = CountedItem(cls: u.cls, position: SIMD3<Float>(shifted), commitID: commitID,
                                       top: u.top.map { SIMD3<Float>($0 + offset) }, productKey: u.productKey,
                                       confidence: u.score, detectionIndex: u.index)
                statuses[u.index] = .new(item: item.id)
                newItems.append(item)
            } else {
                statuses[u.index] = .deferred
            }
        }

        // The zone: the inner frame at the depth of this view's detections in it, then moved by the
        // drift offset into the counted map's frame (sim.py: _zone(view, drift, offset)).
        let depths = units.filter { frame.isInner($0.boxCentre) }.map { frame.depth(of: $0.point) }.sorted()
        let reference: Double, near: Double, far: Double
        if depths.isEmpty {
            reference = view.sceneDepth.map(Double.init) ?? p.defaultZoneDepth
            (near, far) = (reference - p.zoneDepthMargin, reference + p.zoneDepthMargin)
        } else {
            let n = depths.count
            reference = n % 2 == 1 ? depths[n / 2] : (depths[n / 2 - 1] + depths[n / 2]) / 2
            (near, far) = (depths[0] - p.zoneDepthMargin, depths[n - 1] + p.zoneDepthMargin)
        }
        var box = frame.zone(reference: reference, near: near, far: far)
        box.centre += offset
        let zone = CountedZone(commitID: commitID, transform: box.transform, halfExtents: SIMD3<Float>(box.halfExtents))
        let alarm = over >= p.driftAlarmMinimumDetections && Double(unmatchedOver) > p.driftAlarmFraction * Double(over)

        let result = CommitResult(
            commitID: commitID, newItems: newItems, matched: matched, possibleMisses: misses, zone: zone,
            driftAlarm: alarm, statuses: statuses, mergedTops: merged, driftOffset: SIMD3<Float>(offset),
            driftRefined: refined, overCountedZones: over, unmatchedOverCountedZones: unmatchedOver)
        return Plan(result: result, frame: frame, units: units, unitOf: unitOf, offset: offset, refined: refined,
                    box: box)
    }

    /// sim.py `refine_and_match`, first half: the view's drift offset, searched locally.
    private func refineDrift(_ units: [Unit], frame: ViewFrame) -> (offset: SIMD3<Double>, refined: Bool) {
        let p = parameters
        let offset = prior
        guard store.count >= 3, units.count >= 3 else { return (offset, false) }
        // Counted items inside the detections' bounding box, widened by the search radius.
        let search = SIMD3<Double>(repeating: p.driftSearch)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for u in units {
            let m = frame.metric(u.point)
            lo = pointwiseMin(lo, m)
            hi = pointwiseMax(hi, m)
        }
        let o = frame.metric(offset)
        lo = lo + o - search
        hi = hi + o + search
        let near = store.indices.filter { j in
            let m = frame.metric(store[j].point)
            return m.x >= lo.x && m.y >= lo.y && m.z >= lo.z && m.x <= hi.x && m.y <= hi.y && m.z <= hi.z
        }
        guard near.count >= 3 else { return (offset, false) }

        // Candidate offsets: every detection onto every nearby counted item of its family, plus the
        // last estimate; only those within the search radius of it (along the shelf and up), on a grid.
        var candidates: [SIMD3<Double>] = []
        for u in units {
            for j in near where store[j].family == u.cls.family {
                if let (a, b) = Self.comparable(u, store[j]) { candidates.append(b - a) }
            }
        }
        candidates.append(offset)
        candidates = candidates.filter { c in
            let d = frame.metric(c - offset)
            return (d.x * d.x + d.y * d.y).squareRoot() <= p.driftSearch
        }
        candidates = Self.uniqueSorted(candidates.map { c in
            SIMD3((c.x / p.driftGrid).rounded(.toNearestOrEven) * p.driftGrid,
                  (c.y / p.driftGrid).rounded(.toNearestOrEven) * p.driftGrid,
                  (c.z / p.driftGrid).rounded(.toNearestOrEven) * p.driftGrid)
        })

        // Support (sim.py `_support`): per offset, the detections whose nearest counted item of their
        // family lies within the gate; 1 if the products agree, 0.5 if not.
        let w = p.metricWeights
        let scaled: [(body: SIMD3<Double>?, top: SIMD3<Double>?)] = near.map { j in
            (store[j].body.map { w * frame.metric($0) }, store[j].top.map { w * frame.metric($0) })
        }
        var support = [Double](repeating: 0, count: candidates.count)
        for (ci, c) in candidates.enumerated() {
            var total = 0.0
            for u in units {
                let gate = p.gate(u.cls)
                let body = u.body.map { w * frame.metric($0 + c) }
                let top = u.top.map { w * frame.metric($0 + c) }
                var best = Double.infinity, bestJ = -1
                for (n, j) in near.enumerated() where store[j].family == u.cls.family {
                    let pair: (SIMD3<Double>, SIMD3<Double>)
                    if let a = body, let b = scaled[n].body { pair = (a, b) }
                    else if let a = top, let b = scaled[n].top { pair = (a, b) }
                    else { continue }
                    let dx = pair.0.x - pair.1.x, dy = pair.0.y - pair.1.y, dz = pair.0.z - pair.1.z
                    let d2 = dx * dx + dy * dy + dz * dz
                    if d2 < best {
                        best = d2
                        bestJ = j
                    }
                }
                if bestJ >= 0 && best < gate * gate {  // cKDTree's bound is strict
                    total += Self.agree(u, store[bestJ]) ? 1.0 : p.productMismatchSupport
                }
            }
            support[ci] = total
        }
        guard let best = support.max(),
              best >= max(p.driftMinimumSupport, p.driftMinimumSupportFraction * Double(units.count)) else {
            return (offset, false)
        }
        // Near-ties: keep the one closest to the last estimate (the first, in sorted order).
        var chosen = offset, nearest = Double.infinity
        for (ci, c) in candidates.enumerated() where support[ci] >= best - p.driftTieWindow {
            let d = c - prior
            let n = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            if n < nearest {
                nearest = n
                chosen = c
            }
        }
        return (chosen, true)
    }

    /// sim.py `refine_and_match`, second half: 1:1 assignment of the shifted detections to counted
    /// items, per class family. Returns unit index → store index.
    private func match(_ units: [Unit], offset: SIMD3<Double>, frame: ViewFrame) -> [Int: Int] {
        let p = parameters
        let w = p.metricWeights
        let forbidden = 1e3
        var matches: [Int: Int] = [:]
        for family in Family.allCases {
            let rows = units.indices.filter { units[$0].cls.family == family }
            let cols = store.indices.filter { store[$0].family == family }
            guard !rows.isEmpty, !cols.isEmpty else { continue }
            // Pairs within the gate: the only ones the assignment can use (others cost 1e3).
            var pairs: [(r: Int, k: Int, dist: Double, cost: Double)] = []
            for (r, ui) in rows.enumerated() {
                let u = units[ui]
                let gate = p.gate(u.cls)
                let body = u.body.map { $0 + offset }, top = u.top.map { $0 + offset }  // sim.py: shifted
                for (k, j) in cols.enumerated() {
                    let s = store[j]
                    let pair: (SIMD3<Double>, SIMD3<Double>)
                    if let a = body, let b = s.body { pair = (a, b) }
                    else if let a = top, let b = s.top { pair = (a, b) }
                    else { continue }
                    let e = w * frame.metric(pair.0 - pair.1)
                    let dist = (e.x * e.x + e.y * e.y + e.z * e.z).squareRoot()
                    guard dist <= gate else { continue }
                    let mismatch = Self.mismatch(u, s) ? 1.0 : 0.0
                    pairs.append((r, k, dist, dist + p.productMismatchPenalty * gate * mismatch))
                }
            }
            guard !pairs.isEmpty else { continue }
            // Rows and columns with no pair within the gate can't be matched: leave them out.
            let usedRows = Array(Set(pairs.map(\.r))).sorted(), usedCols = Array(Set(pairs.map(\.k))).sorted()
            let rowAt = Dictionary(uniqueKeysWithValues: usedRows.enumerated().map { ($1, $0) })
            let colAt = Dictionary(uniqueKeysWithValues: usedCols.enumerated().map { ($1, $0) })
            var cost = Array(repeating: Array(repeating: forbidden, count: usedCols.count), count: usedRows.count)
            for q in pairs { cost[rowAt[q.r]!][colAt[q.k]!] = q.cost }
            for (r, k) in Hungarian.assign(cost).enumerated() {
                if let k, cost[r][k] < forbidden { matches[rows[usedRows[r]]] = cols[usedCols[k]] }
            }
        }
        return matches
    }

    /// The two points to compare: centres when both have one, else tops (a top seen alone against a
    /// bottle counted whole, or the other way round).
    static func comparable(_ u: Unit, _ s: Stored) -> (SIMD3<Double>, SIMD3<Double>)? {
        if let a = u.body, let b = s.body { return (a, b) }
        if let a = u.top, let b = s.top { return (a, b) }
        return nil
    }

    static func agree(_ u: Unit, _ s: Stored) -> Bool {
        !mismatch(u, s)
    }

    static func mismatch(_ u: Unit, _ s: Stored) -> Bool {
        if let a = u.productKey, let b = s.item.productKey { return a != b }
        return false
    }

    /// numpy's `np.unique(axis=0)`: sorted rows, duplicates removed.
    static func uniqueSorted(_ v: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let sorted = v.sorted { a, b in
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.z < b.z
        }
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(sorted.count)
        for c in sorted where out.last.map({ $0 != c }) ?? true {
            out.append(c)
        }
        return out
    }
}

// MARK: - Storage

enum Family: CaseIterable, Sendable {
    case bottle, can, `case`, carton, bag
}

extension ObjectClass {
    var family: Family {
        switch self {
        case .bottle, .bottleTop: .bottle
        case .can: .can
        case .case: .case
        case .carton: .carton
        case .bag: .bag
        }
    }
}

/// A counted item and its Double-precision points, which the engine computes with.
struct Stored: Sendable {
    var item: CountedItem
    var body: SIMD3<Double>?
    var top: SIMD3<Double>?

    init(item: CountedItem, body: SIMD3<Double>?, top: SIMD3<Double>?) {
        self.item = item
        self.body = body
        self.top = top
    }

    init(restoring item: CountedItem) {
        let p = SIMD3<Double>(item.position)
        self.item = item
        body = item.cls == .bottleTop ? nil : p
        top = item.top.map(SIMD3<Double>.init) ?? (item.cls == .bottleTop ? p : nil)
    }

    var family: Family { item.cls.family }
    var point: SIMD3<Double> { body ?? top! }

    mutating func syncItem() {
        item.position = SIMD3<Float>(point)
        item.top = top.map(SIMD3<Float>.init)
    }
}

struct StoredZone: Sendable {
    var zone: CountedZone
    var box: Box3
}

extension Box3 {
    init(_ zone: CountedZone) {
        let pose = Geometry.rigid(zone.transform)
        self.init(rotation: pose.rotation, centre: pose.translation, halfExtents: SIMD3<Double>(zone.halfExtents))
    }
}

/// A rigid transform.
struct Pose: Sendable {
    var rotation: simd_double3x3
    var translation: SIMD3<Double>

    init(rotation: simd_double3x3, translation: SIMD3<Double>) {
        self.rotation = rotation
        self.translation = translation
    }

    init(_ rigid: (rotation: simd_double3x3, translation: SIMD3<Double>)) {
        self.init(rotation: rigid.rotation, translation: rigid.translation)
    }

    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { Geometry.times(rotation, p) + translation }

    var inverse: Pose {
        let r = rotation.transpose
        return Pose(rotation: r, translation: -Geometry.times(r, translation))
    }

    /// self ∘ other: apply `other`, then `self`.
    func composed(with other: Pose) -> Pose {
        Pose(rotation: rotation * other.rotation, translation: apply(other.translation))
    }
}

/// A commit, remembered for undo, anchor updates and taps on its detections.
struct Record: Sendable {
    let id: UUID
    let zoneID: UUID
    let anchorAtCommit: Pose
    var anchor: Pose
    let priorBefore: SIMD3<Double>?  // nil for commits restored from storage
    let frame: ViewFrame?
    let detections: [Detection]
    let units: [Unit]
    let unitOf: [Int: Int]
    var statuses: [DetectionStatus]
    let offset: SIMD3<Double>
}

/// What a commit would do.
struct Plan {
    var result: CommitResult
    var frame: ViewFrame
    var units: [Unit]
    var unitOf: [Int: Int]
    var offset: SIMD3<Double>
    var refined: Bool
    var box: Box3

    var newItems: [CountedItem] { result.newItems }
    var zone: CountedZone { result.zone }
    var statuses: [DetectionStatus] { result.statuses }
}
