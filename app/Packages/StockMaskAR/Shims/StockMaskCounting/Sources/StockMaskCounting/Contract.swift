// SHIM: remove at integration (see ../../Package.swift).
// The value types of the contract in docs/mvp-test-app.md, with the initialisers StockMaskAR uses.
import Foundation
import simd

public enum ObjectClass: String, Codable, Sendable, CaseIterable {
    case bottle, can, `case`, bottleTop = "bottle_top"
}

/// One detector box, lifted to 3D when depth allows.
public struct Detection: Sendable {
    public var cls: ObjectClass
    public var score: Float
    public var box: SIMD4<Float>            // normalised image coordinates: x0, y0, x1, y1
    public var position: SIMD3<Float>?      // metres, world (or anchor) space
    public var size: SIMD2<Float>?          // metres, width and height in the image plane

    public init(cls: ObjectClass, score: Float, box: SIMD4<Float>, position: SIMD3<Float>? = nil,
                size: SIMD2<Float>? = nil) {
        self.cls = cls
        self.score = score
        self.box = box
        self.position = position
        self.size = size
    }
}

public struct CountedItem: Sendable, Identifiable {
    public let id: UUID
    public var cls: ObjectClass
    public var position: SIMD3<Float>
    public var commitID: UUID
    public var groupKey: Int?

    public init(id: UUID = UUID(), cls: ObjectClass, position: SIMD3<Float>, commitID: UUID, groupKey: Int? = nil) {
        self.id = id
        self.cls = cls
        self.position = position
        self.commitID = commitID
        self.groupKey = groupKey
    }
}

/// An oriented box: `transform` places the box's centre and axes in world space.
public struct CountedZone: Sendable, Identifiable {
    public let id: UUID
    public var commitID: UUID
    public var transform: simd_float4x4
    public var halfExtents: SIMD3<Float>

    public init(id: UUID = UUID(), commitID: UUID, transform: simd_float4x4, halfExtents: SIMD3<Float>) {
        self.id = id
        self.commitID = commitID
        self.transform = transform
        self.halfExtents = halfExtents
    }
}

public struct CommitResult: Sendable {
    public var commitID: UUID
    public var newItems: [CountedItem]        // added to the count
    public var matched: [(detection: Int, item: UUID)]
    public var possibleMisses: [Int]          // detection indices: shown as amber "+", never added
    public var zone: CountedZone
    public var driftAlarm: Bool

    public init(commitID: UUID, newItems: [CountedItem], matched: [(detection: Int, item: UUID)],
                possibleMisses: [Int], zone: CountedZone, driftAlarm: Bool) {
        self.commitID = commitID
        self.newItems = newItems
        self.matched = matched
        self.possibleMisses = possibleMisses
        self.zone = zone
        self.driftAlarm = driftAlarm
    }
}
