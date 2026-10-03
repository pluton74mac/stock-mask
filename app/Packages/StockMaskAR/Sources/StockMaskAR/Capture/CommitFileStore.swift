import CoreImage
import Foundation

/// A commit's photos (PRD: "a photo record of every shelf"; FR-17's item crops), written before the
/// store records their paths ("files first": a crash leaves an orphan file, never a dangling path).
/// Layout under the app's data directory, as StockMaskCore suggests:
/// `sessions/<session-id>/keyframes/<commit-id>.jpg` and `sessions/<session-id>/crops/<item-id>.jpg`.
/// Paths are returned relative to that directory (the container's absolute path changes between
/// installs). Images are saved upright.
public actor CommitFileStore {
    public nonisolated let dataDirectory: URL
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    public func save(_ input: DetectorInput, sessionID: UUID?, commitID: UUID,
                     crops: [(id: UUID, box: SIMD4<Float>)], quality: Double = 0.7) -> CommitFiles {
        let base = "sessions/\(sessionID?.uuidString.lowercased() ?? "unsaved")"
        let source: CIImage = switch input.source {
        case .pixelBuffer(let b): CIImage(cvPixelBuffer: b)
        case .image(let i): CIImage(cgImage: i)
        }
        let upright = source.oriented(input.orientation.cgImageOrientation)
        let extent = upright.extent
        var files = CommitFiles()
        files.keyframe = write(upright, to: "\(base)/keyframes/\(commitID.uuidString.lowercased()).jpg", quality: quality)
        for (id, box) in crops {
            // Boxes are normalised with the origin top-left; Core Image's origin is bottom-left.
            let rect = CGRect(x: extent.minX + CGFloat(box.x) * extent.width,
                              y: extent.minY + CGFloat(1 - box.w) * extent.height,
                              width: CGFloat(box.z - box.x) * extent.width,
                              height: CGFloat(box.w - box.y) * extent.height).intersection(extent)
            guard rect.width >= 2, rect.height >= 2 else { continue }
            files.crops[id] = write(upright.cropped(to: rect), to: "\(base)/crops/\(id.uuidString.lowercased()).jpg",
                                    quality: quality)
        }
        return files
    }

    private func write(_ image: CIImage, to path: String, quality: Double) -> String? {
        let url = dataDirectory.appendingPathComponent(path)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: options) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return path
        } catch {
            return nil
        }
    }
}
