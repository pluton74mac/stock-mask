import Foundation

/// One cell of an exported row.
public enum ExportCell: Equatable, Sendable {
    case text(String)
    /// A product code or barcode: always written as text, never as a number (ADR 005).
    case code(String)
    case integer(Int)
    case decimal(Double)
    case date(Date)
    case empty
}

/// How a CSV file is written (FR-36, ADR 005).
public struct CSVDialect: Hashable, Sendable {
    public var name: String
    public var separator: Character
    public var decimalSeparator: Character
    /// UTF-8 byte order mark, so Excel reads the file as UTF-8 (accents, "ñ").
    public var byteOrderMark: Bool
    public var lineEnding: String
    /// Excel turns all-digit text into a number when it opens a CSV: leading zeros vanish and long
    /// barcodes show as 7,79123E+12. When true, all-digit codes are written as `="0071234"`,
    /// which Excel shows as the text 0071234.
    public var excelTextCodes: Bool

    public init(
        name: String, separator: Character, decimalSeparator: Character, byteOrderMark: Bool,
        lineEnding: String = "\r\n", excelTextCodes: Bool
    ) {
        self.name = name
        self.separator = separator
        self.decimalSeparator = decimalSeparator
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
        self.excelTextCodes = excelTextCodes
    }

    /// What Argentine Excel expects: UTF-8 with BOM, `;` between fields, decimal comma.
    public static let excelArgentina = CSVDialect(
        name: "Excel (Argentina)", separator: ";", decimalSeparator: ",", byteOrderMark: true, excelTextCodes: true)

    /// For Google Sheets and for importing into other systems: UTF-8 without BOM, `,`, decimal
    /// point, codes as plain text.
    public static let standard = CSVDialect(
        name: "Standard", separator: ",", decimalSeparator: ".", byteOrderMark: false, excelTextCodes: false)
}

/// Neutralises text that a spreadsheet would run as a formula (CSV injection). A cell that starts
/// with `= + - @`, a tab or a line break (or their full-width forms) gets a leading apostrophe.
public enum FormulaGuard {
    static let triggers: Set<Unicode.Scalar> = [
        "=", "+", "-", "@", "\t", "\r", "\n", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}",
    ]

    /// True when a spreadsheet could read the text as a formula.
    public static func isRisky(_ text: String) -> Bool {
        text.unicodeScalars.first.map(triggers.contains) ?? false
    }

    public static func escaped(_ text: String) -> String {
        isRisky(text) ? "'" + text : text
    }
}

enum CSVWriter {
    static func write(header: [String], rows: [[ExportCell]], dialect: CSVDialect, timeZone: TimeZone) -> Data {
        var out = ""
        let sep = String(dialect.separator)
        out += header.map { field(.text($0), dialect, timeZone) }.joined(separator: sep) + dialect.lineEnding
        for row in rows {
            out += row.map { field($0, dialect, timeZone) }.joined(separator: sep) + dialect.lineEnding
        }
        var data = Data()
        if dialect.byteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: Array(out.utf8))
        return data
    }

    static func field(_ cell: ExportCell, _ dialect: CSVDialect, _ timeZone: TimeZone) -> String {
        switch cell {
        case .empty:
            return ""
        case let .text(s):
            return quoted(FormulaGuard.escaped(s), dialect)
        case let .code(s):
            if dialect.excelTextCodes, GTIN.isDigits(s), s.count <= 255 {
                return quoted("=\"" + s + "\"", dialect)
            }
            return quoted(FormulaGuard.escaped(s), dialect)
        case let .integer(n):
            return String(n)
        case let .decimal(d):
            return decimal(d, separator: dialect.decimalSeparator)
        case let .date(d):
            return ExportFormat.dateTime(d, timeZone)
        }
    }

    /// RFC 4180 quoting. Fields with either separator are quoted, so a file opened with the other
    /// separator still splits correctly.
    static func quoted(_ s: String, _ dialect: CSVDialect) -> String {
        let needs = s.unicodeScalars.contains { $0 == "\"" || $0 == "," || $0 == ";" || $0 == "\r" || $0 == "\n" || $0 == "\t" }
            || s.contains(dialect.separator)
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Up to 6 decimals, no grouping, no exponent: 0.75 → "0,75" with a decimal comma.
    static func decimal(_ d: Double, separator: Character) -> String {
        guard d.isFinite else { return "" }
        var s = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return s.replacingOccurrences(of: ".", with: String(separator))
    }
}

enum ExportFormat {
    /// "2026-10-02 14:35" in the given time zone: unambiguous, and Excel reads it as a date.
    static func dateTime(_ date: Date, _ timeZone: TimeZone) -> String {
        let c = components(date, timeZone)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(c.year!)-\(two(c.month!))-\(two(c.day!)) \(two(c.hour!)):\(two(c.minute!))"
    }

    static func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}
