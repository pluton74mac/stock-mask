#if os(iOS)
// NOT COMPILED YET: needs the iOS SDK (Xcode). See the package README, "Not compiled yet".
import ARKit
import RealityKit
import SwiftUI
import UIKit

/// The app's root (the thin app target shows only this): a LiDAR check, the start screen, then the
/// counting screen.
public struct StockMaskRootView: View {
    @State private var controller: ARSessionController?
    @State private var starting = false

    public init() {}

    public var body: some View {
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            UnsupportedDeviceView()   // ADR 001: LiDAR devices only
        } else if let controller {
            CountingScreen(controller: controller)
        } else {
            StartView { counter, zone in
                guard !starting else { return }
                starting = true
                Task { controller = await ARSessionController.start(counter: counter, zone: zone) }
            }
        }
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
