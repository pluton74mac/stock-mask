import Foundation
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

/// Holds each run until the test lets it finish: a detector slower than the camera's frames (the
/// GPU sharing time with RealityKit, an unoptimised build).
actor GatedDetector: Detector {
    nonisolated let info = DetectorInfo(classNames: ["", "bottle"], scoreShown: 0.3, scoreCommit: 0.5)
    private var next: [RawDetection] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var runs = 0

    func set(_ d: [RawDetection]) { next = d }
    var isWaiting: Bool { waiting != nil }

    func release() {
        waiting?.resume()
        waiting = nil
    }

    func detect(_ input: DetectorInput) async throws -> DetectorOutput {
        runs += 1
        await withCheckedContinuation { waiting = $0 }
        return DetectorOutput(detections: next, milliseconds: 350)
    }
}

/// The lines of a diagnostic log, as JSON objects.
func records(_ log: DiagnosticsLog) throws -> [[String: Any]] {
    log.flush()
    return try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@Suite("Diagnostics and slow detectors", .serialized)
@MainActor
struct DiagnosticsTests {
    func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
    }

    @Test func aSlowerDetectorWidensTheStableWindow() {
        var t = LiveTracks()
        let o = LiveTracks.Observation(cls: .bottle, score: 0.8, box: SIMD4(0.4, 0.4, 0.5, 0.6), position: SIMD3(0, 0, -1))
        t.detectorPeriod = 0.4
        #expect(abs(t.effectiveWindow - 1.0) < 1e-9)            // 2 periods, 25% spare
        for i in 0..<3 { t.update([o], at: Double(i) * 0.4) }
        #expect(t.stable(at: 0.8).count == 1)
        // A fast detector keeps ADR 003's 0.5 s; a very slow one is capped.
        t.detectorPeriod = 0.05
        #expect(t.effectiveWindow == 0.5)
        t.detectorPeriod = 2
        #expect(t.effectiveWindow == 1.5 && t.effectiveMaxAge == 5)
    }

    /// The bug of 2 October: with the detector slower than one run per 250 ms, three hits never fit
    /// in 0.5 s, no candidate became stable and nothing counted. A run every ~0.37 s counts now.
    @Test func aDetectorSlowerThan250msStillCounts() async throws {
        let store = try CoreStockStore.inMemory()
        let detector = GatedDetector()
        let session = CountingSession(store: store, detector: detector)
        let log = try DiagnosticsLog(folder: temporaryFolder())
        session.diagnostics = log
        session.environment = FakeEnvironment()
        try await store.startSession(venue: CoreStockStore.defaultVenue, zone: "Storeroom", counter: "Tester")
        let scene = SessionTests.shelf
        await detector.set(scene.detections())
        let pump = FramePump(session: session)
        var t = 0.0, started: Double?, countedAt: Double?
        while t < 2.5 {
            let now = t
            let frame = FrameSnapshot(timestamp: now, camera: scene.camera, tracking: .normal, planes: [scene.plane])
            pump.process(light: frame,
                         full: { FrameSnapshot(timestamp: now, camera: scene.camera, depth: scene.depthMap(), planes: [scene.plane]) },
                         image: { DetectorInput(image: tinyImage) },
                         captureFrame: { _ in fatalError("no capture") })
            await pump.committing?.value
            if await detector.isWaiting {
                if started == nil { started = now }
                if now - started! >= 0.35 - 1e-9 {
                    await detector.release()
                    await pump.inFlight?.value
                    started = nil
                }
            }
            if session.commits > 0, countedAt == nil { countedAt = now }
            t += 1.0 / 60
        }
        #expect(session.commits == 1)
        #expect(session.sheet.totalUnits == 3)
        let counted = try #require(countedAt)
        #expect(counted > 1 && counted < 2, "counted after \(counted) s")
        #expect(session.stableWindow > 0.85)                      // stretched to fit three runs

        let lines = try records(log)
        let samples = lines.filter { $0["type"] as? String == "sample" }
        #expect(samples.count >= 2)
        let periods = samples.compactMap { $0["detectorPeriod"] as? Double }
        #expect(periods.contains { $0 > 0.34 && $0 < 0.4 })
        #expect(samples.allSatisfy { $0["why"] is String && $0["hold"] is String && $0["stableTracks"] is Int })
        let commit = try #require(lines.first { $0["type"] as? String == "commit" })
        #expect(commit["newItems"] as? Int == 3 && commit["trigger"] as? String == "hold")
        #expect((commit["statuses"] as? [String: Int])?["new"] == 3)
    }

    /// A hold never commits dashed outlines alone: that would mark an empty counted zone, and the
    /// bottles there would later come up as possible misses instead of counting.
    @Test func outlinesBelowTheCommitScoreNeverHoldACommit() async throws {
        let walk = try await Walk(SessionTests.shelf)
        walk.score = 0.4                                  // shown (0.3), not countable (0.5)
        await walk.hold(1.5)
        #expect(walk.session.commits == 0)
        #expect(walk.session.boxes.count == 3 && walk.session.boxes.allSatisfy { $0.style == .lowConfidence })
        #expect(walk.session.whyNoCommit().contains("below the commit score"), "\(walk.session.whyNoCommit())")
        walk.score = 0.8
        await walk.hold(0.3)
        #expect(walk.session.commits == 1 && walk.session.sheet.totalUnits == 3)
    }

    @Test func theLogSaysWhyNothingCounts() async throws {
        let log = try DiagnosticsLog(folder: temporaryFolder(), prefix: "test")
        #expect(log.url.lastPathComponent.hasPrefix("test-") && log.url.pathExtension == "jsonl")
        let walk = try await Walk(SessionTests.shelf)
        walk.session.diagnostics = log
        walk.session.autoCount = false
        await walk.hold(1.2)
        #expect(walk.session.whyNoCommit() == "auto-count off")
        walk.session.autoCount = true
        walk.tracking = .limited(.relocalizing)
        await walk.hold(0.6)
        #expect(walk.session.whyNoCommit().hasPrefix("paused:"))
        walk.session.log("custom", "a test event", ["k": "v"])
        let lines = try records(log)
        #expect(lines.filter { $0["type"] as? String == "sample" }.count >= 3)   // about 2 Hz
        #expect(lines.contains { $0["why"] as? String == "auto-count off" })
        let event = try #require(lines.first { $0["kind"] as? String == "custom" })
        #expect((event["details"] as? [String: String])?["k"] == "v")
        // A second log made in the same second gets its own file.
        let other = try DiagnosticsLog(folder: log.url.deletingLastPathComponent(), prefix: "test",
                                       now: try #require(log.url.creationDate))
        #expect(other.url != log.url)
    }

    @Test func benchmarkComparisonPairsDetectionsByOverlap() {
        let a = [RawDetection(label: "bottle", score: 0.62, box: SIMD4(0.1, 0.1, 0.2, 0.5)),
                 RawDetection(label: "bottle", score: 0.48, box: SIMD4(0.3, 0.1, 0.4, 0.5)),
                 RawDetection(label: "can", score: 0.9, box: SIMD4(0.6, 0.6, 0.7, 0.7))]
        let b = [RawDetection(label: "bottle", score: 0.58, box: SIMD4(0.101, 0.1, 0.2, 0.5)),
                 RawDetection(label: "bottle", score: 0.52, box: SIMD4(0.3, 0.1, 0.4, 0.501))]
        let c = DetectorBenchmark.compare(("Neural Engine", [a]), ("GPU", [b]), commitScore: 0.5)
        #expect(c.paired == 2 && c.onlyReference == 1 && c.onlyOther == 0)
        #expect(abs((c.meanDelta ?? 9) - 0) < 1e-5 && abs((c.maxAbsDelta ?? 0) - 0.04) < 1e-5)
        #expect(c.commitFlips == 1)
    }
}

extension URL {
    /// The date a log file's name carries (yyyyMMdd-HHmmss), for making a second log in the same second.
    var creationDate: Date? {
        let parts = deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: "\(parts[1])-\(parts[2])")
    }
}
