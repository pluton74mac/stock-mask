import CoreGraphics
import Foundation
import RealityKit
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

@Suite("Grouping (ADR 004)")
struct GroupingTests {
    @Test func clustersByAppearanceWithinEachClass() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
        let e: [[Float]?] = [a, [0.95, 0.1, 0], b, [0.98, 0, 0.1], [0.1, 0.9, 0], nil, nil]
        let cls: [ObjectClass] = [.bottle, .bottle, .bottle, .bottle, .bottle, .can, .bottle]
        let keys = ItemGrouper(threshold: 0.6).groups(classes: cls, embeddings: e)
        #expect(keys[0] == keys[1] && keys[1] == keys[3])     // three of the first kind: the largest group, key 0
        #expect(keys[0] == 0)
        #expect(keys[2] == keys[4] && keys[2] != keys[0])     // two of the second kind
        #expect(keys[5] != keys[6])                           // no embedding: one group per class
        #expect(Set(keys).count == 4)
    }

    /// Two kinds of synthetic label, three of each, through Vision's FeaturePrint (revision 2).
    @Test func featurePrintSeparatesTwoKindsOfLabel() async throws {
        let w = 900, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var boxes: [SIMD4<Float>] = []
        for i in 0..<6 {
            let x = 40 + i * 140
            let r = CGRect(x: x, y: 60, width: 100, height: 280)
            if i % 2 == 0 {   // red with white stripes
                ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(r)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                for s in stride(from: 80, to: 320, by: 40) { ctx.fill(CGRect(x: x, y: s, width: 100, height: 12)) }
            } else {          // blue with a yellow disc
                ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)); ctx.fill(r)
                ctx.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: x + 20, y: 150, width: 60, height: 60))
            }
            // Boxes are normalised with the origin top-left; CoreGraphics draws bottom-up.
            boxes.append(SIMD4(Float(x) / Float(w), Float(h - 340) / Float(h), Float(x + 100) / Float(w), Float(h - 60) / Float(h)))
        }
        let embeddings = try await FeaturePrintEmbedder().embeddings(of: boxes, in: DetectorInput(image: ctx.makeImage()!))
        let e = embeddings.map { $0! }
        #expect(e.allSatisfy { $0.count == 768 })   // revision 2
        var same: [Float] = [], cross: [Float] = []
        for i in 0..<6 { for j in (i + 1)..<6 { (i % 2 == j % 2 ? { same.append($0) } : { cross.append($0) })(ItemGrouper.distance(e[i], e[j])) } }
        print("FeaturePrint distances: same kind \(same.max()!), different kinds \(cross.min()!)")
        #expect(same.max()! < cross.min()!)
        let keys = ItemGrouper().groups(classes: Array(repeating: .bottle, count: 6), embeddings: embeddings)
        #expect(keys == [0, 1, 0, 1, 0, 1])
    }
}

@Suite("Overlays and the HUD", .serialized)
@MainActor
struct OverlayTests {
    func state() -> (OverlayState, UUID, UUID) {
        var s = OverlayState()
        let c1 = UUID(), c2 = UUID()
        let zone1 = CountedZone(commitID: c1, transform: .translation(SIMD3(0, 0, -1)), halfExtents: SIMD3(0.4, 0.5, 0.1))
        let dets = [Detection(cls: .bottle, score: 0.9, box: SIMD4(0.4, 0.4, 0.5, 0.6), position: SIMD3(0.1, 0, -1))]
        s.add(CommitResult(commitID: c1, newItems: [CountedItem(cls: .bottle, position: SIMD3(-0.1, 0, -1), commitID: c1),
                                                    CountedItem(cls: .bottleTop, position: SIMD3(0, 0.1, -1.1), commitID: c1)],
                           matched: [], possibleMisses: [0], zone: zone1, driftAlarm: false), detections: dets)
        let zone2 = CountedZone(commitID: c2, transform: .translation(SIMD3(1, 0, -1)), halfExtents: SIMD3(0.4, 0.5, 0.1))
        s.add(CommitResult(commitID: c2, newItems: [CountedItem(cls: .can, position: SIMD3(1, 0, -1), commitID: c2)],
                           matched: [], possibleMisses: [], zone: zone2, driftAlarm: false), detections: [])
        return (s, c1, c2)
    }

    @Test func stateKeepsPositionsInAnchorSpace() throws {
        var (s, c1, _) = state()
        #expect(s.itemCount == 3 && s.possibleMisses == 1)
        let miss = try #require(s.commits[0].misses.first)
        #expect(miss.local == SIMD3(0.1, 0, 0))
        s.move(commit: c1, to: .translation(SIMD3(0, 0.05, -1)))
        #expect(s.miss(miss.id)?.world == SIMD3(0.1, 0.05, -1))
        s.accept(miss: miss.id, as: CountedItem(cls: .bottle, position: miss.world, commitID: c1))
        #expect(s.itemCount == 4 && s.possibleMisses == 0)
    }

    @Test func rendererFollowsTheState() throws {
        let scene = Entity()
        let renderer = OverlayRenderer(makeRoot: { c in AnchorEntity(world: c.anchor) }, attach: { scene.addChild($0) })
        var (s, c1, c2) = state()
        renderer.sync(s)
        #expect(scene.children.count == 2 && renderer.commitCount == 2)
        let root = try #require(scene.children.first { $0.name == "commit:\(c1.uuidString)" })
        #expect(root.children.count == 4)   // zone tint, two items, one "+"
        let plus = try #require(root.children.first { $0.name.hasPrefix("miss:") })
        #expect(OverlayRenderer.missID(of: plus.children.first) == s.commits[0].misses[0].id)
        #expect(plus.components.has(CollisionComponent.self) && plus.components.has(BillboardComponent.self))

        s.faded = true
        renderer.sync(s)
        #expect(scene.children.allSatisfy { $0.components[OpacityComponent.self]?.opacity == 0.3 })
        s.remove(commit: c2)
        renderer.sync(s)
        #expect(scene.children.count == 1 && renderer.commitCount == 1)
    }

    @Test func boxesLandWhereTheCameraPictureIs() {
        // A portrait upright image (1440 x 1920) aspect-filled in a 393 x 852 pt screen: scaled by
        // 852 / 1920 and cropped 123 pt on each side.
        let view = CGSize(width: 393, height: 852)
        let m = DisplayMapping.aspectFill(upright: CGSize(width: 1440, height: 1920), view: view)
        let centre = m.point(SIMD2(0.5, 0.5), in: view)
        #expect(abs(centre.x - 196.5) < 1e-6 && abs(centre.y - 426) < 1e-6)
        let corner = m.point(SIMD2(0, 0), in: view)
        #expect(abs(corner.x + 123) < 0.01 && abs(corner.y) < 1e-6)
        // The same mapping built from a sensor-to-view transform (as ARKit gives it) agrees.
        let r = DisplayMapping.aspectFill(upright: CGSize(width: 1440, height: 1920), view: view, orientation: .right)
        let box = SIMD4<Float>(0.2, 0.3, 0.4, 0.7)
        #expect(abs(r.rect(box, in: view).minX - m.rect(box, in: view).minX) < 1e-3)
        #expect(abs(r.rect(box, in: view).height - m.rect(box, in: view).height) < 1e-3)
    }

    @Test func theInnerFrameStaysOnScreen() {
        // 393 x 852 pt shows the middle 62% of a 1440 x 1920 portrait image's width.
        let m = DisplayMapping.aspectFill(upright: CGSize(width: 1440, height: 1920), view: CGSize(width: 393, height: 852),
                                          orientation: .right)
        let visible = m.visibleRegion()
        #expect(abs(visible.x - 0.1925) < 1e-3 && abs(visible.z - 0.8075) < 1e-3 && visible.y == 0 && visible.w == 1)
        let session = CountingSession(store: CoreStockStore())
        session.setVisibleRegion(visible, imageSize: SIMD2(1440, 1920))
        #expect(session.innerFrame.x >= visible.x && session.innerFrame.z <= visible.z)
        // An iPad-like 3:4 screen crops nothing: the default band (0.15 of the short side) stays.
        let full = DisplayMapping.aspectFill(upright: CGSize(width: 1440, height: 1920), view: CGSize(width: 768, height: 1024))
        session.setVisibleRegion(full.visibleRegion(), imageSize: SIMD2(1440, 1920))
        #expect(abs(session.innerFrame.x - 0.15) < 1e-4)
    }

    @Test func meters() {
        var fps = RateMeter()
        for i in 0...60 { fps.tick(at: Double(i) / 60) }
        #expect(abs(fps.rate(at: 1) - 60) < 1e-6)
        var lat = LatencyStats(capacity: 100)
        for ms in 1...100 { lat.add(Double(ms)) }
        #expect(lat.p50 == 51 && lat.p95 == 95 && lat.last == 100)
        #expect(ThermalLevel.serious.detectorRate == 5 && ThermalLevel.critical.detectorRate == nil)
        #expect(ThermalLevel(ProcessInfo.ThermalState.fair) == .fair)
        var hud = HUDStats()
        hud.battery = 0.62
        #expect(hud.lines.contains { $0.contains("battery 62%") })
    }
}
