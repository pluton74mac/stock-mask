import simd

/// A pinhole camera with a pose: everything needed to go between image points and world points.
///
/// Conventions (ARKit's): the camera looks along -z, +x is the image's right, +y the image's top;
/// world space is metres with +y up. Intrinsics use ARKit's column layout:
/// `intrinsics[0][0] = fx`, `intrinsics[1][1] = fy`, `intrinsics[2][0] = cx`, `intrinsics[2][1] = cy`,
/// in pixels of an image of `imageSize`. Normalised image points have their origin top-left.
public struct CameraModel: Sendable, Equatable {
    public var intrinsics: simd_float3x3
    public var imageSize: SIMD2<Float>
    public var transform: simd_float4x4   // camera to world

    public init(intrinsics: simd_float3x3, imageSize: SIMD2<Float>, transform: simd_float4x4) {
        self.intrinsics = intrinsics
        self.imageSize = imageSize
        self.transform = transform
    }

    /// A camera with the given focal length and centred principal point (tests, previews).
    public init(fx: Float, fy: Float? = nil, imageSize: SIMD2<Float>, transform: simd_float4x4 = matrix_identity_float4x4) {
        self.init(intrinsics: simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fy ?? fx, 0),
                                                      SIMD3(imageSize.x / 2, imageSize.y / 2, 1))),
                  imageSize: imageSize, transform: transform)
    }

    public var fx: Float { intrinsics[0][0] }
    public var fy: Float { intrinsics[1][1] }
    public var cx: Float { intrinsics[2][0] }
    public var cy: Float { intrinsics[2][1] }
    public var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    public var rotation: simd_float3x3 {
        simd_float3x3(columns: (transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz))
    }
    /// Where the camera looks, in world space.
    public var forward: SIMD3<Float> { -transform.columns.2.xyz }

    /// The camera-space point at `depth` metres in front of the camera, through a normalised image point.
    public func cameraPoint(normalized p: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        let px = p.x * imageSize.x, py = p.y * imageSize.y
        return SIMD3((px - cx) / fx * depth, -(py - cy) / fy * depth, -depth)
    }

    public func worldPoint(normalized p: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        (transform * SIMD4(cameraPoint(normalized: p, depth: depth), 1)).xyz
    }

    /// The world-space unit direction of the ray through a normalised image point.
    public func rayDirection(normalized p: SIMD2<Float>) -> SIMD3<Float> {
        simd_normalize(rotation * cameraPoint(normalized: p, depth: 1))
    }

    /// Camera-space coordinates of a world point.
    public func cameraSpace(_ world: SIMD3<Float>) -> SIMD3<Float> {
        (transform.inverse * SIMD4(world, 1)).xyz
    }

    /// The normalised image point and depth of a world point; nil behind the camera.
    public func project(_ world: SIMD3<Float>) -> (point: SIMD2<Float>, depth: Float)? {
        let c = cameraSpace(world)
        let depth = -c.z
        guard depth > 1e-4 else { return nil }
        let px = cx + fx * c.x / depth
        let py = cy - fy * c.y / depth
        return (SIMD2(px / imageSize.x, py / imageSize.y), depth)
    }

    /// Metres per pixel at `depth`, across and down the image.
    public func metresPerPixel(depth: Float) -> SIMD2<Float> { SIMD2(depth / fx, depth / fy) }

    /// The same camera, described in the upright image of a sensor-oriented capture
    /// (`self` is ARKit's camera for the stored image).
    public func upright(_ o: FrameOrientation) -> CameraModel {
        let w = imageSize.x, h = imageSize.y
        let (fx2, fy2, cx2, cy2): (Float, Float, Float, Float)
        switch o {
        case .up: (fx2, fy2, cx2, cy2) = (fx, fy, cx, cy)
        case .right: (fx2, fy2, cx2, cy2) = (fy, fx, h - cy, cx)
        case .down: (fx2, fy2, cx2, cy2) = (fx, fy, w - cx, h - cy)
        case .left: (fx2, fy2, cx2, cy2) = (fy, fx, cy, w - cx)
        }
        let r = o.cameraRotation
        let turn = simd_float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1)))
        return CameraModel(intrinsics: simd_float3x3(columns: (SIMD3(fx2, 0, 0), SIMD3(0, fy2, 0), SIMD3(cx2, cy2, 1))),
                           imageSize: o.uprightSize(sensor: imageSize), transform: transform * turn)
    }

    /// The intrinsics rescaled to another image size of the same field of view (e.g. the depth map's).
    public func scaled(to size: SIMD2<Float>) -> CameraModel {
        let s = size / imageSize
        return CameraModel(intrinsics: simd_float3x3(columns: (SIMD3(fx * s.x, 0, 0), SIMD3(0, fy * s.y, 0),
                                                               SIMD3(cx * s.x, cy * s.y, 1))),
                           imageSize: size, transform: transform)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension simd_float4x4 {
    /// A transform with this rotation part and the given translation.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}
