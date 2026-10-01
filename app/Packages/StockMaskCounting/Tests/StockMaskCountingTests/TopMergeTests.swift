import simd
import Testing
import StockMaskCounting

/// Bottles and tops: a top that belongs to a bottle in the same view is the same unit; a top with
/// no bottle under it is a bottle in a row behind and counts as one.
@Suite("Bottles and tops")
struct TopMergeTests {
    let camera = TestCamera(at: [0, 1.0, 1.0])
    /// A bottle on the shelf: the lifter puts it on its front surface; its cap sits on its axis,
    /// 4 cm further back, 1.5 cm below the top.
    let bottle = SIMD3<Float>(0, 1.0, 0)
    func cap(of b: SIMD3<Float>, rowsBack: Int = 0) -> SIMD3<Float> {
        b + [0, 0.135, -0.04 - 0.09 * Float(rowsBack)]
    }

    func top(_ c: TestCamera, at p: SIMD3<Float>, score: Float = 0.9) -> Detection {
        c.detect(.bottleTop, at: p, size: [0.03, 0.03], score: score)
    }

    @Test("A bottle and its own top are one unit")
    func bottleWithItsTop() {
        var engine = CommitEngine()
        let r = engine.commit([camera.detect(.bottle, at: bottle), top(camera, at: cap(of: bottle))], view: camera.view)
        #expect(r.newItems.count == 1)
        #expect(r.newItems[0].cls == .bottle)
        #expect(r.statuses[1] == .mergedTop(bottle: 0))
        #expect(r.mergedTops.map(\.top) == [1] && r.mergedTops.map(\.bottle) == [0])
        #expect(r.newItems[0].top.map { simd_distance($0, cap(of: bottle)) < 1e-5 } == true)
    }

    @Test("A top with no bottle under it is a bottle behind, and counts as one")
    func topAlone() {
        var engine = CommitEngine()
        let r = engine.commit([top(camera, at: cap(of: bottle, rowsBack: 1))], view: camera.view)
        #expect(r.newItems.count == 1 && r.newItems[0].cls == .bottleTop)
    }

    @Test("A front bottle, its top, and two rows behind: three units")
    func rowsBehind() {
        var engine = CommitEngine()
        let d = [camera.detect(.bottle, at: bottle), top(camera, at: cap(of: bottle)),
                 top(camera, at: cap(of: bottle, rowsBack: 1)), top(camera, at: cap(of: bottle, rowsBack: 2))]
        let r = engine.commit(d, view: camera.view)
        #expect(r.newItems.count == 3)
        #expect(r.statuses[1] == .mergedTop(bottle: 0))
        #expect(r.newItems.map(\.cls) == [.bottle, .bottleTop, .bottleTop])
    }

    @Test("A back row's top in the bottle's cap window is not absorbed when its own top is missed")
    func sameRowVeto() {
        var engine = CommitEngine()
        let back = top(camera, at: cap(of: bottle, rowsBack: 1))
        let box = camera.detect(.bottle, at: bottle).box
        let c = SIMD2((back.box.x + back.box.z) / 2, (back.box.y + back.box.w) / 2)
        #expect(c.x > box.x && c.x < box.z && c.y < box.y + 0.25 * (box.w - box.y))  // inside the 2D window
        let r = engine.commit([camera.detect(.bottle, at: bottle), back], view: camera.view)
        #expect(r.newItems.count == 2 && r.mergedTops.isEmpty)
    }

    @Test("The 3D top joins a top whose box sits off the cap window; without a size it can't")
    func threeDimensionalTop() {
        var engine = CommitEngine()
        var t = top(camera, at: cap(of: bottle))
        t.box.y -= 0.08  // the box drawn 8% of the image (about 0.23 of the bottle's height) too high
        t.box.w -= 0.08
        let withSize = engine.commit([camera.detect(.bottle, at: bottle), t], view: camera.view)
        #expect(withSize.newItems.count == 1 && withSize.statuses[1] == .mergedTop(bottle: 0))
        var other = CommitEngine()
        var noSize = camera.detect(.bottle, at: bottle)
        noSize.size = nil
        #expect(other.commit([noSize, t], view: camera.view).newItems.count == 2)
    }

    @Test("Each bottle takes one top, the nearest its cap")
    func oneTopPerBottle() {
        var engine = CommitEngine()
        let left = SIMD3<Float>(-0.045, 1.0, 0), right = SIMD3<Float>(0.045, 1.0, 0)
        let d = [camera.detect(.bottle, at: left), camera.detect(.bottle, at: right),
                 top(camera, at: cap(of: right)), top(camera, at: cap(of: left))]
        let r = engine.commit(d, view: camera.view)
        #expect(r.newItems.count == 2)
        #expect(r.statuses[2] == .mergedTop(bottle: 1) && r.statuses[3] == .mergedTop(bottle: 0))
    }

    @Test("With the phone in portrait, the cap window follows gravity, not the image")
    func portrait() {
        let rolled = TestCamera(at: [0, 1.0, 1.0], roll: 1)
        var engine = CommitEngine()
        let r = engine.commit([rolled.detect(.bottle, at: bottle), top(rolled, at: cap(of: bottle))], view: rolled.view)
        #expect(r.newItems.count == 1 && r.statuses[1] == .mergedTop(bottle: 0))
    }

    @Test("The top of a bottle below the commit score counts on its own")
    func lowScoreBottle() {
        var engine = CommitEngine()
        let r = engine.commit([camera.detect(.bottle, at: bottle, score: 0.3), top(camera, at: cap(of: bottle))],
                              view: camera.view)
        #expect(r.statuses[0] == .lowConfidence)
        #expect(r.newItems.count == 1 && r.newItems[0].cls == .bottleTop)
    }

    @Test("A bottle counted by its top while cut matches when seen whole later")
    func cutThenWhole() {
        // 0.6 m away at 1.3 m high: the bottle's bottom is below the image, its top in the inner frame.
        let high = TestCamera(at: [0, 1.30, 0.6])
        var engine = CommitEngine()
        let first = engine.commit([high.detect(.bottle, at: bottle), top(high, at: cap(of: bottle))], view: high.view)
        #expect(first.statuses[0] == .cut)
        #expect(first.newItems.count == 1 && first.newItems[0].cls == .bottleTop)
        let whole = engine.commit([camera.detect(.bottle, at: bottle), top(camera, at: cap(of: bottle))], view: camera.view)
        #expect(whole.newItems.isEmpty && whole.matched.map(\.item) == [first.newItems[0].id])
    }

    @Test("A bottle counted whole matches its top seen alone later, by its estimated top")
    func wholeThenTopAlone() {
        var engine = CommitEngine()
        let first = engine.commit([camera.detect(.bottle, at: bottle)], view: camera.view)
        #expect(first.newItems[0].top != nil)  // estimated from its size
        let high = TestCamera(at: [0, 1.30, 0.6])
        let later = engine.commit([high.detect(.bottle, at: bottle), top(high, at: cap(of: bottle))], view: high.view)
        #expect(later.newItems.isEmpty && later.matched.map(\.item) == [first.newItems[0].id])
    }
}
