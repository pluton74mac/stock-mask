import CoreGraphics
import ImageIO
import Foundation
import Vision

/// A product the app suggests for a group. Never assigned without a tap (PRD FR-31).
public struct Suggestion: Sendable, Equatable {
    public enum Source: String, Sendable {
        case teachOnce = "looks like a product named before"
        case labelText = "label text"
    }

    public var product: ProductInfo
    public var source: Source
    public var confidence: Float   // 0...1
    public var evidence: String    // e.g. the label words that matched

    public init(product: ProductInfo, source: Source, confidence: Float, evidence: String = "") {
        self.product = product
        self.source = source
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Fuzzy-matches label text (from OCR) against the catalogue: every word of a product's name is
/// looked for among the label's words, allowing OCR slips (edit distance), longer words counting
/// more. The brand's words count too when the label shows them, but a label without the brand
/// isn't marked down for it (catalogues often repeat the brand in the name, labels often hide it
/// on the back). A matching size ("750", "750ml", "75cl") adds a little. At least four letters must
/// match, so a lone "gin" picks nothing.
public struct ProductMatcher: Sendable {
    public var minimumConfidence: Float = 0.45
    /// Words that say nothing about the product.
    public var ignored: Set<String> = ["ml", "cc", "cl", "lt", "l", "de", "la", "el", "los", "las", "del", "y", "the", "of",
                                       "and", "x", "con"]

    public init() {}

    public func best(texts: [String], among products: [ProductInfo]) -> (product: ProductInfo, confidence: Float, words: [String])? {
        let label = Set(texts.flatMap(Self.words))
        guard !label.isEmpty else { return nil }
        func meaningful(_ text: String) -> Set<String> {
            Set(Self.words(text).filter { !ignored.contains($0) && $0.rangeOfCharacter(from: .letters) != nil })
        }
        func found(_ words: Set<String>) -> (got: Float, total: Float, matched: [String]) {
            var got: Float = 0, total: Float = 0
            var matched: [String] = []
            for w in words.sorted() {
                let weight = Float(w.count)
                total += weight
                let sim = label.map { Self.similarity(w, $0) }.max() ?? 0
                if sim >= 0.75 {
                    got += weight * sim
                    matched.append(w)
                }
            }
            return (got, total, matched)
        }
        var scored: [(ProductInfo, Float, [String])] = []
        for p in products {
            let nameWords = meaningful(p.name)
            guard !nameWords.isEmpty else { continue }
            let name = found(nameWords), brand = found(meaningful(p.brand).subtracting(nameWords))
            guard name.got + brand.got >= 4 else { continue }
            var score = max(name.got / name.total, (name.got + brand.got) / (name.total + brand.total))
            if let size = p.sizeML, Self.hasSize(size, in: label) { score = min(1, score + 0.1) }
            scored.append((p, score, name.matched + brand.matched))
        }
        scored.sort { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= minimumConfidence else { return nil }
        // A near tie with another product is less sure.
        let confidence = scored.count > 1 && scored[1].1 > top.1 - 0.1 ? top.1 * 0.8 : top.1
        return (top.0, confidence, top.2)
    }

    /// Lowercased, accents folded, split on anything that isn't a letter or a digit.
    public static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) && !$0.isEmpty }
    }

    /// 1 - edit distance / longer length.
    public static func similarity(_ a: String, _ b: String) -> Float {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Float(prev[y.count]) / Float(max(x.count, y.count))
    }

    static func hasSize(_ ml: Int, in label: Set<String>) -> Bool {
        var forms: Set<String> = ["\(ml)", "\(ml)ml", "\(ml)cc"]
        if ml % 10 == 0 { forms.insert("\(ml / 10)cl") }
        if ml % 1000 == 0 { forms.insert("\(ml / 1000)l"); forms.insert("\(ml / 1000)lt") }
        return !forms.isDisjoint(with: label)
    }
}

/// Teach-once (ADR 004): once the user names a group, its items' appearance (FeaturePrint) is kept
/// for that product, and later groups that look the same get it suggested. Session memory only.
public struct TeachOnce: Sendable {
    public var threshold: Float = 0.6      // the same distance the grouper merges at
    public var maxExamples = 24
    private var examples: [UUID: (product: ProductInfo, embeddings: [[Float]])] = [:]

    public init() {}

    public var productCount: Int { examples.count }

    public mutating func learn(_ product: ProductInfo, embeddings: [[Float]]) {
        guard !embeddings.isEmpty else { return }
        var entry = examples[product.id] ?? (product, [])
        entry.product = product
        entry.embeddings = Array((entry.embeddings + embeddings).suffix(maxExamples))
        examples[product.id] = entry
    }

    /// The product whose examples are nearest the group's items (average distance), if close enough.
    public func suggest(_ embeddings: [[Float]]) -> (product: ProductInfo, confidence: Float)? {
        guard !embeddings.isEmpty else { return nil }
        var best: (ProductInfo, Float)?
        for (_, e) in examples {
            var sum: Float = 0
            for a in embeddings { sum += e.embeddings.map { ItemGrouper.distance(a, $0) }.min() ?? .infinity }
            let d = sum / Float(embeddings.count)
            if d < (best?.1 ?? .infinity) { best = (e.product, d) }
        }
        guard let best, best.1 < threshold else { return nil }
        return (best.0, 1 - best.1 / threshold)
    }
}

/// Reads the text on a group's photo crops.
public protocol LabelReader: Sendable {
    func read(_ images: [CGImage], hints: [String]) async throws -> [String]
}

/// Apple Vision's text recognition, Spanish and English, with the catalogue's words as hints.
public actor VisionLabelReader: LabelReader {
    public init() {}

    public func read(_ images: [CGImage], hints: [String]) throws -> [String] {
        var texts: [String] = []
        for image in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es-ES", "en-US"]
            request.usesLanguageCorrection = true
            request.customWords = Array(hints.prefix(500))
            request.minimumTextHeight = 0.02
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            texts += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        return texts
    }
}

/// Loads a photo the app saved (keyframe or crop), from its path relative to the data directory.
public enum PhotoLoader {
    /// Decoded straight away (not when first drawn), so the caller's thread pays for it.
    public static func image(_ path: String, in dataDirectory: URL?) -> CGImage? {
        guard let dataDirectory,
              let source = CGImageSourceCreateWithURL(dataDirectory.appendingPathComponent(path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// `image(_:in:)` off the main thread.
    public static func load(_ path: String, in dataDirectory: URL?) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { image(path, in: dataDirectory) }.value
    }
}
