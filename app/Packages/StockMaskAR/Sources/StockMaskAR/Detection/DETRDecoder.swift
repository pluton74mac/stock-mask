import Foundation

/// Turns RF-DETR's raw outputs into boxes, exactly as rfdetr's `PostProcess` + `predict()` do:
/// scores are sigmoid(logits) over every query and class slot; the `numSelect` highest
/// (query, slot) pairs are kept (ties: lower flat index first); of those, the ones scoring above
/// the threshold become detections; boxes go from (cx, cy, w, h) to corners, clamped to [0, 1].
/// `ml/coreml/parity.py` runs the same decoding in numpy.
public struct DETRDecoder: Sendable, Equatable {
    public var classNames: [String]   // by logit slot; "" = unused slot
    public var numSelect: Int

    public init(classNames: [String], numSelect: Int = 300) {
        self.classNames = classNames
        self.numSelect = numSelect
    }

    /// - Parameters:
    ///   - boxes: `queries * 4` values, (cx, cy, w, h) normalised to the model's input.
    ///   - logits: `queries * classNames.count` values.
    public func decode(boxes: [Float], logits: [Float], queries: Int, threshold: Float) -> [RawDetection] {
        let slots = classNames.count
        precondition(boxes.count >= queries * 4 && logits.count >= queries * slots, "output sizes don't match")
        // Only logits near or above the threshold can make it; skip the sigmoid for the rest.
        let t = min(max(threshold, 1e-6), 1 - 1e-6)
        let cut = log(t / (1 - t)) - 1e-3
        var picked: [(score: Float, index: Int)] = []
        for i in 0..<(queries * slots) where logits[i] > cut {
            let s = 1 / (1 + exp(-logits[i]))
            if s > threshold { picked.append((s, i)) }
        }
        // Every candidate above the threshold outranks everything below it, so taking the top
        // numSelect after the threshold equals rfdetr's top-k-then-threshold.
        picked.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        if picked.count > numSelect { picked.removeLast(picked.count - numSelect) }
        return picked.compactMap { p in
            let q = p.index / slots, c = p.index % slots
            let label = classNames[c]
            guard !label.isEmpty else { return nil }
            let cx = boxes[q * 4], cy = boxes[q * 4 + 1], w = boxes[q * 4 + 2], h = boxes[q * 4 + 3]
            let box = SIMD4(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2).clamped(lowerBound: .zero, upperBound: .one)
            return RawDetection(label: label, score: p.score, box: box)
        }
    }

    /// Drops a box of the same label that overlaps a higher-scoring one by at least `iou`. DETR
    /// models rarely draw two boxes on one object, but the fine-tuned model of 3 October did: a
    /// close-up bottle got a second box at IoU 0.99 (ml/coreml/RESULTS.md), and the commit engine
    /// would have counted it twice. Applied after `decode`, so `decode` itself stays rfdetr's.
    public static func deduplicated(_ detections: [RawDetection], iou: Float = 0.7) -> [RawDetection] {
        var kept: [RawDetection] = []
        for d in detections.sorted(by: { $0.score > $1.score }) {
            let duplicate = kept.contains { k in
                k.label == d.label && Self.iou(k.box, d.box) >= iou
            }
            if !duplicate { kept.append(d) }
        }
        return kept
    }

    static func iou(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let ix = max(0, min(a.z, b.z) - max(a.x, b.x)), iy = max(0, min(a.w, b.w) - max(a.y, b.y))
        let inter = ix * iy
        let union = (a.z - a.x) * (a.w - a.y) + (b.z - b.x) * (b.w - b.y) - inter
        return union > 0 ? inter / union : 0
    }
}
