import CoreGraphics
import Foundation
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

/// Returns whatever the test says the camera sees now.
actor FakeDetector: Detector {
    nonisolated let info = DetectorInfo(classNames: ["", "bottle"], scoreShown: 0.3, scoreCommit: 0.5)
    private var next: [RawDetection] = []
    private(set) var runs = 0

    func set(_ d: [RawDetection]) { next = d }

    func detect(_ input: DetectorInput) throws -> DetectorOutput {
        runs += 1
        return DetectorOutput(detections: next, milliseconds: 12)
    }
}

@MainActor
final class FakeEnvironment: SessionEnvironment {
    var anchors: [UUID: simd_float4x4] = [:]
    var feedback = 0
    var keyframes = 0

    func addAnchor(id: UUID, transform: simd_float4x4) { anchors[id] = transform }
    func removeAnchor(id: UUID) { anchors[id] = nil }
    func commitFeedback() { feedback += 1 }
    func saveKeyframe(_ image: DetectorInput, commitID: UUID) async -> String? {
        keyframes += 1
        return "keyframes/\(commitID.uuidString).jpg"
    }
}

let tinyImage: CGImage = {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}()

/// Walks a synthetic storeroom through the real pipeline: FramePump -> detector -> lifting -> live
/// tracks -> hold trigger -> commit engine (shim) -> store (shim) -> overlays.
@MainActor
final class Walk {
    var scene: SyntheticScene
    let detector = FakeDetector()
    let environment = FakeEnvironment()
    let store = CoreStockStore()
    let session: CountingSession
    let pump: FramePump
    var t: TimeInterval = 0
    var visible: [Int]?          // which bottles the detector finds; nil = all in view
    var tracking: TrackingStatus = .normal
    /// Tracking error: the pose ARKit reports is `drift * true pose`; the image and depth are true.
    var drift = matrix_identity_float4x4

    init(_ scene: SyntheticScene, capture: CaptureController? = nil) async throws {
        self.scene = scene
        session = CountingSession(store: store, detector: detector)
        pump = FramePump(session: session, capture: capture)
        session.environment = environment
        try await store.startSession(venue: "Test venue", zone: "Storeroom", counter: "Tester")
    }

    /// `seconds` of 60 Hz frames from `camera` (default: the scene's).
    func hold(_ seconds: Double, camera: CameraModel? = nil) async {
        let cam = camera ?? scene.camera
        var reported = cam
        reported.transform = drift * cam.transform
        await detector.set(scene.detections(camera: cam, only: visible))
        let end = t + seconds
        while t < end {
            // Portrait, as on the phone: the engine gets boxes and intrinsics turned back to the
            // stored (landscape) image by CountingBridge.
            let frame = FrameSnapshot(timestamp: t, camera: reported, orientation: .right, tracking: tracking,
                                      planes: [scene.plane])
            pump.process(light: frame,
                         full: { FrameSnapshot(timestamp: t, camera: reported, orientation: .right,
                                               depth: scene.depthMap(camera: cam), tracking: tracking,
                                               planes: [scene.plane]) },
                         image: { DetectorInput(image: tinyImage) },
                         captureFrame: { dets in
                             CaptureFrame(timestamp: self.t, image: .jpeg(Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 2, height: 2),
                                          depth: nil, intrinsics: cam.intrinsics, cameraTransform: cam.transform,
                                          orientation: .up, tracking: "normal", mapping: "mapped", detections: dets)
                         })
            await pump.settle()
            t += 1.0 / 60
        }
    }

    /// Turn away by `degrees` over half a second, then back, so the hold trigger re-arms.
    func lookAway(_ degrees: Float = 20) async {
        for step in 0..<30 {
            let a = degrees * Float(step < 15 ? step : 30 - step) / 15
            await hold(1.0 / 60, camera: CameraModel(fx: 1500, imageSize: scene.camera.imageSize, transform: yaw(a)))
        }
    }
}

@Suite("Counting session (M1, M2)", .serialized)
@MainActor
struct SessionTests {
    static let shelf = SyntheticScene(bottles: [SyntheticScene.Bottle(x: -0.12, front: 1.0), SyntheticScene.Bottle(x: 0, front: 1.0),
                                                SyntheticScene.Bottle(x: 0.12, front: 1.0)])

    @Test func holdingStillCountsOnceAndKeepsCount() async throws {
        let walk = try await Walk(Self.shelf)
        await walk.hold(0.5)
        #expect(walk.session.commits == 0)            // not steady long enough yet
        #expect(walk.session.boxes.count == 3)
        #expect(walk.session.boxes.allSatisfy { $0.style == .stable })
        await walk.hold(0.6)
        #expect(walk.session.commits == 1)
        #expect(walk.session.toast?.text == "+3")
        #expect(walk.session.overlay.itemCount == 3)
        #expect(walk.environment.anchors.count == 1 && walk.environment.feedback == 1)
        #expect(walk.session.sheet.totalUnits == 3)
        #expect(walk.session.badge == "3 units · 0 products")
        let card = try #require(walk.session.card)
        #expect(card.groups.count == 1 && card.groups[0].count == 3 && card.groups[0].label == "Unknown A")
        // The lifted positions are the true centres, within a centimetre.
        for item in walk.session.overlay.commits[0].items {
            let world = (walk.session.overlay.commits[0].anchor * SIMD4(item.local, 1)).xyz
            #expect(Self.shelf.bottles.map { simd_distance(Self.shelf.centre($0), world) }.min()! < 0.01)
        }

        // Holding on: no second commit until the view has moved (the trigger re-arms after 5°).
        await walk.hold(1.5)
        #expect(walk.session.commits == 1)

        // Look away and back: a second commit, and nothing counted twice (FR-26).
        await walk.lookAway()
        await walk.hold(1.2)
        #expect(walk.session.commits == 2)
        #expect(walk.session.toast?.text == "+0")
        #expect(walk.session.sheet.totalUnits == 3)
    }

    @Test func namingUndoAndExport() async throws {
        let walk = try await Walk(Self.shelf)
        await walk.hold(1.2)
        let group = try #require(walk.session.card?.groups.first)
        let product = try #require(await walk.session.createProduct(ProductDraft(name: "Test Gin", sizeML: 700, unitsPerCase: 6)))
        #expect(await walk.session.products(matching: "gin").map(\.id) == [product.id])
        await walk.session.name(group: group, product: product)
        #expect(walk.session.card?.groups.first?.product == product)
        #expect(walk.session.sheet.lines.map(\.label) == ["Test Gin"])
        #expect(walk.session.badge == "3 units · 1 products")

        await walk.session.addManualLine(product: product, fullCases: 1, looseUnits: 2)
        #expect(walk.session.sheet.lines.first?.units == 11)
        #expect(walk.session.sheet.lines.first?.quantityText == "1 × 6 + 5")

        let file = try Data(contentsOf: try await walk.session.export(.csvArgentina))
        #expect(Array(file.prefix(3)) == [0xEF, 0xBB, 0xBF])   // UTF-8 BOM, for Excel in Argentina
        let csv = String(decoding: file, as: UTF8.self)
        #expect(csv.contains("session_id;venue;zone;"))
        #expect(csv.contains(";Test Gin;") && csv.contains(";700;6;1;5;11;camera+manual;"))
        // XLSX comes with the real StockMaskCore; the shim refuses it.
        await #expect(throws: (any Error).self) { _ = try await walk.session.export(.xlsx) }

        // Undo the commit: its items leave the list and the overlays, the anchor goes.
        await walk.session.undo()
        #expect(walk.session.sheet.lines.first?.units == 8)   // only the manual line is left
        #expect(walk.session.overlay.commits.isEmpty && walk.environment.anchors.isEmpty)
        #expect(walk.session.card == nil)
    }

    /// Six bottles: one miss among six over the counted zone is 17%, under the drift alarm's 30%
    /// (with three bottles, one miss would be 33% and raise it; see BridgeTests).
    static let longShelf = SyntheticScene(bottles: stride(from: Float(-0.30), through: 0.30, by: 0.12).map {
        SyntheticScene.Bottle(x: $0, front: 1.0)
    })

    @Test func aBottleMissedInsideACountedZoneIsOnlySuggested() async throws {
        let walk = try await Walk(Self.longShelf)
        walk.visible = [0, 1, 2, 4, 5]              // the detector misses one bottle
        await walk.hold(1.2)
        #expect(walk.session.sheet.totalUnits == 5)
        walk.visible = nil
        await walk.lookAway()
        await walk.hold(1.2)
        #expect(walk.session.commits == 2 && !walk.session.driftAlarm)
        // Inside the counted zone nothing is auto-added: the missed bottle is an amber "+" (FR-22).
        #expect(walk.session.sheet.totalUnits == 5)
        #expect(walk.session.overlay.possibleMisses == 1)
        let miss = try #require(walk.session.overlay.commits.last?.misses.first)
        await walk.session.acceptPossibleMiss(miss.id)
        #expect(walk.session.sheet.totalUnits == 6)
        #expect(walk.session.overlay.possibleMisses == 0)
    }

    @Test func driftPausesCounting() async throws {
        var scene = Self.shelf
        scene.bottles.append(SyntheticScene.Bottle(x: 0.24, front: 1.0))
        let walk = try await Walk(scene)
        await walk.hold(1.2)
        #expect(walk.session.sheet.totalUnits == 4)
        // Come back with tracking off by 6 cm: more than the local refinement (±4.5 cm) absorbs,
        // and not a whole bottle pitch (12 cm here), which would line up with the neighbours.
        walk.drift = .translation(SIMD3(0.06, 0, 0))
        await walk.lookAway()
        await walk.hold(1.2)
        #expect(walk.session.driftAlarm)
        #expect(walk.session.pauseReason != nil)
        #expect(walk.session.overlay.faded)
        #expect(walk.session.sheet.totalUnits == 4)       // the drifted view was undone
        #expect(walk.session.overlay.commits.count == 1)
        // Paused: holding still doesn't count.
        await walk.hold(1.2)
        #expect(walk.session.commits == 1)
        // Tracking recovers: the view lines up with the counted shelf again and counting resumes.
        walk.drift = matrix_identity_float4x4
        await walk.hold(0.5)
        #expect(!walk.session.driftAlarm && !walk.session.overlay.faded)
        #expect(walk.session.toast?.text == "Back on counted shelves")
    }

    @Test func limitedTrackingPausesAndTheShutterStillCounts() async throws {
        let walk = try await Walk(Self.shelf)
        walk.tracking = .limited(.relocalizing)
        await walk.hold(1.5)
        #expect(walk.session.commits == 0)
        #expect(walk.session.pauseReason == "Tracking lost: point at a shelf you already counted")
        walk.tracking = .normal
        walk.session.autoCount = false
        await walk.hold(1.5)
        #expect(walk.session.commits == 0)            // auto-count off
        walk.session.shutter()
        await walk.hold(0.1)
        #expect(walk.session.commits == 1)
        #expect(walk.session.sheet.totalUnits == 3)
    }

    @Test func captureRecordsKeyframesAtTwoHertz() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("capture-session-\(UUID().uuidString)")
        let capture = CaptureController(parent: parent)
        let walk = try await Walk(Self.shelf, capture: capture)
        capture.start(manifest: CaptureManifest(app: "test", device: "Mac", system: "macOS", rateHz: 2, orientation: .up,
                                                detector: "fake"))
        await walk.hold(2.05)
        try await Task.sleep(for: .milliseconds(100))
        let zip = await capture.stop()
        #expect(zip != nil)
        let frames = try CaptureReader(folder: try #require(capture.folder)).frames
        #expect(frames.count == 5)                     // t = 0, 0.5, 1, 1.5, 2
        #expect(frames.last?.detections.count == 3)    // what the screen showed
    }
}
