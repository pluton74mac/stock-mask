import Foundation

/// Reads a capture folder back (tests, and replays on a Mac). The Python equivalent is
/// research/capture_replay/read_capture.py.
public struct CaptureReader: Sendable {
    public enum Problem: Error, Equatable {
        case notACapture(String)
        case unsupportedVersion(Int)
    }

    public let folder: URL
    public let manifest: CaptureManifest
    public let frames: [CaptureFrameRecord]

    public init(folder: URL) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(CaptureManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        guard manifest.format == CaptureFormat.name else { throw Problem.notACapture(manifest.format) }
        guard manifest.version <= CaptureFormat.version else { throw Problem.unsupportedVersion(manifest.version) }
        let text = try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        frames = try text.split(separator: "\n").map { try dec.decode(CaptureFrameRecord.self, from: Data($0.utf8)) }
        self.folder = folder
        self.manifest = manifest
    }

    public func imageData(_ f: CaptureFrameRecord) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(f.image)) }

    /// sceneDepth in the sensor's orientation (call `.upright(f.orientation)` to turn it).
    public func depth(_ f: CaptureFrameRecord) throws -> DepthMap? {
        try map(f.depth, f.confidence, f.depthSize)
    }

    public func smoothedDepth(_ f: CaptureFrameRecord) throws -> DepthMap? {
        try map(f.smoothedDepth, f.smoothedConfidence, f.depthSize)
    }

    private func map(_ depth: String?, _ confidence: String?, _ size: [Int]?) throws -> DepthMap? {
        guard let depth, let size, size.count == 2 else { return nil }
        let d = try Data(contentsOf: folder.appendingPathComponent(depth))
        let c = try confidence.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        return DepthMap(width: size[0], height: size[1], depthData: d, confidenceData: c)
    }
}

/// A single file for the share sheet: the capture folder zipped by the system
/// (`NSFileCoordinator`'s `.forUploading`, available on iOS and macOS; no zip library needed).
public enum CaptureArchive {
    public static func zip(_ folder: URL, to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
            let target = directory.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("zip")
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipped, to: target)
                result = .success(target)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
