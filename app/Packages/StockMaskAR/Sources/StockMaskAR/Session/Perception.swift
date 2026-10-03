import Foundation
import StockMaskCounting
import simd

/// A detector box after lifting: what the yellow outlines and the live tracks are made of.
public struct LiftedDetection: Sendable, Equatable {
    public var raw: RawDetection
    public var cls: ObjectClass
    public var lift: LiftResult?

    public var observation: LiveTracks.Observation {
        LiveTracks.Observation(cls: cls, label: raw.label, score: raw.score, box: raw.box, position: lift?.chosen.position,
                               size: lift?.size, plausible: lift?.plausible ?? true)
    }
}

public enum Perception {
    /// Keeps our classes (bottle, can, case, bottle_top) and lifts each box to 3D with the depth,
    /// camera and planes of the frame the detector saw.
    public static func lift(_ output: DetectorOutput, frame: FrameSnapshot, lifter: Lifter = Lifter()) -> [LiftedDetection] {
        output.detections.compactMap { raw in
            guard let cls = raw.cls else { return nil }
            let lift = lifter.lift(box: raw.box, cls: cls, depth: frame.depth, camera: frame.camera, planes: frame.planes)
            return LiftedDetection(raw: raw, cls: cls, lift: lift)
        }
    }

}
