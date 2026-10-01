#if os(iOS)
// NOT COMPILED YET: needs the iOS SDK (Xcode). See the package README, "Not compiled yet".
import ARKit
import RealityKit
import SwiftUI
import UIKit

/// The app's root (the thin app target shows only this): a LiDAR check, the database, then the
/// start screen (or the count in progress, FR-7), then the counting screen.
public struct StockMaskRootView: View {
    @State private var store: CoreStockStore?
    @State private var resumable: ResumedSession?
    @State private var controller: ARSessionController?
    @State private var problem: String?

    public init() {}

    public var body: some View {
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            UnsupportedDeviceView()   // ADR 001: LiDAR devices only
        } else if let controller {
            CountingScreen(controller: controller)
        } else if let store {
            StartView(resumable: resumable, onResume: {
                open(store, notice: "Counting continues. After a restart the camera doesn't remember what it "
                    + "counted before (map restore comes later): don't count those shelves again.")
            }, onStart: { counter, zone in
                Task {
                    do {
                        try await store.startSession(venue: "Test venue", zone: zone, counter: counter)
                        open(store, notice: nil)
                    } catch {
                        problem = "\(error)"
                    }
                }
            })
            .overlay(alignment: .bottom) { if let problem { Text(problem).foregroundStyle(.red).padding() } }
        } else {
            ProgressView().task {
                do {
                    let dir = try AppFolders.data()
                    let s = try CoreStockStore.open(at: dir.appendingPathComponent("stock.sqlite"))
                    resumable = try await s.resumeSession()
                    store = s
                } catch {
                    problem = "Couldn't open the database: \(error)"
                }
            }
            .overlay { if let problem { Text(problem).foregroundStyle(.red).padding() } }
        }
    }

    private func open(_ store: CoreStockStore, notice: String?) {
        guard let dir = try? AppFolders.data() else { return }
        let session = CountingSession(store: store, embedder: FeaturePrintEmbedder())
        session.notice = notice
        Task { await session.refreshSheet() }
        controller = ARSessionController(session: session, dataDirectory: dir)
    }
}

/// Where the app keeps its data: `Application Support/StockMask` (the database `stock.sqlite`, the
/// commits' photos under `sessions/`, compiled models under `models/`). Captures and models to swap
/// in go to Documents, which the Files app and Finder show.
public enum AppFolders {
    public static func data() throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockMask")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The counting screen on the phone: CountingScreenLayout around the ARView.
public struct CountingScreen: View {
    @Bindable var controller: ARSessionController

    public init(controller: ARSessionController) { self.controller = controller }

    public var body: some View {
        let session = controller.session
        CountingScreenLayout(session: session, mapping: controller.displayMapping, torch: $controller.torchOn) {
            ARViewContainer(controller: controller)
        } hud: {
            VStack(alignment: .leading, spacing: 4) {
                HUDView(hud: session.hud,
                        autoCount: Binding(get: { session.autoCount }, set: { session.autoCount = $0 }),
                        useNeuralEngine: $controller.useNeuralEngine, capture: controller.capture,
                        manifest: { controller.captureManifest() })
                Text(controller.detectorStatus).font(.caption2).foregroundStyle(.white.opacity(0.8))
                if let error = controller.errorMessage { Text(error).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .statusBarHidden()
    }
}

/// RealityKit's ARView in SwiftUI, with a tap recogniser for the amber "+".
struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController

    func makeUIView(context: Context) -> ARView {
        let view = controller.makeARView()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject {
        let controller: ARSessionController
        init(controller: ARSessionController) { self.controller = controller }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            controller.handleTap(at: recognizer.location(in: recognizer.view))
        }
    }
}
#endif
