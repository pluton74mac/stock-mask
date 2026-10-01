// SHIM: remove at integration (see ../../Package.swift).
import Foundation

/// One line per product; unnamed groups are lines of their own ("Unknown A").
public struct StockSheet: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: String { skuID?.uuidString ?? "group-\(groupID?.uuidString ?? label)" }
        public var skuID: UUID?
        public var groupID: UUID?          // set for an unnamed group's line
        public var label: String           // product name, or "Unknown A"
        public var cameraUnits: Int
        public var manualUnits: Int
        public var unitsPerCase: Int?
        public var totalUnits: Int { cameraUnits + manualUnits }
        public var fullCases: Int { unitsPerCase.map { $0 > 0 ? totalUnits / $0 : 0 } ?? 0 }
        public var looseUnits: Int { unitsPerCase.map { $0 > 0 ? totalUnits % $0 : totalUnits } ?? totalUnits }
        public var source: String { cameraUnits > 0 ? (manualUnits > 0 ? "camera+manual" : "camera") : "manual" }
    }

    public var lines: [Line]
    public var totalUnits: Int { lines.reduce(0) { $0 + $1.totalUnits } }

    static func build(items: [Item], groups: [ItemGroup], manual: [ManualLine], skus: [Sku]) -> StockSheet {
        let skuByID = Dictionary(uniqueKeysWithValues: skus.map { ($0.id, $0) })
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var lines: [String: Line] = [:]
        func key(_ sku: UUID?, _ group: UUID?, _ label: String) -> String { sku?.uuidString ?? "g\(group?.uuidString ?? label)" }
        for item in items {
            let g = item.groupID.flatMap { groupByID[$0] }
            let sku = g?.skuID
            let label = sku.flatMap { skuByID[$0]?.name } ?? g?.label ?? "Unknown"
            let k = key(sku, sku == nil ? g?.id : nil, label)
            lines[k, default: Line(skuID: sku, groupID: sku == nil ? g?.id : nil, label: label, cameraUnits: 0,
                                   manualUnits: 0, unitsPerCase: sku.flatMap { skuByID[$0]?.unitsPerCase })].cameraUnits += 1
        }
        for m in manual {
            let sku = skuByID[m.skuID]
            let units = m.fullCases * (sku?.unitsPerCase ?? 0) + m.looseUnits
            lines[key(m.skuID, nil, ""), default: Line(skuID: m.skuID, groupID: nil, label: sku?.name ?? "?", cameraUnits: 0,
                                                       manualUnits: 0, unitsPerCase: sku?.unitsPerCase)].manualUnits += units
        }
        return StockSheet(lines: lines.values.sorted {
            ($0.skuID == nil ? 1 : 0, $0.label) < ($1.skuID == nil ? 1 : 0, $1.label)
        })
    }
}

/// ADR 005's CSV: "Excel (Argentina)" is UTF-8 with BOM and `;`; "standard" is `,`. Cells that
/// start with = + - @ are escaped with a leading apostrophe.
public enum CSVExport {
    public static let columns = ["session_id", "venue", "zone", "counted_at", "counted_by", "sku_code", "sku_name", "brand",
                                 "category", "size_ml", "units_per_case", "full_cases", "loose_units", "total_units",
                                 "source", "notes"]

    public static func csv(_ sheet: StockSheet, session: Session, venue: Venue, zone: String, skus: [Sku],
                           argentina: Bool) -> String {
        let sep = argentina ? ";" : ","
        let skuByID = Dictionary(uniqueKeysWithValues: skus.map { ($0.id, $0) })
        let date = ISO8601DateFormatter().string(from: session.startedAt)
        var rows = [columns]
        for l in sheet.lines {
            let s = l.skuID.flatMap { skuByID[$0] }
            rows.append([session.id.uuidString, venue.name, zone, date, session.counterName, s?.code ?? "", l.label,
                         s?.brand ?? "", s?.category ?? "", s?.sizeML.map(String.init) ?? "",
                         l.unitsPerCase.map(String.init) ?? "", String(l.fullCases), String(l.looseUnits),
                         String(l.totalUnits), l.source, ""])
        }
        let body = rows.map { $0.map { cell($0, sep) }.joined(separator: sep) }.joined(separator: "\r\n") + "\r\n"
        return (argentina ? "\u{FEFF}" : "") + body
    }

    static func cell(_ value: String, _ sep: String) -> String {
        var v = value
        if let first = v.first, "=+-@".contains(first) { v = "'" + v }
        if v.contains(sep) || v.contains("\"") || v.contains("\n") || v.contains("\r") {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
