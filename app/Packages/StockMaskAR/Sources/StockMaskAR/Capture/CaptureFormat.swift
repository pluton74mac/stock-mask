import Foundation
import simd

/// Capture mode's file format, version 1 (P0-2: "keyframe JPEG + depth + confidence + pose +
/// intrinsics at 1-2 Hz"). Documented for readers in research/capture_replay/README.md; the
/// Python reader is research/capture_replay/read_capture.py.
///
/// ```
/// capture-YYYYMMDD-HHMMSS/
///   manifest.json                  CaptureManifest
///   frames.jsonl                   one CaptureFrameRecord per line, in time order
///   images/000001.jpg              ARFrame.capturedImage, as stored (sensor orientation)
///   depth/000001.f32               sceneDepth: float32 little-endian metres, row-major
///   confidence/000001.u8           sceneDepth confidence: 0 low, 1 medium, 2 high
///   smoothed/000001.f32            smoothedSceneDepth (when present)
///   smoothed_confidence/000001.u8
/// ```
/// Images and depth are stored as the sensor delivers them (landscape); `orientation` says how
/// they turn upright. Matrices are written as rows. Detections are in the upright image.
public enum CaptureFormat {
    public static let name = "stockmask-capture"
    public static let version = 1
}

public struct CaptureManifest: Codable, Sendable, Equatable {
    public var format = CaptureFormat.name
    public var version = CaptureFormat.version
    public var created: Date
    public var app: String
    public var device: String          // model identifier, e.g. "iPhone14,2"; never a location
    public var system: String
    public var rateHz: Double
    public var orientation: FrameOrientation
    public var detector: String
    public var notes: String

    public init(created: Date = Date(), app: String, device: String, system: String, rateHz: Double,
                orientation: FrameOrientation, detector: String, notes: String = "") {
        self.created = created; self.app = app; self.device = device; self.system = system; self.rateHz = rateHz
        self.orientation = orientation; self.detector = detector; self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case format, version, created, app, device, system, orientation, detector, notes
        case rateHz = "rate_hz"
    }
}

public struct CaptureDetection: Codable, Sendable, Equatable {
    public var label: String
    public var score: Float
    public var box: [Float]            // x0, y0, x1, y1, normalised, upright image

    public init(_ d: RawDetection) {
        label = d.label
        score = d.score
        box = [d.box.x, d.box.y, d.box.z, d.box.w]
    }
}

public struct CaptureFrameRecord: Codable, Sendable, Equatable {
    public var index: Int
    public var timestamp: Double       // seconds, ARFrame.timestamp (device uptime clock)
    public var image: String
    public var imageSize: [Int]        // width, height of the stored image
    public var depth: String?
    public var confidence: String?
    public var depthSize: [Int]?       // width, height
    public var smoothedDepth: String?
    public var smoothedConfidence: String?
    public var intrinsics: [[Float]]   // 3 x 3 rows: fx 0 cx / 0 fy cy / 0 0 1, pixels of the stored image
    public var cameraTransform: [[Float]]   // 4 x 4 rows, camera to world (ARKit: camera looks along -z)
    public var orientation: FrameOrientation
    public var tracking: String
    public var mapping: String
    public var exposureDuration: Double?
    public var exposureOffset: Double?
    public var ambientIntensity: Double?          // lumens (ARKit's estimate; ~1000 is a well-lit room)
    public var ambientColorTemperature: Double?
    public var detections: [CaptureDetection]

    enum CodingKeys: String, CodingKey {
        case index, timestamp, image, depth, confidence, intrinsics, orientation, tracking, mapping, detections
        case imageSize = "image_size", depthSize = "depth_size", smoothedDepth = "smoothed_depth"
        case smoothedConfidence = "smoothed_confidence", cameraTransform = "camera_transform"
        case exposureDuration = "exposure_duration", exposureOffset = "exposure_offset"
        case ambientIntensity = "ambient_intensity", ambientColorTemperature = "ambient_color_temperature"
    }

    public var intrinsicsMatrix: simd_float3x3 { Self.matrix3(intrinsics) }
    public var transformMatrix: simd_float4x4 { Self.matrix4(cameraTransform) }

    /// The sensor camera of this frame.
    public var camera: CameraModel {
        CameraModel(intrinsics: intrinsicsMatrix, imageSize: SIMD2(Float(imageSize[0]), Float(imageSize[1])),
                    transform: transformMatrix)
    }

    static func rows(_ m: simd_float3x3) -> [[Float]] { (0..<3).map { r in (0..<3).map { c in m[c][r] } } }
    static func rows(_ m: simd_float4x4) -> [[Float]] { (0..<4).map { r in (0..<4).map { c in m[c][r] } } }
    static func matrix3(_ r: [[Float]]) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(r[0][0], r[1][0], r[2][0]), SIMD3(r[0][1], r[1][1], r[2][1]), SIMD3(r[0][2], r[1][2], r[2][2])))
    }
    static func matrix4(_ r: [[Float]]) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(r[0][0], r[1][0], r[2][0], r[3][0]), SIMD4(r[0][1], r[1][1], r[2][1], r[3][1]),
                                SIMD4(r[0][2], r[1][2], r[2][2], r[3][2]), SIMD4(r[0][3], r[1][3], r[2][3], r[3][3])))
    }
}

/// When to take a keyframe: at most `rateHz`, and never while the previous one is still being written.
public struct CaptureScheduler: Sendable {
    public var rateHz: Double
    private var last: TimeInterval?

    public init(rateHz: Double = 2) { self.rateHz = rateHz }

    public mutating func shouldCapture(at t: TimeInterval, writerBusy: Bool) -> Bool {
        guard !writerBusy else { return false }
        if let last, t - last < 1 / rateHz - 1e-3 { return false }
        last = t
        return true
    }

    public mutating func reset() { last = nil }
}
