import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd

/// One keyframe as the app hands it to the writer. Depth maps are in the sensor's orientation,
/// as ARKit delivers them; the intrinsics describe the stored image.
public struct CaptureFrame: @unchecked Sendable {   // the pixel buffer is only read
    public enum Image {
        case pixelBuffer(CVPixelBuffer)   // encoded to JPEG by the writer, off the main thread
        case jpeg(Data, width: Int, height: Int)
    }

    public var timestamp: TimeInterval
    public var image: Image
    public var depth: DepthMap?
    public var smoothedDepth: DepthMap?
    public var intrinsics: simd_float3x3
    public var cameraTransform: simd_float4x4
    public var orientation: FrameOrientation
    public var tracking: String
    public var mapping: String
    public var exposureDuration: Double?
    public var exposureOffset: Double?
    public var ambientIntensity: Double?
    public var ambientColorTemperature: Double?
    public var detections: [RawDetection]

    public init(timestamp: TimeInterval, image: Image, depth: DepthMap?, smoothedDepth: DepthMap? = nil,
                intrinsics: simd_float3x3, cameraTransform: simd_float4x4, orientation: FrameOrientation,
                tracking: String, mapping: String, exposureDuration: Double? = nil, exposureOffset: Double? = nil,
                ambientIntensity: Double? = nil, ambientColorTemperature: Double? = nil, detections: [RawDetection] = []) {
        self.timestamp = timestamp; self.image = image; self.depth = depth; self.smoothedDepth = smoothedDepth
        self.intrinsics = intrinsics; self.cameraTransform = cameraTransform; self.orientation = orientation
        self.tracking = tracking; self.mapping = mapping; self.exposureDuration = exposureDuration
        self.exposureOffset = exposureOffset; self.ambientIntensity = ambientIntensity
        self.ambientColorTemperature = ambientColorTemperature; self.detections = detections
    }
}

/// Writes a capture folder (see `CaptureFormat`). Every frame's files are written before its
/// line is appended to frames.jsonl, so a capture cut short by a crash is still readable.
public actor CaptureWriter {
    public nonisolated let folder: URL
    public private(set) var frameCount = 0
    public private(set) var bytesWritten = 0
    public var jpegQuality: Double = 0.8
    private let lines: FileHandle
    private let encoder = JSONEncoder()

    /// Creates `parent/capture-YYYYMMDD-HHMMSS/` with its manifest.
    public init(parent: URL, manifest: CaptureManifest) throws {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var folder = parent.appendingPathComponent("capture-\(stamp.string(from: manifest.created))")
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("capture-\(stamp.string(from: manifest.created))-\(n)")
            n += 1
        }
        for sub in ["images", "depth", "confidence", "smoothed", "smoothed_confidence"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        let jsonl = folder.appendingPathComponent("frames.jsonl")
        fm.createFile(atPath: jsonl.path, contents: nil)
        lines = try FileHandle(forWritingTo: jsonl)
        encoder.outputFormatting = [.sortedKeys]
        self.folder = folder
    }

    public func setJPEGQuality(_ q: Double) { jpegQuality = q }

    @discardableResult
    public func append(_ frame: CaptureFrame) throws -> CaptureFrameRecord {
        frameCount += 1
        let name = String(format: "%06d", frameCount)
        let jpeg: Data, size: [Int]
        switch frame.image {
        case .pixelBuffer(let b):
            jpeg = try JPEGEncoder.encode(b, quality: jpegQuality)
            size = [CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b)]
        case .jpeg(let data, let w, let h):
            jpeg = data
            size = [w, h]
        }
        var record = CaptureFrameRecord(
            index: frameCount, timestamp: frame.timestamp, image: "images/\(name).jpg", imageSize: size,
            intrinsics: CaptureFrameRecord.rows(frame.intrinsics), cameraTransform: CaptureFrameRecord.rows(frame.cameraTransform),
            orientation: frame.orientation, tracking: frame.tracking, mapping: frame.mapping,
            exposureDuration: frame.exposureDuration, exposureOffset: frame.exposureOffset,
            ambientIntensity: frame.ambientIntensity, ambientColorTemperature: frame.ambientColorTemperature,
            detections: frame.detections.map(CaptureDetection.init))
        try write(jpeg, record.image)
        if let d = frame.depth {
            record.depth = "depth/\(name).f32"
            record.depthSize = [d.width, d.height]
            try write(d.depthData, record.depth!)
            if let c = d.confidenceData {
                record.confidence = "confidence/\(name).u8"
                try write(c, record.confidence!)
            }
        }
        if let s = frame.smoothedDepth {
            record.smoothedDepth = "smoothed/\(name).f32"
            try write(s.depthData, record.smoothedDepth!)
            if let c = s.confidenceData {
                record.smoothedConfidence = "smoothed_confidence/\(name).u8"
                try write(c, record.smoothedConfidence!)
            }
        }
        var line = try encoder.encode(record)
        line.append(0x0A)
        try lines.write(contentsOf: line)
        bytesWritten += line.count
        return record
    }

    /// Closes frames.jsonl and returns the folder.
    public func finish() throws -> URL {
        try lines.synchronize()
        try lines.close()
        return folder
    }

    private func write(_ data: Data, _ path: String) throws {
        try data.write(to: folder.appendingPathComponent(path))
        bytesWritten += data.count
    }
}

/// JPEG from a camera buffer (YCbCr or BGRA) or an image, through Core Image and ImageIO.
public enum JPEGEncoder {
    public enum Problem: Error { case encodingFailed }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func encode(_ buffer: CVPixelBuffer, quality: Double = 0.8) throws -> Data {
        let image = CIImage(cvPixelBuffer: buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = context.jpegRepresentation(of: image, colorSpace: space, options: options) else {
            throw Problem.encodingFailed
        }
        return data
    }

    public static func encode(_ image: CGImage, quality: Double = 0.8) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw Problem.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Problem.encodingFailed }
        return data as Data
    }
}
