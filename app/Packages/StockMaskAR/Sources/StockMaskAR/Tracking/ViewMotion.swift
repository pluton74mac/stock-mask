import Foundation
import simd

/// How the view moves between frames, for the hold trigger (FR-13: "steady ... under 10°/s").
///
/// The speed adds the camera's rotation to its sideways travel seen at the scene's distance,
/// because stepping along a shelf moves the view as much as turning does (10 cm/s at 1 m is about
/// 5.7°/s); walkthrough.py measured the same thing from image motion. The shift is the same
/// movement as a vector (degrees across and up the view), which lets StockMaskCounting's
/// HoldTrigger re-arm on net movement rather than on hand tremor. No smoothing here: the trigger
/// filters the speed itself.
public struct ViewMotion: Sendable {
    public struct Step: Sendable, Equatable {
        public var speed: Double              // degrees per second; infinity on the first frame
        public var shift: SIMD2<Double>       // degrees across (+ right) and up (+ up) since the last frame
    }

    public var defaultDistance: Float = 1
    private var last: (t: TimeInterval, transform: simd_float4x4)?

    public init() {}

    public mutating func update(transform: simd_float4x4, timestamp: TimeInterval, sceneDistance: Float?) -> Step {
        defer { last = (timestamp, transform) }
        guard let last, timestamp > last.t else { return Step(speed: .infinity, shift: .zero) }
        let distance = max(sceneDistance ?? defaultDistance, 0.1)
        let shift = Self.shift(from: last.transform, to: transform, distance: distance)
        let degrees = Self.degrees(from: last.transform, to: transform, distance: distance)
        return Step(speed: degrees / (timestamp - last.t), shift: shift)
    }

    public mutating func reset() { last = nil }

    /// Rotation angle between two poses plus the sideways travel's angle at `distance`, in degrees.
    public static func degrees(from a: simd_float4x4, to b: simd_float4x4, distance: Float) -> Double {
        // The relative rotation's angle from a Double quaternion: acos of the trace loses small angles
        // in Float (a 1/6° step reads 2% high).
        func rotation(_ m: simd_float4x4) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3<Double>(m.columns.0.xyz), SIMD3<Double>(m.columns.1.xyz), SIMD3<Double>(m.columns.2.xyz)))
        }
        let q = simd_quatd(rotation(a).transpose * rotation(b))
        let turn = 2 * atan2(simd_length(q.imag), abs(q.real))
        let move = b.columns.3.xyz - a.columns.3.xyz
        let forward = -simd_normalize(b.columns.2.xyz)
        let sideways = simd_length(move - simd_dot(move, forward) * forward)
        let slide = Double(atan2(sideways, distance))
        return (turn + slide) * 180 / .pi
    }

    /// Where the view centre went, in the first pose's camera axes: the new viewing direction's
    /// angles plus the sideways travel's angles at `distance`, in degrees.
    public static func shift(from a: simd_float4x4, to b: simd_float4x4, distance: Float) -> SIMD2<Double> {
        let ra = simd_float3x3(columns: (a.columns.0.xyz, a.columns.1.xyz, a.columns.2.xyz))
        let v = ra.transpose * (-simd_normalize(b.columns.2.xyz))        // new forward, old camera axes
        let m = ra.transpose * (b.columns.3.xyz - a.columns.3.xyz)       // travel, old camera axes
        let across = atan2(v.x, -v.z) + atan2(m.x, distance)
        let up = atan2(v.y, -v.z) + atan2(m.y, distance)
        return SIMD2(Double(across), Double(up)) * 180 / .pi
    }

    /// The scene's distance: the median depth in the central half of the view.
    public static func sceneDistance(_ depth: DepthMap?) -> Float? {
        guard let depth else { return nil }
        let (xs, ys) = depth.pixels(of: SIMD4(0.25, 0.25, 0.75, 0.75))
        var v: [Float] = []
        for y in ys.striding(by: 2) {
            for x in xs.striding(by: 2) where DepthMap.isValid(depth.depthAt(x, y)) { v.append(depth.depthAt(x, y)) }
        }
        return v.isEmpty ? nil : Lifter.median(v)
    }
}

extension Range where Bound == Int {
    func striding(by step: Int) -> StrideTo<Int> { stride(from: lowerBound, to: upperBound, by: step) }
}
