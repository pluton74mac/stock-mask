import Foundation
import simd
import StockMaskCounting

/// A pinhole camera in ARKit's conventions that turns 3D objects into detections: the test's
/// stand-in for the detector and the lifter.
struct TestCamera {
    var transform: simd_float4x4  // camera to world
    var intrinsics: SIMD4<Float>  // normalised fx, fy, cx, cy
    var imageSize: SIMD2<Float>
    /// Quarter turns of roll: 0 = landscape, world up = image up. 1 = the phone in portrait, world up
    /// along the image's +x (ARKit's captured image is landscape).
    var roll: Int

    /// Looking from `position` along `forward`, with a horizontal field of view of `fov` degrees
    /// across a `imageSize` image.
    init(at position: SIMD3<Float>, forward: SIMD3<Float> = [0, 0, -1], roll: Int = 0, fov: Float = 60,
         imageSize: SIMD2<Float> = [1920, 1440]) {
        let z = -simd_normalize(forward)
        var x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z))
        var y = simd_cross(z, x)
        for _ in 0..<(roll % 4) {  // a quarter turn about z: world up moves to the image's +x
            (x, y) = (y, -x)
        }
        transform = simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1)))
        let f = (imageSize.x / 2) / tan(fov * .pi / 360)
        intrinsics = SIMD4(f / imageSize.x, f / imageSize.y, 0.5, 0.5)
        self.imageSize = imageSize
        self.roll = roll
    }

    var view: CommitView { CommitView(cameraTransform: transform, intrinsics: intrinsics, imageSize: imageSize) }

    /// World point to normalised image coordinates.
    func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
        let q = simd_mul(transform.inverse, SIMD4(p, 1))
        return SIMD2(intrinsics.z + intrinsics.x * q.x / -q.z, intrinsics.w - intrinsics.y * q.y / -q.z)
    }

    /// A detection of an upright object: `centre` is where the lifter would put it, `size` its width
    /// along world x and height along world y, metres. The box is clipped to the image.
    func detect(_ cls: ObjectClass, at centre: SIMD3<Float>, size: SIMD2<Float> = [0.08, 0.30],
                score: Float = 0.9, product: Int? = nil, position: SIMD3<Float>? = nil) -> Detection {
        let corners = [SIMD3<Float>(-1, -1, 0), [1, -1, 0], [1, 1, 0], [-1, 1, 0]].map {
            project(centre + $0 * SIMD3(size.x / 2, size.y / 2, 0))
        }
        let lo = corners.reduce(SIMD2<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
        let hi = corners.reduce(SIMD2<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
        let box = SIMD4(max(0, lo.x), max(0, lo.y), min(1, hi.x), min(1, hi.y))
        let imageAxes = roll % 2 == 0 ? size : SIMD2(size.y, size.x)
        return Detection(cls: cls, score: score, box: box, position: position ?? centre, size: imageAxes,
                         productKey: product)
    }
}

/// Bottles of a shelf row: `count` bottles 9 cm apart starting at `x0`, centres at height `y`.
func row(_ count: Int, x0: Float, y: Float = 1.0, z: Float = 0) -> [SIMD3<Float>] {
    (0..<count).map { SIMD3(x0 + 0.09 * Float($0), y, z) }
}

extension CommitResult {
    var newCount: Int { newItems.count }
}

/// A small deterministic generator for reproducible random tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
