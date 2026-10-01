import Foundation
import Testing
@testable import StockMaskCore

let buenosAires = TimeZone(identifier: "America/Argentina/Buenos_Aires")!

/// A small counted session: Lager by camera and by hand in two zones, an unnamed group, two kegs.
func exportScenario() throws -> (World, StockSheet) {
    let world = try World.make()
    let store = world.store
    let session = try world.startSession()
    let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 3, cases: 2))
    try store.nameGroup(a.groups[0].group.id, sku: world.lager.id)
    try store.nameGroup(a.groups[1].group.id, sku: world.lager.id)
    try store.addManualLine(
        sessionID: session.id, zoneID: world.camara.id, skuID: world.lager.id, fullCases: 1,
        note: "caja abierta; 3 \"sueltas\"")
    try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 4, x: 2))
    try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.keg.id, looseUnits: 2)
    return (world, try store.stockSheet(sessionID: session.id))
}

@Suite("CSV export")
struct CSVExportTests {
    @Test("Excel (Argentina): UTF-8 BOM, semicolons, CRLF, codes Excel keeps as text")
    func excelArgentina() throws {
        let (_, sheet) = try exportScenario()
        let file = StockSheetExport.csv(sheet, dialect: .excelArgentina, options: ExportOptions(timeZone: buenosAires))
        #expect(Array(file.data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: file.data.dropFirst(3), as: UTF8.self)
        let sid = sheet.session.id.uuidString.lowercased()
        #expect(text == [
            "session_id;venue;zone;counted_at;counted_by;sku_code;sku_name;brand;category;size_ml;units_per_case;full_cases;loose_units;total_units;source;notes",
            #"\#(sid);Bar Ejemplo;Cámara;2026-10-02 09:00;Ana Prueba;"=""0900""";Barril Lager 50 L;Cervecería Inventada;Barril;50000;;0;2;2;manual;"#,
            #"\#(sid);Bar Ejemplo;"Depósito, Cámara";2026-10-02 09:00;Ana Prueba;"=""0102""";Lager Muestra 1 L;Cervecería Inventada;Cerveza;1000;12;3;3;39;camera+manual;"caja abierta; 3 ""sueltas""""#,
            #"\#(sid);Bar Ejemplo;Depósito;2026-10-02 09:00;Ana Prueba;;Unknown C;;;;;0;4;4;camera;"#,
            "",
        ].joined(separator: "\r\n"))
        #expect(file.fileName == "stock Bar Ejemplo 2026-10-02.csv")
        #expect(file.mimeType == "text/csv")
    }

    @Test("Standard: no BOM, commas, decimal point, codes as plain text")
    func standard() throws {
        let (_, sheet) = try exportScenario()
        let file = StockSheetExport.csv(sheet, dialect: .standard, options: ExportOptions(timeZone: buenosAires))
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(!text.hasPrefix("\u{FEFF}"))
        let sid = sheet.session.id.uuidString.lowercased()
        #expect(text == [
            StockSheetExport.columns.joined(separator: ","),
            "\(sid),Bar Ejemplo,Cámara,2026-10-02 09:00,Ana Prueba,0900,Barril Lager 50 L,Cervecería Inventada,Barril,50000,,0,2,2,manual,",
            #"\#(sid),Bar Ejemplo,"Depósito, Cámara",2026-10-02 09:00,Ana Prueba,0102,Lager Muestra 1 L,Cervecería Inventada,Cerveza,1000,12,3,3,39,camera+manual,"caja abierta; 3 ""sueltas""""#,
            "\(sid),Bar Ejemplo,Depósito,2026-10-02 09:00,Ana Prueba,,Unknown C,,,,,0,4,4,camera,",
            "",
        ].joined(separator: "\r\n"))
    }

    @Test("By zone and source: one row per part, same columns")
    func byZoneAndSource() throws {
        let (_, sheet) = try exportScenario()
        let file = StockSheetExport.csv(
            sheet, dialect: .standard, options: ExportOptions(layout: .byZoneAndSource, timeZone: buenosAires))
        let table = CSVReader.read(file.data)
        #expect(table.header == StockSheetExport.columns)
        let rows = table.rows.map { [$0[2], $0[6], $0[11], $0[12], $0[13], $0[14]] }
        #expect(rows == [
            ["Cámara", "Barril Lager 50 L", "0", "2", "2", "manual"],
            ["Depósito", "Lager Muestra 1 L", "2", "3", "27", "camera"],
            ["Cámara", "Lager Muestra 1 L", "1", "0", "12", "manual"],
            ["Depósito", "Unknown C", "0", "4", "4", "camera"],
        ])
    }

    @Test("Decimals use the dialect's separator")
    func decimals() {
        #expect(CSVWriter.decimal(0.75, separator: ",") == "0,75")
        #expect(CSVWriter.decimal(1500, separator: ",") == "1500")
        #expect(CSVWriter.decimal(-2.125, separator: ".") == "-2.125")
        #expect(CSVWriter.decimal(.nan, separator: ",") == "")
        let row: [ExportCell] = [.decimal(0.75), .integer(12), .text("1,5 L"), .empty, .code("0071")]
        let excel = CSVWriter.write(header: ["a", "b", "c", "d", "e"], rows: [row], dialect: .excelArgentina, timeZone: buenosAires)
        #expect(String(decoding: excel.dropFirst(3), as: UTF8.self) == "a;b;c;d;e\r\n0,75;12;\"1,5 L\";;\"=\"\"0071\"\"\"\r\n")
        let standard = CSVWriter.write(header: ["a", "b", "c", "d", "e"], rows: [row], dialect: .standard, timeZone: buenosAires)
        #expect(String(decoding: standard, as: UTF8.self) == "a,b,c,d,e\r\n0.75,12,\"1,5 L\",,0071\r\n")
    }

    @Test("Text with separators, quotes and line breaks reads back exactly")
    func quotingRoundTrip() throws {
        let values = ["plain", "a;b", "a,b", "say \"hi\"", "two\nlines", "cr\r\nlf", " padded ", "ñandú áéí", ""]
        for dialect in [CSVDialect.excelArgentina, .standard] {
            let data = CSVWriter.write(
                header: values.indices.map { "c\($0)" }, rows: [values.map { .text($0) }], dialect: dialect, timeZone: buenosAires)
            let table = CSVReader.read(data)
            #expect(table.delimiter == dialect.separator)
            #expect(table.rows == [values], "\(dialect.name)")
        }
    }

    @Test("Formula injection: text that could run as a formula gets a leading apostrophe")
    func formulaInjection() throws {
        let store = try StockStore.inMemory(clock: TestClock().tick)
        let venue = try store.createVenue(name: "=Bar", country: "AR", locale: "es-AR")
        let zone = try store.addZone(venueID: venue.id, name: "+Zona")
        let sku = try store.createSKU(venueID: venue.id, SKUFields(
            code: "@code", name: #"=HYPERLINK("http://example.invalid","x")"#, brand: "+54 11 5555", category: "-Promo",
            sizeML: 750, unitsPerCase: 6))
        let session = try store.startSession(venueID: venue.id, counterName: "@admin")
        let saved = try store.saveCommit(makeDraft(session: session, zone: zone, bottles: 2))
        try store.nameGroup(saved.groups[0].group.id, sku: sku.id)
        try store.addManualLine(
            sessionID: session.id, zoneID: zone.id, skuID: sku.id, looseUnits: 1, note: "=cmd|' /C calc'!A0")
        let sheet = try store.stockSheet(sessionID: session.id)

        for dialect in [CSVDialect.excelArgentina, .standard] {
            let table = CSVReader.read(StockSheetExport.csv(sheet, dialect: dialect).data)
            let row = try #require(table.rows.first)
            for (column, field) in zip(StockSheetExport.columns, row) {
                #expect(!FormulaGuard.isRisky(field), "\(dialect.name) \(column) = \(field)")
            }
            #expect(row[1] == "'=Bar")
            #expect(row[2] == "'+Zona")
            #expect(row[4] == "'@admin")
            #expect(row[5] == "'@code")
            #expect(row[6] == #"'=HYPERLINK("http://example.invalid","x")"#)
            #expect(row[7] == "'+54 11 5555")
            #expect(row[8] == "'-Promo")
            #expect(row[15] == "'=cmd|' /C calc'!A0")
        }
        for risky in ["=1", "+1", "-1", "@x", "\t=1", "\r\n=1", "\n=1", "＝1", "＋1", "－1", "＠x"] {
            #expect(FormulaGuard.isRisky(risky), "\(risky.debugDescription)")
            #expect(FormulaGuard.escaped(risky) == "'" + risky)
        }
        for safe in ["1", "a=1", " =1", "'=1", "", "Malbec"] {
            #expect(!FormulaGuard.isRisky(safe), "\(safe.debugDescription)")
        }
    }

    @Test("Only all-digit codes get the Excel text wrapper; other codes stay plain")
    func codesInExcel() {
        let cells: [ExportCell] = [.code("0071234567890"), .code("MAL-750"), .code("12 34"), .code("=1+1")]
        let text = String(decoding: CSVWriter.write(header: ["a", "b", "c", "d"], rows: [cells], dialect: .excelArgentina,
                                                    timeZone: buenosAires).dropFirst(3), as: UTF8.self)
        #expect(text == "a;b;c;d\r\n\"=\"\"0071234567890\"\"\";MAL-750;12 34;'=1+1\r\n")
    }

    @Test("The venue's locale picks the default dialect")
    func defaultDialect() throws {
        let store = try StockStore.inMemory()
        #expect(try store.createVenue(name: "A", country: "AR", locale: "es-AR").defaultCSVDialect == .excelArgentina)
        #expect(try store.createVenue(name: "B", country: "US", locale: "en-US").defaultCSVDialect == .standard)
    }

    @Test("File names are safe for any file system")
    func fileNames() throws {
        let (world, sheet) = try exportScenario()
        var odd = sheet
        odd.venue.name = "Bar: \"El/Patio\"?"
        #expect(StockSheetExport.fileName(odd, ext: "xlsx", timeZone: buenosAires) == "stock Bar ElPatio 2026-10-02.xlsx")
        _ = world
    }
}
