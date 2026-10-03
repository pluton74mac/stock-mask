import Foundation

/// Which rows the export has. Both use the same ADR 005 columns.
public enum ExportLayout: String, Sendable, CaseIterable {
    /// The stock sheet: one row per product (and per unknown group). `zone` lists the zones
    /// ("Cámara, Depósito"); `source` is camera, manual or camera+manual.
    case byProduct = "by_product"
    /// One row per product, zone and source, for venues that keep stock per room.
    case byZoneAndSource = "by_zone_and_source"
}

public struct ExportOptions: Sendable {
    public var layout: ExportLayout
    /// Dates are written in this time zone (the venue's; the phone is at the venue).
    public var timeZone: TimeZone

    public init(layout: ExportLayout = .byProduct, timeZone: TimeZone = .current) {
        self.layout = layout
        self.timeZone = timeZone
    }
}

/// A file ready for the share sheet.
public struct ExportFile: Equatable, Sendable {
    public var fileName: String
    public var data: Data
    public var mimeType: String
}

/// FR-36 export of a stock sheet as CSV (two dialects) or XLSX, with the ADR 005 columns.
public enum StockSheetExport {
    /// ADR 005 export columns (v1), in order.
    public static let columns = [
        "session_id", "venue", "zone", "counted_at", "counted_by", "sku_code", "sku_name", "brand", "category",
        "size_ml", "units_per_case", "full_cases", "loose_units", "total_units", "source", "notes",
    ]

    static let columnWidths: [Double] = [38, 18, 18, 17, 16, 16, 32, 18, 16, 9, 15, 11, 12, 12, 14, 32]

    public static func csv(_ sheet: StockSheet, dialect: CSVDialect, options: ExportOptions = ExportOptions()) -> ExportFile {
        let data = CSVWriter.write(header: columns, rows: rows(sheet, layout: options.layout), dialect: dialect, timeZone: options.timeZone)
        return ExportFile(fileName: fileName(sheet, ext: "csv", timeZone: options.timeZone), data: data, mimeType: "text/csv")
    }

    public static func xlsx(_ sheet: StockSheet, options: ExportOptions = ExportOptions()) -> ExportFile {
        let data = XLSXWriter.workbook(
            sheetName: "Stock", header: columns, rows: rows(sheet, layout: options.layout), columnWidths: columnWidths,
            timeZone: options.timeZone, modified: asOf(sheet))
        return ExportFile(
            fileName: fileName(sheet, ext: "xlsx", timeZone: options.timeZone), data: data,
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    }

    /// The rows under the header, as cells.
    public static func rows(_ sheet: StockSheet, layout: ExportLayout) -> [[ExportCell]] {
        sheet.lines.flatMap { line -> [[ExportCell]] in
            switch layout {
            case .byProduct:
                return [row(sheet, line, zones: line.zones.map(\.name), countedAt: line.countedAt,
                            quantity: line.quantity, source: line.sources.map(\.rawValue).joined(separator: "+"),
                            notes: line.notes)]
            case .byZoneAndSource:
                return line.parts.map { part in
                    row(sheet, line, zones: [part.zone.name], countedAt: part.countedAt, quantity: part.quantity,
                        source: part.source.rawValue, notes: part.notes)
                }
            }
        }
    }

    private static func row(
        _ sheet: StockSheet, _ line: StockLine, zones: [String], countedAt: Date, quantity: Quantity, source: String,
        notes: [String]
    ) -> [ExportCell] {
        func text(_ s: String?) -> ExportCell { s.map { $0.isEmpty ? .empty : .text($0) } ?? .empty }
        func int(_ n: Int?) -> ExportCell { n.map { .integer($0) } ?? .empty }
        return [
            .text(sheet.session.id.dbKey),
            text(sheet.venue.name),
            text(zones.joined(separator: ", ")),
            .date(countedAt),
            text(sheet.session.counterName),
            line.sku?.code.map { .code($0) } ?? .empty,
            text(line.name),
            text(line.sku?.brand),
            text(line.sku?.category),
            int(line.sku?.sizeML),
            int(quantity.unitsPerCase),
            .integer(quantity.fullCases),
            .integer(quantity.looseUnits),
            int(quantity.totalUnits),
            text(source),
            text(notes.joined(separator: " | ")),
        ]
    }

    /// "stock Bar Ejemplo 2026-10-02.xlsx": the venue and the count's date, safe for any file system.
    public static func fileName(_ sheet: StockSheet, ext: String, timeZone: TimeZone) -> String {
        let c = ExportFormat.components(sheet.session.startedAt, timeZone)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let date = "\(c.year!)-\(two(c.month!))-\(two(c.day!))"
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let venue = String(String.UnicodeScalarView(sheet.venue.name.unicodeScalars.filter { !forbidden.contains($0) }))
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (venue.isEmpty ? "stock \(date)" : "stock \(venue.prefix(60)) \(date)") + ".\(ext)"
    }

    /// The time the sheet's content is as of: the lock time, else the latest count.
    static func asOf(_ sheet: StockSheet) -> Date {
        sheet.session.finishedAt ?? sheet.lines.map(\.countedAt).max() ?? sheet.session.startedAt
    }
}
