// SHIM: remove at integration (see ../../Package.swift).
// One record per table of PRD §11, without depth_multiplier.
import Foundation

public struct Venue: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    public var country: String
    public init(name: String, country: String) { self.name = name; self.country = country }
}

public struct Zone: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var venueID: UUID
    public var name: String
    public init(venueID: UUID, name: String) { self.venueID = venueID; self.name = name }
}

public struct Sku: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var code: String
    public var name: String
    public var brand: String
    public var category: String
    public var sizeML: Int?
    public var unitsPerCase: Int?
    public var unitBarcode: String
    public var caseGTIN: String
    public init(code: String = "", name: String, brand: String = "", category: String = "", sizeML: Int? = nil,
                unitsPerCase: Int? = nil, unitBarcode: String = "", caseGTIN: String = "") {
        self.code = code; self.name = name; self.brand = brand; self.category = category; self.sizeML = sizeML
        self.unitsPerCase = unitsPerCase; self.unitBarcode = unitBarcode; self.caseGTIN = caseGTIN
    }
}

public enum SessionStatus: String, Sendable, Codable { case open, review, locked }

public struct Session: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var venueID: UUID
    public var counterName: String
    public var status = SessionStatus.open
    public var startedAt = Date()
    public var finishedAt: Date?
    public init(venueID: UUID, counterName: String) { self.venueID = venueID; self.counterName = counterName }
}

public struct Commit: Sendable, Identifiable, Codable, Equatable {
    public var id: UUID
    public var sessionID: UUID
    public var zoneID: UUID
    public var anchorID: UUID?
    public var pose: [Float]            // camera to world, 16 values, column-major
    public var keyframeFile: String?
    public var createdAt = Date()
    public var undone = false
    public init(id: UUID, sessionID: UUID, zoneID: UUID, anchorID: UUID?, pose: [Float], keyframeFile: String?) {
        self.id = id; self.sessionID = sessionID; self.zoneID = zoneID; self.anchorID = anchorID; self.pose = pose
        self.keyframeFile = keyframeFile
    }
}

/// Table `counted_zone`: an oriented box in anchor space.
public struct CountedZoneRecord: Sendable, Identifiable, Codable, Equatable {
    public var id: UUID
    public var commitID: UUID
    public var transform: [Float]       // 16 values, column-major
    public var halfExtents: [Float]     // 3 values
    public init(id: UUID, commitID: UUID, transform: [Float], halfExtents: [Float]) {
        self.id = id; self.commitID = commitID; self.transform = transform; self.halfExtents = halfExtents
    }
}

public struct Item: Sendable, Identifiable, Codable, Equatable {
    public var id: UUID
    public var commitID: UUID
    public var position: [Float]        // 3 values, anchor space
    public var cls: String
    public var confidence: Float
    public var groupID: UUID?
    public var cropFile: String?
    public var removed = false
    public init(id: UUID, commitID: UUID, position: [Float], cls: String, confidence: Float, groupID: UUID?,
                cropFile: String? = nil) {
        self.id = id; self.commitID = commitID; self.position = position; self.cls = cls
        self.confidence = confidence; self.groupID = groupID; self.cropFile = cropFile
    }
}

public struct ItemGroup: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var sessionID: UUID
    public var skuID: UUID?
    public var label: String            // "Unknown A" until named
    public var confirmed = false
    public init(sessionID: UUID, label: String) { self.sessionID = sessionID; self.label = label }
}

public struct ManualLine: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var sessionID: UUID
    public var zoneID: UUID
    public var skuID: UUID
    public var fullCases: Int
    public var looseUnits: Int
    public var note: String
    public init(sessionID: UUID, zoneID: UUID, skuID: UUID, fullCases: Int, looseUnits: Int, note: String = "") {
        self.sessionID = sessionID; self.zoneID = zoneID; self.skuID = skuID; self.fullCases = fullCases
        self.looseUnits = looseUnits; self.note = note
    }
}

public struct Event: Sendable, Identifiable, Codable, Equatable {
    public var id = UUID()
    public var sessionID: UUID
    public var ts = Date()
    public var type: String
    public var payload: String          // JSON
    public init(sessionID: UUID, type: String, payload: String = "{}") {
        self.sessionID = sessionID; self.type = type; self.payload = payload
    }
}
