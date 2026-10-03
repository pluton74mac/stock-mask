import Foundation
import Observation

/// Capture mode's state for the screens: on/off, frames written, and the zip to share.
@MainActor @Observable
public final class CaptureController {
    public private(set) var isRecording = false
    public private(set) var frames = 0
    public private(set) var folder: URL?
    public private(set) var archive: URL?
    public private(set) var lastError: String?
    public var rateHz: Double = 2 { didSet { scheduler.rateHz = rateHz } }

    private var writer: CaptureWriter?
    private var scheduler = CaptureScheduler(rateHz: 2)
    private var busy = false
    private let parent: URL

    /// `parent` is where capture folders go: Documents/Captures on the phone.
    public init(parent: URL) { self.parent = parent }

    public func start(manifest: CaptureManifest) {
        guard !isRecording else { return }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var m = manifest
            m.rateHz = rateHz
            writer = try CaptureWriter(parent: parent, manifest: m)
            folder = writer?.folder
            frames = 0
            archive = nil
            lastError = nil
            scheduler.reset()
            isRecording = true
        } catch {
            lastError = "Couldn't start capture: \(error.localizedDescription)"
        }
    }

    /// Whether the frame at `t` should be captured (1-2 Hz, one write at a time).
    public func shouldCapture(at t: TimeInterval) -> Bool {
        isRecording && scheduler.shouldCapture(at: t, writerBusy: busy)
    }

    public func submit(_ frame: CaptureFrame) {
        guard let writer else { return }
        busy = true
        Task {
            do {
                let record = try await writer.append(frame)
                self.frames = record.index
            } catch {
                self.lastError = "Capture write failed: \(error.localizedDescription)"
            }
            self.busy = false
        }
    }

    /// Stops recording and zips the folder for the share sheet.
    @discardableResult
    public func stop() async -> URL? {
        guard isRecording, let writer else { return nil }
        isRecording = false
        self.writer = nil
        do {
            let folder = try await writer.finish()
            archive = try CaptureArchive.zip(folder)
        } catch {
            lastError = "Couldn't finish capture: \(error.localizedDescription)"
        }
        return archive
    }
}
