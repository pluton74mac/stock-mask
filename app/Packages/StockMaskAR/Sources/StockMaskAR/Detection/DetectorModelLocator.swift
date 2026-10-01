import CoreML
import Foundation

/// Finds the detector model the app should load.
///
/// 1. `Documents/Models/*.mlpackage` (newest first): a model copied in through the Files app or
///    Finder, so a fine-tuned model can be tried without rebuilding. It is compiled on the device
///    once and the compiled copy is kept in `cache`.
/// 2. `StockMaskDetector.mlmodelc` in the app bundle: Xcode compiles the bundled `.mlpackage` to it
///    (see app/StockMask/README.md).
public enum DetectorModelLocator {
    public static let bundledName = "StockMaskDetector"

    public static func locate(bundle: Bundle = .main, documents: URL?, cache: URL) async throws -> URL? {
        if let documents, let package = newestPackage(in: documents.appendingPathComponent("Models")) {
            return try await compiled(package, cache: cache)
        }
        return bundle.url(forResource: bundledName, withExtension: "mlmodelc")
    }

    static func newestPackage(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return names.filter { $0.pathExtension == "mlpackage" }.max { modified($0) < modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The compiled copy of `package` in `cache`, compiling it when the package is newer.
    public static func compiled(_ package: URL, cache: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let stamp = Int(modified(package).timeIntervalSince1970)
        let target = cache.appendingPathComponent("\(package.deletingPathExtension().lastPathComponent)-\(stamp).mlmodelc")
        if fm.fileExists(atPath: target.path) { return target }
        let temporary = try await MLModel.compileModel(at: package)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: temporary, to: target)
        return target
    }
}
