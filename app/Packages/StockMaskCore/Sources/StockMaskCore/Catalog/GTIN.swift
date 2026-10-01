import Foundation

/// GS1 barcodes: GTIN-8, -12 (UPC-A), -13 (EAN-13) and -14 (the case code, ADR 004).
public enum GTIN {
    static let lengths: Set<Int> = [8, 12, 13, 14]

    /// Removes spaces and hyphens: "779 1234-567893" → "7791234567893".
    public static func stripSeparators(_ code: String) -> String {
        code.filter { !$0.isWhitespace && $0 != "-" }
    }

    static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The GS1 mod-10 check digit for the digits before it, or nil if they aren't all digits.
    public static func checkDigit(for body: String) -> Int? {
        guard isDigits(body) else { return nil }
        var sum = 0
        for (i, ch) in body.reversed().enumerated() {
            let d = Int(ch.asciiValue! - 48)
            sum += i % 2 == 0 ? d * 3 : d
        }
        return (10 - sum % 10) % 10
    }

    /// True when the code is all digits, has a GTIN length and its check digit is right.
    public static func isValid(_ code: String) -> Bool {
        let c = stripSeparators(code)
        guard isDigits(c), lengths.contains(c.count), let check = checkDigit(for: String(c.dropLast())) else {
            return false
        }
        return check == Int(c.last!.asciiValue! - 48)
    }

    /// The case GTIN-14 for a unit GTIN-13 (or 12 or 8): the indicator digit (1–8), the unit code
    /// without its check digit, and a new check digit.
    public static func caseGTIN(fromUnit unit: String, indicator: Int) -> String? {
        let c = stripSeparators(unit)
        guard (1...8).contains(indicator), isValid(c), c.count <= 13 else { return nil }
        let padded = String(repeating: "0", count: 13 - c.count) + c
        let body = "\(indicator)" + padded.dropLast()
        return body + "\(checkDigit(for: body)!)"
    }

    /// Key for comparing codes: GTIN-length digit strings left-padded to 14 digits, other codes
    /// lowercased without separators.
    static func matchKey(_ code: String) -> String {
        let c = stripSeparators(code)
        if isDigits(c), lengths.contains(c.count) { return String(repeating: "0", count: 14 - c.count) + c }
        return c.lowercased()
    }
}
