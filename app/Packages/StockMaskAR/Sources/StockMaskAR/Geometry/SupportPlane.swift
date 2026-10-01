import simd

/// A flat surface items stand on: a shelf board or the floor. On the phone these come from ARKit's
/// horizontal plane anchors (`ARPlaneAnchor`, see `ARFrameConversion.swift`).
public struct SupportPlane: Sendable, Equatable {
    /// Plane to world. The plane is the local y = 0 plane; local +y is its normal (up).
    public var transform: simd_float4x4
    /// Full size along local x and z, centred on the origin. A non-positive value means unbounded.
    public var extent: SIMD2<Float>

    public init(transform: simd_float4x4, extent: SIMD2<Float>) {
        self.transform = transform
        self.extent = extent
    }

    /// A level plane at `height`, centred on `center` (x, z), `extent` metres wide (x) and deep (z).
    public static func level(height: Float, center: SIMD2<Float> = .zero, extent: SIMD2<Float> = .zero) -> SupportPlane {
        SupportPlane(transform: .translation(SIMD3(center.x, height, center.y)), extent: extent)
    }

    public var origin: SIMD3<Float> { transform.columns.3.xyz }
    public var normal: SIMD3<Float> { simd_normalize(transform.columns.1.xyz) }

    /// Where a ray first meets the plane inside its extent (grown by `margin`), and how far along
    /// the ray that is. Rays parallel to the plane, or meeting it behind the origin, miss.
    public func intersect(origin o: SIMD3<Float>, direction d: SIMD3<Float>, margin: Float = 0.05)
        -> (t: Float, point: SIMD3<Float>)? {
        let n = normal
        let denom = simd_dot(n, d)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(n, origin - o) / denom
        guard t > 0 else { return nil }
        let p = o + t * d
        let local = (transform.inverse * SIMD4(p, 1)).xyz
        if extent.x > 0, abs(local.x) > extent.x / 2 + margin { return nil }
        if extent.y > 0, abs(local.z) > extent.y / 2 + margin { return nil }
        return (t, p)
    }
}
