import Foundation

/// FR-13, hold-to-count: commit when the view has been steady (under 10°/s) for 0.8 s, a stable
/// candidate is in view and tracking is normal; then wait until the view has moved 5° before the
/// next commit. The shutter always commits.
///
/// A port of research/walkthrough/walkthrough.py `replay` (the hold branch), which fired on every
/// stretch of 0.8 s or more under 10°/s in the second storeroom walk (walkthrough results §9):
/// - the speed is the median of the last 0.1 s of samples (at least 3);
/// - the hold timer starts at the first steady frame and restarts whenever the view moves too fast;
/// - after a commit the trigger is disarmed. It re-arms once the view has moved `rearmAngle` from
///   where it committed, or after a tracking interruption, and the hold timer then starts again.
///
/// Feed it every frame, in time order. It is a value type: keep one per camera session.
public struct HoldTrigger: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// Seconds steady before a commit. FR-13, ADR 003: 0.8 s.
        public var holdDuration: Double = 0.8
        /// Steady means slower than this, degrees per second. ADR 003: 10°/s.
        public var maxAngularSpeed: Double = 10
        /// Degrees the view must move after a commit before the next one. walkthrough.py `REARM_DEG`.
        public var rearmAngle: Double = 5
        /// Median filter on the angular speed, seconds (walkthrough.py: about 0.1 s, at least 3
        /// samples). 0 turns it off.
        public var speedFilter: Double = 0.1

        public init(holdDuration: Double = 0.8, maxAngularSpeed: Double = 10, rearmAngle: Double = 5,
                    speedFilter: Double = 0.1) {
            self.holdDuration = holdDuration
            self.maxAngularSpeed = maxAngularSpeed
            self.rearmAngle = rearmAngle
            self.speedFilter = speedFilter
        }
    }

    /// One camera frame.
    public struct Frame: Sendable, Equatable {
        public var timestamp: TimeInterval
        /// How fast the view moves, degrees per second. walkthrough.py measures it from image motion,
        /// so stepping sideways counts as well as turning: give translation speed / distance too.
        public var angularSpeed: Double
        /// At least one stable candidate in view (ADR 003: 3 hits in the last 0.5 s).
        public var hasStableCandidate: Bool
        /// ARKit tracking state is `.normal`.
        public var trackingNormal: Bool
        /// Optional: how far the view moved since the previous frame, in degrees across and up the
        /// image. With it, re-arming uses the net movement since the commit, as walkthrough.py does;
        /// without it, the angle travelled (speed × time), which also counts hand tremor.
        public var viewShift: SIMD2<Double>?

        public init(timestamp: TimeInterval, angularSpeed: Double, hasStableCandidate: Bool,
                    trackingNormal: Bool, viewShift: SIMD2<Double>? = nil) {
            self.timestamp = timestamp
            self.angularSpeed = angularSpeed
            self.hasStableCandidate = hasStableCandidate
            self.trackingNormal = trackingNormal
            self.viewShift = viewShift
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Not holding: moving, tracking limited, or auto-count switched off.
        case idle
        /// Steady and armed. `progress` runs from 0 to 1 over the hold; it stays at 1 while waiting
        /// for a stable candidate.
        case holding(progress: Double)
        /// This view was just counted; move about 5° to count the next one.
        case counted
        /// Commit now.
        case commit
    }

    public var parameters: Parameters
    /// FR-13: auto-count can be switched off. The shutter still works.
    public var isAutoCountEnabled = true
    /// False after a commit, until the view has moved `rearmAngle`.
    public private(set) var isArmed = true
    /// The filtered angular speed of the last frame, degrees per second.
    public private(set) var speed: Double = .infinity

    private var samples: [(t: TimeInterval, speed: Double)] = []
    private var holdStart: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var moved = SIMD2<Double>.zero  // net view shift since the last commit, degrees
    private var travelled = 0.0  // angle travelled since the last commit, degrees

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// Feed one frame; returns what to do.
    public mutating func update(_ frame: Frame) -> Decision {
        let t = frame.timestamp
        let dt = lastTimestamp.map { max(0, t - $0) } ?? 0
        lastTimestamp = t
        speed = filteredSpeed(frame.angularSpeed, at: t)
        let steady = frame.trackingNormal && speed < parameters.maxAngularSpeed
        if let shift = frame.viewShift {
            moved += shift
        } else if frame.angularSpeed.isFinite {
            travelled += frame.angularSpeed * dt
        }
        let distance = frame.viewShift == nil ? travelled : (moved.x * moved.x + moved.y * moved.y).squareRoot()
        if !isArmed && (!frame.trackingNormal || distance >= parameters.rearmAngle) {
            isArmed = true  // the view has changed: the hold timer starts again from here
            holdStart = steady ? t : nil
        }
        guard steady else {
            holdStart = nil
            return isArmed ? .idle : .counted
        }
        if holdStart == nil { holdStart = t }
        guard isArmed else { return .counted }
        guard isAutoCountEnabled else { return .idle }
        let held = t - holdStart!
        if held >= parameters.holdDuration - 1e-6 {
            guard frame.hasStableCandidate else { return .holding(progress: 1) }
            markCommitted()
            return .commit
        }
        return .holding(progress: max(0, min(1, held / parameters.holdDuration)))
    }

    /// The shutter (FR-13): always commits, steady or not, candidate or not. Like a hold, it disarms
    /// the trigger, so holding still afterwards doesn't count the same view again. Pause counting
    /// while tracking is limited (FR-20) by disabling the shutter in the UI.
    public mutating func shutter() -> Decision {
        markCommitted()
        return .commit
    }

    /// Forget the hold and re-arm, e.g. after switching zone.
    public mutating func reset() {
        samples.removeAll()
        holdStart = nil
        lastTimestamp = nil
        isArmed = true
        speed = .infinity
        moved = .zero
        travelled = 0
    }

    private mutating func markCommitted() {
        isArmed = false
        moved = .zero
        travelled = 0
    }

    private mutating func filteredSpeed(_ s: Double, at t: TimeInterval) -> Double {
        let value = s.isNaN ? Double.infinity : s
        guard parameters.speedFilter > 0 else { return value }
        samples.append((t, value))
        while samples.count > 3 && samples[0].t <= t - parameters.speedFilter {
            samples.removeFirst()
        }
        let sorted = samples.map(\.speed).sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
