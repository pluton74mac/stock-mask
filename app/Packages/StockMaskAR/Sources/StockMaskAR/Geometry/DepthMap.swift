import CoreVideo
import Foundation

/// A LiDAR depth map as plain values: metres along the camera axis, row-major, with ARKit's
/// confidence per pixel. ARKit's `sceneDepth` is 256 x 192, aligned with the captured image
/// (same field of view, lower resolution). A value that is not finite or not above zero means
/// "no depth".
public struct DepthMap: Sendable, Equatable {
    public static let low: UInt8 = 0, medium: UInt8 = 1, high: UInt8 = 2   // ARConfidenceLevel raw values

    public let width: Int
    public let height: Int
    public var depth: [Float]
    /// nil when the source had no confidence map: every pixel with depth then counts as high.
    public var confidence: [UInt8]?

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]? = nil) {
        precondition(depth.count == width * height, "depth has \(depth.count) values for \(width) x \(height)")
        precondition(confidence.map { $0.count == width * height } ?? true, "confidence size mismatch")
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
    }

    public var size: SIMD2<Float> { SIMD2(Float(width), Float(height)) }

    @inline(__always) public func depthAt(_ x: Int, _ y: Int) -> Float { depth[y * width + x] }
    @inline(__always) public func confidenceAt(_ x: Int, _ y: Int) -> UInt8 { confidence?[y * width + x] ?? Self.high }
    @inline(__always) public static func isValid(_ d: Float) -> Bool { d.isFinite && d > 0 }

    /// The pixel columns and rows a normalised box covers (clamped; empty ranges when outside).
    public func pixels(of box: SIMD4<Float>) -> (xs: Range<Int>, ys: Range<Int>) {
        func span(_ a: Float, _ b: Float, _ n: Int) -> Range<Int> {
            let lo = max(0, min(n, Int((a * Float(n)).rounded(.down))))
            let hi = max(lo, min(n, Int((b * Float(n)).rounded(.up))))
            return lo..<hi
        }
        return (span(box.x, box.z, width), span(box.y, box.w, height))
    }

    /// This map (in the sensor's orientation, as ARKit delivers it) turned upright.
    public func upright(_ o: FrameOrientation) -> DepthMap {
        if o == .up { return self }
        let size = o.uprightSize(sensor: SIMD2(Float(width), Float(height)))
        let w2 = Int(size.x), h2 = Int(size.y)
        var d = [Float](repeating: 0, count: w2 * h2)
        var c: [UInt8]? = confidence.map { _ in [UInt8](repeating: 0, count: w2 * h2) }
        for y2 in 0..<h2 {
            for x2 in 0..<w2 {
                // Pixel centres map onto pixel centres under quarter turns.
                let s = o.sensorPoint(upright: SIMD2((Float(x2) + 0.5) / Float(w2), (Float(y2) + 0.5) / Float(h2)))
                let x = min(width - 1, Int(s.x * Float(width))), y = min(height - 1, Int(s.y * Float(height)))
                d[y2 * w2 + x2] = depth[y * width + x]
                c?[y2 * w2 + x2] = confidence![y * width + x]
            }
        }
        return DepthMap(width: w2, height: h2, depth: d, confidence: c)
    }

    /// Copies an ARKit depth map (`kCVPixelFormatType_DepthFloat32`) and its confidence map
    /// (`kCVPixelFormatType_OneComponent8`), so no camera buffer is held after the frame.
    public init?(depthBuffer: CVPixelBuffer, confidenceBuffer: CVPixelBuffer? = nil) {
        let format = CVPixelBufferGetPixelFormatType(depthBuffer)
        guard format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_OneComponent32Float else { return nil }
        let w = CVPixelBufferGetWidth(depthBuffer), h = CVPixelBufferGetHeight(depthBuffer)
        guard let d: [Float] = Self.copyPlane(depthBuffer, width: w, height: h) else { return nil }
        var c: [UInt8]?
        if let cb = confidenceBuffer {
            guard CVPixelBufferGetPixelFormatType(cb) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(cb) == w, CVPixelBufferGetHeight(cb) == h,
                  let copied: [UInt8] = Self.copyPlane(cb, width: w, height: h) else { return nil }
            c = copied
        }
        self.init(width: w, height: h, depth: d, confidence: c)
    }

    static func copyPlane<T>(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [T]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard rowBytes >= width * MemoryLayout<T>.stride else { return nil }
        var out = [T]()
        out.reserveCapacity(width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: T.self)
            out.append(contentsOf: UnsafeBufferPointer(start: row, count: width))
        }
        return out
    }
}

extension DepthMap {
    /// Little-endian raw bytes (the capture format's `.f32` / `.u8` files).
    public var depthData: Data { depth.withUnsafeBytes { Data($0) } }
    public var confidenceData: Data? { confidence.map { Data($0) } }

    public init?(width: Int, height: Int, depthData: Data, confidenceData: Data?) {
        guard depthData.count == width * height * 4 else { return nil }
        let d = depthData.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
        let c = confidenceData.map { [UInt8]($0) }
        if let c, c.count != width * height { return nil }
        self.init(width: width, height: height, depth: d, confidence: c)
    }
}
