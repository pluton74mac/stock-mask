import CoreGraphics
import simd

/// Maps normalised points of the upright camera image onto the screen, for the 2D overlays
/// (yellow outlines, the inner frame). On the phone it is built from ARKit's own
/// `ARFrame.displayTransform(for:viewportSize:)`, so it matches the camera picture exactly;
/// elsewhere (previews, tests) from aspect-fill geometry, which is what that transform does.
public struct DisplayMapping: Sendable, Equatable {
    /// Sensor-normalised -> view-normalised, as CGAffineTransform's a, b, c, d, tx, ty.
    public var sensorToView: CGAffineTransform
    public var orientation: FrameOrientation

    public init(sensorToView: CGAffineTransform, orientation: FrameOrientation) {
        self.sensorToView = sensorToView
        self.orientation = orientation
    }

    /// The upright image shown aspect-filled in a view of `view` size (both in the same units).
    public static func aspectFill(upright image: CGSize, view: CGSize, orientation: FrameOrientation = .up) -> DisplayMapping {
        let scale = max(view.width / image.width, view.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let dx = (shown.width - view.width) / 2 / view.width, dy = (shown.height - view.height) / 2 / view.height
        let sx = shown.width / view.width, sy = shown.height / view.height
        // upright-normalised -> view-normalised
        let fill = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: -dx, ty: -dy)
        // sensor-normalised -> upright-normalised, then fill
        return DisplayMapping(sensorToView: orientation.sensorToUpright.concatenating(fill), orientation: orientation)
    }

    public func point(_ upright: SIMD2<Float>, in view: CGSize) -> CGPoint {
        let s = orientation.sensorPoint(upright: upright)
        let p = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)).applying(sensorToView)
        return CGPoint(x: p.x * view.width, y: p.y * view.height)
    }

    /// The part of the upright image the screen shows (x0, y0, x1, y1, normalised). Aspect fill
    /// crops it: a 19.5:9 phone in portrait shows about the middle 62% of the camera image's width.
    public func visibleRegion() -> SIMD4<Float> {
        let back = sensorToView.inverted()
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)].map { p -> SIMD2<Float> in
            let s = p.applying(back)
            return orientation.uprightPoint(sensor: SIMD2(Float(s.x), Float(s.y)))
        }
        let b = FrameOrientation.box(corners[0], corners[1])
        return b.clamped(lowerBound: .zero, upperBound: .one)
    }

    /// A box (x0, y0, x1, y1, upright-normalised) on screen.
    public func rect(_ box: SIMD4<Float>, in view: CGSize) -> CGRect {
        let a = point(SIMD2(box.x, box.y), in: view), b = point(SIMD2(box.z, box.w), in: view)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension FrameOrientation {
    /// `uprightPoint(sensor:)` as an affine transform of normalised points.
    public var sensorToUpright: CGAffineTransform {
        switch self {
        case .up: .identity
        case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)    // (x, y) -> (1 - y, x)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .left: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)     // (x, y) -> (y, 1 - x)
        }
    }
}
