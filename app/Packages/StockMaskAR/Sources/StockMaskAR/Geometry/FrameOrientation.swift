import CoreGraphics
import ImageIO
import simd

/// How the camera's stored image (ARKit's `capturedImage`, always in the sensor's landscape
/// orientation) turns to stand upright on screen. Names follow `CGImagePropertyOrientation`: a
/// portrait app with the back camera uses `.right`.
///
/// Everything downstream of the frame conversion works in the **upright image**: detector boxes,
/// the inner frame, the camera model and the depth map. This type is the only place where the
/// sensor orientation appears.
public enum FrameOrientation: String, Codable, Sendable, CaseIterable {
    case up, right, down, left

    public var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    /// Upright size from the sensor image's size (width and height swap for `.left`/`.right`).
    public func uprightSize(sensor s: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .up, .down: s
        case .left, .right: SIMD2(s.y, s.x)
        }
    }

    /// A normalised point (origin top-left) of the sensor image, in the upright image.
    public func uprightPoint(sensor p: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .up: p
        case .right: SIMD2(1 - p.y, p.x)      // turned 90° clockwise
        case .down: SIMD2(1 - p.x, 1 - p.y)
        case .left: SIMD2(p.y, 1 - p.x)       // turned 90° anticlockwise
        }
    }

    /// The inverse of `uprightPoint(sensor:)`.
    public func sensorPoint(upright p: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .up: p
        case .right: SIMD2(p.y, 1 - p.x)
        case .down: SIMD2(1 - p.x, 1 - p.y)
        case .left: SIMD2(1 - p.y, p.x)
        }
    }

    /// A normalised box (x0, y0, x1, y1) of the upright image, in the sensor image.
    public func sensorBox(upright b: SIMD4<Float>) -> SIMD4<Float> {
        Self.box(sensorPoint(upright: SIMD2(b.x, b.y)), sensorPoint(upright: SIMD2(b.z, b.w)))
    }

    /// A normalised box (x0, y0, x1, y1) of the sensor image, in the upright image.
    public func uprightBox(sensor b: SIMD4<Float>) -> SIMD4<Float> {
        Self.box(uprightPoint(sensor: SIMD2(b.x, b.y)), uprightPoint(sensor: SIMD2(b.z, b.w)))
    }

    static func box(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD4<Float> {
        SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
    }

    /// The upright camera's axes (columns) in the sensor camera's coordinates. ARKit's camera
    /// looks along -z with +x to the sensor image's right and +y to its top; the upright camera
    /// keeps z and turns x and y with the image.
    public var cameraRotation: simd_float3x3 {
        switch self {
        case .up: matrix_identity_float3x3
        case .right: simd_float3x3(columns: (SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)))
        case .down: simd_float3x3(columns: (SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)))
        case .left: simd_float3x3(columns: (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)))
        }
    }
}
