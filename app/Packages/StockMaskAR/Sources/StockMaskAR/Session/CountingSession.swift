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

/// The card that slides up after a commit: its groups, to name (FR-27, FR-28).
public struct CommitCard: Sendable, Equatable {
    public var commitID: UUID
    public var added: Int
    public var groups: [GroupInfo]
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
    public weak var environment: (any SessionEnvironment)?

    public var grouper = ItemGrouper()
    public var lifter = Lifter()
    public var undoWindow: TimeInterval = 5
    /// A possible miss seen again within this distance keeps its id (StockMaskCore: an open miss
    /// moves to the new commit instead of being listed twice).
    public var missMatchRadius: Float = 0.04

    /// FR-13: auto-count can be switched off; the shutter always counts.
    public var autoCount: Bool {
        get { counting.autoCount }
        set { counting.autoCount = newValue }
    }

    // Engines (value types owned here).
    private var counting = CountingBridge()
    private var tracks = LiveTracks()
    private var motion = ViewMotion()
    private var fps = RateMeter()
    private var detectorRate = RateMeter()
    private var latency = LatencyStats()
    private var lastDetectorStart = -Double.infinity
    private var lastDetectorFrame: TimeInterval?
    private var lastSceneDistance: Float?
    private var detectorBusy = false
    private var shutterRequested = false

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

    public init(store: any CountingStore, detector: (any Detector)? = nil, embedder: (any AppearanceEmbedder)? = nil) {
        self.store = store
        self.embedder = embedder
        setDetector(detector)
    }

    public func setDetector(_ d: (any Detector)?, computeUnits: String = "") {
        detector = d
        counting.commitScore = d?.info.scoreCommit ?? 0.5
        hud.computeUnits = computeUnits
        detectorBusy = false
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
        let stable = !isCommitting && !tracks.stable(at: lastDetectorFrame ?? f.timestamp).isEmpty
        switch counting.hold(viewSpeed: step.speed, viewShift: step.shift, at: f.timestamp, stableCandidate: stable,
                             trackingNormal: !isPaused) {
        case .commit: decision.commit = .hold
        case .holding(let progress): hold = .holding(progress)
        case .counted: hold = .counted
        case .idle: hold = .idle
        }
        if shutterRequested {
            shutterRequested = false
            if !isPaused, !isCommitting {   // FR-20: the shutter is off while counting is paused
                counting.shutter()
                decision.commit = .shutter
            }
        }
        if decision.commit != nil { hold = .counted }

        hud.fps = fps.rate(at: f.timestamp)
        hud.viewSpeed = counting.trigger.speed.isFinite ? counting.trigger.speed : step.speed
        hud.tracking = f.tracking.name
        hud.mapping = f.mapping.rawValue
        hud.sceneDistance = lastSceneDistance
        return decision
    }

    /// A detector run finished on `frame` (whose snapshot carries the depth).
    public func detectorDidFinish(_ output: DetectorOutput, frame: FrameSnapshot) {
        detectorBusy = false
        latency.add(output.milliseconds)
        detectorRate.tick(at: frame.timestamp)
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
            }
        }
        hud.detectorRate = detectorRate.rate(at: frame.timestamp)
        hud.detectorLast = latency.last
        hud.detectorP50 = latency.p50
        hud.detectorP95 = latency.p95
        hud.tracks = tracks.tracks.count
        hud.stable = stableIDs.count
        hud.lifted = lifted.filter { $0.lift != nil }.count
        hud.unlifted = lifted.count - hud.lifted
    }

    public func detectorDidFail(_ error: Error) {
        detectorBusy = false
        lastError = "Detector: \(error)"
    }

    /// The shutter: the next frame commits (FR-13), unless counting is paused (FR-20).
    public func shutter() { shutterRequested = true }

    // MARK: commits (FR-13 to FR-16, FR-21 to FR-23, FR-27)

    /// Runs a commit on `frame` with the stable candidates. `image` is the frame's camera image, for
    /// the keyframe, the crops and the groups' appearance; without it, items are grouped by kind.
    public func commit(_ trigger: CommitTrigger, frame: FrameSnapshot, image: DetectorInput?) async {
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        let detections = tracks.stable(at: lastDetectorFrame ?? frame.timestamp).map(\.detection)
        var result = counting.commit(detections, camera: frame.camera, orientation: frame.orientation,
                                     sceneDepth: frame.sceneDistance)
        if result.driftAlarm {
            // The engine applied it; nothing from a view that doesn't line up is counted (FR-23).
            counting.undoLastCommit()
            driftAlarm = true
            overlay.faded = true
            toast = Toast(text: "Counting paused: point at a shelf you already counted")
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
        let keys = grouper.groups(classes: result.newItems.map { $0.cls == .bottleTop ? .bottle : $0.cls }, embeddings: embeddings)
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
        let record = CommitRecord(
            id: result.commitID, zone: result.zone, anchorID: anchorID,
            cameraTransform: frame.camera.sensor(frame.orientation).transform, keyframePath: files.keyframe,
            trigger: trigger, items: result.newItems.map { ItemRecord($0, cropPath: files.crops[$0.id]) },
            possibleMisses: misses, matchedCount: result.matched.count)
        let groups: [GroupInfo]
        do {
            groups = try await store.saveCommit(record)
        } catch {
            counting.undoLastCommit()   // nothing counted that isn't saved (FR-7)
            environment?.removeAnchor(id: result.commitID)
            lastError = "Couldn't save the commit: \(error)"
            return
        }

        for m in misses { overlay.removeMiss(m.id) }   // a miss seen again moves to this commit
        overlay.add(result, detections: detections, missIDs: misses.map(\.id))
        environment?.commitFeedback()
        commits += 1
        toast = Toast(text: "+\(n)")
        card = CommitCard(commitID: result.commitID, added: n, groups: groups, possibleMisses: misses.count)
        undoDeadline = Date().addingTimeInterval(undoWindow)
        await refreshSheet()
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
        await refreshSheet()
    }

    /// FR-22: the user tapped an amber "+": count it.
    public func acceptPossibleMiss(_ id: String) async {
        guard let miss = overlay.miss(id),
              let item = counting.addDetection(miss.detection, ofCommit: miss.commitID) else { return }
        do {
            let group = try await store.addPossibleMiss(miss.missID, item: item)
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

    // MARK: naming, the list, review, export (M2)

    /// FR-28/31: the user picked a product for a group. The engine's matching then prefers it.
    public func name(group: GroupInfo, product: ProductInfo) async {
        do {
            let named = try await store.name(group: group.id, product: product.id)
            counting.setProductKey(named.product?.productKey, forItems: named.itemIDs)
            if card?.commitID == group.commitID { card?.groups = try await store.groups(ofCommit: group.commitID) }
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
            await refreshSheet()
        } catch {
            lastError = "Couldn't name the line: \(error)"
        }
    }

    public func products(matching query: String) async -> [ProductInfo] {
        (try? await store.products(matching: query)) ?? []
    }

    public func createProduct(_ draft: ProductDraft) async -> ProductInfo? {
        do { return try await store.createProduct(draft) } catch {
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
