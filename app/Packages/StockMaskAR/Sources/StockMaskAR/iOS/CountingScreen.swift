#if os(iOS)
import ARKit
import RealityKit
import SwiftUI
import UIKit

/// The app's root (the thin app target shows only this): a LiDAR check, the database, then the
/// start screen (continue the count in progress, FR-7; import the product catalogue, FR-4), then
/// the counting screen. Going back from the counting screen keeps its controller, so continuing
/// the count comes back to the same AR world.
///
/// The start screen's "Benchmark the detector" (or the launch argument `-StockMaskBenchmark`) runs
/// `BenchmarkRun`.
public struct StockMaskRootView: View {
    @State private var store: CoreStockStore?
    @State private var resumable: ResumedSession?
    @State private var controller: ARSessionController?
    @State private var counting = false
    @State private var catalog = CatalogStep()
    @State private var benchmark = BenchmarkRun()
    @State private var problem: String?

    public init() {}

    public var body: some View {
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            UnsupportedDeviceView()   // ADR 001: LiDAR devices only
        } else if counting, let controller {
            CountingScreen(controller: controller) { close(controller) }
        } else if let store {
            StartView(resumable: resumable, catalog: catalog, onImport: { url in importCatalog(url, into: store) },
                      onRefreshCatalog: { Task { await refreshCatalog(store) } },
                      benchmark: BenchmarkStep(running: benchmark.running, status: benchmark.status) {
                          if let dir = try? AppFolders.data() { benchmark.start(dataDirectory: dir) }
                      },
                      onResume: { resume(store) }, onStart: { counter, zone in start(store, counter: counter, zone: zone) })
                .overlay(alignment: .bottom) { if let problem { Text(problem).foregroundStyle(.red).padding() } }
                .task { await refreshCatalog(store) }
        } else {
            ProgressView().task {
                do {
                    let dir = try AppFolders.data()
                    let s = try CoreStockStore.open(at: dir.appendingPathComponent("stock.sqlite"))
                    resumable = try await s.resumeSession()
                    store = s
                    if ProcessInfo.processInfo.arguments.contains("-StockMaskBenchmark") {
                        benchmark.start(dataDirectory: dir)
                    }
                } catch {
                    problem = "Couldn't open the database: \(error)"
                }
            }
            .overlay { if let problem { Text(problem).foregroundStyle(.red).padding() } }
        }
    }

    private func start(_ store: CoreStockStore, counter: String, zone: String) {
        Task {
            do {
                try await store.startSession(venue: CoreStockStore.defaultVenue, zone: zone, counter: counter)
                open(store, notice: nil, fresh: true)
            } catch {
                problem = "\(error)"
            }
        }
    }

    private func resume(_ store: CoreStockStore) {
        if controller != nil {
            counting = true   // the same controller: same world, overlays and tracks
            benchmark.countingScreenShown = true
        } else {
            open(store, notice: "Counting continues. After a restart the camera doesn't remember what it "
                + "counted before (map restore comes later): don't count those shelves again.", fresh: false)
        }
    }

    private func open(_ store: CoreStockStore, notice: String?, fresh: Bool) {
        guard let dir = try? AppFolders.data() else { return }
        controller?.pause()
        let session = CountingSession(store: store, embedder: FeaturePrintEmbedder(), labelReader: VisionLabelReader())
        session.notice = notice
        Task { await session.refreshSheet() }
        controller = ARSessionController(session: session, dataDirectory: dir)
        counting = true
        benchmark.countingScreenShown = true
    }

    /// Back to the start screen. The count is saved commit by commit, so nothing is lost; the
    /// controller stays for "Continue this count".
    private func close(_ controller: ARSessionController) {
        controller.pause()
        counting = false
        benchmark.countingScreenShown = false
        guard let store else { return }
        Task {
            resumable = try? await store.resumeSession()
            if resumable == nil { self.controller = nil }   // locked: the next count starts afresh
            await refreshCatalog(store)
        }
    }

    // MARK: the product catalogue (FR-4)

    private func refreshCatalog(_ store: CoreStockStore) async {
        catalog.files = AppFolders.catalogFiles()
        catalog.products = await store.productCount()
    }

    private func importCatalog(_ url: URL, into store: CoreStockStore) {
        catalog.importing = true
        catalog.message = nil
        Task {
            do {
                let data = try Data(contentsOf: url)
                let summary = try await store.importCatalog(csv: data)
                catalog.message = "\(url.lastPathComponent): \(summary.text)"
                catalog.products = summary.products
            } catch {
                catalog.message = "Couldn't import \(url.lastPathComponent): \(error)"
            }
            catalog.importing = false
        }
    }

}

/// The detector benchmark (the start screen's "Benchmark the detector", or the launch argument
/// `-StockMaskBenchmark`): each compute unit on a synthetic camera frame (timing) and on up to three
/// keyframes of earlier commits (scores), then the GPU and the CPU against the Neural Engine on
/// those keyframes. Each unit's result is written as soon as it is done, to
/// `Documents/diagnostics/benchmark-*.jsonl`. The screen stays on while it runs.
@MainActor @Observable
public final class BenchmarkRun {
    public private(set) var running = false
    public private(set) var status: String?
    /// Set by the root view: the counting screen needs the screen on after the benchmark too.
    @ObservationIgnored public var countingScreenShown = false

    public init() {}

    public func start(dataDirectory: URL) {
        guard !running else { return }
        running = true
        status = "Starting: keep StockMask open (about a minute)…"
        let app = UIApplication.shared
        app.isIdleTimerDisabled = true
        let background = app.beginBackgroundTask(withName: "StockMask benchmark")
        Task.detached(priority: .userInitiated) { [self] in
            let file = await Self.run(dataDirectory: dataDirectory) { stage in
                await MainActor.run { self.status = "Benchmark: \(stage)…" }
            }
            await MainActor.run {
                self.running = false
                self.status = file.map { "Done: Documents/diagnostics/\($0)" } ?? "No detector model to benchmark"
                // The counting screen keeps the screen on for itself while it shows.
                if !self.countingScreenShown { UIApplication.shared.isIdleTimerDisabled = false }
                UIApplication.shared.endBackgroundTask(background)
            }
        }
    }

    /// Returns the log's file name, or nil without a model.
    nonisolated static func run(dataDirectory: URL, stage: @escaping @Sendable (String) async -> Void) async -> String? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let log = try? DiagnosticsLog(folder: AppFolders.diagnostics(documents: documents), prefix: "benchmark"),
              let url = try? await DetectorModelLocator.locate(documents: documents, cache: dataDirectory.appendingPathComponent("models"))
        else { return nil }
        let keyframes = AppFolders.recentKeyframes(in: dataDirectory, limit: 3)
        let frames = keyframes.compactMap { PhotoLoader.image($0, in: dataDirectory) }.map { DetectorInput(image: $0) }
        log.write(DiagnosticsEvent(kind: "benchmark_start", message: "\(frames.count) keyframes",
                                   details: ["build": AppFolders.buildKind, "device": DeviceInfo.modelIdentifier]))
        let results = await DetectorBenchmark.runWithDetections(
            compiledModelURL: url, runs: 20, frames: frames,
            stage: { s in
                log.write(DiagnosticsEvent(kind: "benchmark_stage", message: s))
                await stage(s)
            },
            finished: { r in
                log.write(r)
                log.flush()
            })
        if let reference = results.first(where: { $0.result.computeUnits == "Neural Engine" }), !frames.isEmpty {
            for other in results where other.result.computeUnits != reference.result.computeUnits {
                log.write(DetectorBenchmark.compare((reference.result.computeUnits, reference.detections),
                                                    (other.result.computeUnits, other.detections),
                                                    commitScore: reference.commitScore))
            }
        }
        log.write(DiagnosticsEvent(kind: "benchmark_done", message: "\(results.count) compute units"))
        log.flush()
        return log.url.lastPathComponent
    }
}

/// Where the app keeps its data: `Application Support/StockMask` (the database `stock.sqlite`, the
/// commits' photos under `sessions/`, compiled models under `models/`). Captures, diagnostics,
/// catalogue CSVs and models to swap in go to Documents, which the Files app and Finder show.
public enum AppFolders {
    public static func data() throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockMask")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `Documents/diagnostics`: the counting screen's log and the benchmark's.
    public static func diagnostics(documents: URL) -> URL { documents.appendingPathComponent("diagnostics") }

    /// CSV (or tab-separated) files in Documents, and in Documents/Inbox where "Open in" puts them.
    public static func catalogFiles() -> [URL] {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folders = [documents, documents.appendingPathComponent("Inbox")]
        return folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["csv", "tsv", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The newest commit keyframes (paths relative to the data directory).
    static func recentKeyframes(in dataDirectory: URL, limit: Int) -> [String] {
        let fm = FileManager.default
        let sessions = dataDirectory.appendingPathComponent("sessions")
        var found: [(path: String, date: Date)] = []
        for s in (try? fm.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let folder = sessions.appendingPathComponent(s).appendingPathComponent("keyframes")
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jpg") {
                let date = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate]) as? Date
                found.append(("sessions/\(s)/keyframes/\(name)", date ?? .distantPast))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map(\.path)
    }

    /// Debug builds run the packages unoptimised (-Onone): the CPU parts of the detector are slower.
    public static var buildKind: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }
}

/// The counting screen on the phone: CountingScreenLayout around the ARView.
public struct CountingScreen: View {
    @Bindable var controller: ARSessionController
    let onClose: () -> Void

    public init(controller: ARSessionController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    public var body: some View {
        let session = controller.session
        CountingScreenLayout(session: session, mapping: controller.displayMapping, torch: $controller.torchOn,
                             onClose: onClose) {
            ARViewContainer(controller: controller)
        } hud: {
            VStack(alignment: .leading, spacing: 4) {
                HUDView(hud: session.hud,
                        autoCount: Binding(get: { session.autoCount }, set: { session.autoCount = $0 }),
                        useNeuralEngine: $controller.useNeuralEngine, capture: controller.capture,
                        manifest: { controller.captureManifest() }, countNow: { session.shutter() })
                Text(controller.detectorStatus).font(.caption2).foregroundStyle(.white.opacity(0.8))
                if let error = controller.errorMessage { Text(error).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .statusBarHidden()
    }
}

/// RealityKit's ARView in SwiftUI, with a tap recogniser for the amber "+". The view belongs to the
/// controller and outlives this wrapper (the count can be continued after going back).
struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController

    func makeUIView(context: Context) -> ARView {
        let view = controller.makeARView()
        view.gestureRecognizers?.filter { $0.name == "StockMask.tap" }.forEach { view.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.name = "StockMask.tap"
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
