import Foundation

/// A parsed CSV file: the header row and the data rows.
public struct CSVTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    /// The spreadsheet row number of each data row (the header is row 1; blank rows are counted),
    /// so messages can say "row 7" and match what the owner sees in Excel.
    public var rowNumbers: [Int]
    public var delimiter: Character
    /// "utf-8", "utf-16" or "windows-1252".
    public var encoding: String
}

/// Reads the CSV files people actually have: Excel's "CSV UTF-8" (BOM, `;`), Excel's plain CSV
/// (Windows-1252 in Argentina), Google Sheets (`,`), and tab-separated "Unicode text" (UTF-16).
public enum CSVReader {
    public static func read(_ data: Data, delimiter: Character? = nil) -> CSVTable {
        let (text, encoding) = decode(data)
        let delimiter = delimiter ?? detectDelimiter(text)
        var records = parse(text, delimiter: delimiter)
        var numbers = records.indices.map { $0 + 1 }
        // Blank lines (or Excel's ";;;;" lines) carry no data.
        let keep = records.indices.filter { !records[$0].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        records = keep.map { records[$0] }
        numbers = keep.map { numbers[$0] }
        guard let header = records.first else {
            return CSVTable(header: [], rows: [], rowNumbers: [], delimiter: delimiter, encoding: encoding)
        }
        return CSVTable(
            header: header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            rows: Array(records.dropFirst()), rowNumbers: Array(numbers.dropFirst()),
            delimiter: delimiter, encoding: encoding)
    }

    static func decode(_ data: Data) -> (String, String) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), "utf-8")
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
            let s = String(data: data, encoding: .utf16)
        {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, "utf-16")
        }
        if let s = String(data: data, encoding: .utf8) { return (s, "utf-8") }
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, "windows-1252") }
        return (String(data: data, encoding: .isoLatin1) ?? "", "windows-1252")
    }

    /// The most frequent of `;`, tab and `,` in the first line, outside quotes.
    static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [";": 0, "\t": 0, ",": 0]
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, ch == "\n" || ch == "\r" || ch == "\r\n" { break }
            if !inQuotes, counts[ch] != nil { counts[ch]! += 1 }
        }
        let best = [";", "\t", ","].max { counts[$0]! < counts[$1]! }!
        return counts[best]! > 0 ? best : ","
    }

    /// RFC 4180, leniently: quotes may wrap fields with separators, quotes ("" inside) and line
    /// breaks; text after a closing quote is kept.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var pendingQuote = false  // inside quotes, saw a quote: either "" or the closing quote

        func endField() {
            record.append(field)
            field = ""
            fieldStarted = false
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }

        for ch in text {
            if inQuotes {
                if pendingQuote {
                    pendingQuote = false
                    if ch == "\"" {
                        field.append("\"")
                        continue
                    }
                    inQuotes = false  // that was the closing quote; handle ch below
                } else if ch == "\"" {
                    pendingQuote = true
                    continue
                } else {
                    field.append(ch)
                    continue
                }
            }
            if ch == delimiter {
                endField()
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                endRecord()
            } else if ch == "\"" && !fieldStarted && field.isEmpty {
                inQuotes = true
                fieldStarted = true
            } else {
                field.append(ch)
                fieldStarted = true
            }
        }
        if inQuotes && pendingQuote { inQuotes = false }
        if fieldStarted || !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
