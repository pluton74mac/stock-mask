#if os(iOS)
@preconcurrency import ARKit
import CoreML
import Observation
import RealityKit
import UIKit

/// Owns the AR session and connects it to the counting session:
/// - runs ARKit world tracking with `sceneDepth` + `smoothedSceneDepth`, horizontal planes, and
///   relocalisation on (P0-2, ADR 001);
/// - feeds every frame to `FramePump` (detector, lifting, tracks, hold trigger, commit, capture);
/// - keeps one ARAnchor per commit and passes ARKit's updates to the engine (FR-21);
/// - renders the 3D overlays with RealityKit (`OverlayRenderer`) and turns taps on "+" into counts;
/// - loads the detector, polls thermal state and battery, haptics, torch, keyframes;
/// - writes the diagnostic log (`Documents/diagnostics/diag-*.jsonl`).
///
/// It outlives the counting screen: going back to the start screen pauses the camera, and
/// continuing the count runs the same ARView and world again (anchors, overlays, tracks).
@MainActor @Observable
public final class ARSessionController {
    public let session: CountingSession
    public let capture: CaptureController
    public private(set) var displayMapping: DisplayMapping?
    public private(set) var detectorStatus = "Loading the detector…"
    public private(set) var errorMessage: String?
    /// The GPU is the default (3 October). It counts since the input resize got 13x faster.
    /// Against PyTorch, the fine-tuned model in FP16 on CPU + GPU matches on 23 of 24 frames,
    /// while the Neural Engine drifts (10 of 24 frames; about 1 in 10 bottle tops lost)
    /// (ml/coreml/RESULTS.md). The HUD switch still tries the Neural Engine. See StockMaskAR's
    /// README, "GPU or Neural Engine".
    public var useNeuralEngine = false { didSet { if useNeuralEngine != oldValue { loadDetector() } } }
    /// Lift from `smoothedSceneDepth` instead of `sceneDepth` (P0-4 compares them).
    public var smoothedDepth = false
    public var torchOn = false { didSet { setTorch(torchOn) } }
    @ObservationIgnored public let diagnostics: DiagnosticsLog?

    @ObservationIgnored private var pump: FramePump
    /// Kept (strongly) while the controller lives, so a closed counting screen comes back to the same world.
    @ObservationIgnored private var arView: ARView?
    @ObservationIgnored private var delegate: ARDelegateProxy?
    @ObservationIgnored private var renderer: OverlayRenderer?
    @ObservationIgnored private var syncedRevision = -1
    @ObservationIgnored private var anchors: [UUID: ARAnchor] = [:]
    @ObservationIgnored private var planes: [UUID: SupportPlane] = [:]
    @ObservationIgnored private var viewport: CGSize = .zero
    @ObservationIgnored private var lastStatusPoll: TimeInterval = 0
    @ObservationIgnored private let files: CommitFileStore
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let documents: URL
    @ObservationIgnored private let modelCache: URL

    /// `dataDirectory` holds the database and the commits' photos (`AppFolders.data`).
    public init(session: CountingSession, dataDirectory: URL) {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelCache = dataDirectory.appendingPathComponent("models")
        let capture = CaptureController(parent: documents.appendingPathComponent("Captures"))
        self.session = session
        self.capture = capture
        files = CommitFileStore(dataDirectory: dataDirectory)
        pump = FramePump(session: session, capture: capture)
        diagnostics = try? DiagnosticsLog(folder: AppFolders.diagnostics(documents: documents))
        session.environment = self
        session.dataDirectory = dataDirectory
        session.diagnostics = diagnostics
        let info = Bundle.main.infoDictionary ?? [:]
        session.log("start", "counting screen opened", [
            "app": "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "build": AppFolders.buildKind, "device": DeviceInfo.modelIdentifier,
            "system": "iOS \(UIDevice.current.systemVersion)",
        ])
        loadDetector()
    }

    // MARK: the view

    /// The camera view. RealityKit draws the camera and the 3D overlays; we configure ARKit. The
    /// second time (the count continued after going back to the start screen) it is the same view,
    /// and its session runs again without a reset: same world, same anchors.
    public func makeARView() -> ARView {
        if let view = arView {
            run(view.session)
            session.log("camera_resumed", "counting screen shown again")
            return view
        }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        let proxy = ARDelegateProxy(controller: self)
        view.session.delegate = proxy
        delegate = proxy
        renderer = OverlayRenderer(
            makeRoot: { [weak self] c in
                // Each commit's overlays hang off its ARAnchor, so ARKit's refinements move them.
                if let anchor = self?.anchors[c.id] { return AnchorEntity(anchor: anchor) }
                return AnchorEntity(world: c.anchor)
            },
            attach: { [weak view] root in
                if let anchor = root as? AnchorEntity { view?.scene.addAnchor(anchor) }
            },
            detach: { [weak view] root in
                if let anchor = root as? AnchorEntity { view?.scene.removeAnchor(anchor) }
            },
            followsAnchors: true)
        arView = view
        run(view.session)
        return view
    }

    func run(_ arSession: ARSession) {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]   // LiDAR only: RootView checks support
        config.planeDetection = [.horizontal]                         // shelves, for the shelf-plane fallback
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.imageResolution == CGSize(width: 1920, height: 1440) && $0.framesPerSecond == 60
        }) {
            config.videoFormat = format
        }
        arSession.run(config)
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Back to the start screen: the camera and the torch go off; the count, the world and the
    /// overlays stay for when the count continues.
    public func pause() {
        if torchOn { torchOn = false }
        arView?.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        session.log("camera_paused", "back to the start screen")
        diagnostics?.flush()
    }

    // MARK: per frame (called on the main thread by ARKit)

    func process(_ frame: ARFrame) {
        let light = ARFrameConversion.light(frame)
        // The closures run inside `process` only: the frame is never retained.
        pump.process(
            light: light,
            full: { ARFrameConversion.full(frame, planes: Array(planes.values), smoothed: smoothedDepth) },
            image: { ARFrameConversion.detectorInput(frame) },
            captureFrame: { ARFrameConversion.captureFrame(frame, detections: $0) })

        if session.overlayRevision != syncedRevision {
            renderer?.sync(session.overlay)
            syncedRevision = session.overlayRevision
        }
        if let view = arView, view.bounds.size != viewport, view.bounds.size.width > 0 {
            viewport = view.bounds.size
            // ARKit's own image -> screen transform (aspect fill + rotation), in normalised units.
            let mapping = DisplayMapping(sensorToView: frame.displayTransform(for: .portrait, viewportSize: viewport),
                                         orientation: ARFrameConversion.orientation)
            displayMapping = mapping
            session.setVisibleRegion(mapping.visibleRegion(), imageSize: light.camera.imageSize)
        }
        if frame.timestamp - lastStatusPoll > 2 {
            lastStatusPoll = frame.timestamp
            session.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
            let level = UIDevice.current.batteryLevel
            session.battery = level >= 0 ? level : nil
        }
    }

    func anchorsUpdated(_ updated: [ARAnchor]) {
        for anchor in updated {
            if let plane = anchor as? ARPlaneAnchor {
                planes[plane.identifier] = ARFrameConversion.supportPlane(plane)
            } else if let name = anchor.name, name.hasPrefix("commit:"), let id = UUID(uuidString: String(name.dropFirst(7))) {
                session.anchorDidUpdate(id: id, transform: anchor.transform)
            }
        }
    }

    func anchorsRemoved(_ removed: [ARAnchor]) {
        for anchor in removed where anchor is ARPlaneAnchor { planes[anchor.identifier] = nil }
    }

    func failed(_ error: Error) { errorMessage = "AR session: \(error.localizedDescription)" }

    /// A tap on the camera view: an amber "+" there becomes a count (FR-22).
    public func handleTap(at point: CGPoint) {
        guard let view = arView, let id = OverlayRenderer.missID(of: view.entity(at: point)) else { return }
        Task { await session.acceptPossibleMiss(id) }
    }

    // MARK: detector, torch, capture

    var computeUnitsLabel: String { useNeuralEngine ? "Neural Engine" : "GPU" }

    func loadDetector() {
        let units: MLComputeUnits = useNeuralEngine ? .cpuAndNeuralEngine : .cpuAndGPU
        let label = computeUnitsLabel
        detectorStatus = "Loading the detector (\(label))…"
        let documents = documents, cache = modelCache
        Task {
            do {
                guard let url = try await DetectorModelLocator.locate(documents: documents, cache: cache) else {
                    detectorStatus = "No detector model in the app (see app/StockMask/README.md)"
                    session.log("detector_missing", "no model in the bundle or Documents/Models")
                    return
                }
                // Loading compiles for the device's chips: keep it off the main thread.
                let clock = ContinuousClock(), start = clock.now
                let detector = try await Task.detached { try CoreMLDetector(compiledModelURL: url, computeUnits: units) }.value
                let loadMs = (clock.now - start).milliseconds
                // One run before counting: the first is slow (the chip's own compilation), and it
                // shows the outputs' element types and strides for the log.
                let warmUp = try? await detector.detect(
                    DetectorInput(pixelBuffer: DetectorBenchmark.syntheticCameraFrame(), orientation: .right))
                let outputs = await detector.lastOutputInfo
                guard label == computeUnitsLabel else { return }   // switched again while this one loaded
                session.setDetector(detector, computeUnits: label)
                detectorStatus = "\(detector.info.source) · \(label)"
                session.log("detector_loaded", label, [
                    "loadMs": String(format: "%.0f", loadMs),
                    "firstRunMs": warmUp.map { String(format: "%.0f", $0.milliseconds) } ?? "failed",
                    "outputs": outputs, "scoreShown": "\(detector.info.scoreShown)",
                    "scoreCommit": "\(detector.info.scoreCommit)", "model": detector.info.source, "build": AppFolders.buildKind,
                ])
            } catch {
                detectorStatus = "Detector failed to load: \(error)"
                session.log("detector_failed", "\(error)", ["units": label])
            }
        }
    }

    /// P0-9: the torch during an AR session, through the capture device ARKit uses (iOS 16+).
    func setTorch(_ on: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Torch: \(error.localizedDescription)"
        }
    }

    public func captureManifest() -> CaptureManifest {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "StockMask \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        return CaptureManifest(app: app, device: DeviceInfo.modelIdentifier, system: "iOS \(UIDevice.current.systemVersion)",
                               rateHz: capture.rateHz, orientation: ARFrameConversion.orientation,
                               detector: session.detector?.info.source ?? "none")
    }
}

extension ARSessionController: SessionEnvironment {
    /// The commit's ARAnchor, at the counted zone's transform; its identifier is the commit's anchorID.
    public func addAnchor(id: UUID, transform: simd_float4x4) -> UUID? {
        let anchor = ARAnchor(name: "commit:\(id.uuidString)", transform: transform)
        anchors[id] = anchor
        arView?.session.add(anchor: anchor)
        return anchor.identifier
    }

    public func removeAnchor(id: UUID) {
        if let anchor = anchors.removeValue(forKey: id) { arView?.session.remove(anchor: anchor) }
    }

    public func commitFeedback() { haptics.impactOccurred() }

    public func saveFiles(_ image: DetectorInput, sessionID: UUID?, commitID: UUID,
                          crops: [(id: UUID, box: SIMD4<Float>)]) async -> CommitFiles {
        await files.save(image, sessionID: sessionID, commitID: commitID, crops: crops)
    }
}

/// ARSessionDelegate needs an NSObject; the controller stays a plain @Observable class. ARKit calls
/// the delegate on the main queue (no delegateQueue set), which the preconcurrency conformance checks.
@MainActor
final class ARDelegateProxy: NSObject, @preconcurrency ARSessionDelegate {
    weak var controller: ARSessionController?

    init(controller: ARSessionController) { self.controller = controller }

    func session(_ session: ARSession, didUpdate frame: ARFrame) { controller?.process(frame) }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { controller?.anchorsUpdated(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { controller?.anchorsUpdated(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { controller?.anchorsRemoved(anchors) }
    func session(_ session: ARSession, didFailWithError error: Error) { controller?.failed(error) }
    /// ADR 001: relocalise after tracking loss instead of resetting the world origin (anchors survive).
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
#endif
