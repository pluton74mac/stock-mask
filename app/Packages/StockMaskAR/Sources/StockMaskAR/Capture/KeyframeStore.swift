import CoreImage
import Foundation

/// Each commit's photo (PRD: "a photo record of every shelf"; `commit.keyframe_file`), saved upright
/// as JPEG under `folder`, off the main thread.
public actor KeyframeStore {
    public nonisolated let folder: URL
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
    }

    /// Writes `<id>.jpg` and returns its path relative to the folder's parent (e.g. "Keyframes/<id>.jpg").
    public func save(_ input: DetectorInput, id: UUID, quality: Double = 0.7) throws -> String {
        let image: CIImage = switch input.source {
        case .pixelBuffer(let b): CIImage(cvPixelBuffer: b)
        case .image(let i): CIImage(cgImage: i)
        }
        let upright = image.oriented(input.orientation.cgImageOrientation)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = context.jpegRepresentation(of: upright, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: options) else { throw JPEGEncoder.Problem.encodingFailed }
        let name = "\(id.uuidString).jpg"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return "\(folder.lastPathComponent)/\(name)"
    }
}
