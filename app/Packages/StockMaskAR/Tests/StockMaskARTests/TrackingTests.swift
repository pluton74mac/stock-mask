import Foundation
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

@Suite("Live tracks and view motion")
struct TrackingTests {
    func obs(_ x: Float, _ z: Float = -1, cls: ObjectClass = .bottle, box: SIMD4<Float>? = nil) -> LiveTracks.Observation {
        LiveTracks.Observation(cls: cls, score: 0.8, box: box ?? SIMD4(0.5 + x, 0.4, 0.55 + x, 0.6),
                               position: SIMD3(x, 0, z))
    }

    @Test func neighboursNineCentimetresApartStaySeparate() {
        var t = LiveTracks()
        let noise: [Float] = [0, 0.01, -0.008, 0.006]
        for (i, n) in noise.enumerated() {
            t.update([obs(0 + n), obs(0.09 - n), obs(0.18 + n)], at: Double(i) * 0.1)
        }
        #expect(t.tracks.count == 3)
        #expect(t.stable(at: 0.3).count == 3)
        // The fused position averages the noise out.
        let first = t.tracks.min { $0.position!.x < $1.position!.x }!
        #expect(abs(first.position!.x) < 0.005)
    }

    @Test func stableNeedsThreeHitsInHalfASecond() {
        var t = LiveTracks()
        t.update([obs(0)], at: 0)
        t.update([obs(0)], at: 0.1)
        #expect(t.stable(at: 0.1).isEmpty)
        t.update([obs(0)], at: 0.2)
        #expect(t.stable(at: 0.2).count == 1)
        // Hits spread over more than the window don't add up.
        var slow = LiveTracks()
        for i in 0..<3 { slow.update([obs(0)], at: Double(i) * 0.4) }
        #expect(slow.stable(at: 0.8).isEmpty)
    }

    @Test func classesDontMix() {
        var t = LiveTracks()
        t.update([obs(0)], at: 0)
        t.update([obs(0, cls: .can)], at: 0.1)
        #expect(t.tracks.count == 2)
    }

    @Test func unseenTracksAreDropped() {
        var t = LiveTracks()
        t.update([obs(0)], at: 0)
        t.update([], at: 1.5)
        #expect(t.tracks.isEmpty)
    }

    @Test func detectionsWithoutDepthAssociateByOverlap() {
        var t = LiveTracks()
        let box = SIMD4<Float>(0.4, 0.4, 0.5, 0.6)
        for i in 0..<3 {
            t.update([LiveTracks.Observation(cls: .bottle, score: 0.7, box: box + SIMD4(repeating: Float(i) * 0.005))],
                     at: Double(i) * 0.1)
        }
        #expect(t.tracks.count == 1)
        #expect(t.tracks[0].position == nil)
        #expect(t.stable(at: 0.2).count == 1)
    }

    @Test func implausibleTracksAreNeverCandidates() {
        var t = LiveTracks()
        for i in 0..<4 {
            var o = obs(0)
            o.plausible = false
            t.update([o], at: Double(i) * 0.1)
        }
        #expect(t.stable(at: 0.3).isEmpty)
    }

    @Test func turningTenDegreesPerSecondReadsTen() {
        var m = ViewMotion()
        var speed = 0.0
        for i in 0...60 {
            speed = m.update(transform: yaw(Float(i) / 6), timestamp: Double(i) / 60, sceneDistance: 1)
        }
        #expect(abs(speed - 10) < 0.5)
    }

    @Test func steppingSidewaysCountsAsViewMotion() {
        var m = ViewMotion()
        var speed = 0.0
        for i in 0...60 {
            let t = Double(i) / 60
            speed = m.update(transform: .translation(SIMD3(Float(t) * 0.1, 0, 0)), timestamp: t, sceneDistance: 1)
        }
        #expect(abs(speed - 5.71) < 0.3)   // atan(0.1 / 1) per second
        var still = ViewMotion()
        for i in 0...30 { speed = still.update(transform: yaw(3), timestamp: Double(i) / 60, sceneDistance: 1) }
        #expect(speed < 1e-6)
    }

    @Test func sceneDistanceIsTheCentralMedian() {
        let d = DepthMap(width: 4, height: 4, depth: [Float](repeating: 2, count: 16))
        #expect(ViewMotion.sceneDistance(d) == 2)
        #expect(ViewMotion.sceneDistance(nil) == nil)
    }
}

@Suite("DETR decoding")
struct DecoderTests {
    let classes = ["", "bottle", "cup", ""]

    @Test func decodesLikeRFDETR() {
        let d = DETRDecoder(classNames: classes, numSelect: 300)
        let boxes: [Float] = [0.5, 0.5, 0.2, 0.4, 0.1, 0.1, 0.4, 0.4, 0.9, 0.9, 0.1, 0.1]
        let logits: [Float] = [-9, 2.0, -9, -9,   -9, -9, 0.5, -9,   -9, -1, -9, -9]
        let out = d.decode(boxes: boxes, logits: logits, queries: 3, threshold: 0.3)
        #expect(out.map(\.label) == ["bottle", "cup"])
        #expect(abs(out[0].score - 0.8808) < 1e-3)
        #expect(out[0].cls == .bottle && out[1].cls == nil)
        #expect(out[0].box == SIMD4(0.4, 0.3, 0.6, 0.7))
        // Boxes past the image edge are clamped, as rfdetr clamps them.
        #expect(out[1].box == SIMD4(0, 0, 0.3, 0.3))
    }

    @Test func keepsTheTopPairsThenDropsUnusedSlots() {
        // 4 queries all confident in the unused slot 0 and in bottle; numSelect 3 keeps the three
        // best pairs (the unused slot wins ties by index), and only bottles come out.
        let d = DETRDecoder(classNames: classes, numSelect: 3)
        let boxes = [Float](repeating: 0.5, count: 16)
        let logits: [Float] = [3, 3, -9, -9,  3, 3, -9, -9,  3, 3, -9, -9,  3, 3, -9, -9]
        let out = d.decode(boxes: boxes, logits: logits, queries: 4, threshold: 0.5)
        #expect(out.count == 1)   // pairs kept: (q0, slot0), (q0, bottle), (q1, slot0) -> one bottle
    }

    @Test func thresholdIsStrict() {
        let d = DETRDecoder(classNames: ["bottle"], numSelect: 300)
        let out = d.decode(boxes: [0.5, 0.5, 0.1, 0.1], logits: [0], queries: 1, threshold: 0.5)
        #expect(out.isEmpty)   // sigmoid(0) == 0.5 is not above 0.5
    }

    @Test func metadataGivesTheClassList() throws {
        let m = try ModelMetadata(["stockmask.classes": #"["", "bottle", "can", "case", "bottle_top"]"#,
                                   "stockmask.score_commit": "0.6"])
        #expect(m.classNames.count == 5)
        #expect(m.scoreCommit == 0.6 && m.scoreShown == 0.3 && m.boxesOutput == "boxes")
        #expect(DetectorInfo(classNames: m.classNames).countedClasses == [.bottle, .can, .case, .bottleTop])
        #expect(throws: ModelMetadata.Problem.missing("stockmask.classes")) { try ModelMetadata([:]) }
    }
}
