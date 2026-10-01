// SHIM: remove at integration (see ../../Package.swift).
// FR-13 in its simplest form: commit after `holdSeconds` under `maxDegreesPerSecond`, with a stable
// candidate in view and tracking normal; then wait for `rearmDegrees` of movement.
import Foundation

public struct HoldTrigger: Sendable {
    public var holdSeconds: Double
    public var maxDegreesPerSecond: Double
    public var rearmDegrees: Double

    private var steadySince: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var armed = true
    private var movedSinceCommit = 0.0

    public init(holdSeconds: Double = 0.8, maxDegreesPerSecond: Double = 10, rearmDegrees: Double = 5) {
        self.holdSeconds = holdSeconds
        self.maxDegreesPerSecond = maxDegreesPerSecond
        self.rearmDegrees = rearmDegrees
    }

    /// Feed one frame. Returns true when a commit should fire now.
    public mutating func update(angularSpeed: Double, timestamp: TimeInterval, stableCandidateInView: Bool,
                                trackingNormal: Bool) -> Bool {
        let dt = lastTimestamp.map { max(0, timestamp - $0) } ?? 0
        lastTimestamp = timestamp
        if !armed {
            movedSinceCommit += angularSpeed * dt
            if movedSinceCommit >= rearmDegrees { armed = true }
        }
        guard trackingNormal, angularSpeed < maxDegreesPerSecond else {
            steadySince = nil
            return false
        }
        let since = steadySince ?? timestamp
        steadySince = since
        guard armed, stableCandidateInView, timestamp - since >= holdSeconds else { return false }
        didCommit()
        return true
    }

    /// Call after every commit, including the shutter's.
    public mutating func didCommit() {
        armed = false
        movedSinceCommit = 0
        steadySince = nil
    }

    /// 0...1: how far into a hold the view is (for a progress ring); 0 while not armed.
    public func holdProgress(at timestamp: TimeInterval) -> Double {
        guard armed, let since = steadySince else { return 0 }
        return min(1, max(0, (timestamp - since) / holdSeconds))
    }
}
