import Foundation
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

@Suite("Lifter (P0-4 strategies)")
struct LifterTests {
    let lifter = Lifter()

    @Test func labelBandFindsTheBottleThroughGlass() throws {
        let b = SyntheticScene.Bottle(x: 0.1, front: 1.0)
        let scene = SyntheticScene(bottles: [b])
        let r = try #require(lifter.lift(box: scene.box(b), cls: .bottle, depth: scene.depthMap(), camera: scene.camera,
                                         planes: [scene.plane]))
        #expect(r.chosen.strategy == .labelBand)
        #expect(abs(r.chosen.surfaceDepth - 1.0) < 0.01)
        #expect(simd_distance(r.chosen.position, scene.centre(b)) < 0.01)
        #expect(abs(r.size.x - 0.08) < 0.01 && abs(r.size.y - 0.30) < 0.02)
        #expect(r.plausible)
        // The whole-box strategies see the wall through the glass: that's what P0-4 measures.
        let all = try #require(r.estimates.first { $0.strategy == .medianAll })
        #expect(all.surfaceDepth > 1.2)
        let plane = try #require(r.estimates.first { $0.strategy == .shelfPlane })
        #expect(simd_distance(plane.position, scene.centre(b)) < 0.02)
    }

    @Test func clearGlassFallsBackToTheShelfPlane() throws {
        let b = SyntheticScene.Bottle(x: -0.15, front: 0.9, label: nil)
        let scene = SyntheticScene(bottles: [b])
        let r = try #require(lifter.lift(box: scene.box(b), cls: .bottle, depth: scene.depthMap(), camera: scene.camera,
                                         planes: [scene.plane]))
        #expect(r.chosen.strategy == .shelfPlane)
        #expect(simd_distance(r.chosen.position, scene.centre(b)) < 0.02)
    }

    @Test func clearGlassWithoutAPlaneIsLiftedToTheWall() throws {
        let b = SyntheticScene.Bottle(x: 0, front: 1.0, label: nil)
        let scene = SyntheticScene(bottles: [b])
        let r = try #require(lifter.lift(box: scene.box(b), cls: .bottle, depth: scene.depthMap(), camera: scene.camera))
        #expect(r.chosen.strategy == .labelBand)
        #expect(r.chosen.surfaceDepth > 1.2)   // the wrong answer, on purpose: no plane to catch it
    }

    @Test func lowConfidenceGlassIsSkippedByTheConfidentStrategies() throws {
        var scene = SyntheticScene(bottles: [SyntheticScene.Bottle(x: 0, front: 1.0, label: nil)])
        scene.glassConfidence = DepthMap.low
        let b = scene.bottles[0]
        let hc = lifter.estimate(.highConfidence, box: scene.box(b), cls: .bottle, depth: scene.depthMap(),
                                 camera: scene.camera, planes: [])
        #expect(hc == nil)
        let band = lifter.estimate(.labelBand, box: scene.box(b), cls: .bottle, depth: scene.depthMap(),
                                   camera: scene.camera, planes: [])
        #expect(band == nil)
    }

    @Test func noDepthAndNoPlaneGivesNothing() {
        let scene = SyntheticScene(bottles: [SyntheticScene.Bottle(x: 0, front: 1.0)])
        #expect(lifter.lift(box: scene.box(scene.bottles[0]), cls: .bottle, depth: nil, camera: scene.camera) == nil)
    }

    @Test func topsNeverUseThePlane() {
        let scene = SyntheticScene(bottles: [SyntheticScene.Bottle(x: 0, front: 1.0, label: nil)])
        let box = SIMD4<Float>(0.48, 0.49, 0.52, 0.51)
        #expect(lifter.estimate(.shelfPlane, box: box, cls: .bottleTop, depth: nil, camera: scene.camera,
                                planes: [scene.plane]) == nil)
    }

    @Test func implausibleSizesAreFlagged() {
        #expect(ClassPrior.of(.bottle).plausible(SIMD2(0.08, 0.3)))
        #expect(!ClassPrior.of(.bottle).plausible(SIMD2(0.9, 0.3)))     // a metre-wide "bottle": a shelf edge
        #expect(!ClassPrior.of(.bottleTop).plausible(SIMD2(0.08, 0.3))) // a whole bottle called a top
    }
}
