import Foundation
import GRDB

/// A product field a spreadsheet column can map to (FR-4).
public enum CatalogField: String, CaseIterable, Sendable {
    case code
    case name
    case brand
    case category
    case sizeML = "size_ml"
    case unitsPerCase = "units_per_case"
    case unitBarcode = "unit_barcode"
    case caseGTIN = "case_gtin"
}

/// Which column (0-based) holds which field.
public struct ColumnMapping: Equatable, Sendable {
    public var columns: [CatalogField: Int]

    public init(_ columns: [CatalogField: Int] = [:]) {
        self.columns = columns
    }

    public subscript(field: CatalogField) -> Int? {
        get { columns[field] }
        set { columns[field] = newValue }
    }

    /// A first guess from the header names, in Spanish or English ("Código de barras",
    /// "U. x caja", "Marca", "EAN", "DUN-14"…). The user can change it before importing.
    public static func suggested(for header: [String]) -> ColumnMapping {
        var candidates: [(score: Int, column: Int, field: CatalogField)] = []
        for (column, name) in header.enumerated() {
            let h = Text.fold(name)
            guard !h.isEmpty else { continue }
            for (field, synonyms) in Self.synonyms {
                var best = 0
                for s in synonyms {
                    if h == s {
                        best = max(best, 1000 + s.count)
                    } else if " \(h) ".contains(" \(s) ") {
                        best = max(best, s.count)
                    }
                }
                if best > 0 { candidates.append((best, column, field)) }
            }
        }
        var mapping = ColumnMapping()
        var usedColumns = Set<Int>()
        for c in candidates.sorted(by: { ($0.score, -$0.column) > ($1.score, -$1.column) })
        where mapping[c.field] == nil && !usedColumns.contains(c.column) {
            mapping[c.field] = c.column
            usedColumns.insert(c.column)
        }
        return mapping
    }

    /// Folded header names (lowercase, no accents, punctuation as spaces).
    static let synonyms: [CatalogField: [String]] = [
        .code: ["codigo", "cod", "code", "sku", "codigo interno", "cod interno", "codigo producto", "cod producto",
                "product code", "item code", "plu", "id"],
        .name: ["nombre", "producto", "descripcion", "detalle", "articulo", "name", "product", "description",
                "item", "nombre producto", "product name", "item name"],
        .brand: ["marca", "brand", "bodega", "fabricante", "manufacturer"],
        .category: ["categoria", "rubro", "subrubro", "familia", "tipo", "grupo", "clase", "category", "type"],
        .sizeML: ["tamano", "ml", "cc", "contenido", "volumen", "capacidad", "presentacion", "medida", "litros",
                  "lts", "size", "volume", "tamano ml", "size ml", "contenido ml", "capacidad ml"],
        .unitsPerCase: ["unidades por caja", "u x caja", "uxcaja", "u caja", "unid caja", "unidades caja",
                        "unidades x caja", "cantidad por caja", "x caja", "unidades por bulto", "u x bulto", "bulto",
                        "pack", "units per case", "case size", "case qty", "units case"],
        .unitBarcode: ["ean", "ean13", "ean 13", "codigo de barras", "codigo de barra", "cod barras",
                       "cod de barras", "codigo barras", "barras", "barcode", "upc", "gtin", "ean unidad",
                       "gtin unidad", "unit barcode"],
        .caseGTIN: ["dun", "dun14", "dun 14", "ean caja", "gtin caja", "ean bulto", "codigo de barras caja",
                    "cod barras caja", "case gtin", "gtin 14", "gtin14", "itf", "itf14", "itf 14", "case barcode",
                    "barcode case"],
    ]
}

/// Something wrong with one cell of a row. The row can still be imported unless it has no name.
public enum ImportIssue: Equatable, Sendable {
    case missingName
    case invalidSize(String)
    case invalidUnitsPerCase(String)
    /// Excel already turned the code into a number like 7,79123E+12: the digits are lost.
    case scientificNotation(CatalogField, String)
    /// All digits with a GTIN length, but the check digit is wrong. The code is kept.
    case badCheckDigit(CatalogField, String)
}

/// How a row repeats another product.
public enum DuplicateKey: String, Sendable {
    case code
    case unitBarcode = "unit_barcode"
    case caseGTIN = "case_gtin"
    /// Same brand, name and size, and no codes that tell them apart.
    case nameAndSize = "name_and_size"
}

public struct Duplicate: Equatable, Sendable {
    public enum Of: Equatable, Sendable {
        /// An earlier row of the file (its spreadsheet row number).
        case row(Int)
        /// A product already in the catalog.
        case sku(UUID)
    }

    public var key: DuplicateKey
    public var of: Of
}

public enum ImportAction: Equatable, Sendable {
    case create
    case skip
    /// Overwrite this catalog product with the row's fields.
    case update(UUID)
}

public struct CatalogImportRow: Equatable, Sendable {
    /// The spreadsheet row number (header = 1).
    public var rowNumber: Int
    /// Nil when the row can't be imported (no name).
    public var fields: SKUFields?
    public var issues: [ImportIssue]
    public var duplicates: [Duplicate]
    /// Defaults: create; skip rows without a name and flagged duplicates. The user can change it.
    public var action: ImportAction

    public var isFlagged: Bool { !issues.isEmpty || !duplicates.isEmpty }
}

/// What an import would do, for the user to check before applying it.
public struct CatalogImportPlan: Equatable, Sendable {
    public var venueID: UUID
    public var header: [String]
    public var mapping: ColumnMapping
    public var rows: [CatalogImportRow]

    public var flaggedRows: [CatalogImportRow] { rows.filter(\.isFlagged) }
    public var duplicateRows: [CatalogImportRow] { rows.filter { !$0.duplicates.isEmpty } }
    public var createCount: Int { rows.filter { $0.action == .create }.count }
    public var skipCount: Int { rows.filter { $0.action == .skip }.count }
    public var updateCount: Int { rows.filter { if case .update = $0.action { true } else { false } }.count }
}

public struct CatalogImportResult: Equatable, Sendable {
    public var created: [SKU]
    public var updated: [SKU]
    public var skipped: Int
}

public enum CatalogImport {
    /// Reads the rows with the mapping and flags duplicates within the file and against the catalog.
    public static func plan(table: CSVTable, mapping: ColumnMapping, venueID: UUID, existing: [SKU]) -> CatalogImportPlan {
        var catalogKeys: [DuplicateKey: [String: SKU]] = [:]
        for sku in existing {
            for (key, value) in keys(sku.fields) where catalogKeys[key]?[value] == nil {
                catalogKeys[key, default: [:]][value] = sku
            }
        }
        var fileKeys: [DuplicateKey: [String: (row: Int, fields: SKUFields)]] = [:]
        var rows: [CatalogImportRow] = []

        for (index, cells) in table.rows.enumerated() {
            let number = table.rowNumbers[index]
            let (fields, parseIssues) = parseRow(cells, mapping)
            var issues = parseIssues
            var duplicates: [Duplicate] = []
            if let f = fields {
                for (key, value) in keys(f) {
                    if let sku = catalogKeys[key]?[value], !codesDiffer(key, f, sku.fields) {
                        duplicates.append(Duplicate(key: key, of: .sku(sku.id)))
                    }
                    if let earlier = fileKeys[key]?[value], !codesDiffer(key, f, earlier.fields) {
                        duplicates.append(Duplicate(key: key, of: .row(earlier.row)))
                    } else if fileKeys[key]?[value] == nil {
                        fileKeys[key, default: [:]][value] = (number, f)
                    }
                }
            } else {
                issues.insert(.missingName, at: 0)
            }
            let action: ImportAction = (fields == nil || !duplicates.isEmpty) ? .skip : .create
            rows.append(CatalogImportRow(rowNumber: number, fields: fields, issues: issues, duplicates: duplicates, action: action))
        }
        return CatalogImportPlan(venueID: venueID, header: table.header, mapping: mapping, rows: rows)
    }

    /// The duplicate keys of a product: its codes, and brand + name + size.
    static func keys(_ f: SKUFields) -> [(DuplicateKey, String)] {
        var keys: [(DuplicateKey, String)] = []
        if let c = f.code { keys.append((.code, GTIN.matchKey(c))) }
        if let b = f.unitBarcode { keys.append((.unitBarcode, GTIN.matchKey(b))) }
        if let g = f.caseGTIN { keys.append((.caseGTIN, GTIN.matchKey(g))) }
        let name = Text.fold(f.name)
        if !name.isEmpty {
            keys.append((.nameAndSize, "\(Text.fold(f.brand ?? ""))|\(name)|\(f.sizeML.map(String.init) ?? "")"))
        }
        return keys
    }

    /// Same brand, name and size is no duplicate when both have codes and the codes differ.
    static func codesDiffer(_ key: DuplicateKey, _ a: SKUFields, _ b: SKUFields) -> Bool {
        guard key == .nameAndSize else { return false }
        func differ(_ x: String?, _ y: String?) -> Bool {
            guard let x, let y else { return false }
            return GTIN.matchKey(x) != GTIN.matchKey(y)
        }
        return differ(a.code, b.code) || differ(a.unitBarcode, b.unitBarcode) || differ(a.caseGTIN, b.caseGTIN)
    }

    static func parseRow(_ cells: [String], _ mapping: ColumnMapping) -> (SKUFields?, [ImportIssue]) {
        func cell(_ field: CatalogField) -> String? {
            guard let column = mapping[field], column < cells.count else { return nil }
            let value = cells[column].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        var issues: [ImportIssue] = []
        var sizeML: Int?
        if let raw = cell(.sizeML) {
            if let ml = parseSizeML(raw) { sizeML = ml } else { issues.append(.invalidSize(raw)) }
        }
        var unitsPerCase: Int?
        if let raw = cell(.unitsPerCase) {
            if let n = parseUnitsPerCase(raw) { unitsPerCase = n == 0 ? nil : n } else { issues.append(.invalidUnitsPerCase(raw)) }
        }
        func code(_ field: CatalogField) -> String? {
            guard let raw = cell(field) else { return nil }
            if isScientific(raw) {
                issues.append(.scientificNotation(field, raw))
                return nil
            }
            let c = GTIN.stripSeparators(raw)
            if field != .code, GTIN.isDigits(c), GTIN.lengths.contains(c.count), !GTIN.isValid(c) {
                issues.append(.badCheckDigit(field, c))
            }
            return field == .code ? raw : c
        }
        let codeValue = code(.code)
        let unit = code(.unitBarcode)
        let caseCode = code(.caseGTIN)
        guard let name = cell(.name) else { return (nil, issues) }
        let fields = SKUFields(
            code: codeValue, name: name, brand: cell(.brand), category: cell(.category), sizeML: sizeML,
            unitsPerCase: unitsPerCase, unitBarcode: unit, caseGTIN: caseCode)
        return (fields, issues)
    }

    /// "750", "750 ml", "750cc", "75 cl", "1 L", "1,5 lts", "0.75" → millilitres.
    /// A number without a unit is litres when it has decimals or is at most 10, else millilitres.
    /// "1.000 ml" is a thousands separator (1000 ml). Nil when unreadable or not 1 ml – 100 L.
    public static func parseSizeML(_ raw: String) -> Int? {
        let t = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let numberPart = t.prefix { $0.isNumber || $0 == "." || $0 == "," }
        let unit = String(t.dropFirst(numberPart.count).filter { $0.isLetter || $0.isNumber })
        guard !numberPart.isEmpty else { return nil }
        let pieces = numberPart.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," })
        guard pieces.count <= 2, pieces.allSatisfy({ piece in !piece.isEmpty && piece.allSatisfy { $0.isNumber } }),
            let whole = Double(pieces[0])
        else { return nil }
        let fraction = pieces.count == 2 ? String(pieces[1]) : nil
        let factor: Double
        var value = whole
        switch unit {
        case "ml", "cc", "cm3", "mililitros", "mililitro":
            factor = 1
            if let fraction {
                if fraction.count == 3 { value = whole * 1000 + Double(fraction)! } else { value = Double("\(pieces[0]).\(fraction)")! }
            }
        case "cl":
            factor = 10
            if let fraction { value = Double("\(pieces[0]).\(fraction)")! }
        case "l", "lt", "lts", "ltr", "ltrs", "litro", "litros":
            factor = 1000
            if let fraction { value = Double("\(pieces[0]).\(fraction)")! }
        case "":
            if let fraction {
                value = Double("\(pieces[0]).\(fraction)")!
                factor = 1000
            } else {
                factor = whole <= 10 ? 1000 : 1
            }
        default:
            return nil
        }
        let ml = (value * factor).rounded()
        guard ml >= 1, ml <= 100_000 else { return nil }
        return Int(ml)
    }

    /// "12", "x12", "12 u", "caja x 6" → the first whole number (0 means none). Nil if unreadable.
    public static func parseUnitsPerCase(_ raw: String) -> Int? {
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n <= 10_000 else { return nil }
        return n
    }

    static func isScientific(_ raw: String) -> Bool {
        let t = raw.lowercased().replacingOccurrences(of: ",", with: ".")
        guard let e = t.firstIndex(of: "e") else { return false }
        let mantissa = t[..<e], exponent = t[t.index(after: e)...]
        return Double(mantissa) != nil && Int(exponent.replacingOccurrences(of: "+", with: "")) != nil
    }
}

extension StockStore {
    /// Reads a CSV export of the venue's stock list and plans the import: mapped rows, issues and
    /// duplicates. Nothing is written. Pass `mapping` to override the guess from the header.
    public func planCatalogImport(venueID: UUID, csv: Data, mapping: ColumnMapping? = nil) throws -> CatalogImportPlan {
        let table = CSVReader.read(csv)
        let existing = try writer.read { db -> [SKU] in
            _ = try Self.requireVenue(db, venueID)
            return try Self.catalog(db, venueID)
        }
        return CatalogImport.plan(
            table: table, mapping: mapping ?? .suggested(for: table.header), venueID: venueID, existing: existing)
    }

    /// Applies a plan in one transaction: creates and updates products as each row's action says.
    @discardableResult
    public func applyCatalogImport(_ plan: CatalogImportPlan) throws -> CatalogImportResult {
        var work: [(row: Int, fields: SKUFields, action: ImportAction)] = []
        for row in plan.rows where row.action != .skip {
            guard let fields = row.fields else { throw StoreError.invalid("Row \(row.rowNumber) has no product name") }
            do {
                work.append((row.rowNumber, try fields.validated(), row.action))
            } catch let StoreError.invalid(message) {
                throw StoreError.invalid("Row \(row.rowNumber): \(message)")
            }
        }
        let now = timestamp()
        return try writer.write { db in
            _ = try Self.requireVenue(db, plan.venueID)
            var created: [SKU] = []
            var updated: [SKU] = []
            for item in work {
                switch item.action {
                case .create:
                    let sku = SKU(id: UUID(), venueID: plan.venueID, fields: item.fields, createdAt: now, updatedAt: now)
                    try sku.insert(db)
                    created.append(sku)
                case let .update(id):
                    var sku = try Self.requireSKU(db, id, venue: plan.venueID)
                    sku.fields = item.fields
                    sku.updatedAt = now
                    try sku.update(db)
                    updated.append(sku)
                case .skip:
                    break
                }
            }
            let skipped = plan.rows.count - work.count
            try Self.log(db, .catalogImported, venue: plan.venueID, at: now, [
                "rows": .int(plan.rows.count), "created": .init(created.map(\.id)), "updated": .init(updated.map(\.id)),
                "skipped": .int(skipped),
                "mapping": .object(Dictionary(uniqueKeysWithValues: plan.mapping.columns.map { ($0.key.rawValue, JSONValue.int($0.value)) })),
            ])
            return CatalogImportResult(created: created, updated: updated, skipped: skipped)
        }
    }
}
