import Foundation

/// A minimal XLSX (Office Open XML) writer: one worksheet, inline strings, a stored ZIP.
///
/// - Text and codes are string cells with the Text number format ("@"), so Excel keeps barcodes
///   and codes as text (leading zeros, no 7,79E+12) even when the user edits the cell.
/// - String cells are never formulas. Text that a spreadsheet could run as a formula is also
///   marked `quotePrefix`, so editing the cell or saving the sheet as CSV can't turn it into one.
/// - Integers and decimals are numbers; dates are real date cells shown as yyyy-mm-dd hh:mm.
enum XLSXWriter {
    // Style indexes into cellXfs (see `styles`).
    private static let styleText = 1
    private static let styleTextQuoted = 2
    private static let styleDate = 3
    private static let styleHeader = 4

    static func workbook(
        sheetName: String, header: [String], rows: [[ExportCell]], columnWidths: [Double], timeZone: TimeZone,
        modified: Date
    ) -> Data {
        var zip = ZipWriter(modified: modified, timeZone: timeZone)
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rootRels.utf8))
        zip.add("xl/workbook.xml", Data(workbookXML(sheetName: sheetName).utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8))
        zip.add("xl/styles.xml", Data(styles.utf8))
        zip.add("xl/worksheets/sheet1.xml", Data(sheetXML(header: header, rows: rows, widths: columnWidths, timeZone: timeZone).utf8))
        return zip.finish()
    }

    // MARK: - Worksheet

    static func sheetXML(header: [String], rows: [[ExportCell]], widths: [Double], timeZone: TimeZone) -> String {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        let lastCell = "\(columnName(max(columnCount, 1) - 1))\(rows.count + 1)"
        xml += #"<dimension ref="A1:\#(lastCell)"/>"#
        xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        xml += #"<sheetFormatPr defaultRowHeight="15"/>"#
        if !widths.isEmpty {
            xml += "<cols>"
            for (i, w) in widths.enumerated() {
                xml += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(w)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        xml += row(1, header.map { ExportCell.text($0) }, header: true, timeZone: timeZone)
        for (i, cells) in rows.enumerated() {
            xml += row(i + 2, cells, header: false, timeZone: timeZone)
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func row(_ number: Int, _ cells: [ExportCell], header: Bool, timeZone: TimeZone) -> String {
        var xml = #"<row r="\#(number)">"#
        for (i, cell) in cells.enumerated() {
            let ref = "\(columnName(i))\(number)"
            switch cell {
            case .empty:
                continue
            case let .text(s), let .code(s):
                let text = String(xmlSafe(s).prefix(32_767))
                guard !text.isEmpty else { continue }
                let style = header ? styleHeader : (FormulaGuard.isRisky(text) ? styleTextQuoted : styleText)
                let space = text.first!.isWhitespace || text.last!.isWhitespace ? #" xml:space="preserve""# : ""
                xml += #"<c r="\#(ref)" s="\#(style)" t="inlineStr"><is><t\#(space)>\#(escape(text))</t></is></c>"#
            case let .integer(n):
                xml += #"<c r="\#(ref)"><v>\#(n)</v></c>"#
            case let .decimal(d):
                guard d.isFinite else { continue }
                xml += #"<c r="\#(ref)"><v>\#(d)</v></c>"#
            case let .date(d):
                xml += #"<c r="\#(ref)" s="\#(styleDate)"><v>\#(serial(d, timeZone))</v></c>"#
            }
        }
        return xml + "</row>"
    }

    /// 0 → "A", 25 → "Z", 26 → "AA".
    static func columnName(_ index: Int) -> String { groupLetters(index + 1) }

    /// Excel's date serial: days since 1899-12-30 in local time, with the time as a fraction.
    static func serial(_ date: Date, _ timeZone: TimeZone) -> Double {
        let c = ExportFormat.components(date, timeZone)
        let days = DBTime.daysFromCivil(Int64(c.year!), Int64(c.month!), Int64(c.day!)) - DBTime.daysFromCivil(1899, 12, 30)
        let seconds = Double(c.hour! * 3600 + c.minute! * 60 + c.second!)
        return Double(days) + seconds / 86_400
    }

    /// Drops characters XML 1.0 forbids (control characters other than tab, LF and CR).
    static func xmlSafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD: true
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
            default: false
            }
        }))
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Package parts

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """

    static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    static func workbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/></sheets>\
        </workbook>
        """
    }

    static let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """

    /// cellXfs: 0 general, 1 text ("@"), 2 text with quotePrefix, 3 date-time, 4 bold header text.
    static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="5">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" quotePrefix="1"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="49" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>\
        </cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
}
