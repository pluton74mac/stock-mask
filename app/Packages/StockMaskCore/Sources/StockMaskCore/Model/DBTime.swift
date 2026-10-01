import Foundation
import GRDB

/// Timestamps are stored as UTC text, "yyyy-MM-dd HH:mm:ss.SSS" (GRDB's format, readable in any
/// SQLite tool and understood by SQLite's date functions), with whole milliseconds.
///
/// The conversion uses integer arithmetic, and every timestamp is rounded to the millisecond
/// before it is stored, so a value read back is exactly the value written.
enum DBTime {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The date rounded to the millisecond, as it will read back from the database.
    static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds(date)) / 1000)
    }

    static func text(_ date: Date) -> String {
        let ms = milliseconds(date)
        let day = floorDiv(ms, 86_400_000)
        var rest = ms - day * 86_400_000
        let (y, m, d) = civil(fromDays: day)
        let hour = rest / 3_600_000
        rest -= hour * 3_600_000
        let minute = rest / 60_000
        rest -= minute * 60_000
        let second = rest / 1000
        let milli = rest - second * 1000
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2)) \(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(milli, 3))"
    }

    /// Parses "yyyy-MM-dd HH:mm:ss[.SSS]" (a "T" separator is accepted too), in UTC.
    static func date(_ text: String) -> Date? {
        let chars = Array(text.utf8)
        func number(_ from: Int, _ count: Int) -> Int64? {
            guard from + count <= chars.count else { return nil }
            var n: Int64 = 0
            for c in chars[from..<(from + count)] {
                guard c >= 48, c <= 57 else { return nil }
                n = n * 10 + Int64(c - 48)
            }
            return n
        }
        guard chars.count >= 19, chars[4] == 45, chars[7] == 45, chars[10] == 32 || chars[10] == 84,
            chars[13] == 58, chars[16] == 58,
            let y = number(0, 4), let mo = number(5, 2), let d = number(8, 2),
            let h = number(11, 2), let mi = number(14, 2), let s = number(17, 2)
        else { return nil }
        var milli: Int64 = 0
        if chars.count > 20, chars[19] == 46 {
            let digits = min(3, chars.count - 20)
            guard let f = number(20, digits) else { return nil }
            milli = f * Int64([1, 100, 10, 1][digits])
        }
        let days = daysFromCivil(y, mo, d)
        let ms = ((days * 24 + h) * 60 + mi) * 60_000 + s * 1000 + milli
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    // Howard Hinnant's civil-calendar algorithms (proleptic Gregorian).
    static func daysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func pad(_ n: Int64, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

extension Row {
    func time(_ column: String) throws -> Date {
        guard let date = try optionalTime(column) else {
            throw StoreError.invalid("Missing timestamp in column \(column)")
        }
        return date
    }

    func optionalTime(_ column: String) throws -> Date? {
        guard let text: String = try decode(forColumn: column) else { return nil }
        guard let date = DBTime.date(text) else { throw StoreError.invalid("Bad timestamp \(text) in \(column)") }
        return date
    }
}
