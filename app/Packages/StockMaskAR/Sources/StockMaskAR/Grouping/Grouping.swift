import Foundation
import StockMaskCounting
import Vision

/// ADR 004 step 1: "group the items that look the same". Items are clustered within each class
/// by their appearance embeddings (average linkage, merging while the clusters are closer than
/// `threshold`). Items without an embedding share one group per class. Keys run 0, 1, 2, ... from
/// the largest group down. The threshold is a starting value: P0-6 calibrates it on real crops.
public struct ItemGrouper: Sendable {
    public var threshold: Float

    public init(threshold: Float = 0.6) { self.threshold = threshold }

    public func groups(classes: [ObjectClass], embeddings: [[Float]?]) -> [Int] {
        precondition(classes.count == embeddings.count)
        var clusters: [[Int]] = []
        for cls in ObjectClass.allCases {
            let members = classes.indices.filter { classes[$0] == cls }
            let withEmbedding = members.filter { embeddings[$0] != nil }
            let without = members.filter { embeddings[$0] == nil }
            var cs = withEmbedding.map { [$0] }
            while cs.count > 1 {
                var best: (d: Float, i: Int, j: Int)?
                for i in 0..<cs.count {
                    for j in (i + 1)..<cs.count {
                        let d = averageDistance(cs[i], cs[j], embeddings)
                        if d < (best?.d ?? .infinity) { best = (d, i, j) }
                    }
                }
                guard let b = best, b.d < threshold else { break }
                cs[b.i] += cs[b.j]
                cs.remove(at: b.j)
            }
            clusters += cs
            if !without.isEmpty { clusters.append(without) }
        }
        clusters.sort { $0.count != $1.count ? $0.count > $1.count : $0.min()! < $1.min()! }
        var keys = [Int](repeating: 0, count: classes.count)
        for (k, c) in clusters.enumerated() { for i in c { keys[i] = k } }
        return keys
    }

    func averageDistance(_ a: [Int], _ b: [Int], _ e: [[Float]?]) -> Float {
        var sum: Float = 0
        for i in a { for j in b { sum += Self.distance(e[i]!, e[j]!) } }
        return sum / Float(a.count * b.count)
    }

    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<min(a.count, b.count) { let d = a[k] - b[k]; s += d * d }
        return s.squareRoot()
    }
}

/// An appearance embedding per box of an image (nil where it fails).
public protocol AppearanceEmbedder: Sendable {
    func embeddings(of boxes: [SIMD4<Float>], in image: DetectorInput) async throws -> [[Float]?]
}

/// Apple Vision's FeaturePrint (ADR 004: revision 2, pinned, because stored embeddings are tied to
/// it). Each box is a region of interest of the upright image.
public actor FeaturePrintEmbedder: AppearanceEmbedder {
    public init() {}

    public func embeddings(of boxes: [SIMD4<Float>], in image: DetectorInput) throws -> [[Float]?] {
        guard !boxes.isEmpty else { return [] }
        let requests = boxes.map { b -> VNGenerateImageFeaturePrintRequest in
            let r = VNGenerateImageFeaturePrintRequest()
            r.revision = VNGenerateImageFeaturePrintRequestRevision2
            r.imageCropAndScaleOption = .scaleFill
            // Vision's regions are normalised with the origin bottom-left.
            let x0 = max(0, min(1, b.x)), x1 = max(0, min(1, b.z)), y0 = max(0, min(1, b.y)), y1 = max(0, min(1, b.w))
            r.regionOfInterest = CGRect(x: CGFloat(x0), y: CGFloat(1 - y1), width: CGFloat(max(x1 - x0, 1e-3)),
                                        height: CGFloat(max(y1 - y0, 1e-3)))
            return r
        }
        let handler: VNImageRequestHandler = switch image.source {
        case .pixelBuffer(let buffer):
            VNImageRequestHandler(cvPixelBuffer: buffer, orientation: image.orientation.cgImageOrientation, options: [:])
        case .image(let cg):
            VNImageRequestHandler(cgImage: cg, orientation: image.orientation.cgImageOrientation, options: [:])
        }
        try handler.perform(requests)
        return requests.map { r in
            guard let o = r.results?.first, o.elementType == .float else { return nil }
            return o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
}
