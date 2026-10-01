import Testing
import StockMaskCounting

@Suite("Inner frame (FR-14)")
struct InnerFrameTests {
    let frame = InnerFrame()  // band 0.15 of the short side, cut within 0.005 of the long side
    let landscape = SIMD2<Float>(1920, 1440)
    let portrait = SIMD2<Float>(1440, 1920)

    @Test("The band is a fraction of the short side, on both axes")
    func bandFractions() {
        let b = frame.bandFractions(imageSize: landscape)
        #expect(abs(b.x - 0.15 * 1440 / 1920) < 1e-12)
        #expect(abs(b.y - 0.15) < 1e-12)
        let p = frame.bandFractions(imageSize: portrait)
        #expect(abs(p.x - 0.15) < 1e-12)
        #expect(abs(p.y - 0.15 * 1440 / 1920) < 1e-12)
    }

    @Test func wholeAndCentredIsInner() {
        #expect(frame.placement(of: [0.4, 0.3, 0.45, 0.7], imageSize: landscape) == .inner)
    }

    @Test("Whole, centre in the band: left for the neighbouring view")
    func centreInBand() {
        // Centre x = 0.08, inside the 0.1125 band on the left.
        #expect(frame.placement(of: [0.05, 0.4, 0.11, 0.6], imageSize: landscape) == .band)
        // Centre y = 0.9, inside the 0.15 band at the bottom.
        #expect(frame.placement(of: [0.4, 0.82, 0.45, 0.98], imageSize: landscape) == .band)
    }

    @Test("Touching the image border is cut, whatever the centre")
    func cut() {
        #expect(frame.placement(of: [0.4, 0.2, 0.45, 1.0], imageSize: landscape) == .cut)
        #expect(frame.placement(of: [0.0, 0.4, 0.3, 0.6], imageSize: landscape) == .cut)
        // The cut margin is 0.005 of the long side: 0.005 on x, 0.0067 on y for a landscape image.
        #expect(frame.placement(of: [0.4, 0.006, 0.45, 0.5], imageSize: landscape) == .cut)
        #expect(frame.placement(of: [0.4, 0.008, 0.45, 0.5], imageSize: landscape) == .inner)
    }

    @Test("The inner frame's edges are inside, as in sim.py")
    func edgesInclusive() {
        let b = frame.bandFractions(imageSize: landscape)
        #expect(frame.contains(centre: [b.x, 0.5], imageSize: landscape))
        #expect(frame.contains(centre: [1 - b.x, 1 - b.y], imageSize: landscape))
        #expect(!frame.contains(centre: [b.x - 1e-9, 0.5], imageSize: landscape))
    }
}
