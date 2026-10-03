import CoreGraphics
import Foundation
import Observation
import StockMaskCounting
import simd

/// Files a commit writes before the store records them (StockMaskCore: "files first"), as paths
/// relative to the app's data directory.
public struct CommitFiles: Sendable, Equatable {
    public var keyframe: String?
    public var crops: [UUID: String]

    public init(keyframe: String? = nil, crops: [UUID: String] = [:]) {
        self.keyframe = keyframe
        self.crops = crops
    }
}

/// Side effects the session asks of the AR layer (ARSessionController on the phone, a fake in tests).
@MainActor
public protocol SessionEnvironment: AnyObject {
    /// Makes the commit's ARAnchor at the counted zone's transform (FR-21) and returns its
    /// identifier, which the store keeps as the commit's `anchorID`. Called before the save.
    func addAnchor(id: UUID, transform: simd_float4x4) -> UUID?
    func removeAnchor(id: UUID)
    /// One haptic per commit, never one per item (FR-15).
    func commitFeedback()
    /// Writes the commit's keyframe (upright) and its items' crops.
    func saveFiles(_ image: DetectorInput, sessionID: UUID?, commitID: UUID,
                   crops: [(id: UUID, box: SIMD4<Float>)]) async -> CommitFiles
}

public enum CommitTrigger: String, Sendable { case hold, shutter }

/// What the AR layer should do with the current frame.
public struct FrameDecision: Sendable, Equatable {
    public var runDetector = false
    public var commit: CommitTrigger?
}

/// The hold ring: idle, filling up over 0.8 s, or "counted, move on".
public enum HoldState: Sendable, Equatable {
    case idle
    case holding(Double)
    case counted

    var name: String {
        switch self {
        case .idle: "idle"
        case .holding(let p): String(format: "holding %.2f", p)
        case .counted: "counted"
        }
    }
}

/// A yellow outline (PRD §9): thin = candidate, dashed = low confidence (FR-18), bold = stable.
public struct BoxOverlay: Sendable, Identifiable, Equatable {
    public enum Style: Sendable, Equatable { case candidate, lowConfidence, stable }
    public var id: Int
    public var box: SIMD4<Float>
    public var style: Style
    public var label: String
    public var score: Float
}

/// The card that slides up after a commit: its groups, to name (FR-27, FR-28), with their photos
/// and a suggested product each. `joined` are earlier groups this commit's rows behind joined.
public struct CommitCard: Sendable, Equatable {
    public var commitID: UUID
    public var added: Int
    public var groups: [GroupInfo]
    public var joined: [GroupInfo] = []
    public var possibleMisses: Int
}

public struct Toast: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var text: String
}

/// The counting screen's model (M1 + M2). It owns the live tracks and StockMaskCounting's trigger
/// and engine (through CountingBridge), and turns each commit into overlays, a card, the list and
/// the store's records. It never touches ARKit: the AR layer feeds it `FrameSnapshot`s and detector
/// outputs (FramePump) and gets side effects through `SessionEnvironment`.
@MainActor @Observable
public final class CountingSession {
    public let store: any CountingStore
    public private(set) var detector: (any Detector)?
    public let embedder: (any AppearanceEmbedder)?
    public let labelReader: (any LabelReader)?
    public weak var environment: (any SessionEnvironment)?
    /// Where the commits' photos are (the data directory their relative paths start from).
    public var dataDirectory: URL?
    /// Documents/diagnostics/*.jsonl, about 2 Hz plus commits and events.
    public var diagnostics: DiagnosticsLog?

    public var grouper = ItemGrouper()
    public var rows = RowGrouper()
    public var matcher = ProductMatcher()
    public var teachOnce = TeachOnce()
    public var lifter = Lifter()
    public var undoWindow: TimeInterval = 5
    /// A possible miss seen again within this distance keeps its id (StockMaskCore: an open miss
    /// moves to the new commit instead of being listed twice).
    public var missMatchRadius: Float = 0.04

    /// FR-13: counting is automatic (hold-to-count); the debug panel's "count now" is for testing.
    public var autoCount: Bool {
        get { counting.autoCount }
        set { counting.autoCount = newValue }
    }

    // Engines (value types owned here).
    private var counting = CountingBridge()
    var tracks = LiveTracks()   // internal: tests feed it tracks directly
    private var motion = ViewMotion()
    private var fps = RateMeter()
    private var detectorRate = RateMeter()
    private var latency = LatencyStats()
    private var lastDetectorStart = -Double.infinity
    private var lastDetectorFrame: TimeInterval?
    private var detectorFrames: [TimeInterval] = []
    private var lastSceneDistance: Float?
    private var lastSpeed = 0.0
    private var lastDiagnostics = -Double.infinity
    private var detectorBusy = false
    private var shutterRequested = false
    /// Store group of every counted item (for rows joining the group of the bottle in front).
    private var itemGroups: [UUID: UUID] = [:]
    /// FeaturePrint of the counted items, for teach-once.
    private var itemEmbeddings: [UUID: [Float]] = [:]
    private var catalogCache: [ProductInfo]?
    /// Groups the user named or left unknown (a late suggestion never lands on them).
    private var namedGroups: Set<UUID> = []

    // What the screens show.
    public private(set) var hud = HUDStats()
    public private(set) var boxes: [BoxOverlay] = []
    public private(set) var innerFrame = SIMD4<Float>(0.15, 0.11, 0.85, 0.89)
    public private(set) var hold = HoldState.idle
    public private(set) var pauseReason: String?
    public private(set) var driftAlarm = false
    public private(set) var toast: Toast?
    public private(set) var undoDeadline: Date?
    public private(set) var card: CommitCard?
    /// The product suggested for each unnamed group (teach-once or label text), by group id.
    public private(set) var suggestions: [UUID: Suggestion] = [:]
    /// Groups whose labels are being read right now.
    public private(set) var readingLabels: Set<UUID> = []
    public private(set) var overlay = OverlayState() { didSet { if overlay != oldValue { overlayRevision &+= 1 } } }
    /// Bumped whenever `overlay` changes: the AR layer re-syncs RealityKit only then.
    public private(set) var overlayRevision = 0
    public private(set) var sheet = StockSheetSummary()
    public private(set) var isCommitting = false
    public private(set) var isLocked = false
    public private(set) var lastError: String?
    /// A one-off message for the top of the screen (e.g. after a relaunch).
    public var notice: String?
    public private(set) var commits = 0
    public var thermal: ThermalLevel = .nominal { didSet { hud.thermal = thermal } }
    public var battery: Float? { didSet { hud.battery = battery } }

    public init(store: any CountingStore, detector: (any Detector)? = nil, embedder: (any AppearanceEmbedder)? = nil,
                labelReader: (any LabelReader)? = nil) {
        self.store = store
        self.embedder = embedder
        self.labelReader = labelReader
        setDetector(detector)
    }

    public func setDetector(_ d: (any Detector)?, computeUnits: String = "") {
        detector = d
        counting.commitScore = d?.info.scoreCommit ?? 0.5
        hud.computeUnits = computeUnits
        detectorBusy = false
        detectorFrames = []
        tracks.detectorPeriod = nil
        tracks.removeAll()
        boxes = []
    }

    /// The screen shows `visible` of the upright camera image of `imageSize` (DisplayMapping): keep
    /// the inner frame inside it.
    public func setVisibleRegion(_ visible: SIMD4<Float>, imageSize: SIMD2<Float>) {
        counting.setVisibleRegion(visible, imageSize: imageSize)
        innerFrame = counting.innerFrame(imageSize: imageSize)
    }

    /// The commit threshold of the model in use (FR-18: below it, outlines are dashed and never counted).
    public var commitScore: Float { counting.commitScore }

    /// Counting is paused (FR-20, FR-23, PRD §10's `critical`, a locked session): no commits at all.
    public var isPaused: Bool { pauseReason != nil }

    /// The seconds the stable-candidate rule looks back now (it stretches with a slow detector).
    public var stableWindow: Double { tracks.effectiveWindow }

    public func photoURL(_ path: String) -> URL? { dataDirectory?.appendingPathComponent(path) }

    public func log(_ kind: String, _ message: String, t: Double? = nil, _ details: [String: String] = [:]) {
        diagnostics?.write(DiagnosticsEvent(t: t, kind: kind, message: message, details: details))
    }

    // MARK: per frame

    /// Every AR frame (60 Hz). Cheap: no depth, no image.
    public func frameDidUpdate(_ f: FrameSnapshot) -> FrameDecision {
        fps.tick(at: f.timestamp)
        if let d = f.sceneDistance { lastSceneDistance = d }
        let step = motion.update(transform: f.camera.transform, timestamp: f.timestamp, sceneDistance: lastSceneDistance)
        innerFrame = counting.innerFrame(imageSize: f.camera.imageSize)
        pauseReason = f.tracking.pauseMessage ?? (thermal == .critical ? thermal.message : nil)
            ?? (driftAlarm ? "Counted shelves look shifted: point at a shelf you already counted" : nil)
            ?? (isLocked ? "This count is locked" : nil)

        var decision = FrameDecision()
        if detector != nil, !detectorBusy, let rate = thermal.detectorRate, f.timestamp - lastDetectorStart >= 1 / rate - 1e-3 {
            decision.runDetector = true
            detectorBusy = true
            lastDetectorStart = f.timestamp
        }
        // While a commit is being saved, the trigger waits at a full ring rather than fire into it.
        // Only a candidate the engine can count (at or above the commit score, FR-18) makes a hold:
        // a commit of dashed outlines alone would mark an empty counted zone, where those bottles
        // would later come up as possible misses instead of counting.
        let stable = !isCommitting && tracks.stable(at: lastDetectorFrame ?? f.timestamp).contains { $0.score >= commitScore }
        switch counting.hold(viewSpeed: step.speed, viewShift: step.shift, at: f.timestamp, stableCandidate: stable,
                             trackingNormal: !isPaused) {
        case .commit: decision.commit = .hold
        case .holding(let progress): hold = .holding(progress)
        case .counted: hold = .counted
        case .idle: hold = .idle
        }
        if shutterRequested {
            shutterRequested = false
            if !isPaused, !isCommitting {   // FR-20: no counting while paused
                counting.shutter()
                decision.commit = .shutter
            } else {
                log("commit_skipped", "count now while paused or saving", t: f.timestamp,
                    ["paused": pauseReason ?? "", "committing": "\(isCommitting)"])
            }
        }
        if decision.commit != nil { hold = .counted }

        hud.fps = fps.rate(at: f.timestamp)
        lastSpeed = counting.trigger.speed.isFinite ? counting.trigger.speed : step.speed
        hud.viewSpeed = lastSpeed
        hud.tracking = f.tracking.name
        hud.mapping = f.mapping.rawValue
        hud.sceneDistance = lastSceneDistance
        if f.timestamp - lastDiagnostics >= 0.5 {
            lastDiagnostics = f.timestamp
            let s = sample(f)
            hud.why = s.why
            diagnostics?.write(s)
        }
        return decision
    }

    /// A detector run finished on `frame` (whose snapshot carries the depth).
    public func detectorDidFinish(_ output: DetectorOutput, frame: FrameSnapshot) {
        detectorBusy = false
        latency.add(output.milliseconds)
        detectorRate.tick(at: frame.timestamp)
        detectorFrames = (detectorFrames + [frame.timestamp]).suffix(9)
        tracks.detectorPeriod = detectorPeriod
        if let d = frame.sceneDistance { lastSceneDistance = d }
        let lifted = Perception.lift(output, frame: frame, lifter: lifter)
        let ids = tracks.update(lifted.map(\.observation), at: frame.timestamp)
        lastDetectorFrame = frame.timestamp
        let stable = tracks.stable(at: frame.timestamp)
        let stableIDs = Set(stable.map(\.id))
        boxes = zip(lifted, ids).map { l, id in
            BoxOverlay(id: id, box: l.raw.box,
                       style: l.raw.score < commitScore ? .lowConfidence : (stableIDs.contains(id) ? .stable : .candidate),
                       label: l.raw.label, score: l.raw.score)
        }
        // FR-23: the alarm clears once the view lines up with counted items again.
        if driftAlarm {
            let p = counting.preview(stable.map(\.detection), camera: frame.camera, orientation: frame.orientation,
                                     sceneDepth: frame.sceneDistance)
            if p.overCountedZones >= 3, !p.driftAlarm {
                resumeAfterDrift()
                toast = Toast(text: "Back on counted shelves")
                log("drift_cleared", "a preview over counted shelves lines up again", t: frame.timestamp)
            }
        }
        hud.detectorRate = detectorRate.rate(at: frame.timestamp)
        hud.detectorLast = latency.last
        hud.detectorP50 = latency.p50
        hud.detectorP95 = latency.p95
        hud.tracks = tracks.tracks.count
        hud.stable = stableIDs.count
        hud.stableWindow = tracks.effectiveWindow
        hud.lifted = lifted.filter { $0.lift != nil }.count
        hud.unlifted = lifted.count - hud.lifted
    }

    public func detectorDidFail(_ error: Error) {
        detectorBusy = false
        lastError = "Detector: \(error)"
        log("detector_failed", "\(error)")
    }

    /// Seconds between detector frames: the median of the last few.
    var detectorPeriod: Double? {
        guard detectorFrames.count >= 3 else { return nil }
        let gaps = zip(detectorFrames.dropFirst(), detectorFrames).map { $0 - $1 }.sorted()
        return gaps[gaps.count / 2]
    }

    /// Debug panel only (counting is automatic): commit the next frame, held or not.
    public func shutter() { shutterRequested = true }

    // MARK: diagnostics

    func sample(_ f: FrameSnapshot) -> DiagnosticsSample {
        let candidates = tracks.stable(at: lastDetectorFrame ?? f.timestamp)
        let stable = candidates.count
        return DiagnosticsSample(
            t: f.timestamp, computeUnits: hud.computeUnits, detectorMs: latency.last, detectorMsP50: latency.p50,
            detectorMsP95: latency.p95, detectorHz: hud.detectorRate, detectorPeriod: detectorPeriod,
            detectorBusy: detectorBusy, boxes: boxes.count, boxesLowConfidence: boxes.filter { $0.style == .lowConfidence }.count,
            boxesStable: boxes.filter { $0.style == .stable }.count, maxScore: boxes.map(\.score).max(),
            tracks: tracks.tracks.count, stableTracks: stable,
            stableCountable: candidates.filter { $0.score >= commitScore }.count, stableWindow: tracks.effectiveWindow,
            hold: hold.name, viewSpeed: lastSpeed, tracking: f.tracking.name, paused: pauseReason, autoCount: autoCount,
            committing: isCommitting, why: whyNoCommit(candidates), fps: hud.fps, thermal: thermal.rawValue,
            battery: battery, commits: commits)
    }

    /// Why no commit is happening right now, in words (for the diagnostic log and the HUD).
    public func whyNoCommit() -> String { whyNoCommit(tracks.stable(at: lastDetectorFrame ?? 0)) }

    func whyNoCommit(_ candidates: [LiveTrack]) -> String {
        let stable = candidates.count
        if detector == nil { return "no detector loaded" }
        if let p = pauseReason { return "paused: \(p)" }
        if isCommitting { return "saving a commit" }
        if !autoCount { return "auto-count off" }
        switch hold {
        case .counted: return "this view is counted: move about 5° to count the next"
        case .holding(let p) where p >= 1:
            if stable == 0 {
                return String(format: "steady, but no stable candidate yet (%d hits within %.2f s; detector every %.2f s, %d tracks)",
                              tracks.stableHits, tracks.effectiveWindow, detectorPeriod ?? -1, tracks.tracks.count)
            }
            let best = candidates.map(\.score).max() ?? 0
            return best < commitScore
                ? String(format: "steady, %d stable candidates but all below the commit score %.2f (best %.2f)",
                         stable, commitScore, best)
                : "about to commit"
        case .holding(let p): return String(format: "holding %.0f%%", p * 100)
        case .idle:
            return lastSpeed >= 10 ? String(format: "moving %.0f°/s (steady is under 10°/s)", lastSpeed) : "not steady yet"
        }
    }

    // MARK: commits (FR-13 to FR-16, FR-21 to FR-23, FR-27)

    /// Runs a commit on `frame` with the stable candidates. `image` is the frame's camera image, for
    /// the keyframe, the crops and the groups' appearance; without it, items are grouped by kind.
    public func commit(_ trigger: CommitTrigger, frame: FrameSnapshot, image: DetectorInput?) async {
        guard !isCommitting else {
            log("commit_skipped", "a commit is already being saved", t: frame.timestamp)
            return
        }
        isCommitting = true
        defer { isCommitting = false }
        let clock = ContinuousClock()
        let started = clock.now

        let detections = tracks.stable(at: lastDetectorFrame ?? frame.timestamp).map(\.detection)
        var result = counting.commit(detections, camera: frame.camera, orientation: frame.orientation,
                                     sceneDepth: frame.sceneDistance)
        var record = DiagnosticsCommit(
            t: frame.timestamp, trigger: trigger.rawValue, detections: detections.count, newItems: result.newItems.count,
            matched: result.matched.count, possibleMisses: result.possibleMisses.count,
            statuses: Dictionary(result.statuses.map { (Self.statusName($0), 1) }, uniquingKeysWith: +),
            driftAlarm: result.driftAlarm, overCountedZones: result.overCountedZones,
            unmatchedOverCountedZones: result.unmatchedOverCountedZones, groups: 0, rowsJoined: 0, undone: false)
        if result.driftAlarm {
            // The engine applied it; nothing from a view that doesn't line up is counted (FR-23).
            counting.undoLastCommit()
            driftAlarm = true
            overlay.faded = true
            toast = Toast(text: "Counting paused: point at a shelf you already counted")
            record.undone = true
            diagnostics?.write(record)
            return
        }

        // Group the new items by appearance (ADR 004), within what they count as.
        let n = result.newItems.count
        let boxes: [SIMD4<Float>?] = result.newItems.map { item in
            item.detectionIndex.flatMap { $0 < detections.count ? detections[$0].box : nil }
        }
        var embeddings = [[Float]?](repeating: nil, count: n)
        if let embedder, let image, n > 0 {
            let withBox = (0..<n).filter { boxes[$0] != nil }
            if let found = try? await embedder.embeddings(of: withBox.map { boxes[$0]! }, in: image) {
                for (k, i) in withBox.enumerated() where k < found.count { embeddings[i] = found[k] }
            }
        }
        var keys = grouper.groups(classes: result.newItems.map { $0.cls == .bottleTop ? .bottle : $0.cls }, embeddings: embeddings)
        for i in 0..<n { if let e = embeddings[i] { itemEmbeddings[result.newItems[i].id] = e } }

        // Rows behind take the group of the bottle in front (the owner's decision of 2 October):
        // within this commit by sharing a key, across commits by moving into the earlier group.
        let newIDs = Set(result.newItems.map(\.id))
        let earlier = counting.engine.items.filter { !newIDs.contains($0.id) }
        let candidates = (result.newItems + earlier).map { RowGrouper.Item(id: $0.id, cls: $0.cls, position: $0.position) }
        let fronts = rows.fronts(of: result.newItems.map { RowGrouper.Item(id: $0.id, cls: $0.cls, position: $0.position) },
                                 among: candidates, forward: frame.camera.forward)
        let index = Dictionary(uniqueKeysWithValues: result.newItems.enumerated().map { ($1.id, $0) })
        var joins: [UUID: [UUID]] = [:]   // earlier store group -> new items joining it
        for (i, item) in result.newItems.enumerated() where fronts[item.id] != nil {
            let front = RowGrouper.frontOfRow(item.id, fronts: fronts)
            if let k = index[front] {
                keys[i] = keys[k]
            } else if let group = itemGroups[front] {
                joins[group, default: []].append(item.id)
            }
        }
        for i in 0..<n { result.newItems[i].groupKey = keys[i] }
        counting.setGroupKeys(Dictionary(uniqueKeysWithValues: zip(result.newItems.map(\.id), keys)))

        // Files first, then the anchor, then one transaction (StockMaskCore README).
        let sessionID = await store.sessionID()
        var files = CommitFiles()
        if let image, let environment {
            let crops = (0..<n).compactMap { i in boxes[i].map { (id: result.newItems[i].id, box: $0) } }
            files = await environment.saveFiles(image, sessionID: sessionID, commitID: result.commitID, crops: crops)
        }
        let anchorID = environment?.addAnchor(id: result.commitID, transform: result.zone.transform)
        let misses = result.possibleMisses.map { d in
            MissRecord(id: knownMissID(near: detections[d].position) ?? UUID(), detection: detections[d], detectionIndex: d)
        }
        let commitRecord = CommitRecord(
            id: result.commitID, zone: result.zone, anchorID: anchorID,
            cameraTransform: frame.camera.sensor(frame.orientation).transform, keyframePath: files.keyframe,
            trigger: trigger, items: result.newItems.map { ItemRecord($0, cropPath: files.crops[$0.id]) },
            possibleMisses: misses, matchedCount: result.matched.count)
        var groups: [GroupInfo]
        var joined: [GroupInfo] = []
        do {
            groups = try await store.saveCommit(commitRecord)
            for g in groups { for id in g.itemIDs { itemGroups[id] = g.id } }
            for (target, ids) in joins {
                let g = try await store.moveItems(ids, toGroup: target)
                for id in ids { itemGroups[id] = g.id }
                counting.setProductKey(g.product?.productKey, forItems: ids)
                joined.append(g)
            }
            if !joins.isEmpty { groups = try await store.groups(ofCommit: result.commitID) }
        } catch {
            counting.undoLastCommit()   // nothing counted that isn't saved (FR-7)
            environment?.removeAnchor(id: result.commitID)
            lastError = "Couldn't save the commit: \(error)"
            log("commit_failed", "\(error)", t: frame.timestamp)
            return
        }

        for m in misses { overlay.removeMiss(m.id) }   // a miss seen again moves to this commit
        overlay.add(result, detections: detections, missIDs: misses.map(\.id))
        environment?.commitFeedback()
        commits += 1
        toast = Toast(text: "+\(n)")
        card = CommitCard(commitID: result.commitID, added: n, groups: groups, joined: joined, possibleMisses: misses.count)
        undoDeadline = Date().addingTimeInterval(undoWindow)
        record.groups = groups.count
        record.rowsJoined = result.newItems.filter { fronts[$0.id] != nil }.count
        record.saveMs = (clock.now - started).milliseconds
        diagnostics?.write(record)
        await refreshSheet()
        // Reading labels takes a moment: after the commit, so the next hold isn't kept waiting.
        let toSuggest = groups + joined
        suggesting = Task { await self.suggest(for: toSuggest) }
    }

    /// The suggestions being worked out for the last commit's groups.
    public private(set) var suggesting: Task<Void, Never>?

    static func statusName(_ s: DetectionStatus) -> String {
        switch s {
        case .new: "new"
        case .matched: "matched"
        case .possibleMiss: "possibleMiss"
        case .deferred: "deferred"
        case .mergedTop: "mergedTop"
        case .lowConfidence: "lowConfidence"
        case .cut: "cut"
        case .noPosition: "noPosition"
        }
    }

    /// The id of an open possible miss within `missMatchRadius` of `position`, if any.
    private func knownMissID(near position: SIMD3<Float>?) -> UUID? {
        guard let position else { return nil }
        let near = overlay.commits.flatMap(\.misses).map { ($0.missID, simd_distance($0.world, position)) }
            .filter { $0.1 <= missMatchRadius }
        return near.min { $0.1 < $1.1 }?.0
    }

    /// FR-16: undo the last commit (the snackbar, for `undoWindow` seconds), in the engine and the store.
    public func undo() async {
        guard let undone = counting.undoLastCommit() else { return }
        let id = undone.commitID
        do { try await store.undoCommit(id) } catch { lastError = "Couldn't undo in the store: \(error)" }
        overlay.remove(commit: id)
        environment?.removeAnchor(id: id)
        if card?.commitID == id { card = nil }
        undoDeadline = nil
        toast = Toast(text: "Undone")
        log("undo", "commit undone", ["commit": id.uuidString])
        await refreshSheet()
    }

    /// FR-22: the user tapped an amber "+": count it.
    public func acceptPossibleMiss(_ id: String) async {
        guard let miss = overlay.miss(id),
              let item = counting.addDetection(miss.detection, ofCommit: miss.commitID) else { return }
        do {
            let group = try await store.addPossibleMiss(miss.missID, item: item)
            itemGroups[item.id] = group.id
            counting.setProductKey(group.product?.productKey, forItems: [item.id])
            overlay.accept(miss: id, as: item)
            environment?.commitFeedback()
            if card?.commitID == miss.commitID {
                card?.groups = try await store.groups(ofCommit: miss.commitID)
                card?.added += 1
                card?.possibleMisses -= 1
            }
            await refreshSheet()
        } catch {
            lastError = "Couldn't add it: \(error)"
        }
    }

    /// FR-21: ARKit moved a commit's anchor (map optimisation, relocalisation).
    public func anchorDidUpdate(id: UUID, transform: simd_float4x4) {
        counting.updateAnchor(ofCommit: id, to: transform)
        overlay.move(commit: id, to: transform)
    }

    /// The drift alarm is over: the user is back on a counted shelf (or says so).
    public func resumeAfterDrift() {
        driftAlarm = false
        overlay.faded = false
    }

    public func dismissCard() { card = nil }

    public func clearToast(_ id: UUID) { if toast?.id == id { toast = nil } }

    public func undoExpired(now: Date = Date()) { if let d = undoDeadline, now >= d { undoDeadline = nil } }

    // MARK: suggestions (teach-once, label text)

    /// Suggests a product for each unnamed group: teach-once (it looks like a product named before),
    /// and unless that is sure, the label text read from its photos (Vision) matched against the
    /// catalogue; the more confident of the two. A suggestion is only pre-selected: naming still
    /// takes a tap (FR-31).
    public func suggest(for groups: [GroupInfo]) async {
        let unnamed = groups.filter { $0.product == nil && !$0.markedUnknown && !namedGroups.contains($0.id) }
        guard !unnamed.isEmpty else { return }
        readingLabels.formUnion(unnamed.map(\.id))
        defer { readingLabels.subtract(unnamed.map(\.id)) }
        let catalog = await catalogProducts()
        let hints = Array(Set(catalog.flatMap { ProductMatcher.words("\($0.name) \($0.brand)") })).sorted()
        for g in unnamed {
            defer { readingLabels.remove(g.id) }
            // Teach-once costs nothing; a sure one (0.6 and up) is taken without reading the label.
            var best = teachOnce.suggest(g.itemIDs.compactMap { itemEmbeddings[$0] })
                .flatMap { $0.confidence >= 0.3 ? Suggestion(product: $0.product, source: .teachOnce, confidence: $0.confidence) : nil }
            var details = ["group": g.label, "teachOnce": best.map { String(format: "%.2f", $0.confidence) } ?? ""]
            if (best?.confidence ?? 0) < 0.6, let labelReader, !catalog.isEmpty {
                var images: [CGImage] = []
                for path in g.cropPaths.prefix(3) {
                    if let image = await PhotoLoader.load(path, in: dataDirectory) { images.append(image) }
                }
                if !images.isEmpty {
                    let clock = ContinuousClock(), started = clock.now
                    let texts = (try? await labelReader.read(images, hints: hints)) ?? []
                    let match = matcher.best(texts: texts, among: catalog)
                    if let match, match.confidence > (best?.confidence ?? 0) {
                        best = Suggestion(product: match.product, source: .labelText, confidence: match.confidence,
                                          evidence: match.words.joined(separator: " "))
                    }
                    details["photos"] = "\(images.count)"
                    details["lines"] = "\(texts.count)"
                    details["labelText"] = match.map { String(format: "%.2f", $0.confidence) } ?? "no match"
                    details["ms"] = String(format: "%.0f", (clock.now - started).milliseconds)
                }
            }
            // Named while the labels were being read: the tap wins.
            if let best, !namedGroups.contains(g.id) { suggestions[g.id] = best }
            log("suggestion", best.map { $0.source == .teachOnce ? "teach-once" : "label text" } ?? "none", details)
        }
    }

    private func catalogProducts() async -> [ProductInfo] {
        if let catalogCache { return catalogCache }
        let all = (try? await store.catalog()) ?? []
        catalogCache = all
        return all
    }

    /// One tap: the suggestion becomes the group's product.
    public func confirmSuggestion(for group: GroupInfo) async {
        guard let s = suggestions[group.id] else { return }
        await name(group: group, product: s.product)
    }

    // MARK: naming, the list, review, export (M2)

    /// FR-28/31: the user picked a product for a group. The engine's matching then prefers it, and
    /// later groups that look like it get it suggested (teach-once).
    public func name(group: GroupInfo, product: ProductInfo) async {
        do {
            let named = try await store.name(group: group.id, product: product.id)
            counting.setProductKey(named.product?.productKey, forItems: named.itemIDs)
            teachOnce.learn(product, embeddings: named.itemIDs.compactMap { itemEmbeddings[$0] })
            suggestions[group.id] = nil
            namedGroups.insert(group.id)
            await refreshCard(group.commitID)
            await refreshSheet()
        } catch {
            lastError = "Couldn't name the group: \(error)"
        }
    }

    /// FR-35: leave a group unknown on purpose (it exports as "Unknown A").
    public func markUnknown(group id: UUID) async {
        do {
            let g = try await store.markUnknown(group: id)
            counting.setProductKey(nil, forItems: g.itemIDs)
            suggestions[id] = nil
            namedGroups.insert(id)
            await refreshSheet()
        } catch {
            lastError = "Couldn't mark it unknown: \(error)"
        }
    }

    /// Names an unnamed line of the list (its group).
    public func name(line: SheetLine, product: ProductInfo) async {
        guard let id = line.groupID else { return }
        do {
            let named = try await store.name(group: id, product: product.id)
            counting.setProductKey(named.product?.productKey, forItems: named.itemIDs)
            teachOnce.learn(product, embeddings: named.itemIDs.compactMap { itemEmbeddings[$0] })
            suggestions[id] = nil
            namedGroups.insert(id)
            await refreshSheet()
        } catch {
            lastError = "Couldn't name the line: \(error)"
        }
    }

    private func refreshCard(_ commitID: UUID) async {
        guard let c = card else { return }
        if c.commitID == commitID { card?.groups = (try? await store.groups(ofCommit: commitID)) ?? c.groups }
        var joined: [GroupInfo] = []
        for g in c.joined {
            if let fresh = try? await store.groups(ofCommit: g.commitID).first(where: { $0.id == g.id }) { joined.append(fresh) }
        }
        card?.joined = joined
    }

    public func products(matching query: String) async -> [ProductInfo] {
        (try? await store.products(matching: query)) ?? []
    }

    public func createProduct(_ draft: ProductDraft) async -> ProductInfo? {
        do {
            let p = try await store.createProduct(draft)
            catalogCache = nil
            return p
        } catch {
            lastError = "Couldn't create the product: \(error)"
            return nil
        }
    }

    /// FR-30: kegs, partial cases, closed cupboards.
    public func addManualLine(product: ProductInfo, fullCases: Int, looseUnits: Int, note: String = "") async {
        do {
            try await store.addManualLine(product: product.id, fullCases: fullCases, looseUnits: looseUnits, note: note)
            await refreshSheet()
        } catch {
            lastError = "Couldn't add the line: \(error)"
        }
    }

    public func refreshSheet() async {
        do { sheet = try await store.sheet() } catch { lastError = "Couldn't read the list: \(error)" }
    }

    /// FR-9: lock the count (every group named or marked unknown). A locked count is read-only.
    public func lock() async {
        do {
            try await store.lock()
            isLocked = true
            await refreshSheet()
        } catch {
            lastError = "Couldn't lock: \(error)"
        }
    }

    /// FR-36, through the share sheet.
    public func export(_ format: ExportFormat, to directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        try await store.export(format, to: directory)
    }

    /// The list button's badge: "units · products".
    public var badge: String { "\(sheet.totalUnits) units · \(sheet.products) products" }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
