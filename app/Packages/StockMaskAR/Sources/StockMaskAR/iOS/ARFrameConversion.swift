#if os(iOS)
// NOT COMPILED YET: needs the iOS SDK (Xcode). See the package README, "Not compiled yet".
@preconcurrency import ARKit
import CoreVideo
import simd

/// ARKit -> StockMaskAR's plain values. Everything here reads an ARFrame inside the delegate
/// callback and copies what it needs (or holds only its camera buffer, for one detector run), so no
/// ARFrame outlives the callback (ADR 001: ARKit's buffer pool is finite).
enum ARFrameConversion {
    /// The app is portrait-only (Info.plist), and ARKit's captured image is always landscape:
    /// turning it 90° clockwise shows it as the user sees it.
    static let orientation = FrameOrientation.right

    static func tracking(_ s: ARCamera.TrackingState) -> TrackingStatus {
        switch s {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .limited(.initializing)
            case .relocalizing: return .limited(.relocalizing)
            case .excessiveMotion: return .limited(.excessiveMotion)
            case .insufficientFeatures: return .limited(.insufficientFeatures)
            @unknown default: return .limited(.unknown)
            }
        }
    }

    static func mapping(_ s: ARFrame.WorldMappingStatus) -> MappingStatus {
        switch s {
        case .notAvailable: return .notAvailable
        case .limited: return .limited
        case .extending: return .extending
        case .mapped: return .mapped
        @unknown default: return .limited
        }
    }

    /// ARKit's camera for the stored image (landscape): intrinsics in its pixels, camera to world.
    static func sensorCamera(_ frame: ARFrame) -> CameraModel {
        let size = frame.camera.imageResolution
        return CameraModel(intrinsics: frame.camera.intrinsics, imageSize: SIMD2(Float(size.width), Float(size.height)),
                           transform: frame.camera.transform)
    }

    /// Every frame: pose, tracking, time. No depth (cheap at 60 Hz).
    static func light(_ frame: ARFrame) -> FrameSnapshot {
        FrameSnapshot(timestamp: frame.timestamp, camera: sensorCamera(frame).upright(orientation), orientation: orientation,
                      tracking: tracking(frame.camera.trackingState), mapping: mapping(frame.worldMappingStatus))
    }

    /// Detector and commit frames: the same plus the depth map (copied, turned upright) and the planes.
    static func full(_ frame: ARFrame, planes: [SupportPlane], smoothed: Bool) -> FrameSnapshot {
        let data = smoothed ? (frame.smoothedSceneDepth ?? frame.sceneDepth) : frame.sceneDepth
        let depth = data.flatMap { DepthMap(depthBuffer: $0.depthMap, confidenceBuffer: $0.confidenceMap) }
        return FrameSnapshot(timestamp: frame.timestamp, camera: sensorCamera(frame).upright(orientation),
                             orientation: orientation, depth: depth?.upright(orientation),
                             tracking: tracking(frame.camera.trackingState), mapping: mapping(frame.worldMappingStatus),
                             planes: planes)
    }

    /// The camera image for the detector (Core ML gets it resized by ModelInputResizer) and the commit.
    static func detectorInput(_ frame: ARFrame) -> DetectorInput {
        DetectorInput(pixelBuffer: frame.capturedImage, orientation: orientation)
    }

    /// Capture mode keeps everything as ARKit delivers it (research/capture_replay/README.md).
    static func captureFrame(_ frame: ARFrame, detections: [RawDetection]) -> CaptureFrame {
        func map(_ d: ARDepthData?) -> DepthMap? { d.flatMap { DepthMap(depthBuffer: $0.depthMap, confidenceBuffer: $0.confidenceMap) } }
        return CaptureFrame(
            timestamp: frame.timestamp, image: .pixelBuffer(frame.capturedImage), depth: map(frame.sceneDepth),
            smoothedDepth: map(frame.smoothedSceneDepth), intrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform, orientation: orientation,
            tracking: tracking(frame.camera.trackingState).name, mapping: mapping(frame.worldMappingStatus).rawValue,
            exposureDuration: frame.camera.exposureDuration, exposureOffset: Double(frame.camera.exposureOffset),
            ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) },
            ambientColorTemperature: frame.lightEstimate.map { Double($0.ambientColorTemperature) },
            detections: detections)
    }

    /// A horizontal plane anchor (a shelf board, the floor) as a support plane for the Lifter's
    /// shelf-plane fallback (P0-4 strategy d).
    static func supportPlane(_ a: ARPlaneAnchor) -> SupportPlane? {
        guard a.alignment == .horizontal else { return nil }
        let e = a.planeExtent   // iOS 16+: width, height (along local x, z), rotationOnYAxis
        let local = simd_float4x4.translation(a.center) * simd_float4x4(simd_quatf(angle: e.rotationOnYAxis, axis: SIMD3(0, 1, 0)))
        return SupportPlane(transform: a.transform * local, extent: SIMD2(e.width, e.height))
    }
}
#endif
