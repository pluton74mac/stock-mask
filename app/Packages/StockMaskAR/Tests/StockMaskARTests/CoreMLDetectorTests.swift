import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
import StockMaskCounting
@testable import StockMaskAR

/// Runs the exported detector from Swift on macOS, through the app's own path (Vision + the DETR
/// decoder). The model and the parity frames are git-ignored (the frames come from venue footage),
/// so these tests are skipped when they are absent. Make them with:
///     ml/coreml/.venv/bin/python ml/coreml/export_detector.py
///     ml/coreml/.venv/bin/python ml/coreml/parity.py VIDEO
/// or point STOCKMASK_DETECTOR_PACKAGE / STOCKMASK_PARITY_DIR elsewhere.
enum LocalModel {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let package = ProcessInfo.processInfo.environment["STOCKMASK_DETECTOR_PACKAGE"].map(URL.init(fileURLWithPath:))
        ?? repo.appendingPathComponent("ml/coreml/out/StockMaskDetector.mlpackage")
    static let parity = ProcessInfo.processInfo.environment["STOCKMASK_PARITY_DIR"].map(URL.init(fileURLWithPath:))
        ?? repo.appendingPathComponent("ml/coreml/out/parity")
    static var available: Bool { FileManager.default.fileExists(atPath: package.path) }
    static var parityFrames: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: parity, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("frame_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let cache = FileManager.default.temporaryDirectory.appendingPathComponent("stockmask-test-models")

    static func detector(_ units: MLComputeUnits = .cpuAndGPU) async throws -> CoreMLDetector {
        let compiled = try await DetectorModelLocator.compiled(package, cache: cache)
        return try CoreMLDetector(compiledModelURL: compiled, computeUnits: units)
    }
}

struct ParityFixture: Decodable {
    struct Box: Decodable { var label: String; var score: Float; var box: [Float] }
    var image: String
    var width: Int
    var height: Int
    var commit: Float
    var torch: [Box]
}

@Suite("Core ML detector on macOS", .serialized, .enabled(if: LocalModel.available, "no exported model in ml/coreml/out"))
struct CoreMLDetectorTests {
    @Test func classListComesFromTheModel() async throws {
        let d = try await LocalModel.detector()
        #expect(d.info.classNames.count == 91)            // COCO's sparse category ids
        #expect(d.info.classNames[44] == "bottle")
        #expect(d.info.countedClasses == [.bottle])       // COCO knows none of can, case, bottle_top
        #expect(d.info.inputSize == SIMD2(384, 384))
        #expect(d.info.scoreShown == 0.3 && d.info.scoreCommit == 0.5)
    }

    @Test func runsOnASyntheticImage() async throws {
        let d = try await LocalModel.detector()
        let out = try await d.detect(DetectorInput(image: Self.gradient(width: 480, height: 640)))
        #expect(out.milliseconds > 0)
        #expect(out.detections.count < 300)
        for det in out.detections {
            #expect(det.score > 0.3)
            #expect(det.box.x >= 0 && det.box.z <= 1 && det.box.x <= det.box.z && det.box.y <= det.box.w)
        }
    }

    /// The same frames as ml/coreml/parity.py, through Vision instead of a numpy resize: the
    /// bottles at >= 0.5 must pair up with PyTorch's (IoU >= 0.5), allowing for scores within 0.05
    /// of the threshold.
    @Test(.enabled(if: !LocalModel.parityFrames.isEmpty, "no parity frames in ml/coreml/out/parity"))
    func matchesPyTorchOnVenueFrames() async throws {
        let d = try await LocalModel.detector(.cpuAndGPU)
        var reference = 0, ours = 0, failures: [String] = []
        for url in LocalModel.parityFrames {
            let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: url))
            let image = try #require(Self.load(LocalModel.parity.appendingPathComponent(fixture.image)))
            let out = try await d.detect(DetectorInput(image: image))
            let swift = out.detections.filter { $0.cls != nil }
            let torch = fixture.torch.map { RawDetection(label: $0.label, score: $0.score, box: SIMD4($0.box[0], $0.box[1], $0.box[2], $0.box[3])) }
            let r = Self.compare(torch, swift, threshold: fixture.commit)
            reference += torch.filter { $0.score >= fixture.commit }.count
            ours += swift.filter { $0.score >= fixture.commit }.count
            print("\(fixture.image): PyTorch \(r.reference), Swift \(r.candidate), pairs \(r.pairs), mean IoU \(String(format: "%.3f", r.meanIoU)), max Δscore \(String(format: "%.3f", r.maxDelta)), \(Int(out.milliseconds)) ms")
            if !r.ok { failures.append(fixture.image) }
        }
        print("Swift (ModelInputResizer + Core ML, CPU+GPU): \(ours) bottles >= 0.5 vs PyTorch \(reference) over \(LocalModel.parityFrames.count) frames")
        #expect(failures.isEmpty, "frames with a confident box on one side only: \(failures)")
    }

    struct Comparison { var reference = 0, candidate = 0, pairs = 0; var meanIoU: Float = 1, maxDelta: Float = 0; var ok = true }

    /// Greedy 1:1 pairing by IoU (best first); fails on a confident box (>= threshold + 0.05) without
    /// a partner, or a pair whose scores fall on opposite sides of the threshold by more than that.
    static func compare(_ a: [RawDetection], _ b: [RawDetection], threshold: Float) -> Comparison {
        var c = Comparison()
        c.reference = a.filter { $0.score >= threshold }.count
        c.candidate = b.filter { $0.score >= threshold }.count
        var pairs: [(iou: Float, i: Int, j: Int)] = []
        for (i, x) in a.enumerated() {
            for (j, y) in b.enumerated() where x.label == y.label {
                let v = LiveTracks.iou(x.box, y.box)
                if v >= 0.5 { pairs.append((v, i, j)) }
            }
        }
        var ua = Set<Int>(), ub = Set<Int>(), ious: [Float] = []
        for p in pairs.sorted(by: { $0.iou > $1.iou }) where !ua.contains(p.i) && !ub.contains(p.j) {
            ua.insert(p.i); ub.insert(p.j); ious.append(p.iou)
            let s = a[p.i].score, t = b[p.j].score
            c.maxDelta = max(c.maxDelta, abs(s - t))
            if (s >= threshold + 0.05 && t < threshold) || (t >= threshold + 0.05 && s < threshold) { c.ok = false }
        }
        c.pairs = ious.count
        c.meanIoU = ious.isEmpty ? 1 : ious.reduce(0, +) / Float(ious.count)
        let lonely = a.indices.filter { !ua.contains($0) }.map { a[$0].score } + b.indices.filter { !ub.contains($0) }.map { b[$0].score }
        if lonely.contains(where: { $0 >= threshold + 0.05 }) { c.ok = false }
        return c
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func gradient(width: Int, height: Int) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                px[i] = UInt8(x * 255 / width); px[i + 1] = UInt8(y * 255 / height); px[i + 2] = 128
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }
}
