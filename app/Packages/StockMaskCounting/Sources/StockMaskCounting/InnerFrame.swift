import simd

/// FR-14: a commit counts only objects fully inside the inner frame; objects cut by the frame edge
/// wait for the next view.
///
/// The rule as research/walkthrough/walkthrough.py implements it (`view_status`, `BAND`, `EDGE`),
/// and as research/dedup_sim/sim.py models it:
/// - **cut**: the box touches the image border (within `edge`). Its centre is biased, so it is not
///   used at all; the next view sees it whole.
/// - **inner**: whole, and its centre is inside the inner frame, the image minus a band of `band`
///   on each side. This view counts it.
/// - **band**: whole, but its centre is in the band. The neighbouring view counts it.
///
/// "Fully inside" is read as "whole, centre inside", not "whole box inside the inner frame". The
/// counted zone is the inner frame itself, so with a whole-box rule an object straddling the inner
/// frame's edge, centre inside, would be counted by neither view: this one leaves it, and the next
/// finds it inside a counted zone and only suggests it. With the band at about half the largest
/// object (ADR 003), a centre in the inner frame also means the object is whole.
public struct InnerFrame: Sendable, Equatable {
    /// Edge band on each side, as a fraction of the image's short side. walkthrough.py `BAND` = 0.15
    /// ("about half a bottle"). The simulation's 18 cm on a 0.9 m wide view is 0.2.
    public var band: Double
    /// A box this close to the image border, as a fraction of the long side, is cut.
    /// walkthrough.py `EDGE` = 0.005.
    public var edge: Double

    public enum Placement: Sendable, Equatable {
        case inner, band, cut
    }

    public init(band: Double = 0.15, edge: Double = 0.005) {
        self.band = band
        self.edge = edge
    }

    /// Where a box sits. `box` is x0, y0, x1, y1 in normalised image coordinates; `imageSize` gives
    /// the aspect ratio (pixels, width and height).
    public func placement(of box: SIMD4<Float>, imageSize: SIMD2<Float>) -> Placement {
        if isCut(box, imageSize: imageSize) { return .cut }
        return contains(centre: Self.centre(of: box), imageSize: imageSize) ? .inner : .band
    }

    /// Whether the box touches the image border.
    public func isCut(_ box: SIMD4<Float>, imageSize: SIMD2<Float>) -> Bool {
        let m = edgeFractions(imageSize: imageSize)
        let b = SIMD4<Double>(box)
        return b.x <= m.x || b.y <= m.y || b.z >= 1 - m.x || b.w >= 1 - m.y
    }

    /// Whether a normalised image point is inside the inner frame (edges included).
    public func contains(centre c: SIMD2<Double>, imageSize: SIMD2<Float>) -> Bool {
        let b = bandFractions(imageSize: imageSize)
        return c.x >= b.x && c.x <= 1 - b.x && c.y >= b.y && c.y <= 1 - b.y
    }

    /// The band in normalised units along x and y.
    public func bandFractions(imageSize: SIMD2<Float>) -> SIMD2<Double> {
        let w = Double(imageSize.x), h = Double(imageSize.y)
        let short = min(w, h)
        return SIMD2(band * short / w, band * short / h)
    }

    /// The cut margin in normalised units along x and y.
    public func edgeFractions(imageSize: SIMD2<Float>) -> SIMD2<Double> {
        let w = Double(imageSize.x), h = Double(imageSize.y)
        let long = max(w, h)
        return SIMD2(edge * long / w, edge * long / h)
    }

    static func centre(of box: SIMD4<Float>) -> SIMD2<Double> {
        SIMD2((Double(box.x) + Double(box.z)) / 2, (Double(box.y) + Double(box.w)) / 2)
    }
}
