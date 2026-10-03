import Foundation
import simd

/// ARKit's tracking state as plain values (FR-20: counting pauses, with the reason shown).
public enum TrackingStatus: Sendable, Equatable {
    case normal
    case limited(Reason)
    case notAvailable

    public enum Reason: String, Sendable {
        case initializing, relocalizing, excessiveMotion, insufficientFeatures, unknown
    }

    public var isNormal: Bool { self == .normal }

    /// The name capture mode writes (research/capture_replay/README.md).
    public var name: String {
        switch self {
        case .normal: "normal"
        case .limited(let r): "limited:\(r.rawValue)"
        case .notAvailable: "notAvailable"
        }
    }

    /// What the user reads while counting is paused (PRD §9 hints).
    public var pauseMessage: String? {
        switch self {
        case .normal: nil
        case .notAvailable: "Tracking lost: point at a shelf you already counted"
        case .limited(.initializing): "Starting: move the phone slowly"
        case .limited(.relocalizing): "Tracking lost: point at a shelf you already counted"
        case .limited(.excessiveMotion): "Move slower"
        case .limited(.insufficientFeatures): "Too dark or too plain: turn on the torch"
        case .limited(.unknown): "Tracking limited"
        }
    }
}

public enum MappingStatus: String, Sendable {
    case notAvailable, limited, extending, mapped
}

/// One AR frame as plain values, in the upright image (see FrameOrientation). Built from an ARFrame
/// by ARFrameConversion.swift on the phone, and by hand in tests. Holds no camera buffer.
public struct FrameSnapshot: Sendable {
    public var timestamp: TimeInterval
    public var camera: CameraModel            // upright
    /// How ARKit's stored image turns upright (`.right` in portrait): the counting engine works in
    /// the stored image, so the bridge turns boxes and the camera back with it.
    public var orientation: FrameOrientation
    public var depth: DepthMap?               // upright; nil when not copied for this frame
    public var tracking: TrackingStatus
    public var mapping: MappingStatus
    public var planes: [SupportPlane]
    public var sceneDistance: Float?          // median depth in the middle of the view

    public init(timestamp: TimeInterval, camera: CameraModel, orientation: FrameOrientation = .up, depth: DepthMap? = nil,
                tracking: TrackingStatus = .normal, mapping: MappingStatus = .mapped, planes: [SupportPlane] = [],
                sceneDistance: Float? = nil) {
        self.timestamp = timestamp
        self.camera = camera
        self.orientation = orientation
        self.depth = depth
        self.tracking = tracking
        self.mapping = mapping
        self.planes = planes
        self.sceneDistance = sceneDistance ?? ViewMotion.sceneDistance(depth)
    }
}
