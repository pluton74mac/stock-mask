import Foundation
import Testing
@testable import StockMaskCore

/// Reads a ZIP the strict way: every central-directory entry must point at a matching local
/// header, be stored, and carry the right CRC-32 and sizes.
struct ZipReader {
    struct Entry: Equatable {
        var name: String
        var data: Data
        var crc: UInt32
    }

    enum Failure: Error { case malformed(String) }

    static func entries(_ zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) throws -> Int {
            guard at + 2 <= bytes.count else { throw Failure.malformed("read past end at \(at)") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Failure.malformed("read past end at \(at)") }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 22, let eocd = (0...(bytes.count - 22)).reversed().first(where: { (try? u32($0)) == 0x0605_4B50 })
        else { throw Failure.malformed("no end of central directory") }
        let count = try u16(eocd + 10)
        guard try u16(eocd + 8) == count else { throw Failure.malformed("entry counts differ") }
        let directorySize = Int(try u32(eocd + 12)), directoryOffset = Int(try u32(eocd + 16))
        guard directoryOffset + directorySize == eocd else { throw Failure.malformed("directory doesn't end at EOCD") }

        var entries: [Entry] = []
        var p = directoryOffset
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4B50 else { throw Failure.malformed("bad central header at \(p)") }
            let method = try u16(p + 10), crc = try u32(p + 16)
            let compressed = Int(try u32(p + 20)), size = Int(try u32(p + 24))
            let nameLength = try u16(p + 28), extra = try u16(p + 30), comment = try u16(p + 32)
            let local = Int(try u32(p + 42))
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard method == 0, compressed == size else { throw Failure.malformed("\(name) is not stored") }
            guard try u32(local) == 0x0403_4B50, try u32(local + 14) == crc, Int(try u32(local + 18)) == size,
                Int(try u32(local + 22)) == size, try u16(local + 8) == method
            else { throw Failure.malformed("local header of \(name) disagrees") }
            let localName = String(decoding: bytes[(local + 30)..<(local + 30 + (try u16(local + 26)))], as: UTF8.self)
            guard localName == name else { throw Failure.malformed("names differ: \(localName) / \(name)") }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start + size <= directoryOffset else { throw Failure.malformed("\(name) overruns the directory") }
            let data = Data(bytes[start..<(start + size)])
            guard CRC32.checksum(data) == crc else { throw Failure.malformed("CRC mismatch in \(name)") }
            entries.append(Entry(name: name, data: data, crc: crc))
            p += 46 + nameLength + extra + comment
        }
        return entries
    }
}

/// Collects the cells of a worksheet: reference → (style, type, text).
final class SheetCells: NSObject, XMLParserDelegate {
    struct Cell: Equatable {
        var style: String?
        var type: String?
        var text: String
    }

    var cells: [String: Cell] = [:]
    var formulas = 0
    private var current: (ref: String, cell: Cell)?
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "c": current = (attributes["r"] ?? "?", Cell(style: attributes["s"], type: attributes["t"], text: ""))
        case "t", "v": inText = true
        case "f": formulas += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current?.cell.text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "t", "v": inText = false
        case "c":
            if let current { cells[current.ref] = current.cell }
            current = nil
        default: break
        }
    }
}

func parseXML(_ data: Data, delegate: (any XMLParserDelegate)? = nil) -> Bool {
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    return parser.parse()
}

#if os(macOS)
/// The repository root, from this file's path (Tests/StockMaskCoreTests/ in app/Packages/StockMaskCore).
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

/// A Python that can import openpyxl: $STOCKMASK_OPENPYXL_PYTHON, else the research venv.
let openpyxlPython: String? = {
    let candidates = [
        ProcessInfo.processInfo.environment["STOCKMASK_OPENPYXL_PYTHON"],
        repositoryRoot.appendingPathComponent("research/walkthrough/venv/bin/python").path,
    ].compactMap { $0 }
    return candidates.first { path in
        FileManager.default.isExecutableFile(atPath: path) && ((try? run(path, ["-c", "import openpyxl"]).status) == 0)
    }
}()
#endif

@Suite("XLSX export")
struct XLSXExportTests {
    static func file() throws -> (StockSheet, ExportFile) {
        let (_, sheet) = try exportScenario()
        return (sheet, StockSheetExport.xlsx(sheet, options: ExportOptions(timeZone: buenosAires)))
    }

    @Test("CRC-32 matches the standard check value")
    func crc() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("The package is a valid stored ZIP with the Office Open XML parts, content types first")
    func zipStructure() throws {
        let (_, file) = try Self.file()
        #expect(file.fileName == "stock Bar Ejemplo 2026-10-02.xlsx")
        #expect(file.mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        let entries = try ZipReader.entries(file.data)
        #expect(entries.map(\.name) == [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
            "xl/worksheets/sheet1.xml",
        ])
        for entry in entries {
            #expect(parseXML(entry.data), "\(entry.name) is not well-formed XML")
        }
    }

    @Test("Codes are text cells, quantities are numbers, the date is a date cell")
    func cellTypes() throws {
        let (sheet, file) = try Self.file()
        let entries = try ZipReader.entries(file.data)
        let xml = try #require(entries.first { $0.name == "xl/worksheets/sheet1.xml" }).data
        let cells = SheetCells()
        #expect(parseXML(xml, delegate: cells))
        #expect(cells.formulas == 0)

        // Header: bold text.
        for (i, column) in StockSheetExport.columns.enumerated() {
            #expect(cells.cells["\(XLSXWriter.columnName(i))1"] == .init(style: "4", type: "inlineStr", text: column))
        }
        // Row 3 is Lager (row 2 the keg, row 4 Unknown C).
        #expect(cells.cells["A3"]?.text == sheet.session.id.uuidString.lowercased())
        #expect(cells.cells["F3"] == .init(style: "1", type: "inlineStr", text: "0102"))  // leading zero kept
        #expect(cells.cells["F2"] == .init(style: "1", type: "inlineStr", text: "0900"))
        #expect(cells.cells["G3"] == .init(style: "1", type: "inlineStr", text: "Lager Muestra 1 L"))
        #expect(cells.cells["C3"]?.text == "Depósito, Cámara")
        #expect(cells.cells["J3"] == .init(style: nil, type: nil, text: "1000"))
        #expect(cells.cells["K3"] == .init(style: nil, type: nil, text: "12"))
        #expect(cells.cells["L3"]?.text == "3")
        #expect(cells.cells["M3"]?.text == "3")
        #expect(cells.cells["N3"]?.text == "39")
        #expect(cells.cells["O3"]?.text == "camera+manual")
        #expect(cells.cells["P3"]?.text == #"caja abierta; 3 "sueltas""#)
        // Empty values have no cell: the keg has no units per case; Unknown C has no code.
        #expect(cells.cells["K2"] == nil)
        #expect(cells.cells["F4"] == nil)
        #expect(cells.cells["G4"]?.text == "Unknown C")

        // 2026-10-02 09:00:xx in Buenos Aires: Excel serial 46297.375…
        let date = try #require(cells.cells["D3"])
        #expect(date.style == "3" && date.type == nil)
        let serial = try #require(Double(date.text))
        #expect(serial >= 46297.375 && serial < 46297.375 + 60.0 / 86_400)
        #expect(XLSXWriter.serial(Date(timeIntervalSince1970: 0), TimeZone(identifier: "UTC")!) == 25569)
    }

    @Test("Text that could run as a formula stays a string cell, marked quotePrefix, unchanged")
    func formulaInjection() throws {
        let rows: [[ExportCell]] = [[.text("=1+1"), .code("@code"), .text("plain"), .text("-5 rotas"), .text("a\u{1}b")]]
        let data = XLSXWriter.workbook(
            sheetName: "Stock", header: ["a", "b", "c", "d", "e"], rows: rows, columnWidths: [], timeZone: buenosAires,
            modified: TestClock.start)
        let xml = try #require(try ZipReader.entries(data).first { $0.name == "xl/worksheets/sheet1.xml" }).data
        let cells = SheetCells()
        #expect(parseXML(xml, delegate: cells))
        #expect(cells.formulas == 0)
        #expect(cells.cells["A2"] == .init(style: "2", type: "inlineStr", text: "=1+1"))
        #expect(cells.cells["B2"] == .init(style: "2", type: "inlineStr", text: "@code"))
        #expect(cells.cells["C2"] == .init(style: "1", type: "inlineStr", text: "plain"))
        #expect(cells.cells["D2"] == .init(style: "2", type: "inlineStr", text: "-5 rotas"))
        #expect(cells.cells["E2"]?.text == "ab", "control characters are dropped, XML 1.0 forbids them")
        let styles = String(decoding: try #require(try ZipReader.entries(data).first { $0.name == "xl/styles.xml" }).data, as: UTF8.self)
        #expect(styles.contains(#"quotePrefix="1""#))
    }

    @Test("Column names follow Excel: A…Z, AA…")
    func columnNames() {
        #expect(XLSXWriter.columnName(0) == "A")
        #expect(XLSXWriter.columnName(15) == "P")
        #expect(XLSXWriter.columnName(26) == "AA")
    }

    // Checks with outside tools (macOS only: they run processes).
    #if os(macOS)
    @Test("unzip -t accepts the file", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip")))
    func unzipAccepts() throws {
        let (_, file) = try Self.file()
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sheet.xlsx")
        try file.data.write(to: url)
        let result = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("No errors detected"))
    }

    @Test("openpyxl reads the values back", .enabled(if: openpyxlPython != nil))
    func openpyxlReadsBack() throws {
        let (sheet, file) = try Self.file()
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sheet.xlsx")
        try file.data.write(to: url)
        let script = """
            import json, sys, openpyxl
            wb = openpyxl.load_workbook(sys.argv[1])
            ws = wb.active
            def cell(c):
                v = c.value
                return {"v": v.isoformat() if hasattr(v, "isoformat") else v, "type": c.data_type,
                        "format": c.number_format, "quote": bool(c.quotePrefix)}
            print(json.dumps({"title": ws.title, "sheets": wb.sheetnames, "freeze": ws.freeze_panes,
                              "rows": [[cell(c) for c in row] for row in ws.iter_rows()]}))
            """
        let result = try run(openpyxlPython!, ["-c", script, url.path])
        #expect(result.status == 0, "\(result.output)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        #expect(json["title"] as? String == "Stock")
        #expect(json["sheets"] as? [String] == ["Stock"])
        #expect(json["freeze"] as? String == "A2")
        let rows = try #require(json["rows"] as? [[[String: Any]]])
        #expect(rows.count == 4)
        #expect(rows[0].map { $0["v"] as? String } == StockSheetExport.columns)
        let lager = rows[2]
        #expect(lager[0]["v"] as? String == sheet.session.id.uuidString.lowercased())
        #expect(lager[3]["v"] as? String == "2026-10-02T09:00:\(String(format: "%02d", Int(sheet.lines[1].countedAt.timeIntervalSince1970) % 60))")
        #expect(lager[3]["type"] as? String == "d")
        #expect(lager[5]["v"] as? String == "0102")
        #expect(lager[5]["type"] as? String == "s")
        #expect(lager[5]["format"] as? String == "@")
        #expect(lager[6]["v"] as? String == "Lager Muestra 1 L")
        #expect(lager.map { $0["v"] as? Int }[9...13] == [1000, 12, 3, 3, 39])
        #expect(lager[14]["v"] as? String == "camera+manual")
        #expect(rows[1][10]["v"] is NSNull)  // the keg has no units per case
        #expect(rows[3][6]["v"] as? String == "Unknown C")
    }

    @Test("openpyxl sees risky text as plain strings with quotePrefix", .enabled(if: openpyxlPython != nil))
    func openpyxlFormulaInjection() throws {
        let rows: [[ExportCell]] = [[.text(#"=HYPERLINK("http://example.invalid","x")"#), .code("+54 11"), .text("ok")]]
        let data = XLSXWriter.workbook(
            sheetName: "Stock", header: ["a", "b", "c"], rows: rows, columnWidths: [10, 10, 10], timeZone: buenosAires,
            modified: TestClock.start)
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("risky.xlsx")
        try data.write(to: url)
        let script = """
            import json, sys, openpyxl
            ws = openpyxl.load_workbook(sys.argv[1]).active
            print(json.dumps([[c.value, c.data_type, bool(c.quotePrefix)] for c in ws[2]]))
            """
        let result = try run(openpyxlPython!, ["-c", script, url.path])
        #expect(result.status == 0, "\(result.output)")
        let cells = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[Any]])
        #expect(cells.map { $0[0] as? String } == [#"=HYPERLINK("http://example.invalid","x")"#, "+54 11", "ok"])
        #expect(cells.map { $0[1] as? String } == ["s", "s", "s"])
        #expect(cells.map { $0[2] as? Bool } == [true, true, false])
    }
    #endif
}
