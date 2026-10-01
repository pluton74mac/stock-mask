import Foundation
import simd
import Testing
import StockMaskCounting

@Suite("Commit engine (ADR 003 S5)")
struct CommitEngineTests {
    /// 1 m from a shelf at z = 0, looking straight at it: the inner frame spans about ±0.45 m across
    /// and 0.70–1.30 m up.
    let camera = TestCamera(at: [0, 1.0, 1.0])
    /// Five bottles, irregularly spaced so that no drift lines one up with its neighbour.
    let bottles = [SIMD3<Float>(-0.24, 1.0, 0), [-0.12, 1.0, 0], [0, 1.0, 0], [0.13, 1.0, 0], [0.25, 1.0, 0]]

    func detections(_ points: [SIMD3<Float>], shift: SIMD3<Float> = .zero, product: Int? = nil) -> [Detection] {
        points.map { camera.detect(.bottle, at: $0, product: product, position: $0 + shift) }
    }

    @Test("A first commit counts whole objects centred in the inner frame, and nothing else")
    func firstCommit() {
        var engine = CommitEngine()
        var d = detections(bottles)
        d.append(camera.detect(.bottle, at: [0.50, 1.0, 0]))  // centre in the edge band
        d.append(camera.detect(.bottle, at: [0.56, 1.0, 0]))  // cut by the image border
        d.append(camera.detect(.bottle, at: [-0.36, 1.0, 0], score: 0.3))  // below the commit score
        var noDepth = camera.detect(.bottle, at: [0.36, 1.0, 0])
        noDepth.position = nil
        d.append(noDepth)
        let r = engine.commit(d, view: camera.view)
        #expect(r.newItems.count == 5)
        #expect(r.newItems.map(\.detectionIndex) == [0, 1, 2, 3, 4])
        #expect(r.statuses[5] == .deferred)
        #expect(r.statuses[6] == .cut)
        #expect(r.statuses[7] == .lowConfidence)
        #expect(r.statuses[8] == .noPosition)
        #expect(r.matched.isEmpty && r.possibleMisses.isEmpty && !r.driftAlarm)
        #expect(engine.items.count == 5 && engine.zones.count == 1)
        #expect(engine.items.allSatisfy { $0.commitID == r.commitID && $0.cls == .bottle })
    }

    @Test("The zone is the inner frame at the items' depth, an oriented box in world space")
    func zoneGeometry() {
        var engine = CommitEngine()
        let r = engine.commit(detections(bottles), view: camera.view)
        let zone = r.zone
        #expect(zone.commitID == r.commitID)
        // Centre on the shelf, straight ahead; axes are the camera's.
        #expect(simd_distance(SIMD3(zone.transform.columns.3.x, zone.transform.columns.3.y, zone.transform.columns.3.z),
                              SIMD3<Float>(0, 1, 0)) < 1e-5)
        // Half the inner frame at 1 m: (0.5 - 0.1125) × tan(30°) × 2 across, (0.5 - 0.15) × 0.866 up; ±5 cm deep.
        let tan30 = Float(tan(Double.pi / 6))
        #expect(abs(zone.halfExtents.x - (0.5 - 0.1125) * 2 * tan30) < 1e-4)
        #expect(abs(zone.halfExtents.y - (0.5 - 0.15) * 2 * tan30 * 0.75) < 1e-4)
        #expect(abs(zone.halfExtents.z - 0.05) < 1e-6)
        for item in engine.items { #expect(zone.contains(item.position)) }
        #expect(!zone.contains([0.50, 1.0, 0]))  // the band
        #expect(!zone.contains([0, 1.0, -0.2]))  // 20 cm behind the counted row
    }

    @Test("The zone turns with the camera")
    func rotatedZone() {
        let forward = simd_normalize(SIMD3<Float>(sin(0.5), 0, -cos(0.5)))  // yawed about 29°
        let cam = TestCamera(at: [0, 1.0, 0] - forward, forward: forward)
        var engine = CommitEngine()
        let along = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let points = (-2...2).map { SIMD3<Float>(0, 1.0, 0) + along * (0.11 * Float($0)) }
        let r = engine.commit(points.map { cam.detect(.bottle, at: $0) }, view: cam.view)
        #expect(r.newItems.count == 5)
        let zoneX = SIMD3(r.zone.transform.columns.0.x, r.zone.transform.columns.0.y, r.zone.transform.columns.0.z)
        let cameraX = SIMD3(cam.transform.columns.0.x, cam.transform.columns.0.y, cam.transform.columns.0.z)
        #expect(simd_distance(zoneX, cameraX) < 1e-5)
        for p in points { #expect(r.zone.contains(p)) }
        #expect(!r.zone.contains(SIMD3<Float>(0, 1.0, 0) + forward * 0.2))
    }

    @Test("Seen again, counted items match and nothing is added (FR-26)")
    func revisitMatches() {
        var engine = CommitEngine()
        let first = engine.commit(detections(bottles), view: camera.view)
        let again = engine.commit(detections(bottles), view: camera.view)
        #expect(again.newItems.isEmpty && again.possibleMisses.isEmpty)
        #expect(again.matched.map(\.detection) == [0, 1, 2, 3, 4])
        #expect(again.matched.map(\.item) == first.newItems.map(\.id))
        #expect(engine.items.count == 5 && engine.zones.count == 2)
        #expect(again.overCountedZones == 5 && !again.driftAlarm)
    }

    @Test("A revisit drifted by 4.2 cm is refined back and matches")
    func driftRefined() {
        var engine = CommitEngine()
        engine.commit(detections(bottles), view: camera.view)
        let r = engine.commit(detections(bottles, shift: [0.042, 0, 0]), view: camera.view)
        #expect(r.driftRefined)
        #expect(simd_distance(r.driftOffset, SIMD3<Float>(-0.04, 0, 0)) < 1e-6)  // on sim.py's 1 cm grid
        #expect(r.matched.count == 5 && r.newItems.isEmpty && r.possibleMisses.isEmpty)
        #expect(simd_distance(engine.driftEstimate, SIMD3<Float>(-0.04, 0, 0)) < 1e-6)
        engine.resetDriftEstimate()
        #expect(engine.driftEstimate == .zero)
    }

    @Test("Drift beyond ±4.5 cm is not snapped away: possible misses and the drift alarm (FR-23)")
    func driftBeyondSearch() {
        var engine = CommitEngine()
        engine.commit(detections(bottles), view: camera.view)
        let r = engine.commit(detections(bottles, shift: [0.07, 0, 0]), view: camera.view)
        #expect(!r.driftRefined && r.driftOffset == .zero)
        #expect(r.matched.isEmpty && r.newItems.isEmpty)
        #expect(r.possibleMisses == [0, 1, 2, 3, 4])  // inside the counted zone: never added
        #expect(r.driftAlarm && r.unmatchedOverCountedZones == 5)
        #expect(engine.items.count == 5)
    }

    @Test("The drift alarm needs more than 30% unmatched, over at least 3 detections")
    func driftAlarmThreshold() {
        var engine = CommitEngine()
        engine.commit(detections(bottles), view: camera.view)
        // A sixth bottle the first commit missed: 1 of 6 unmatched over the zone is 17%.
        let extra = SIMD3<Float>(0.36, 1.0, 0)
        let r = engine.commit(detections(bottles + [extra]), view: camera.view)
        #expect(r.possibleMisses == [5] && !r.driftAlarm)
        // Two detections over the zone, one unmatched: 50%, but too few to call it drift.
        var small = CommitEngine()
        small.commit(detections(Array(bottles.prefix(1))), view: camera.view)
        let s = small.commit(detections([bottles[0], bottles[2]]), view: camera.view)
        #expect(s.possibleMisses == [1] && !s.driftAlarm)
    }

    @Test("A possible miss is never added until the user taps it (FR-22)")
    func possibleMissAccepted() {
        var engine = CommitEngine()
        var partial = bottles
        partial.remove(at: 2)  // the detector missed the middle bottle
        engine.commit(detections(partial), view: camera.view)
        let r = engine.commit(detections(bottles), view: camera.view)
        #expect(r.possibleMisses == [2] && r.newItems.isEmpty)
        #expect(engine.items.count == 4)
        let added = engine.addDetection(2, ofCommit: r.commitID)
        #expect(added != nil && added?.commitID == r.commitID)
        #expect(engine.items.count == 5)
        #expect(engine.addDetection(2, ofCommit: r.commitID) == nil)  // already counted
        #expect(engine.addDetection(0, ofCommit: r.commitID) == nil)  // matched
        // Counted now, it matches next time.
        let next = engine.commit(detections(bottles), view: camera.view)
        #expect(next.matched.count == 5 && next.possibleMisses.isEmpty)
    }

    @Test("A low-confidence detection can be included by a tap (FR-18)")
    func lowConfidenceIncluded() {
        var engine = CommitEngine()
        var d = detections(bottles)
        d[1].score = 0.2
        let r = engine.commit(d, view: camera.view)
        #expect(r.statuses[1] == .lowConfidence && r.newItems.count == 4)
        let item = engine.addDetection(1, ofCommit: r.commitID)
        #expect(item.map { simd_distance($0.position, bottles[1]) < 1e-6 } == true)
        #expect(engine.items.count == 5)
    }

    @Test("Undo removes the last commit's items, zone and drift update (FR-16)")
    func undo() {
        var engine = CommitEngine()
        let a = engine.commit(detections(bottles), view: camera.view)
        let b = engine.commit(detections(bottles, shift: [0.042, 0, 0]), view: camera.view)  // refines drift
        let right = TestCamera(at: [1.0, 1.0, 1.0])
        let c = engine.commit((0..<4).map { right.detect(.bottle, at: [0.85 + 0.1 * Float($0), 1.0, 0]) }, view: right.view)
        #expect(engine.items.count == 9)
        let undone = engine.undoLastCommit()
        #expect(undone?.commitID == c.commitID && undone?.removedItems.count == 4 && undone?.removedZone == c.zone.id)
        #expect(engine.items.count == 5 && engine.zones.count == 2)
        #expect(simd_distance(engine.driftEstimate, SIMD3<Float>(-0.04, 0, 0)) < 1e-6)
        #expect(engine.undoLastCommit()?.commitID == b.commitID)
        #expect(engine.driftEstimate == .zero)  // b's refinement undone
        #expect(engine.undoLastCommit()?.removedItems == a.newItems.map(\.id))
        #expect(engine.items.isEmpty && engine.zones.isEmpty)
        #expect(engine.undoLastCommit() == nil)
    }

    @Test("Undo also removes possible misses added from that commit")
    func undoRemovesAcceptedMisses() {
        var engine = CommitEngine()
        engine.commit(detections(Array(bottles.prefix(4))), view: camera.view)
        let r = engine.commit(detections(bottles), view: camera.view)
        engine.addDetection(4, ofCommit: r.commitID)
        #expect(engine.items.count == 5)
        #expect(engine.undoLastCommit()?.removedItems.count == 1)
        #expect(engine.items.count == 4)
    }

    @Test("Items and zones move with their commit's anchor (FR-21)")
    func anchorUpdate() {
        var engine = CommitEngine()
        let r = engine.commit(detections(bottles), view: camera.view)
        var moved = r.zone.transform
        moved.columns.3 += SIMD4(0.1, 0, 0, 0)
        engine.updateAnchor(ofCommit: r.commitID, to: moved)
        for (item, p) in zip(engine.items, bottles) {
            #expect(simd_distance(item.position, p + [0.1, 0, 0]) < 1e-5)
        }
        #expect(abs(engine.zones[0].transform.columns.3.x - 0.1) < 1e-5)
        // Seen where they now are, they match.
        let again = engine.commit(detections(bottles, shift: [0.1, 0, 0]), view: camera.view)
        #expect(again.matched.count == 5)
    }

    @Test("Resumed from saved items and zones, the engine behaves the same (FR-7)")
    func restore() throws {
        var engine = CommitEngine()
        engine.commit(detections(Array(bottles.prefix(4))), view: camera.view)
        let data = try JSONEncoder().encode(engine.zones)
        let zones = try JSONDecoder().decode([CountedZone].self, from: data)
        #expect(zones == engine.zones)
        var resumed = CommitEngine(items: engine.items, zones: zones)
        let r = resumed.commit(detections(bottles), view: camera.view)
        #expect(r.matched.count == 4 && r.possibleMisses == [4] && r.newItems.isEmpty)
        #expect(resumed.undoLastCommit() != nil)
        #expect(resumed.undoLastCommit()?.removedItems.count == 4)
    }

    @Test("Preview classifies without changing anything")
    func preview() {
        var engine = CommitEngine()
        engine.commit(detections(Array(bottles.prefix(3))), view: camera.view)
        let before = engine.items
        let p = engine.preview(detections(bottles), view: camera.view)
        #expect(p.matched.count == 3)
        #expect(engine.items == before && engine.zones.count == 1)
    }

    @Test("Matching prefers a counted item of the same product")
    func productPreference() {
        var engine = CommitEngine()
        let a = SIMD3<Float>(0, 1.0, 0), b = SIMD3<Float>(0.06, 1.0, 0)
        let first = engine.commit(detections([a, b]), view: camera.view)
        engine.setProductKey(1, forItems: [first.newItems[0].id])
        engine.setProductKey(2, forItems: [first.newItems[1].id])
        let between = SIMD3<Float>(0.025, 1.0, 0)  // 2.5 cm from a, 3.5 cm from b
        #expect(engine.preview(detections([between]), view: camera.view).matched.first?.item == first.newItems[0].id)
        #expect(engine.preview(detections([between], product: 2), view: camera.view).matched.first?.item
                == first.newItems[1].id)
        #expect(engine.preview(detections([between], product: 1), view: camera.view).matched.first?.item
                == first.newItems[0].id)
    }

    @Test("Detections whose product disagrees support a drift offset only half as much")
    func productSupport() {
        func revisit(_ products: [Int]) -> CommitResult {
            var engine = CommitEngine()
            let points = Array(bottles.prefix(4))
            let first = engine.commit(detections(points, product: 1), view: camera.view)
            engine.setProductKey(1, forItems: first.newItems.map(\.id))
            let d = zip(points, products).map { camera.detect(.bottle, at: $0, product: $1, position: $0 + [0.042, 0, 0]) }
            return engine.commit(d, view: camera.view)
        }
        #expect(revisit([1, 1, 2, 2]).driftRefined)  // 1 + 1 + 0.5 + 0.5 = 3: enough
        let r = revisit([1, 2, 2, 2])  // 2.5: not enough, so nothing is matched
        #expect(!r.driftRefined && r.matched.isEmpty && r.possibleMisses.count == 4)
    }

    @Test("Removing and renaming items")
    func removeAndKeys() {
        var engine = CommitEngine()
        let r = engine.commit(detections(bottles), view: camera.view)
        engine.setGroupKey(7, forItems: r.newItems.prefix(2).map(\.id))
        #expect(engine.items.filter { $0.groupKey == 7 }.count == 2)
        engine.removeItems([r.newItems[0].id])
        #expect(engine.items.count == 4)
        // Its zone stays counted: seen again, the removed bottle is a possible miss.
        let again = engine.commit(detections(bottles), view: camera.view)
        #expect(again.possibleMisses == [0])
    }

    @Test("An empty view still counts its zone, at the scene depth")
    func emptyView() {
        var engine = CommitEngine()
        var view = camera.view
        view.sceneDepth = 1.0
        let r = engine.commit([], view: view)
        #expect(r.newItems.isEmpty)
        #expect(r.zone.contains([0, 1.0, 0]))
        let later = engine.commit(detections(bottles), view: camera.view)
        #expect(later.possibleMisses.count == 5 && later.newItems.isEmpty)
    }
}
