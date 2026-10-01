import Foundation

/// The creator-defined metadata `ml/coreml/export_detector.py` writes into the model. The class
/// list comes from here, so a fine-tuned model (bottle, can, case, bottle_top) replaces the COCO
/// one without code changes.
public struct ModelMetadata: Sendable, Equatable {
    public static let classesKey = "stockmask.classes"

    public var decoder: String          // "detr"
    public var classNames: [String]
    public var boxesOutput: String
    public var logitsOutput: String
    public var numSelect: Int
    public var scoreShown: Float
    public var scoreCommit: Float
    public var source: String

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalid(String)
        public var description: String {
            switch self {
            case .missing(let k): "model metadata has no \(k)"
            case .invalid(let k): "model metadata \(k) is not valid"
            }
        }
    }

    public init(_ values: [String: String]) throws {
        guard let json = values[Self.classesKey] else { throw Problem.missing(Self.classesKey) }
        guard let data = json.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data),
              !names.isEmpty else { throw Problem.invalid(Self.classesKey) }
        classNames = names
        decoder = values["stockmask.decoder"] ?? "detr"
        boxesOutput = values["stockmask.boxes"] ?? "boxes"
        logitsOutput = values["stockmask.logits"] ?? "logits"
        numSelect = values["stockmask.num_select"].flatMap(Int.init) ?? 300
        scoreShown = values["stockmask.score_shown"].flatMap(Float.init) ?? 0.3
        scoreCommit = values["stockmask.score_commit"].flatMap(Float.init) ?? 0.5
        source = values["stockmask.source"] ?? ""
    }
}
