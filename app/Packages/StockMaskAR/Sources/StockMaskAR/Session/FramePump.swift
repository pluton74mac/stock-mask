import Foundation

/// Runs the data flow of docs/mvp-test-app.md for one AR frame:
/// frame -> (detector at 5-12 Hz) -> lifting -> live tracks -> hold trigger -> commit, plus capture.
///
/// The AR layer calls `process` from its frame callback with closures over the frame. They are only
/// called synchronously, inside `process`, so the ARFrame is never retained (ADR 001); what goes into
/// the async work is copied (the depth map) or is just the camera buffer for the duration of one
/// detector run (one frame in flight).
@MainActor
public final class FramePump {
    public let session: CountingSession
    public let capture: CaptureController?
    private(set) var inFlight: Task<Void, Never>?
    private(set) var committing: Task<Void, Never>?

    public init(session: CountingSession, capture: CaptureController? = nil) {
        self.session = session
        self.capture = capture
    }

    /// - Parameters:
    ///   - light: pose, tracking and time only (every frame).
    ///   - full: the same frame with its depth map and planes (copied only when needed).
    ///   - image: the camera image for the detector and the commit.
    ///   - captureFrame: the frame for capture mode, given the detections shown at that moment.
    public func process(light: FrameSnapshot, full: () -> FrameSnapshot, image: () -> DetectorInput,
                        captureFrame: ([RawDetection]) -> CaptureFrame) {
        let decision = session.frameDidUpdate(light)
        var snapshot: FrameSnapshot?
        func fullSnapshot() -> FrameSnapshot {
            if let snapshot { return snapshot }
            let s = full()
            snapshot = s
            return s
        }
        if decision.runDetector, let detector = session.detector {
            let frame = fullSnapshot(), input = image(), session = self.session
            inFlight = Task {
                do {
                    let output = try await detector.detect(input)
                    session.detectorDidFinish(output, frame: frame)
                } catch {
                    session.detectorDidFail(error)
                }
            }
        }
        if let trigger = decision.commit {
            let frame = fullSnapshot(), input = image(), session = self.session
            committing = Task { await session.commit(trigger, frame: frame, image: input) }
        }
        if let capture, capture.shouldCapture(at: light.timestamp) {
            let shown = session.boxes.map { RawDetection(label: $0.label, score: $0.score, box: $0.box) }
            capture.submit(captureFrame(shown))
        }
    }

    /// Waits for the detector run and the commit started by the last `process` calls (tests, replays).
    public func settle() async {
        await inFlight?.value
        await committing?.value
    }
}
