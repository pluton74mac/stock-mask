import Foundation
import simd
import StockMaskCounting
@testable import StockMaskAR

/// A tiny ray-cast "LiDAR" for tests: a back wall and bottles standing on a shelf, seen by an
/// upright camera anywhere. Each bottle's front face is at its depth; only its label band is
/// opaque, so elsewhere on the bottle the sensor sees through the glass to the wall (P0-4's worst
/// case).
struct SyntheticScene {
    struct Bottle {
        var x: Float                 // centre, metres
        var front: Float             // distance of the front face from the origin along -z, metres
        var width: Float = 0.08
        var height: Float = 0.30
        var label: ClosedRange<Float>? = 0.3...0.7   // opaque band, as fractions from the top; nil = all glass
    }

    var shelfY: Float = -0.3
    var wall: Float = 1.3
    var bottles: [Bottle]
    var camera = CameraModel(fx: 1500, imageSize: SIMD2(1440, 1920))
    var depthSize = (width: 192, height: 256)
    var glassConfidence: UInt8 = DepthMap.high

    /// The bottle's box in the upright image of `cam` (default: the scene's camera), normalised.
    func box(_ b: Bottle, camera cam: CameraModel? = nil) -> SIMD4<Float> {
        let c = cam ?? camera
        let corners = [SIMD3(b.x - b.width / 2, shelfY, -b.front), SIMD3(b.x + b.width / 2, shelfY, -b.front),
                       SIMD3(b.x - b.width / 2, shelfY + b.height, -b.front), SIMD3(b.x + b.width / 2, shelfY + b.height, -b.front)]
        let p = corners.compactMap { c.project($0)?.point }
        return SIMD4(p.map(\.x).min()!, p.map(\.y).min()!, p.map(\.x).max()!, p.map(\.y).max()!)
    }

    /// What a perfect detector would return from `cam`: every bottle wholly in view.
    func detections(camera cam: CameraModel? = nil, score: Float = 0.8, only: [Int]? = nil) -> [RawDetection] {
        bottles.indices.filter { only?.contains($0) ?? true }.compactMap { i in
            let b = box(bottles[i], camera: cam)
            guard b.x >= 0, b.y >= 0, b.z <= 1, b.w <= 1 else { return nil }
            return RawDetection(label: "bottle", score: score, box: b)
        }
    }

    /// The true centre (axis at mid-height).
    func centre(_ b: Bottle) -> SIMD3<Float> {
        SIMD3(b.x, shelfY + b.height / 2, -(b.front + ClassPrior.of(.bottle).radius))
    }

    var plane: SupportPlane { .level(height: shelfY) }

    /// The depth map `cam` would see (upright, aligned with its image).
    func depthMap(camera cam: CameraModel? = nil) -> DepthMap {
        let c = cam ?? camera
        let (w, h) = depthSize
        let small = c.scaled(to: SIMD2(Float(w), Float(h)))
        var depth = [Float](repeating: 0, count: w * h)
        var conf = [UInt8](repeating: DepthMap.high, count: w * h)
        let o = c.position
        for y in 0..<h {
            for x in 0..<w {
                let n = SIMD2((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))
                let dir = small.rayDirection(normalized: n)
                func cameraDepth(_ p: SIMD3<Float>) -> Float { -c.cameraSpace(p).z }
                var hit = cameraDepth(o + dir * ((-wall - o.z) / dir.z))
                for b in bottles {
                    let p = o + dir * ((-b.front - o.z) / dir.z)
                    let top = shelfY + b.height
                    guard abs(p.x - b.x) <= b.width / 2, p.y <= top, p.y >= shelfY else { continue }
                    let fromTop = (top - p.y) / b.height
                    if let band = b.label, band.contains(fromTop) {
                        hit = cameraDepth(p)
                    } else {
                        conf[y * w + x] = glassConfidence   // glass: the wall shows through
                    }
                }
                depth[y * w + x] = hit
            }
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: conf)
    }

    /// A frame as the AR layer would hand it over.
    func snapshot(_ t: TimeInterval, camera cam: CameraModel? = nil, withDepth: Bool = true,
                  tracking: TrackingStatus = .normal) -> FrameSnapshot {
        let c = cam ?? camera
        return FrameSnapshot(timestamp: t, camera: c, depth: withDepth ? depthMap(camera: c) : nil, tracking: tracking,
                             planes: [plane])
    }
}
