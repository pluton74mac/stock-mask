import CoreVideo
import Foundation
import Testing
import simd
@testable import StockMaskAR

@Suite("Capture format")
struct CaptureTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cameraBuffer() throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &b)
        let buffer = try #require(b)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), 90, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 48)
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 24)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func writesAndReadsBack() async throws {
        let parent = try tempDir()
        let manifest = CaptureManifest(created: Date(timeIntervalSince1970: 1_790_000_000), app: "test", device: "Mac",
                                       system: "macOS", rateHz: 2, orientation: .right, detector: "none")
        let writer = try CaptureWriter(parent: parent, manifest: manifest)
        var k = matrix_identity_float3x3
        k[0][0] = 50; k[1][1] = 51; k[2][0] = 32; k[2][1] = 24
        let pose = yaw(30, at: SIMD3(1, 1.4, -2))
        let depth = DepthMap(width: 4, height: 3, depth: (0..<12).map { 0.5 + Float($0) * 0.1 }, confidence: [UInt8](repeating: 2, count: 12))
        for i in 0..<3 {
            try await writer.append(CaptureFrame(
                timestamp: 100 + Double(i) * 0.5, image: .pixelBuffer(try cameraBuffer()), depth: depth, smoothedDepth: depth,
                intrinsics: k, cameraTransform: pose, orientation: .right, tracking: "normal", mapping: "mapped",
                ambientIntensity: 900, detections: [RawDetection(label: "bottle", score: 0.8, box: SIMD4(0.1, 0.2, 0.3, 0.6))]))
        }
        let folder = try await writer.finish()

        let r = try CaptureReader(folder: folder)
        #expect(r.manifest == manifest)
        #expect(r.frames.count == 3)
        let f = r.frames[1]
        #expect(f.index == 2 && f.timestamp == 100.5 && f.image == "images/000002.jpg" && f.imageSize == [64, 48])
        #expect(f.intrinsicsMatrix == k)
        #expect(f.transformMatrix == pose)
        #expect(f.intrinsics[0] == [50, 0, 32])   // rows, as written for Python
        #expect(try r.depth(f) == depth)
        #expect(try r.smoothedDepth(f) == depth)
        #expect(f.detections.first?.box == [0.1, 0.2, 0.3, 0.6])
        let jpeg = try r.imageData(f)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        // The raw files are exactly what read_capture.py expects.
        let raw = try Data(contentsOf: folder.appendingPathComponent(f.depth!))
        #expect(raw.count == 12 * 4)
        #expect(raw.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) } == Float(0.6))

        let zip = try CaptureArchive.zip(folder, to: parent)
        let header = try Data(contentsOf: zip).prefix(2)
        #expect(Array(header) == [0x50, 0x4B])   // "PK"

        // For checking research/capture_replay/read_capture.py against what Swift writes.
        if let keep = ProcessInfo.processInfo.environment["STOCKMASK_CAPTURE_OUT"] {
            let out = URL(fileURLWithPath: keep)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: out.appendingPathComponent(folder.lastPathComponent))
            try FileManager.default.copyItem(at: zip, to: out.appendingPathComponent(zip.lastPathComponent))
        }
    }

    @Test func schedulerKeepsTheRateAndWaitsForTheWriter() {
        var s = CaptureScheduler(rateHz: 2)
        let answers = [s.shouldCapture(at: 0, writerBusy: false), s.shouldCapture(at: 0.3, writerBusy: false),
                       s.shouldCapture(at: 0.6, writerBusy: true), s.shouldCapture(at: 0.6, writerBusy: false)]
        #expect(answers == [true, false, false, true])
    }
}
