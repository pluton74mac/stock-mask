import Foundation
import simd

// The value types shared with StockMaskCore and StockMaskAR (docs/mvp-test-app.md, "Contract between
// the packages"). The names are fixed; fields marked "added" grow the contract and all have defaults.

/// A detector class (ADR 006). `bottleTop` is the top of a bottle: the rows behind a front row are
/// counted by their tops (product decision of 2 October 2026, PRD FR-29 removed). `carton` and `bag`
/// are single units packed in a carton (cream, juice) or a bag (sugar): the camera counts everything
/// it sees (product decision of 3 October 2026). New classes go at the end: raw values are stored.
public enum ObjectClass: String, Codable, Sendable, CaseIterable {
    case bottle, can, `case`, bottleTop = "bottle_top", carton, bag
}

/// One detector box, lifted to 3D when depth allows.
public struct Detection: Sendable, Equatable, Codable {
    public var cls: ObjectClass
    public var score: Float
    /// Normalised image coordinates x0, y0, x1, y1: x to the right, y down, both 0...1. The image is
    /// the one `CommitView` describes (for ARKit: the captured image, in sensor orientation).
    public var box: SIMD4<Float>
    /// Metres, in the world space of `CommitView.cameraTransform`. Without it the detection can't be
    /// placed, so it is never counted (`DetectionStatus.noPosition`).
    public var position: SIMD3<Float>?
    /// Metres: the box's extent along the image's x and y axes, at the object's depth. Used only to
    /// estimate a bottle's top (bottles and tops; see the README).
    public var size: SIMD2<Float>?
    /// Added. The product the appearance model suggests, if any. Matching prefers counted items of
    /// the same product (ADR 003 S5). Nil means "no suggestion" and never penalises a match.
    public var productKey: Int?

    public init(cls: ObjectClass, score: Float, box: SIMD4<Float>, position: SIMD3<Float>? = nil,
                size: SIMD2<Float>? = nil, productKey: Int? = nil) {
        self.cls = cls
        self.score = score
        self.box = box
        self.position = position
        self.size = size
        self.productKey = productKey
    }
}

/// One counted unit: a whole bottle, can or case, or a bottle counted by its top.
public struct CountedItem: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    /// `.bottleTop` means a bottle counted by its top alone (a row behind). It is one unit, like a
    /// bottle.
    public var cls: ObjectClass
    /// Metres, world space, drift-corrected: the centre of the object, or the top for `.bottleTop`.
    public var position: SIMD3<Float>
    public var commitID: UUID
    /// The group the AR layer put the item in (FR-27). The engine never sets it.
    public var groupKey: Int?
    /// Added. Where the bottle's top is: the top detected with it, or one estimated from its size.
    /// Lets a top seen alone in a later view match a bottle counted whole, and the other way round.
    /// Nil for cans and cases. Persist it if you can; without it those cross matches can't happen.
    public var top: SIMD3<Float>?
    /// Added. The product of the item, once known (`CommitEngine.setProductKey`).
    public var productKey: Int?
    /// Added. The detector score of the detection that was counted.
    public var confidence: Float?
    /// Added. Index of that detection in its commit's detections.
    public var detectionIndex: Int?

    public init(id: UUID = UUID(), cls: ObjectClass, position: SIMD3<Float>, commitID: UUID,
                groupKey: Int? = nil, top: SIMD3<Float>? = nil, productKey: Int? = nil,
                confidence: Float? = nil, detectionIndex: Int? = nil) {
        self.id = id
        self.cls = cls
        self.position = position
        self.commitID = commitID
        self.groupKey = groupKey
        self.top = top
        self.productKey = productKey
        self.confidence = confidence
        self.detectionIndex = detectionIndex
    }
}

/// The 3D region a commit counted: the view's inner frame at the items' depth (FR-21), as an
/// oriented box in world space.
public struct CountedZone: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var commitID: UUID
    /// World from box. The box's axes are the camera's at the commit (x right, y up, z towards the
    /// camera) and its origin is the box centre. Create the commit's ARAnchor with this transform and
    /// pass its updates to `CommitEngine.updateAnchor(ofCommit:to:)`.
    public var transform: simd_float4x4
    /// Half the box's size along its own x, y and z axes, metres.
    public var halfExtents: SIMD3<Float>

    public init(id: UUID = UUID(), commitID: UUID, transform: simd_float4x4, halfExtents: SIMD3<Float>) {
        self.id = id
        self.commitID = commitID
        self.transform = transform
        self.halfExtents = halfExtents
    }

    /// Whether a world point lies inside the box, faces included.
    public func contains(_ point: SIMD3<Float>) -> Bool {
        let local = simd_mul(transform.inverse, SIMD4<Float>(point, 1))
        return abs(local.x) <= halfExtents.x && abs(local.y) <= halfExtents.y && abs(local.z) <= halfExtents.z
    }
}

extension CountedZone: Codable {
    private enum CodingKeys: String, CodingKey { case id, commitID, transform, halfExtents }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let m = try c.decode([Float].self, forKey: .transform)
        guard m.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .transform, in: c,
                                                   debugDescription: "expected 16 numbers, column-major")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), commitID: try c.decode(UUID.self, forKey: .commitID),
                  transform: simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                                     SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))),
                  halfExtents: try c.decode(SIMD3<Float>.self, forKey: .halfExtents))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(commitID, forKey: .commitID)
        let t = transform
        try c.encode([t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                     forKey: .transform)
        try c.encode(halfExtents, forKey: .halfExtents)
    }
}

/// What a commit did with one detection.
public enum DetectionStatus: Sendable, Equatable {
    /// Counted by this commit: green, and in `CommitResult.newItems`.
    case new(item: UUID)
    /// Already counted: green. Never counted again (FR-26).
    case matched(item: UUID)
    /// Inside a counted zone, but no counted item explains it: amber "+", never added on its own
    /// (FR-22). `CommitEngine.addDetection` adds it when the user taps.
    case possibleMiss
    /// Whole and uncounted, but its centre is in the inner frame's edge band (FR-14): left for the
    /// neighbouring view.
    case deferred
    /// A `bottle_top` that is the same unit as this bottle detection: it shares the bottle's status.
    case mergedTop(bottle: Int)
    /// Below the commit score (FR-18): dashed, excluded from auto-count, `addDetection` includes it.
    case lowConfidence
    /// Cut by the image border (FR-14): its box centre is biased, so the next view counts it.
    case cut
    /// No 3D position, so it can't be placed or matched.
    case noPosition
}

/// The outcome of `CommitEngine.commit`.
public struct CommitResult: Sendable {
    public var commitID: UUID
    /// Added to the count, in detection order.
    public var newItems: [CountedItem]
    /// Detections that are counted items seen again: green, not counted again.
    public var matched: [(detection: Int, item: UUID)]
    /// Detection indices shown as amber "+", never added on their own.
    public var possibleMisses: [Int]
    public var zone: CountedZone
    /// FR-23: more than 30% of the detections over counted zones are unmatched. The commit is still
    /// applied; the AR layer shows the banner, pauses auto-count and can `undoLastCommit()`.
    public var driftAlarm: Bool
    /// Added. One status per detection, in detection order.
    public var statuses: [DetectionStatus]
    /// Added. Merged `bottle_top` detections and the bottle each one belongs to.
    public var mergedTops: [(top: Int, bottle: Int)]
    /// Added. The drift correction applied to this view's detections (and zone), metres, world.
    public var driftOffset: SIMD3<Float>
    /// Added. Whether this commit's local drift refinement found a new offset (else the previous
    /// estimate was applied).
    public var driftRefined: Bool
    /// Added. Detections over counted zones, and how many of them are unmatched (the alarm's ratio).
    public var overCountedZones: Int
    public var unmatchedOverCountedZones: Int

    public init(commitID: UUID, newItems: [CountedItem], matched: [(detection: Int, item: UUID)],
                possibleMisses: [Int], zone: CountedZone, driftAlarm: Bool, statuses: [DetectionStatus] = [],
                mergedTops: [(top: Int, bottle: Int)] = [], driftOffset: SIMD3<Float> = .zero,
                driftRefined: Bool = false, overCountedZones: Int = 0, unmatchedOverCountedZones: Int = 0) {
        self.commitID = commitID
        self.newItems = newItems
        self.matched = matched
        self.possibleMisses = possibleMisses
        self.zone = zone
        self.driftAlarm = driftAlarm
        self.statuses = statuses
        self.mergedTops = mergedTops
        self.driftOffset = driftOffset
        self.driftRefined = driftRefined
        self.overCountedZones = overCountedZones
        self.unmatchedOverCountedZones = unmatchedOverCountedZones
    }
}
