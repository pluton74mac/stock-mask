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
}
