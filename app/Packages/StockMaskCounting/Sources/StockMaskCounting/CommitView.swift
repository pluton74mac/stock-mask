import simd

/// The view geometry of one commit: where the camera was and how it projects.
///
/// Conventions (ARKit's): the camera transform maps camera space to world space; the camera looks
/// along its -z axis, with +x to the right of the image and +y up the image. Image coordinates are
/// normalised, x to the right and y down, and must be those of the detection boxes. With ARKit, use
/// the captured image's orientation for both (`ARCamera.intrinsics` and `imageResolution` refer to
/// it), even when the phone is held in portrait: rotate boxes from a rotated detector input back.
public struct CommitView: Sendable {
    /// Camera to world (`ARCamera.transform`). Rigid.
    public var cameraTransform: simd_float4x4
    /// fx, fy, cx, cy in normalised image units: fx and cx divided by the image width, fy and cy by
    /// its height.
    public var intrinsics: SIMD4<Float>
    /// The image the boxes are normalised by, in pixels. Only its aspect ratio matters.
    public var imageSize: SIMD2<Float>
    /// Depth along the view, metres, at which to place the counted zone when no detection inside the
    /// inner frame has a position (an empty shelf). The LiDAR depth at the image centre is a good
    /// choice. Nil: `CommitEngine.Parameters.defaultZoneDepth`.
    public var sceneDepth: Float?

    public init(cameraTransform: simd_float4x4, intrinsics: SIMD4<Float>, imageSize: SIMD2<Float>,
                sceneDepth: Float? = nil) {
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.imageSize = imageSize
        self.sceneDepth = sceneDepth
    }

    /// From ARKit's pixel intrinsics (`ARCamera.intrinsics`) and `imageResolution`.
    public init(cameraTransform: simd_float4x4, pixelIntrinsics k: simd_float3x3, imageResolution: SIMD2<Float>,
                sceneDepth: Float? = nil) {
        self.init(cameraTransform: cameraTransform,
                  intrinsics: SIMD4(k.columns.0.x / imageResolution.x, k.columns.1.y / imageResolution.y,
                                    k.columns.2.x / imageResolution.x, k.columns.2.y / imageResolution.y),
                  imageSize: imageResolution, sceneDepth: sceneDepth)
    }
}

/// An oriented box in Double precision: rotation columns are the box axes in world space.
struct Box3: Sendable {
    var rotation: simd_double3x3
    var centre: SIMD3<Double>
    var halfExtents: SIMD3<Double>

    func contains(_ p: SIMD3<Double>) -> Bool {
        let l = Geometry.transposedTimes(rotation, p - centre)
        return abs(l.x) <= halfExtents.x && abs(l.y) <= halfExtents.y && abs(l.z) <= halfExtents.z
    }

    var transform: simd_float4x4 {
        Geometry.transform(rotation: rotation, translation: centre)
    }
}

enum Geometry {
    /// Rᵀ v, summed left to right (the simulation's numpy order; no fused multiply-add).
    static func transposedTimes(_ r: simd_double3x3, _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(dot(r.columns.0, v), dot(r.columns.1, v), dot(r.columns.2, v))
    }

    /// R v.
    static func times(_ r: simd_double3x3, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let a = r.columns.0 * v.x
        let b = r.columns.1 * v.y
        let c = r.columns.2 * v.z
        return a + b + c
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let x = a.x * b.x
        let y = a.y * b.y
        let z = a.z * b.z
        return x + y + z
    }

    static func length(_ v: SIMD3<Double>) -> Double {
        dot(v, v).squareRoot()
    }

    static func rigid(_ m: simd_float4x4) -> (rotation: simd_double3x3, translation: SIMD3<Double>) {
        func axis(_ c: SIMD4<Float>) -> SIMD3<Double> {
            let v = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
            let n = length(v)
            return n > 0 ? v / n : v
        }
        let t = m.columns.3
        return (simd_double3x3(columns: (axis(m.columns.0), axis(m.columns.1), axis(m.columns.2))),
                SIMD3(Double(t.x), Double(t.y), Double(t.z)))
    }

    static func transform(rotation r: simd_double3x3, translation t: SIMD3<Double>) -> simd_float4x4 {
        func col(_ v: SIMD3<Double>, _ w: Float) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), w) }
        return simd_float4x4(columns: (col(r.columns.0, 0), col(r.columns.1, 0), col(r.columns.2, 0), col(t, 1)))
    }
}

/// One commit's view, prepared for the engine: projection, inner frame, and the shelf axes used by
/// the matching metric.
struct ViewFrame {
    let rotation: simd_double3x3  // camera axes in world space
    let position: SIMD3<Double>  // camera centre
    let fx, fy, cx, cy: Double
    let imageSize: SIMD2<Float>
    let innerFrame: InnerFrame
    let worldUp: SIMD3<Double>
    /// The metric frame of ADR 003's anisotropic gate: along the shelf, up, and depth (horizontal,
    /// towards the camera). The simulation's x, y and z.
    let along, up, depthAxis: SIMD3<Double>
    /// Which way world up points in the image, as a quarter turn: 0 = up the image (-y), 1 = towards
    /// +x, 2 = down the image, 3 = towards -x.
    let upTurn: Int

    init(_ view: CommitView, innerFrame: InnerFrame, worldUp: SIMD3<Double>) {
        let pose = Geometry.rigid(view.cameraTransform)
        rotation = pose.rotation
        position = pose.translation
        fx = Double(view.intrinsics.x)
        fy = Double(view.intrinsics.y)
        cx = Double(view.intrinsics.z)
        cy = Double(view.intrinsics.w)
        imageSize = view.imageSize
        self.innerFrame = innerFrame
        let upLength = Geometry.length(worldUp)
        let up = upLength > 0 ? worldUp / upLength : SIMD3(0, 1, 0)
        self.worldUp = up
        self.up = up
        // Depth runs from the shelf towards the camera, flattened to the horizontal. Looking almost
        // straight up or down, fall back to the image's own vertical axis, flattened.
        func horizontal(_ v: SIMD3<Double>) -> SIMD3<Double> { v - up * Geometry.dot(v, up) }
        var back = horizontal(rotation.columns.2)
        if Geometry.length(back) < 0.05 { back = horizontal(rotation.columns.1) }
        if Geometry.length(back) < 0.05 { back = horizontal(rotation.columns.0) }
        depthAxis = back / Geometry.length(back)
        along = simd_cross(up, depthAxis)
        let u = Geometry.transposedTimes(rotation, up)  // world up, in camera axes
        if abs(u.y) >= abs(u.x) {
            upTurn = u.y >= 0 ? 0 : 2
        } else {
            upTurn = u.x >= 0 ? 1 : 3
        }
    }

    /// A world vector in the metric frame (along, up, depth), unweighted.
    func metric(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(Geometry.dot(along, v), Geometry.dot(up, v), Geometry.dot(depthAxis, v))
    }

    /// Distance along the view direction, metres.
    func depth(of p: SIMD3<Double>) -> Double {
        -Geometry.transposedTimes(rotation, p - position).z
    }

    func isCut(_ box: SIMD4<Float>) -> Bool {
        innerFrame.isCut(box, imageSize: imageSize)
    }

    func isInner(_ centre: SIMD2<Double>) -> Bool {
        innerFrame.contains(centre: centre, imageSize: imageSize)
    }

    /// A normalised image point in "upright" pixel units: rotated by quarter turns so that world up
    /// is up the image (-y), scaled by the image size so both axes have the same unit.
    func upright(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let w = Double(imageSize.x), h = Double(imageSize.y)
        switch upTurn {
        case 0: return SIMD2(p.x * w, p.y * h)
        case 2: return SIMD2((1 - p.x) * w, (1 - p.y) * h)
        case 1: return SIMD2(p.y * h, (1 - p.x) * w)  // world up is +x: a quarter turn counter-clockwise
        default: return SIMD2((1 - p.y) * h, p.x * w)  // world up is -x: a quarter turn clockwise
        }
    }

    /// A box in upright pixel units: min x, min y (its top), max x, max y.
    func upright(box b: SIMD4<Float>) -> SIMD4<Double> {
        let p = upright(SIMD2(Double(b.x), Double(b.y)))
        let q = upright(SIMD2(Double(b.z), Double(b.w)))
        return SIMD4(min(p.x, q.x), min(p.y, q.y), max(p.x, q.x), max(p.y, q.y))
    }

    /// The extent of `size` (metres along the image's x and y) along world up.
    func verticalExtent(of size: SIMD2<Float>) -> Double {
        Double(upTurn % 2 == 0 ? size.y : size.x)
    }

    /// The counted zone of this view (FR-21, ADR 003): the inner frame's cross-section at `reference`
    /// depth, spanning depths `near...far`, as a box with the camera's axes.
    func zone(reference: Double, near: Double, far: Double) -> Box3 {
        let b = innerFrame.bandFractions(imageSize: imageSize)
        let x0 = (b.x - cx) / fx * reference, x1 = (1 - b.x - cx) / fx * reference
        let y0 = -(1 - b.y - cy) / fy * reference, y1 = -(b.y - cy) / fy * reference
        let z0 = -far, z1 = -near
        let centreCamera = SIMD3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
        let half = SIMD3((x1 - x0) / 2, (y1 - y0) / 2, (z1 - z0) / 2)
        return Box3(rotation: rotation, centre: position + Geometry.times(rotation, centreCamera), halfExtents: half)
    }
}
