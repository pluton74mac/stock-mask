import Foundation
import Observation
import StockMaskCounting
import simd

/// Side effects the session asks of the AR layer (ARSessionController on the phone, a fake in tests).
@MainActor
public protocol SessionEnvironment: AnyObject {
    /// A per-commit ARAnchor with the counted zone's transform (FR-21); the overlays hang off it.
    func addAnchor(id: UUID, transform: simd_float4x4)
    func removeAnchor(id: UUID)
    /// One haptic per commit, never one per item (FR-15).
    func commitFeedback()
    /// Saves the commit's keyframe photo; returns its path relative to the app's documents.
    func saveKeyframe(_ image: DetectorInput, commitID: UUID) async -> String?
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
    public let store: any StockStore
    public private(set) var detector: (any Detector)?
    public let embedder: (any AppearanceEmbedder)?
    public weak var environment: (any SessionEnvironment)?

    public var grouper = ItemGrouper()
    public var lifter = Lifter()
    public var undoWindow: TimeInterval = 5

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
    public private(set) var overlay = OverlayState()
    public private(set) var sheet = StockSheetSummary()
    public private(set) var isCommitting = false
    public private(set) var lastError: String?
    public private(set) var commits = 0
    public var thermal: ThermalLevel = .nominal { didSet { hud.thermal = thermal } }
    public var battery: Float? { didSet { hud.battery = battery } }

    public init(store: any StockStore, detector: (any Detector)? = nil, embedder: (any AppearanceEmbedder)? = nil) {
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

    /// The commit threshold of the model in use (FR-18: below it, outlines are dashed and never counted).
    public var commitScore: Float { counting.commitScore }

    /// Counting is paused (FR-20, FR-23, PRD §10's `critical`): no hold commits, no shutter.
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
    /// the keyframe and the groups' appearance; without it, items are grouped by class only.
    public func commit(_ trigger: CommitTrigger, frame: FrameSnapshot, image: DetectorInput?) async {
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        let detections = tracks.stable(at: lastDetectorFrame ?? frame.timestamp).map(\.detection)
        let result = counting.commit(detections, camera: frame.camera, orientation: frame.orientation,
                                     sceneDepth: frame.sceneDistance)
        if result.driftAlarm {
            // The engine applied it; nothing from a view that doesn't line up is counted (FR-23).
            counting.undoLastCommit()
            driftAlarm = true
            overlay.faded = true
            toast = Toast(text: "Counting paused: point at a shelf you already counted")
            return
        }

        // Group the new items by appearance (ADR 004), within each class.
        let n = result.newItems.count
        let sources = result.newItems.map { $0.detectionIndex.flatMap { $0 < detections.count ? $0 : nil } }
        var embeddings = [[Float]?](repeating: nil, count: n)
        if let embedder, let image, n > 0 {
            let withBox = (0..<n).filter { sources[$0] != nil }
            if let found = try? await embedder.embeddings(of: withBox.map { detections[sources[$0]!].box }, in: image) {
                for (k, i) in withBox.enumerated() where k < found.count { embeddings[i] = found[k] }
            }
        }
        let keys = grouper.groups(classes: result.newItems.map { $0.cls == .bottleTop ? .bottle : $0.cls }, embeddings: embeddings)
        counting.setGroupKeys(Dictionary(uniqueKeysWithValues: zip(result.newItems.map(\.id), keys)))
        let keyframe: String? = if let image { await environment?.saveKeyframe(image, commitID: result.commitID) } else { nil }

        let record = CommitRecord(id: result.commitID, zoneTransform: result.zone.transform,
                                  zoneHalfExtents: result.zone.halfExtents, cameraTransform: frame.camera.transform,
                                  keyframePath: keyframe,
                                  items: zip(result.newItems, keys).map { ItemRecord($0, groupKey: $1) })
        let groups: [GroupInfo]
        do {
            groups = try await store.saveCommit(record)
        } catch {
            counting.undoLastCommit()   // nothing counted that isn't saved (FR-7)
            lastError = "Couldn't save the commit: \(error)"
            return
        }

        overlay.add(result, detections: detections)
        environment?.addAnchor(id: result.commitID, transform: result.zone.transform)
        environment?.commitFeedback()
        commits += 1
        toast = Toast(text: "+\(n)")
        card = CommitCard(commitID: result.commitID, added: n, groups: groups, possibleMisses: result.possibleMisses.count)
        undoDeadline = Date().addingTimeInterval(undoWindow)
        await refreshSheet()
    }

    /// FR-16: undo the last commit (the snackbar, for `undoWindow` seconds).
    public func undo() async {
        guard let undone = counting.undoLastCommit() else { return }
        let id = undone.commitID
        do { try await store.undoCommit(id) } catch { lastError = "Couldn't undo: \(error)" }
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
            let group = try await store.addItem(ItemRecord(item, groupKey: 0), toCommit: miss.commitID)
            overlay.accept(miss: id, as: item)
            environment?.commitFeedback()
            if card?.commitID == miss.commitID {
                card?.groups.append(group)
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

    // MARK: naming, the list, export (M2)

    /// FR-28/31: the user picked a product for a group (nil: back to unknown).
    public func name(group: GroupInfo, product: ProductInfo?) async {
        do {
            try await store.name(group: group.id, product: product?.id)
            counting.setProduct(product?.id, forItems: group.itemIDs)
            if card?.commitID == group.commitID { card?.groups = try await store.groups(ofCommit: group.commitID) }
            await refreshSheet()
        } catch {
            lastError = "Couldn't name the group: \(error)"
        }
    }

    /// Names an unnamed line of the list (its group).
    public func name(line: SheetLine, product: ProductInfo) async {
        guard let id = line.groupID else { return }
        do {
            try await store.name(group: id, product: product.id)
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

    /// FR-36, through the share sheet.
    public func export(_ format: ExportFormat, to directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        try await store.export(format, to: directory)
    }

    /// The list button's badge: "units · products".
    public var badge: String { "\(sheet.totalUnits) units · \(sheet.products) products" }
}
