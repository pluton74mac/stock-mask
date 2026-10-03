import Foundation

/// A diagnostic log to copy off the phone after a test and debug from:
/// `Documents/diagnostics/<prefix>-YYYYMMDD-HHMMSS.jsonl`, one JSON object per line, written in
/// order on a background queue. Copy it with
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
///  --domain-identifier com.pluton74mac.stockmask --source Documents/diagnostics --destination <dir>`.
///
/// Record types (`type`): `start`, `sample` (about 2 Hz while counting), `commit`, `event`
/// (detector loaded or failed, commit skipped, drift alarm, ...), `benchmark`.
public final class DiagnosticsLog: @unchecked Sendable {   // the handle and encoder are used on `queue` only
    public let url: URL
    private let queue = DispatchQueue(label: "StockMask.diagnostics", qos: .utility)
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    public init(folder: URL, prefix: String = "diag", now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var url = folder.appendingPathComponent("\(prefix)-\(stamp.string(from: now)).jsonl")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(prefix)-\(stamp.string(from: now))-\(n).jsonl")
            n += 1
        }
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.url = url
    }

    public func write<T: Encodable & Sendable>(_ record: T) {
        queue.async { [self] in
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            try? handle.write(contentsOf: line)
        }
    }

    /// Waits for the queued lines and syncs the file (tests; before the app stops).
    public func flush() {
        queue.sync { try? handle.synchronize() }
    }
}

/// About twice a second while the counting screen runs: what the detector, the tracks and the hold
/// trigger are doing, and why no commit is happening right now.
public struct DiagnosticsSample: Codable, Sendable, Equatable {
    public var type = "sample"
    public var time = Date()
    public var t: Double                  // ARFrame timestamp, seconds
    public var computeUnits: String
    public var detectorMs: Double?        // last run, end to end: resize, Core ML, decoding
    public var detectorMsP50: Double?
    public var detectorMsP95: Double?
    public var detectorHz: Double
    public var detectorPeriod: Double?    // seconds between detector frames (median of the last few)
    public var detectorBusy: Bool
    public var boxes: Int                 // yellow outlines now
    public var boxesLowConfidence: Int    // dashed: below the commit score (FR-18)
    public var boxesStable: Int           // bold: stable candidates
    public var maxScore: Float?
    public var tracks: Int
    public var stableTracks: Int
    public var stableCountable: Int       // of those, at or above the commit score: only these make a hold count
    public var stableWindow: Double       // seconds the stable rule looks back
    public var hold: String               // idle, holding 0.62, counted
    public var viewSpeed: Double          // degrees per second, as the hold trigger filters it
    public var tracking: String
    public var paused: String?
    public var autoCount: Bool
    public var committing: Bool
    public var why: String                // why no commit is happening right now
    public var fps: Double
    public var thermal: String
    public var battery: Float?
    public var commits: Int
}

/// One commit, or a commit that was undone because the view didn't line up (drift alarm).
public struct DiagnosticsCommit: Codable, Sendable, Equatable {
    public var type = "commit"
    public var time = Date()
    public var t: Double
    public var trigger: String
    public var detections: Int            // stable candidates handed to the engine
    public var newItems: Int
    public var matched: Int
    public var possibleMisses: Int
    public var statuses: [String: Int]    // the engine's verdict per detection: new, matched, cut, ...
    public var driftAlarm: Bool
    public var overCountedZones: Int
    public var unmatchedOverCountedZones: Int
    public var groups: Int
    public var rowsJoined: Int            // items that joined the group of the bottle in front
    public var undone: Bool               // the session undid it (drift alarm)
    public var saveMs: Double?            // grouping, photos and the store's transaction
}

public struct DiagnosticsEvent: Codable, Sendable, Equatable {
    public var type = "event"
    public var time = Date()
    public var t: Double?
    public var kind: String
    public var message: String
    public var details: [String: String]

    public init(t: Double? = nil, kind: String, message: String, details: [String: String] = [:]) {
        self.t = t
        self.kind = kind
        self.message = message
        self.details = details
    }
}
