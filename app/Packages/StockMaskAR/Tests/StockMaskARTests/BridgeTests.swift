import Foundation
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

@Suite("Counting bridge (StockMaskCounting, portrait)")
struct BridgeTests {
    static let shelf = SyntheticScene(bottles: [SyntheticScene.Bottle(x: -0.12, front: 1.0), SyntheticScene.Bottle(x: 0, front: 1.0),
                                                SyntheticScene.Bottle(x: 0.12, front: 1.0)])

    /// The scene's bottles as lifted detections from `camera` (upright image).
    func detections(_ scene: SyntheticScene, camera: CameraModel, only: [Int]? = nil) -> [Detection] {
        let depth = scene.depthMap(camera: camera)
        return scene.detections(camera: camera, only: only).map { raw in
            let lift = Lifter().lift(box: raw.box, cls: .bottle, depth: depth, camera: camera, planes: [scene.plane])!
            return Detection(cls: .bottle, score: raw.score, box: raw.box, position: lift.chosen.position, size: lift.size)
        }
    }

    @Test func boxesReachTheEngineInTheStoredImage() {
        let d = Detection(cls: .bottle, score: 0.9, box: SIMD4(0.2, 0.3, 0.4, 0.7), size: SIMD2(0.08, 0.3))
        let s = CountingBridge.sensor([d], .right)[0]
        // Portrait (.right): the upright box's top-left (0.2, 0.3) is the stored image's (0.3, 0.8).
        #expect(s.box == SIMD4(0.3, 0.6, 0.7, 0.8))
        #expect(s.size == SIMD2(0.3, 0.08))   // the bottle's height runs along the stored image's x
    }

    @Test func aMissedBottleInsideACountedZoneIsAPossibleMiss() {
        var bridge = CountingBridge()
        let cam = Self.shelf.camera
        let first = bridge.commit(detections(Self.shelf, camera: cam, only: [0, 1]), camera: cam, orientation: .right,
                                  sceneDepth: 1.3)
        #expect(first.newItems.count == 2)
        #expect(first.zone.contains(Self.shelf.centre(Self.shelf.bottles[2])))
        let second = bridge.commit(detections(Self.shelf, camera: cam), camera: cam, orientation: .right, sceneDepth: 1.3)
        #expect(second.newItems.isEmpty)
        #expect(second.matched.count == 2)
        #expect(second.possibleMisses == [2], "statuses: \(second.statuses)")
        // One miss among three detections over counted zones is 33%: above FR-23's 30%, so the engine
        // flags drift (the session then undoes the commit and pauses).
        #expect(second.driftAlarm)
        let added = bridge.addDetection(2, ofCommit: second.commitID)
        #expect(added != nil)
        #expect(bridge.engine.items.count == 3)
    }

    @Test func driftShowsAsUnmatchedDetectionsOverCountedZones() {
        var bridge = CountingBridge()
        let cam = Self.shelf.camera
        _ = bridge.commit(detections(Self.shelf, camera: cam), camera: cam, orientation: .right, sceneDepth: 1.3)
        var off = cam
        off.transform = simd_float4x4.translation(SIMD3(0.06, 0, 0)) * cam.transform   // tracking 6 cm off
        let view = detections(Self.shelf, camera: cam).map { d -> Detection in
            var moved = d
            moved.position = d.position! + SIMD3(0.06, 0, 0)
            return moved
        }
        let p = bridge.preview(view, camera: off, orientation: .right, sceneDepth: 1.3)
        #expect(p.driftAlarm && p.unmatchedOverCountedZones == 3)
        #expect(bridge.engine.items.count == 3)   // preview changes nothing
    }
}
