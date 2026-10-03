import CoreGraphics
import CoreVideo
import StockMaskCounting

/// What a detector looks at: a camera buffer (on the phone) or an image (tests, replay), plus how
/// it turns upright. Detectors return boxes in the upright image.
public struct DetectorInput: @unchecked Sendable {  // the buffer/image is never written while in flight
    public enum Source {
        case pixelBuffer(CVPixelBuffer)
        case image(CGImage)
    }

    public var source: Source
    public var orientation: FrameOrientation

    public init(pixelBuffer: CVPixelBuffer, orientation: FrameOrientation) {
        source = .pixelBuffer(pixelBuffer)
        self.orientation = orientation
    }

    public init(image: CGImage, orientation: FrameOrientation = .up) {
        source = .image(image)
        self.orientation = orientation
    }

    /// Size of the upright image in pixels.
    public var uprightSize: SIMD2<Float> {
        let s: SIMD2<Float> = switch source {
        case .pixelBuffer(let b): SIMD2(Float(CVPixelBufferGetWidth(b)), Float(CVPixelBufferGetHeight(b)))
        case .image(let i): SIMD2(Float(i.width), Float(i.height))
        }
        return orientation.uprightSize(sensor: s)
    }
}

/// One detector box in the upright image: normalised x0, y0, x1, y1, origin top-left.
public struct RawDetection: Sendable, Equatable {
    public var label: String          // the model's own class name
    public var cls: ObjectClass?      // ours, when the label is bottle, can, case or bottle_top
    public var score: Float
    public var box: SIMD4<Float>

    public init(label: String, score: Float, box: SIMD4<Float>) {
        self.label = label
        cls = ObjectClass(rawValue: label)
        self.score = score
        self.box = box
    }
}

public struct DetectorOutput: Sendable {
    public var detections: [RawDetection]
    public var milliseconds: Double

    public init(detections: [RawDetection], milliseconds: Double) {
        self.detections = detections
        self.milliseconds = milliseconds
    }
}

/// What the app needs to know about a model; read from its metadata, never hard-coded.
public struct DetectorInfo: Sendable, Equatable {
    public var classNames: [String]   // by output slot; "" for unused slots
    public var scoreShown: Float      // from here a box is drawn (dashed below `scoreCommit`, FR-18)
    public var scoreCommit: Float     // from here it can be counted
    public var inputSize: SIMD2<Int>?
    public var source: String

    public init(classNames: [String], scoreShown: Float = 0.3, scoreCommit: Float = 0.5, inputSize: SIMD2<Int>? = nil,
                source: String = "") {
        self.classNames = classNames
        self.scoreShown = scoreShown
        self.scoreCommit = scoreCommit
        self.inputSize = inputSize
        self.source = source
    }

    /// The model's classes that are ours (bottle, can, case, bottle_top).
    public var countedClasses: [ObjectClass] {
        var seen: [ObjectClass] = []
        for name in classNames { if let c = ObjectClass(rawValue: name), !seen.contains(c) { seen.append(c) } }
        return seen
    }
}

/// The detector behind the app (ADR 002: swappable). RF-DETR through Core ML now; a fine-tuned
/// model or a YOLO with Core ML's NMS later, with no change above this protocol.
public protocol Detector: Sendable {
    var info: DetectorInfo { get }
    func detect(_ input: DetectorInput) async throws -> DetectorOutput
}
