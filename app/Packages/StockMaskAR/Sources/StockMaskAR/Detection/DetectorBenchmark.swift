import CoreML
import CoreVideo
import Foundation

/// One compute unit's numbers: the detector end to end (resize, Core ML, decoding) on a
/// camera-sized frame, outside the AR session, and its scores on real frames when there are any
/// (the keyframes of earlier commits). The counting screen's diagnostics samples give the same
/// timings with ARKit and RealityKit running.
public struct DetectorBenchmarkResult: Codable, Sendable, Equatable {
    public var type = "benchmark"
    public var time = Date()
    public var computeUnits: String
    public var loadMs: Double?
    public var firstMs: Double?
    public var p50Ms: Double?
    public var p95Ms: Double?
    public var runs: Int
    public var resizeP50Ms: Double?
    public var detections: Int?        // on the synthetic frame: noise, so usually none
    public var outputs: String         // output names, element types, shapes and strides
    public var frames: [FrameScores] = []
    public var error: String?
}

/// What one compute unit saw on one real frame.
public struct FrameScores: Codable, Sendable, Equatable {
    public var frame: Int
    public var ms: Double
    public var shown: Int              // above the model's shown threshold
    public var commit: Int             // above its commit threshold
    public var maxScore: Float?
    public var top: [Float]            // the ten best scores, rounded to 3 decimals
}

/// Two compute units on the same real frames: detections paired by label and overlap (IoU ≥ 0.7).
/// A constant score offset (`meanDelta`) would mean a different score scale; a large spread with
/// no offset is FP16 noise.
public struct DetectorComparison: Codable, Sendable, Equatable {
    public var type = "benchmark_compare"
    public var time = Date()
    public var reference: String
    public var other: String
    public var paired: Int
    public var onlyReference: Int
    public var onlyOther: Int
    public var meanDelta: Float?       // other - reference
    public var meanAbsDelta: Float?
    public var maxAbsDelta: Float?
    public var commitFlips: Int        // pairs on different sides of the commit threshold
}

public enum DetectorBenchmark {
    /// The GPU first: it loads in a moment, while the Neural Engine compiles the model for itself the
    /// first time (after each install), which can take a while.
    public static let units: [(name: String, units: MLComputeUnits)] = [
        ("GPU", .cpuAndGPU), ("Neural Engine", .cpuAndNeuralEngine), ("CPU", .cpuOnly),
    ]

    /// Benchmarks each compute unit in turn (the model is loaded once per unit), on a synthetic
    /// camera frame for timing and on `frames` (real pictures, upright) for the scores.
    public static func run(compiledModelURL url: URL, runs: Int = 10, frames: [DetectorInput] = [],
                           units: [(name: String, units: MLComputeUnits)] = units) async -> [DetectorBenchmarkResult] {
        await runWithDetections(compiledModelURL: url, runs: runs, frames: frames, units: units).map(\.result)
    }

    /// `run`, plus the detections on each real frame (for `compare`). `stage` hears what is starting
    /// ("loading the model on the GPU"), `finished` each unit's result as soon as it is done, so an
    /// interrupted run still leaves its first results behind.
    public static func runWithDetections(compiledModelURL url: URL, runs: Int = 10, frames: [DetectorInput] = [],
                                         units: [(name: String, units: MLComputeUnits)] = units,
                                         stage: (@Sendable (String) async -> Void)? = nil,
                                         finished: (@Sendable (DetectorBenchmarkResult) async -> Void)? = nil)
        async -> [(result: DetectorBenchmarkResult, detections: [[RawDetection]], commitScore: Float)] {
        let input = DetectorInput(pixelBuffer: syntheticCameraFrame(), orientation: .right)
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var resize = LatencyStats(capacity: runs)
        for _ in 0..<runs {
            let d = clock.measure { _ = try? ModelInputResizer.resize(input, to: SIMD2(384, 384)) }
            resize.add(ms(d))
        }
        var results: [(result: DetectorBenchmarkResult, detections: [[RawDetection]], commitScore: Float)] = []
        for (name, u) in units {
            var r = DetectorBenchmarkResult(computeUnits: name, runs: runs, resizeP50Ms: resize.p50, outputs: "")
            var seen: [[RawDetection]] = []
            var commitScore: Float = 0.5
            do {
                await stage?("loading the model on the \(name)")
                let start = clock.now
                let detector = try CoreMLDetector(compiledModelURL: url, computeUnits: u)
                commitScore = detector.info.scoreCommit
                r.loadMs = ms(clock.now - start)
                await stage?("running the detector on the \(name)")
                let first = try await detector.detect(input)
                r.firstMs = first.milliseconds
                var stats = LatencyStats(capacity: runs)
                var last = first
                for _ in 0..<runs {
                    last = try await detector.detect(input)
                    stats.add(last.milliseconds)
                }
                r.p50Ms = stats.p50
                r.p95Ms = stats.p95
                r.detections = last.detections.count
                r.outputs = await detector.lastOutputInfo
                for (i, frame) in frames.enumerated() {
                    let out = try await detector.detect(frame)
                    let scores = out.detections.map(\.score).sorted(by: >)
                    r.frames.append(FrameScores(frame: i, ms: out.milliseconds, shown: scores.count,
                                                commit: scores.filter { $0 >= detector.info.scoreCommit }.count,
                                                maxScore: scores.first,
                                                top: scores.prefix(10).map { ($0 * 1000).rounded() / 1000 }))
                    seen.append(out.detections)
                }
            } catch {
                r.error = "\(error)"
            }
            await finished?(r)
            results.append((r, seen, commitScore))
        }
        return results
    }

    /// Pairs the detections of two compute units frame by frame (same label, IoU ≥ 0.7, best first).
    public static func compare(_ reference: (name: String, detections: [[RawDetection]]),
                               _ other: (name: String, detections: [[RawDetection]]),
                               commitScore: Float) -> DetectorComparison {
        var deltas: [Float] = []
        var onlyReference = 0, onlyOther = 0, flips = 0
        for (a, b) in zip(reference.detections, other.detections) {
            var pairs: [(iou: Float, i: Int, j: Int)] = []
            for (i, x) in a.enumerated() {
                for (j, y) in b.enumerated() where x.label == y.label {
                    let v = LiveTracks.iou(x.box, y.box)
                    if v >= 0.7 { pairs.append((v, i, j)) }
                }
            }
            var usedA = Set<Int>(), usedB = Set<Int>()
            for p in pairs.sorted(by: { $0.iou > $1.iou }) where !usedA.contains(p.i) && !usedB.contains(p.j) {
                usedA.insert(p.i)
                usedB.insert(p.j)
                let d = b[p.j].score - a[p.i].score
                deltas.append(d)
                if (a[p.i].score >= commitScore) != (b[p.j].score >= commitScore) { flips += 1 }
            }
            onlyReference += a.count - usedA.count
            onlyOther += b.count - usedB.count
        }
        let n = Float(deltas.count)
        return DetectorComparison(
            reference: reference.name, other: other.name, paired: deltas.count, onlyReference: onlyReference,
            onlyOther: onlyOther, meanDelta: deltas.isEmpty ? nil : deltas.reduce(0, +) / n,
            meanAbsDelta: deltas.isEmpty ? nil : deltas.map(abs).reduce(0, +) / n,
            maxAbsDelta: deltas.map(abs).max(), commitFlips: flips)
    }

    /// A 1920 x 1440 YCbCr buffer of noise, like ARKit's captured image.
    public static func syntheticCameraFrame(width: Int = 1920, height: Int = 1440) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &b)
        let buffer = b!
        CVPixelBufferLockBaseAddress(buffer, [])
        var seed: UInt32 = 12345
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let n = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            for k in 0..<n {
                seed = seed &* 1664525 &+ 1013904223
                base[k] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
