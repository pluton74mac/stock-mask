import CoreML
import Foundation
import Vision

public enum DetectorError: Error, CustomStringConvertible {
    case unsupportedModel(String)
    case missingOutput(String)

    public var description: String {
        switch self {
        case .unsupportedModel(let why): "unsupported detector model: \(why)"
        case .missingOutput(let name): "the detector returned no \(name)"
        }
    }
}

/// The Core ML detector. The model must carry the metadata `ml/coreml/export_detector.py` writes
/// (class list, output names, thresholds, resize rule).
///
/// Decoders (`stockmask.decoder`):
/// - `detr`: raw RF-DETR outputs (`boxes`, `logits`), decoded by `DETRDecoder`. The input image is
///   made by `ModelInputResizer` (rfdetr's own resize), not by Vision, whose antialiased resize
///   costs bottles (`ml/coreml/RESULTS.md`).
/// - `vision`: a model Vision reads as object observations (e.g. YOLO with Core ML's NMS stage);
///   Vision does the resize.
///
/// An actor, so one frame is in flight at a time (ADR 001). Compute units: the app asks for the
/// Neural Engine (ADR 001; on the phone nothing counted on the GPU, see StockMaskAR's README, "GPU
/// or Neural Engine"), although on an M5 Mac its FP16 output fails parity with PyTorch while the
/// GPU's passes (`ml/coreml/RESULTS.md`). This initialiser's default stays CPU + GPU for the
/// parity tests; the debug HUD switches.
public actor CoreMLDetector: Detector {
    public nonisolated let info: DetectorInfo
    public nonisolated let computeUnits: MLComputeUnits
    private let model: MLModel
    private let visionModel: VNCoreMLModel?
    private let inputName: String
    private let metadata: ModelMetadata
    private let decoder: DETRDecoder
    /// The last outputs' names, element types, shapes and strides (diagnostics: does the GPU hand
    /// back what the Neural Engine does?).
    public private(set) var lastOutputInfo = ""

    public init(compiledModelURL url: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let ml = try MLModel(contentsOf: url, configuration: config)
        let values = ml.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let meta = try ModelMetadata(values)
        guard let input = ml.modelDescription.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let image = input.imageConstraint else {
            throw DetectorError.unsupportedModel("the model has no image input")
        }
        switch meta.decoder {
        case "detr":
            let outputs = ml.modelDescription.outputDescriptionsByName
            guard outputs[meta.boxesOutput] != nil, outputs[meta.logitsOutput] != nil else {
                throw DetectorError.unsupportedModel("no outputs named \(meta.boxesOutput) and \(meta.logitsOutput)")
            }
            visionModel = nil
        case "vision":
            visionModel = try VNCoreMLModel(for: ml)
        default:
            throw DetectorError.unsupportedModel("decoder \(meta.decoder)")
        }
        model = ml
        inputName = input.name
        metadata = meta
        info = DetectorInfo(classNames: meta.classNames, scoreShown: meta.scoreShown, scoreCommit: meta.scoreCommit,
                            inputSize: SIMD2(image.pixelsWide, image.pixelsHigh), source: meta.source)
        decoder = DETRDecoder(classNames: meta.classNames, numSelect: meta.numSelect)
        self.computeUnits = computeUnits
    }

    /// Compiles an `.mlpackage` into a temporary `.mlmodelc` (on the device or on a Mac; no Xcode needed).
    public static func compile(_ packageURL: URL) async throws -> URL {
        try await MLModel.compileModel(at: packageURL)
    }

    public func detect(_ input: DetectorInput) throws -> DetectorOutput {
        let clock = ContinuousClock()
        let start = clock.now
        let detections = try visionModel.map { try detectWithVision($0, input) } ?? detectDETR(input)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return DetectorOutput(detections: detections, milliseconds: ms)
    }

    private func detectDETR(_ input: DetectorInput) throws -> [RawDetection] {
        let size = info.inputSize ?? SIMD2(384, 384)
        let image = try ModelInputResizer.resize(input, to: size)
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: image)])
        let out = try model.prediction(from: features)
        guard let boxes = out.featureValue(for: metadata.boxesOutput)?.multiArrayValue else {
            throw DetectorError.missingOutput(metadata.boxesOutput)
        }
        guard let logits = out.featureValue(for: metadata.logitsOutput)?.multiArrayValue else {
            throw DetectorError.missingOutput(metadata.logitsOutput)
        }
        lastOutputInfo = [(metadata.boxesOutput, boxes), (metadata.logitsOutput, logits)].map { name, a in
            "\(name) \(Self.typeName(a.dataType)) \(a.shape.map(\.intValue)) strides \(a.strides.map(\.intValue))"
        }.joined(separator: "; ")
        let queries = boxes.shape.count >= 2 ? boxes.shape[boxes.shape.count - 2].intValue : boxes.count / 4
        return DETRDecoder.deduplicated(decoder.decode(boxes: MultiArrayReader.floats(boxes),
                                                       logits: MultiArrayReader.floats(logits),
                                                       queries: queries, threshold: info.scoreShown))
    }

    private func detectWithVision(_ vision: VNCoreMLModel, _ input: DetectorInput) throws -> [RawDetection] {
        let request = VNCoreMLRequest(model: vision)
        request.imageCropAndScaleOption = .scaleFill
        let handler: VNImageRequestHandler = switch input.source {
        case .pixelBuffer(let buffer):
            VNImageRequestHandler(cvPixelBuffer: buffer, orientation: input.orientation.cgImageOrientation, options: [:])
        case .image(let image):
            VNImageRequestHandler(cgImage: image, orientation: input.orientation.cgImageOrientation, options: [:])
        }
        try handler.perform([request])
        var detections: [RawDetection] = []
        for case let o as VNRecognizedObjectObservation in request.results ?? [] {
            guard let top = o.labels.first, top.confidence > info.scoreShown else { continue }
            let b = o.boundingBox   // Vision: normalised, origin bottom-left
            detections.append(RawDetection(label: top.identifier, score: top.confidence,
                                           box: SIMD4(Float(b.minX), Float(1 - b.maxY), Float(b.maxX), Float(1 - b.minY))))
        }
        return detections
    }
}

extension CoreMLDetector {
    static func typeName(_ t: MLMultiArrayDataType) -> String {
        switch t {
        case .float32: "float32"
        case .float16: "float16"
        case .double: "double"
        case .int32: "int32"
        default: "type \(t.rawValue)"
        }
    }
}

/// Reads an MLMultiArray of any rank and strides into row-major Floats.
enum MultiArrayReader {
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        let type = a.dataType
        a.withUnsafeBytes { raw in
            var index = [Int](repeating: 0, count: shape.count)
            for i in 0..<count {
                var offset = 0
                for d in 0..<shape.count { offset += index[d] * strides[d] }
                out[i] = read(raw, offset, type)
                var d = shape.count - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < shape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        return out
    }

    private static func read(_ raw: UnsafeRawBufferPointer, _ i: Int, _ type: MLMultiArrayDataType) -> Float {
        switch type {
        case .double: Float(raw.load(fromByteOffset: i * 8, as: Double.self))
        case .int32: Float(raw.load(fromByteOffset: i * 4, as: Int32.self))
        #if arch(arm64)
        case .float16: Float(raw.load(fromByteOffset: i * 2, as: Float16.self))
        #endif
        default: raw.load(fromByteOffset: i * 4, as: Float.self)   // .float32
        }
    }
}
