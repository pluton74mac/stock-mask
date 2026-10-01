import SwiftUI

/// The debug HUD (P0-2): tracking and mapping, FPS, detector rate and milliseconds, thermal state,
/// battery, view speed, tracks; plus the switches the spike needs: auto-count, the detector's compute
/// units (P0-3 compares them) and capture mode.
public struct HUDView: View {
    let hud: HUDStats
    @Binding var autoCount: Bool
    @Binding var useNeuralEngine: Bool
    let capture: CaptureController?
    let manifest: () -> CaptureManifest

    public init(hud: HUDStats, autoCount: Binding<Bool>, useNeuralEngine: Binding<Bool>, capture: CaptureController?,
                manifest: @escaping () -> CaptureManifest) {
        self.hud = hud
        _autoCount = autoCount
        _useNeuralEngine = useNeuralEngine
        self.capture = capture
        self.manifest = manifest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(hud.lines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11, design: .monospaced))
            Toggle("Auto-count on hold", isOn: $autoCount).font(.caption)
            Toggle("Detector on Neural Engine (else GPU)", isOn: $useNeuralEngine).font(.caption)
            if let capture { CaptureControls(capture: capture, manifest: manifest) }
        }
        .toggleStyle(.switch)
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Capture mode (P0-2): record keyframes + depth + pose at 1-2 Hz, then share the zip.
public struct CaptureControls: View {
    let capture: CaptureController
    let manifest: () -> CaptureManifest

    public init(capture: CaptureController, manifest: @escaping () -> CaptureManifest) {
        self.capture = capture
        self.manifest = manifest
    }

    public var body: some View {
        HStack {
            if capture.isRecording {
                Button {
                    Task { await capture.stop() }
                } label: {
                    Label("Stop capture (\(capture.frames))", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            } else {
                Button {
                    capture.start(manifest: manifest())
                } label: {
                    Label("Capture", systemImage: "record.circle")
                }
                Picker("Rate", selection: Binding(get: { capture.rateHz }, set: { capture.rateHz = $0 })) {
                    Text("1 Hz").tag(1.0)
                    Text("2 Hz").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            if let archive = capture.archive, !capture.isRecording {
                ShareLink(item: archive) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        if let error = capture.lastError { Text(error).font(.caption2).foregroundStyle(.orange) }
    }
}
