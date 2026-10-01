import Foundation
import simd

/// How fast the view moves, in degrees per second, for the hold trigger (FR-13: "steady ... under
/// 10°/s"). It adds the camera's rotation to its sideways travel seen at the scene's distance,
/// because stepping along a shelf moves the view as much as turning does: 10 cm/s at 1 m is
/// about 5.7°/s. Smoothed with a short time constant so one jittery frame doesn't break a hold.
public struct ViewMotion: Sendable {
    public var timeConstant: Double
    public var defaultDistance: Float = 1
    public private(set) var speed: Double = 0
    private var last: (t: TimeInterval, transform: simd_float4x4)?

    public init(timeConstant: Double = 0.1) { self.timeConstant = timeConstant }

    /// Feed one frame's camera transform; returns the smoothed view speed in degrees per second.
    @discardableResult
    public mutating func update(transform: simd_float4x4, timestamp: TimeInterval, sceneDistance: Float?) -> Double {
        defer { last = (timestamp, transform) }
        guard let last, timestamp > last.t else { return speed }
        let dt = timestamp - last.t
        let instant = Self.degrees(from: last.transform, to: transform, distance: sceneDistance ?? defaultDistance) / dt
        if dt > 0.5 {
            speed = instant  // a gap: start over rather than average across it
        } else {
            speed += (1 - exp(-dt / timeConstant)) * (instant - speed)
        }
        return speed
    }

    public mutating func reset() {
        last = nil
        speed = 0
    }

    /// Rotation angle between two poses plus the sideways travel's angle at `distance`, in degrees.
    public static func degrees(from a: simd_float4x4, to b: simd_float4x4, distance: Float) -> Double {
        let ra = simd_float3x3(columns: (a.columns.0.xyz, a.columns.1.xyz, a.columns.2.xyz))
        let rb = simd_float3x3(columns: (b.columns.0.xyz, b.columns.1.xyz, b.columns.2.xyz))
        let r = ra.transpose * rb
        let cosine = max(-1, min(1, (r[0][0] + r[1][1] + r[2][2] - 1) / 2))
        let turn = Double(acos(cosine))
        let move = b.columns.3.xyz - a.columns.3.xyz
        let forward = -simd_normalize(b.columns.2.xyz)
        let sideways = simd_length(move - simd_dot(move, forward) * forward)
        let slide = Double(atan2(sideways, max(distance, 0.1)))
        return (turn + slide) * 180 / .pi
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
