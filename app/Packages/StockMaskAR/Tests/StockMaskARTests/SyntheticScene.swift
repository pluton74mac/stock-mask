import Foundation
import simd
import StockMaskCounting
@testable import StockMaskAR

/// A tiny ray-cast "LiDAR" for tests: an upright camera at the origin looking along -z, a back wall,
/// and bottles standing on a shelf. Each bottle's front face is at its depth; only its label band
/// is opaque, so elsewhere on the bottle the sensor sees through the glass to the wall (P0-4's
/// worst case).
struct SyntheticScene {
    struct Bottle {
        var x: Float                 // centre, metres
        var front: Float             // depth of the front face, metres
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

    /// The bottle's box in the upright image, normalised.
    func box(_ b: Bottle) -> SIMD4<Float> {
        let p0 = camera.project(SIMD3(b.x - b.width / 2, shelfY + b.height, -b.front))!.point
        let p1 = camera.project(SIMD3(b.x + b.width / 2, shelfY, -b.front))!.point
        return SIMD4(p0.x, p0.y, p1.x, p1.y)
    }

    /// The true centre (axis at mid-height).
    func centre(_ b: Bottle) -> SIMD3<Float> {
        SIMD3(b.x, shelfY + b.height / 2, -(b.front + ClassPrior.of(.bottle).radius))
    }

    var plane: SupportPlane { .level(height: shelfY) }

    func depthMap() -> DepthMap {
        let (w, h) = depthSize
        let small = camera.scaled(to: SIMD2(Float(w), Float(h)))
        var depth = [Float](repeating: wall, count: w * h)
        var conf = [UInt8](repeating: DepthMap.high, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let n = SIMD2((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))
                for b in bottles {
                    let p = small.cameraPoint(normalized: n, depth: b.front)
                    let top = shelfY + b.height
                    guard abs(p.x - b.x) <= b.width / 2, p.y <= top, p.y >= shelfY else { continue }
                    let fromTop = (top - p.y) / b.height
                    if let band = b.label, band.contains(fromTop) {
                        depth[y * w + x] = b.front
                    } else {
                        conf[y * w + x] = glassConfidence   // glass: the wall shows through
                    }
                }
            }
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: conf)
    }
}
