import Foundation
import Testing
@testable import StockMaskCore

@Suite("Catalog import")
struct CatalogImportTests {
    @Test("Spanish and English headers map to product fields")
    func suggestedMapping() {
        let spanish = ColumnMapping.suggested(for: [
            "Código", "Artículo", "Marca", "Rubro", "Contenido (ml)", "U. x caja", "Código de barras",
            "Código de barras caja", "Precio",
        ])
        #expect(spanish.columns == [
            .code: 0, .name: 1, .brand: 2, .category: 3, .sizeML: 4, .unitsPerCase: 5, .unitBarcode: 6, .caseGTIN: 7,
        ])
        let english = ColumnMapping.suggested(for: ["SKU", "Product name", "Brand", "Category", "Size", "Units per case", "EAN", "DUN-14"])
        #expect(english.columns == [
            .code: 0, .name: 1, .brand: 2, .category: 3, .sizeML: 4, .unitsPerCase: 5, .unitBarcode: 6, .caseGTIN: 7,
        ])
        #expect(ColumnMapping.suggested(for: ["Precio", "Stock"]).columns.isEmpty)
    }

    @Test("Sizes in ml, cc, cl and litres", arguments: [
        ("750", 750), ("750 ml", 750), ("750ml", 750), ("750 cc", 750), ("750 c.c.", 750), ("75 cl", 750),
        ("1 L", 1000), ("1L", 1000), ("1", 1000), ("1,5 lts", 1500), ("0.75", 750), ("0,75 L", 750),
        ("1.000 ml", 1000), ("354 ml", 354), ("50 litros", 50_000), ("5", 5000),
    ])
    func sizes(raw: String, ml: Int) {
        #expect(CatalogImport.parseSizeML(raw) == ml, "\(raw)")
    }

    @Test("Unreadable sizes are refused", arguments: ["", "grande", "750 oz", "1.2.3", "0", "200 l"])
    func badSizes(raw: String) {
        #expect(CatalogImport.parseSizeML(raw) == nil, "\(raw)")
    }

    @Test("Units per case: the first whole number")
    func unitsPerCase() {
        #expect(CatalogImport.parseUnitsPerCase("12") == 12)
        #expect(CatalogImport.parseUnitsPerCase("x6") == 6)
        #expect(CatalogImport.parseUnitsPerCase("caja x 24 u") == 24)
        #expect(CatalogImport.parseUnitsPerCase("0") == 0)
        #expect(CatalogImport.parseUnitsPerCase("doce") == nil)
    }

    @Test("Excel's CSV in Windows-1252, with semicolons and quoted fields")
    func windows1252() throws {
        let text = "Código;Nombre;Marca\r\n0071;\"Malbec; edición \"\"Muestra\"\"\";Bodega Ficticia\r\n;;\r\n0102;Tónica;Ñandú\r\n"
        let data = try #require(text.data(using: .windowsCP1252))
        let table = CSVReader.read(data)
        #expect(table.encoding == "windows-1252")
        #expect(table.delimiter == ";")
        #expect(table.header == ["Código", "Nombre", "Marca"])
        #expect(table.rows == [["0071", "Malbec; edición \"Muestra\"", "Bodega Ficticia"], ["0102", "Tónica", "Ñandú"]])
        #expect(table.rowNumbers == [2, 4])  // the blank ";;" line is row 3
    }

    @Test("UTF-8 with BOM, UTF-16 tab-separated, and Google Sheets CSV")
    func encodings() throws {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("nombre;ml\nTónica;354\n".utf8))
        let a = CSVReader.read(bom)
        #expect(a.encoding == "utf-8" && a.header == ["nombre", "ml"] && a.rows == [["Tónica", "354"]])

        let utf16 = try #require("nombre\tml\r\nTónica\t354\r\n".data(using: .utf16))  // with BOM
        let b = CSVReader.read(utf16)
        #expect(b.encoding == "utf-16" && b.delimiter == "\t" && b.rows == [["Tónica", "354"]])

        let c = CSVReader.read(Data("name,size\n\"Gin, Muestra\",700\nAgua,500".utf8))
        #expect(c.delimiter == "," && c.rows == [["Gin, Muestra", "700"], ["Agua", "500"]])
    }

    @Test("Duplicates are flagged within the file and against the catalog")
    func duplicates() throws {
        let world = try World.make()
        let csv = """
            codigo;nombre;marca;ml;u x caja;ean;dun14
            0071;Malbec Muestra;Bodega Ficticia;750;6;;
            0500;Gin Muestra;Destilería Ficticia;700 ml;6;\(fakeEAN(10));
            0501;Agua Muestra;Bebidas Prueba;500;12;\(fakeEAN(11));
            0502;Gin Muestra;Destilería Ficticia;700;6;;
            0503;Soda Prueba;Bebidas Prueba;1,5 L;x6;\(fakeEAN(11));
            0504;Vermut Rojo;Bodega Ficticia;1 L;6;;\(world.lager.caseGTIN!)
            ;Sin código;;;;;
            0506;Licor Raro;;grande;doce;7,79123E+12;
            ;Gin Muestra;Destilería Ficticia;700;6;;\(GTIN.caseGTIN(fromUnit: fakeEAN(10), indicator: 1)!)
            0508;;Bebidas Prueba;500;;;
            0509;Agua Tónica;Bebidas Prueba;500;24;2000000000011;
            """
        let plan = try world.store.planCatalogImport(venueID: world.venue.id, csv: Data(csv.utf8))
        #expect(plan.mapping.columns.count == 7)
        func row(_ n: Int) throws -> CatalogImportRow { try #require(plan.rows.first { $0.rowNumber == n }) }

        // Row 2 is already in the catalog (same code, same name and size).
        #expect(try row(2).duplicates == [
            Duplicate(key: .code, of: .sku(world.malbec.id)), Duplicate(key: .nameAndSize, of: .sku(world.malbec.id)),
        ])
        #expect(try row(2).action == .skip)
        #expect(try row(3).action == .create && row(3).duplicates.isEmpty)
        #expect(try row(3).fields?.sizeML == 700)
        // Row 5 has row 3's brand, name and size, but its code (0502) differs from row 3's (0500):
        // the venue tracks them as two products, so it is no duplicate.
        #expect(try row(5).duplicates.isEmpty && row(5).action == .create)
        // Row 6 has row 4's unit barcode.
        #expect(try row(6).duplicates == [Duplicate(key: .unitBarcode, of: .row(4))])
        #expect(try row(6).fields?.sizeML == 1500 && row(6).fields?.unitsPerCase == 6)
        // Row 7 has the catalog's Lager case GTIN.
        #expect(try row(7).duplicates == [Duplicate(key: .caseGTIN, of: .sku(world.lager.id))])
        // Row 8: no code is fine.
        #expect(try row(8).action == .create && row(8).fields?.code == nil)
        // Row 9: unreadable size and units; a barcode Excel already turned into 7,79123E+12.
        #expect(try row(9).issues == [
            .invalidSize("grande"), .invalidUnitsPerCase("doce"), .scientificNotation(.unitBarcode, "7,79123E+12"),
        ])
        #expect(try row(9).action == .create && row(9).fields?.unitBarcode == nil)
        // Row 10 has no code: row 3's brand, name and size, and nothing that tells them apart.
        #expect(try row(10).duplicates == [Duplicate(key: .nameAndSize, of: .row(3))])
        #expect(try row(10).action == .skip)
        // Row 11: no name.
        #expect(try row(11).issues == [.missingName] && row(11).fields == nil && row(11).action == .skip)
        // Row 12: a barcode with a wrong check digit is kept, and flagged.
        #expect(try row(12).issues == [.badCheckDigit(.unitBarcode, "2000000000011")])
        #expect(try row(12).fields?.unitBarcode == "2000000000011")

        #expect(plan.createCount == 6)
        #expect(plan.skipCount == 5)
        #expect(plan.flaggedRows.map(\.rowNumber) == [2, 6, 7, 9, 10, 11, 12])
    }

    @Test("Applying a plan creates, updates and skips in one transaction")
    func apply() throws {
        let world = try World.make()
        let store = world.store
        let csv = """
            Código,Nombre,Marca,Contenido,Unidades por caja,EAN
            0071,Malbec Muestra,Bodega Ficticia,750,12,\(world.malbec.unitBarcode!)
            0600,Espumante Prueba,Bodega Ficticia,750,6,\(fakeEAN(20))
            0601,Cola Ejemplo,Bebidas Prueba,2.25,8,\(fakeEAN(21))
            """
        var plan = try store.planCatalogImport(venueID: world.venue.id, csv: Data(csv.utf8))
        #expect(plan.rows.map(\.action) == [.skip, .create, .create])
        plan.rows[0].action = .update(world.malbec.id)  // the owner chose to update units per case
        let result = try store.applyCatalogImport(plan)
        #expect(result.created.map(\.name) == ["Espumante Prueba", "Cola Ejemplo"])
        #expect(result.updated.map(\.id) == [world.malbec.id])
        #expect(result.skipped == 0)
        #expect(try store.sku(id: world.malbec.id)?.unitsPerCase == 12)
        #expect(try store.sku(id: result.created[1].id)?.sizeML == 2250)
        #expect(try store.skus(venueID: world.venue.id).count == 7)
        let event = try #require(store.events(venueID: world.venue.id).last)
        #expect(event.type == .catalogImported)
        #expect(event.payloadValue["rows"] == 3)

        // A row edited into something invalid stops the whole import: nothing is written.
        var bad = try store.planCatalogImport(venueID: world.venue.id, csv: Data("nombre,u x caja\nA,6\nB,4\n".utf8))
        bad.rows[1].fields?.unitsPerCase = 0
        #expect(throws: StoreError.invalid("Row 3: units_per_case must be at least 1, got 0")) {
            try store.applyCatalogImport(bad)
        }
        #expect(try store.skus(venueID: world.venue.id).count == 7)
    }
}

@Suite("GTIN")
struct GTINTests {
    @Test("Check digits and validity")
    func checkDigits() {
        #expect(GTIN.checkDigit(for: "629104150021") == 3)  // GS1's own example: 6291041500213
        #expect(GTIN.isValid("6291041500213"))
        #expect(!GTIN.isValid("6291041500214"))
        #expect(GTIN.isValid("96385074"))  // GTIN-8
        #expect(!GTIN.isValid("12345"))
        #expect(GTIN.isValid(fakeEAN(42)))
    }

    @Test("A case GTIN-14 from a unit EAN-13 and an indicator digit")
    func caseCode() throws {
        let unit = fakeEAN(7)
        let carton = try #require(GTIN.caseGTIN(fromUnit: unit, indicator: 1))
        #expect(carton.count == 14 && carton.hasPrefix("1" + unit.dropLast()))
        #expect(GTIN.isValid(carton))
        #expect(GTIN.caseGTIN(fromUnit: carton, indicator: 1) == nil)
        #expect(GTIN.caseGTIN(fromUnit: unit, indicator: 9) == nil)
    }

    @Test("Codes compare as GTIN-14")
    func matchKeys() {
        #expect(GTIN.matchKey("0" + fakeEAN(3)) == GTIN.matchKey(fakeEAN(3)))
        #expect(GTIN.matchKey("012345678905") == "00012345678905")
        #expect(GTIN.matchKey("AB-12 c") == "ab12c")
    }
}

@Suite("Timestamps")
struct DBTimeTests {
    @Test("Text round trip is exact after rounding to the millisecond")
    func roundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let date = Date(timeIntervalSince1970: Double.random(in: -2_000_000_000...4_000_000_000, using: &generator))
            let normalized = DBTime.normalize(date)
            let text = DBTime.text(normalized)
            #expect(DBTime.date(text) == normalized, "\(text)")
            #expect(DBTime.text(try #require(DBTime.date(text))) == text)
        }
    }

    @Test("The format is GRDB's UTC text")
    func format() {
        #expect(DBTime.text(TestClock.start) == "2026-10-02 12:00:00.000")
        #expect(DBTime.text(Date(timeIntervalSince1970: -0.001)) == "1969-12-31 23:59:59.999")
        #expect(DBTime.date("2026-10-02T12:00:00.5") == TestClock.start.addingTimeInterval(0.5))
        #expect(DBTime.date("2026-10-02 12:00:00") == TestClock.start)
        #expect(DBTime.date("not a date") == nil)
    }
}
