import StockMaskCounting
import simd

/// Physical priors per class: how far an item's centre sits behind its visible front, and the
/// sizes that are plausible for it (PRD §11: "plausibility (size per class)").
public struct ClassPrior: Sendable, Equatable {
    public var radius: Float                 // metres from the visible front surface to the item's axis
    public var width: ClosedRange<Float>     // metres, across the image plane
    public var height: ClosedRange<Float>

    public static func of(_ cls: ObjectClass) -> ClassPrior {
        switch cls {
        // Heights start low: a bottle in a row behind shows only its upper part.
        case .bottle: ClassPrior(radius: 0.04, width: 0.04...0.16, height: 0.08...0.50)
        case .can: ClassPrior(radius: 0.033, width: 0.045...0.10, height: 0.06...0.25)
        case .case: ClassPrior(radius: 0.12, width: 0.15...0.70, height: 0.08...0.50)
        case .bottleTop: ClassPrior(radius: 0.015, width: 0.012...0.07, height: 0.008...0.08)
        }
    }

    /// Plausible: within the ranges, with 30% of slack either way (box padding, perspective).
    public func plausible(_ size: SIMD2<Float>) -> Bool {
        size.x >= width.lowerBound * 0.7 && size.x <= width.upperBound * 1.3
            && size.y >= height.lowerBound * 0.7 && size.y <= height.upperBound * 1.3
    }
}

/// The depth sampling strategies Phase 0 task P0-4 compares on glass bottles.
public enum LiftStrategy: String, Codable, Sendable, CaseIterable {
    case medianAll = "median_all"            // (a) median of every depth pixel in the box
    case highConfidence = "high_confidence"  // (b) median of the high-confidence pixels in the box
    case labelBand = "label_band"            // (c) the label band: central 40% of the height, 60% of the width
    case shelfPlane = "shelf_plane"          // (d) the box's bottom on a support plane, plus the class radius
}

public struct LiftEstimate: Sendable, Equatable {
    public var strategy: LiftStrategy
    public var surfaceDepth: Float           // metres along the camera axis to the visible front
    public var position: SIMD3<Float>        // world: the item's axis at mid-height
    public var support: Int                  // depth pixels used (0 for the plane)
}

public struct LiftResult: Sendable, Equatable {
    public var chosen: LiftEstimate
    public var size: SIMD2<Float>            // metres: the box's width and height at the surface depth
    public var plausible: Bool
    public var estimates: [LiftEstimate]     // every strategy that produced one, for P0-4 and the HUD
}

/// Box -> 3D point from LiDAR depth (PRD §11 "Lifter").
///
/// The starting policy, until P0-4 measures which strategy wins:
/// 1. the label band, from medium- or high-confidence pixels (labels are opaque; glass is not);
/// 2. else the high-confidence pixels anywhere in the box;
/// 3. if that depth lies more than `throughGlassMargin` behind the shelf-plane estimate, the
///    sensor saw through the glass to the wall behind: use the plane instead;
/// 4. else the shelf plane, else the median of every pixel.
/// Bottle tops never use the plane: they don't stand on it.
public struct Lifter: Sendable {
    public var bandRows: ClosedRange<Float> = 0.3...0.7
    public var bandColumns: ClosedRange<Float> = 0.2...0.8
    public var minPixels = 4
    public var depthRange: ClosedRange<Float> = 0.15...5
    public var throughGlassMargin: Float = 0.10

    public init() {}

    /// Lift one box (normalised, upright image). `camera` describes the same upright image; the
    /// depth map must be upright too, covering the same field of view.
    public func lift(box: SIMD4<Float>, cls: ObjectClass, depth: DepthMap?, camera: CameraModel,
                     planes: [SupportPlane] = []) -> LiftResult? {
        var estimates: [LiftEstimate] = []
        for s in LiftStrategy.allCases {
            if let e = estimate(s, box: box, cls: cls, depth: depth, camera: camera, planes: planes) { estimates.append(e) }
        }
        func get(_ s: LiftStrategy) -> LiftEstimate? { estimates.first { $0.strategy == s } }
        var chosen = get(.labelBand) ?? get(.highConfidence)
        if let c = chosen, let p = get(.shelfPlane), c.surfaceDepth > p.surfaceDepth + throughGlassMargin { chosen = p }
        guard let pick = chosen ?? get(.shelfPlane) ?? get(.medianAll) else { return nil }
        let mpp = camera.metresPerPixel(depth: pick.surfaceDepth)
        let size = SIMD2((box.z - box.x) * camera.imageSize.x * mpp.x, (box.w - box.y) * camera.imageSize.y * mpp.y)
        return LiftResult(chosen: pick, size: size, plausible: ClassPrior.of(cls).plausible(size), estimates: estimates)
    }

    /// One strategy on its own; nil when it has too little to go on.
    public func estimate(_ strategy: LiftStrategy, box: SIMD4<Float>, cls: ObjectClass, depth: DepthMap?,
                         camera: CameraModel, planes: [SupportPlane]) -> LiftEstimate? {
        let centre = SIMD2((box.x + box.z) / 2, (box.y + box.w) / 2)
        switch strategy {
        case .medianAll, .highConfidence, .labelBand:
            guard let depth else { return nil }
            var region = box
            var minConfidence: UInt8 = DepthMap.low
            if strategy == .highConfidence { minConfidence = DepthMap.high }
            if strategy == .labelBand {
                let w = box.z - box.x, h = box.w - box.y
                region = SIMD4(box.x + w * bandColumns.lowerBound, box.y + h * bandRows.lowerBound,
                               box.x + w * bandColumns.upperBound, box.y + h * bandRows.upperBound)
                minConfidence = DepthMap.medium
            }
            let values = samples(depth, region, minConfidence)
            guard values.count >= minPixels else { return nil }
            let d = Self.median(values)
            return LiftEstimate(strategy: strategy, surfaceDepth: d,
                                position: push(camera.worldPoint(normalized: centre, depth: d), cls, camera, centre),
                                support: values.count)
        case .shelfPlane:
            guard cls != .bottleTop else { return nil }
            let foot = SIMD2(centre.x, box.w)                  // bottom centre: where the item meets the shelf
            let dir = camera.rayDirection(normalized: foot)
            var best: (t: Float, point: SIMD3<Float>, plane: SupportPlane)?
            for plane in planes {
                if let hit = plane.intersect(origin: camera.position, direction: dir), hit.t < (best?.t ?? .infinity) {
                    best = (hit.t, hit.point, plane)
                }
            }
            guard let best else { return nil }
            let d = -camera.cameraSpace(best.point).z
            guard depthRange.contains(d) else { return nil }
            let height = (box.w - box.y) * camera.imageSize.y * camera.metresPerPixel(depth: d).y
            let base = best.point + best.plane.normal * (height / 2)
            return LiftEstimate(strategy: .shelfPlane, surfaceDepth: d, position: push(base, cls, camera, centre), support: 0)
        }
    }

    /// Valid depths inside a normalised region, at or above a confidence level.
    func samples(_ depth: DepthMap, _ region: SIMD4<Float>, _ minConfidence: UInt8) -> [Float] {
        let (xs, ys) = depth.pixels(of: region)
        var out: [Float] = []
        out.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs {
                let d = depth.depthAt(x, y)
                if DepthMap.isValid(d), depthRange.contains(d), depth.confidenceAt(x, y) >= minConfidence { out.append(d) }
            }
        }
        return out
    }

    /// Moves a point away from the camera by the class radius: horizontally for items standing on
    /// a shelf (so the height stays put), along the ray for tops or when looking straight down.
    func push(_ p: SIMD3<Float>, _ cls: ObjectClass, _ camera: CameraModel, _ at: SIMD2<Float>) -> SIMD3<Float> {
        let ray = camera.rayDirection(normalized: at)
        let flat = SIMD3(ray.x, 0, ray.z)
        let dir = cls == .bottleTop || simd_length(flat) < 0.2 ? ray : simd_normalize(flat)
        return p + ClassPrior.of(cls).radius * dir
    }

    static func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
