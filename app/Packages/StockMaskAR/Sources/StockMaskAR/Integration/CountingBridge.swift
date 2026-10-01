import Foundation
import StockMaskCounting
import simd

/// StockMaskCounting's HoldTrigger and CommitEngine behind the API the session uses. This is the
/// only file that calls them, and the only place where boxes leave StockMaskAR's upright image:
/// the engine wants boxes, intrinsics and image size in ARKit's stored image (sensor orientation,
/// landscape; StockMaskCounting README, "Conventions"), so `commit` and `preview` turn them back.
public struct CountingBridge: Sendable {
    public private(set) var trigger = HoldTrigger()
    public private(set) var engine = CommitEngine()
    private var productKeys: [UUID: Int] = [:]

    public init() {}

    /// FR-13: auto-count can be switched off; the shutter still counts.
    public var autoCount: Bool {
        get { trigger.isAutoCountEnabled }
        set { trigger.isAutoCountEnabled = newValue }
    }

    /// FR-18: the detector's commit threshold (from the model's metadata).
    public var commitScore: Float {
        get { engine.parameters.minimumScore }
        set { engine.parameters.minimumScore = newValue }
    }

    /// The engine's inner frame, for drawing it: x0, y0, x1, y1 of an image of `size`.
    public func innerFrame(imageSize size: SIMD2<Float>) -> SIMD4<Float> {
        let b = engine.parameters.innerFrame.bandFractions(imageSize: size)
        return SIMD4(Float(b.x), Float(b.y), Float(1 - b.x), Float(1 - b.y))
    }

    /// Keeps the inner frame on screen: the band (a fraction of the image's short side, 0.15 by
    /// default) grows to cover whatever the screen crops off the camera image, so nothing outside
    /// the screen is ever counted. `visible` is the shown part of the upright image of `size`.
    public mutating func setVisibleRegion(_ visible: SIMD4<Float>, imageSize size: SIMD2<Float>) {
        let short = min(size.x, size.y)
        let crops = [visible.x * size.x, (1 - visible.z) * size.x, visible.y * size.y, (1 - visible.w) * size.y]
        let band = min(0.3, max(0.15, Double(crops.max()! / short) + 0.005))
        engine.parameters.innerFrame.band = band
    }

    /// Every frame. `viewShift`: degrees across and up since the last frame (ViewMotion).
    public mutating func hold(viewSpeed: Double, viewShift: SIMD2<Double>?, at t: TimeInterval, stableCandidate: Bool,
                              trackingNormal: Bool) -> HoldTrigger.Decision {
        trigger.update(HoldTrigger.Frame(timestamp: t, angularSpeed: viewSpeed, hasStableCandidate: stableCandidate,
                                         trackingNormal: trackingNormal, viewShift: viewShift))
    }

    /// The shutter: always commits, and disarms the trigger like a hold does.
    public mutating func shutter() { _ = trigger.shutter() }

    /// One commit. `detections` are in the upright image of `camera`; their positions in world space.
    public mutating func commit(_ detections: [Detection], camera: CameraModel, orientation: FrameOrientation,
                                sceneDepth: Float?) -> CommitResult {
        engine.commit(Self.sensor(detections, orientation), view: Self.view(camera, orientation, sceneDepth))
    }

    /// What a commit would do, changing nothing (to see whether the drift alarm has cleared).
    public func preview(_ detections: [Detection], camera: CameraModel, orientation: FrameOrientation,
                        sceneDepth: Float?) -> CommitResult {
        engine.preview(Self.sensor(detections, orientation), view: Self.view(camera, orientation, sceneDepth))
    }

    @discardableResult
    public mutating func undoLastCommit() -> CommitEngine.UndoneCommit? { engine.undoLastCommit() }

    /// FR-22: the user tapped an amber "+" (detection `index` of commit `commitID`).
    public mutating func addDetection(_ index: Int, ofCommit commitID: UUID) -> CountedItem? {
        engine.addDetection(index, ofCommit: commitID)
    }

    /// FR-21: ARKit moved a commit's anchor.
    public mutating func updateAnchor(ofCommit id: UUID, to transform: simd_float4x4) {
        engine.updateAnchor(ofCommit: id, to: transform)
    }

    /// FR-27: the groups the AR layer made.
    public mutating func setGroupKeys(_ keys: [UUID: Int]) {
        for (key, ids) in Dictionary(grouping: keys.keys, by: { keys[$0]! }) { engine.setGroupKey(key, forItems: ids) }
    }

    /// FR-28: a group was named; later matches prefer the same product. nil un-names.
    public mutating func setProduct(_ product: UUID?, forItems ids: [UUID]) {
        let key = product.map { p in
            if let k = productKeys[p] { return k }
            let k = productKeys.count + 1
            productKeys[p] = k
            return k
        }
        engine.setProductKey(key, forItems: ids)
    }

    /// Boxes and sizes from the upright image to the stored image.
    static func sensor(_ detections: [Detection], _ o: FrameOrientation) -> [Detection] {
        detections.map { d in
            var s = d
            s.box = o.sensorBox(upright: d.box)
            if let size = d.size, o == .left || o == .right { s.size = SIMD2(size.y, size.x) }
            return s
        }
    }

    static func view(_ camera: CameraModel, _ o: FrameOrientation, _ sceneDepth: Float?) -> CommitView {
        let sensor = camera.sensor(o)
        return CommitView(cameraTransform: sensor.transform, pixelIntrinsics: sensor.intrinsics,
                          imageResolution: sensor.imageSize, sceneDepth: sceneDepth)
    }
}
