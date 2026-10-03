import Foundation
import Synchronization
import simd
import Testing
@testable import StockMaskCore

// Everything here is made up: the repository is public, so no real venue or product data.

/// A clock that starts at 2026-10-02 12:00:00 UTC and moves one second per reading.
final class TestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_790_942_400)
    private let time = Mutex(TestClock.start)

    func tick() -> Date {
        time.withLock { t in
            defer { t += 1 }
            return t
        }
    }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 += seconds }
    }
}

/// An EAN-13 in the GS1 "restricted circulation" range (prefix 20–29), which no real product uses.
func fakeEAN(_ n: Int) -> String {
    let body = "20" + String(format: "%010d", n)
    return body + String(GTIN.checkDigit(for: body)!)
}

/// A venue with three zones and a small invented catalog.
struct World {
    let store: StockStore
    let clock: TestClock
    let venue: Venue
    let deposito: Zone
    let camara: Zone
    let seco: Zone
    let malbec: SKU  // 750 ml, 6 per case
    let lager: SKU  // 1 L, 12 per case
    let fernet: SKU  // 750 ml, 6 per case
    let tonica: SKU  // can, 24 per case
    let keg: SKU  // no units per case

    static func make(at url: URL? = nil) throws -> World {
        let clock = TestClock()
        let store = try url.map { try StockStore.open(at: $0, clock: clock.tick) } ?? StockStore.inMemory(clock: clock.tick)
        return try make(store: store, clock: clock)
    }

    static func make(store: StockStore, clock: TestClock) throws -> World {
        let venue = try store.createVenue(name: "Bar Ejemplo", country: "ar", locale: "es-AR")
        let deposito = try store.addZone(venueID: venue.id, name: "Depósito")
        let camara = try store.addZone(venueID: venue.id, name: "Cámara")
        let seco = try store.addZone(venueID: venue.id, name: "Seco")
        func sku(_ code: String, _ name: String, _ brand: String, _ category: String, _ ml: Int, _ perCase: Int?, _ n: Int) throws -> SKU {
            let unit = fakeEAN(n)
            return try store.createSKU(venueID: venue.id, SKUFields(
                code: code, name: name, brand: brand, category: category, sizeML: ml, unitsPerCase: perCase,
                unitBarcode: unit, caseGTIN: perCase == nil ? nil : GTIN.caseGTIN(fromUnit: unit, indicator: 1)))
        }
        return World(
            store: store, clock: clock, venue: venue, deposito: deposito, camara: camara, seco: seco,
            malbec: try sku("0071", "Malbec Muestra", "Bodega Ficticia", "Vino", 750, 6, 1),
            lager: try sku("0102", "Lager Muestra 1 L", "Cervecería Inventada", "Cerveza", 1000, 12, 2),
            fernet: try sku("0230", "Fernet Imaginario", "Destilería Ficticia", "Aperitivo", 750, 6, 3),
            tonica: try sku("0345", "Tónica Ejemplo lata", "Bebidas Prueba", "Sin alcohol", 354, 24, 4),
            keg: try sku("0900", "Barril Lager 50 L", "Cervecería Inventada", "Barril", 50_000, nil, 5))
    }

    func startSession(zones: [Zone]? = nil) throws -> Session {
        try store.startSession(venueID: venue.id, counterName: "Ana Prueba", zoneIDs: zones?.map(\.id))
    }
}

/// A commit with `bottles` bottles in group key 0 and `cases` cases in group key 1 (by default).
func makeDraft(
    session: Session, zone: Zone, bottles: Int = 0, cases: Int = 0, cans: Int = 0, tops: Int = 0,
    keyed: Bool = true, suggestions: [NewGroup] = [], misses: Int = 0, keyframe: String? = nil, x: Float = 0
) -> CommitDraft {
    var items: [NewItem] = []
    func add(_ cls: ItemClass, _ count: Int, key: Int) {
        for i in 0..<count {
            let position = SIMD3(x + Float(items.count) * 0.09, Float(i) * 0.01, Float(1.25))
            // As the engine gives them: a bottle's top above its centre; a lone top is its own top.
            let top: SIMD3<Float>? = switch cls {
            case .bottle: position + SIMD3(0, 0.14, 0)
            case .bottleTop: position
            case .can, .case: nil
            }
            items.append(NewItem(
                id: UUID(), cls: cls, position: position, top: top, confidence: 0.93, detectionIndex: items.count,
                groupKey: keyed ? key : nil, cropPath: "crops/\(UUID().uuidString.lowercased()).jpg"))
        }
    }
    add(.bottle, bottles, key: 0)
    add(.bottleTop, tops, key: 0)
    add(.case, cases, key: 1)
    add(.can, cans, key: 2)
    let id = UUID()
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(x, 1.4, -0.3, 1)
    var box = matrix_identity_float4x4
    box.columns.3 = SIMD4(x + 0.4, 1.1, 1.25, 1)
    return CommitDraft(
        id: id, sessionID: session.id, zoneID: zone.id, anchorID: UUID(), pose: pose,
        keyframePath: keyframe ?? "keyframes/\(id.uuidString.lowercased()).jpg", trigger: .hold, items: items,
        groups: suggestions,
        countedZone: NewCountedZone(id: UUID(), transform: box, halfExtents: SIMD3(0.45, 0.3, 0.18)),
        possibleMisses: (0..<misses).map { i in
            NewPossibleMiss(id: UUID(), cls: .bottle, position: SIMD3(x + Float(i) * 0.09, 0.5, 1.3), confidence: 0.41)
        },
        matchedCount: 0)
}

/// A fresh directory under the system temp directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("StockMaskCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension StockSheet {
    func line(_ sku: SKU) -> StockLine? { lines.first { $0.sku?.id == sku.id } }
    func line(named name: String) -> StockLine? { lines.first { $0.name == name } }
}
