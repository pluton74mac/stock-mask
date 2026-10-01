import Foundation

/// Events per second over the last `window` seconds (frames, detector runs).
public struct RateMeter: Sendable {
    public var window: Double
    private var times: [TimeInterval] = []

    public init(window: Double = 1) { self.window = window }

    public mutating func tick(at t: TimeInterval) {
        times.append(t)
        times.removeAll { $0 < t - window }
    }

    public func rate(at t: TimeInterval) -> Double {
        let recent = times.filter { $0 >= t - window }
        guard let first = recent.first, recent.count > 1, t > first else { return 0 }
        return Double(recent.count - 1) / (recent.last! - first)
    }
}

/// p50 / p95 over the last `capacity` measurements (P0-3: in-app latency with ARKit running).
public struct LatencyStats: Sendable, Equatable {
    public var capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int = 200) { self.capacity = capacity }

    public mutating func add(_ ms: Double) {
        values.append(ms)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var last: Double? { values.last }
    public var p50: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    public func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
}

/// PRD §10: at `serious`, the detector drops to 5 Hz; at `critical`, the camera pauses.
public enum ThermalLevel: String, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    /// Detector runs per second; nil means paused.
    public var detectorRate: Double? {
        switch self {
        case .nominal, .fair: 12
        case .serious: 5
        case .critical: nil
        }
    }

    public var message: String? {
        switch self {
        case .nominal, .fair: nil
        case .serious: "Phone is hot: slowing down"
        case .critical: "Phone is too hot: counting paused"
        }
    }
}

/// What the debug HUD shows (P0-2: tracking state, FPS, detector ms, thermal state, battery).
public struct HUDStats: Sendable, Equatable {
    public var fps: Double = 0
    public var detectorRate: Double = 0
    public var detectorP50: Double?
    public var detectorP95: Double?
    public var detectorLast: Double?
    public var thermal: ThermalLevel = .nominal
    public var battery: Float?               // 0...1, nil when unknown
    public var tracking = "–"
    public var mapping = "–"
    public var viewSpeed: Double = 0         // degrees per second
    public var sceneDistance: Float?
    public var tracks = 0
    public var stable = 0
    public var lifted = 0
    public var unlifted = 0
    public var computeUnits = ""
    public var captureFrames: Int?

    public init() {}

    public var lines: [String] {
        func f(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
        return [
            "tracking \(tracking) · map \(mapping)",
            "\(f(fps)) fps · detector \(f(detectorRate, 1)) Hz · \(computeUnits)",
            "detector ms last \(f(detectorLast)) · p50 \(f(detectorP50)) · p95 \(f(detectorP95))",
            "thermal \(thermal.rawValue) · battery \(battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")",
            "view \(f(viewSpeed))°/s · distance \(sceneDistance.map { String(format: "%.2f m", $0) } ?? "–")",
            "tracks \(tracks) (stable \(stable)) · lifted \(lifted) · no depth \(unlifted)",
        ] + (captureFrames.map { ["capturing: \($0) keyframes"] } ?? [])
    }
}
