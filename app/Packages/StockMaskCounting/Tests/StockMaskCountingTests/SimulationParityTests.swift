import Foundation
import simd
import Testing
import StockMaskCounting

/// Parity with research/dedup_sim/sim.py's strategy S5: each fixture is a seeded storeroom counted
/// and revisited by the simulation (Fixtures/make_fixtures.py). The engine is given the same views
/// and detections and must reach the same decision for every detection, the same drift offset for
/// every commit, and the same double-count, miss and prompt totals.
@Suite("Parity with the simulation")
struct SimulationParityTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static var fixtureNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix("sim-") && $0.hasSuffix(".json") }.sorted()
    }

    @Test("The fixtures are there")
    func fixturesExist() {
        #expect(Self.fixtureNames.count >= 15)
    }

    @Test("Same decisions, offsets and totals as sim.py", arguments: fixtureNames)
    func replay(_ file: String) throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent(file))
        let fixture = try JSONDecoder().decode(SimFixture.self, from: data)
        let outcome = Self.run(fixture)
        #expect(outcome.mismatches.isEmpty,
                "\(outcome.mismatches.count) of \(outcome.detections) decisions differ; first: \(outcome.mismatches.prefix(5))")
        #expect(outcome.offsetMismatches.isEmpty, "drift offsets differ at commits \(outcome.offsetMismatches.prefix(10))")
        #expect(outcome.metrics == fixture.expected)
        // The fixture's own checks: its replay is sim.run_once, and float32 inputs changed nothing.
        #expect(fixture.expected == fixture.runOnce)
        #expect(fixture.float32ChangedDecisions == 0)
    }

    struct Outcome {
        var metrics: SimFixture.Metrics
        var detections = 0
        var mismatches: [String] = []
        var offsetMismatches: [Int] = []
    }

    static func run(_ fixture: SimFixture) -> Outcome {
        var p = CommitEngine.Parameters()
        p.innerFrame = InnerFrame(band: fixture.camera.band)
        p.minimumScore = 0
        p.zoneDepthMargin = 1000  // the simulation's zones are flat rectangles, unbounded in depth
        p.matchGate = fixture.parameters.gate
        p.metricWeights = SIMD3(fixture.parameters.metric[0], fixture.parameters.metric[1], fixture.parameters.metric[2])
        p.driftSearch = fixture.parameters.search
        p.driftGrid = fixture.parameters.grid
        var engine = CommitEngine(parameters: p)
        let classes = fixture.classes.map { ObjectClass(rawValue: $0)! }
        let c = fixture.camera
        var order: [UUID: Int] = [:]  // counted item -> its index in the simulation's counted list
        var truth: [Int] = []  // per counted item, the true object it is
        var prompted = Set<Int>()
        var outcome = Outcome(metrics: fixture.expected)
        for (k, commit) in fixture.commits.enumerated() {
            if commit.resetDrift { engine.resetDriftEstimate() }
            var pose = matrix_identity_float4x4  // looking along -z at the rack, from DISTANCE away
            pose.columns.3 = SIMD4(commit.camera[0], commit.camera[1], commit.camera[2], 1)
            let view = CommitView(cameraTransform: pose,
                                  intrinsics: SIMD4(c.intrinsics[0], c.intrinsics[1], c.intrinsics[2], c.intrinsics[3]),
                                  imageSize: SIMD2(c.image[0], c.image[1]), sceneDepth: Float(c.distance))
            let detections = commit.detections.map { d in
                Detection(cls: classes[d.cls], score: 1, box: SIMD4(d.u, d.v, d.u, d.v), position: SIMD3(d.x, d.y, d.z),
                          productKey: d.suggested)
            }
            let result = engine.commit(detections, view: view)
            let expectedOffset = SIMD3<Float>(Float(commit.offset[0]), Float(commit.offset[1]), Float(commit.offset[2]))
            if result.driftOffset != expectedOffset { outcome.offsetMismatches.append(k) }
            var nextNew = order.count
            for (i, d) in commit.detections.enumerated() {
                outcome.detections += 1
                let got = result.statuses[i]
                let ok: Bool
                switch (d.status, got) {
                case ("matched", .matched(let id)): ok = order[id] == d.ref
                case ("new", .new): ok = nextNew == d.ref; nextNew += 1
                case ("miss", .possibleMiss): ok = true; prompted.insert(d.truth)
                case ("left", .deferred): ok = true
                default: ok = false
                }
                if !ok { outcome.mismatches.append("commit \(k) detection \(i): sim \(d.status) \(d.ref), engine \(got)") }
            }
            for item in result.newItems {  // the user confirms each new item's product (sim.py `conf`)
                let d = commit.detections[item.detectionIndex!]
                order[item.id] = order.count
                truth.append(d.truth)
                engine.setProductKey(d.confirmed, forItems: [item.id])
            }
        }
        var counts = [Int](repeating: 0, count: fixture.expected.trueItems)
        for t in truth { counts[t] += 1 }
        outcome.metrics = SimFixture.Metrics(
            trueItems: counts.count, counted: truth.count, double: counts.reduce(0) { $0 + max(0, $1 - 1) },
            missed: counts.filter { $0 == 0 }.count, prompts: prompted.count,
            promptsUseful: prompted.filter { counts[$0] == 0 }.count)
        return outcome
    }
}

struct SimFixture: Decodable {
    struct Camera: Decodable {
        var distance: Double
        var image: [Float]
        var intrinsics: [Float]
        var band: Double
    }

    struct Parameters: Decodable {
        var gate: Double
        var metric: [Double]
        var search: Double
        var grid: Double
    }

    struct Metrics: Decodable, Equatable, CustomStringConvertible {
        var trueItems, counted, double, missed, prompts, promptsUseful: Int

        enum CodingKeys: String, CodingKey {
            case trueItems = "true", counted, double, missed, prompts, promptsUseful = "prompts_useful"
        }

        var description: String {
            "\(trueItems) items: \(counted) counted, \(double) double, \(missed) missed, \(prompts) prompts (\(promptsUseful) useful)"
        }
    }

    struct Commit: Decodable {
        var resetDrift: Bool
        var camera: [Float]
        var offset: [Double]
        var detections: [Row]

        enum CodingKeys: String, CodingKey {
            case resetDrift = "reset_drift", camera, offset, detections
        }
    }

    /// class, suggested_sku, confirmed_sku, truth, x, y, z, u, v, status, ref
    struct Row: Decodable {
        var cls, suggested, confirmed, truth: Int
        var x, y, z, u, v: Float
        var status: String
        var ref: Int

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            cls = try c.decode(Int.self)
            suggested = try c.decode(Int.self)
            confirmed = try c.decode(Int.self)
            truth = try c.decode(Int.self)
            x = try c.decode(Float.self)
            y = try c.decode(Float.self)
            z = try c.decode(Float.self)
            u = try c.decode(Float.self)
            v = try c.decode(Float.self)
            status = try c.decode(String.self)
            ref = try c.decode(Int.self)
        }
    }

    var name: String
    var classes: [String]
    var camera: Camera
    var parameters: Parameters
    var expected: Metrics
    var runOnce: Metrics
    var float32ChangedDecisions: Int
    var commits: [Commit]

    enum CodingKeys: String, CodingKey {
        case name, classes, camera, parameters, expected, runOnce = "run_once",
             float32ChangedDecisions = "float32_changed_decisions", commits
    }
}
