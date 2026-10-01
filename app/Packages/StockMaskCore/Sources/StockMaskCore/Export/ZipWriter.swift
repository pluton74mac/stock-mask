import Foundation

/// CRC-32 (IEEE 802.3, the one ZIP uses).
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A ZIP archive with stored (uncompressed) entries: enough for an Office Open XML package.
/// No Zip64: entries and the archive must stay under 4 GB, which a stock sheet always does.
struct ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// `modified` is written as the entries' local time in `timeZone` (ZIP has no time zone).
    init(modified: Date, timeZone: TimeZone) {
        let c = ExportFormat.components(modified, timeZone)
        let year = max(1980, min(2107, c.year ?? 1980))
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let entry = Entry(name: nameBytes, crc: CRC32.checksum(data), size: UInt32(data.count), offset: UInt32(output.count))
        output.append(le32: 0x0403_4B50)  // local file header
        output.append(le16: 20)  // version needed: 2.0
        output.append(le16: 0x0800)  // flags: names are UTF-8
        output.append(le16: 0)  // method: stored
        output.append(le16: dosTime)
        output.append(le16: dosDate)
        output.append(le32: entry.crc)
        output.append(le32: entry.size)  // compressed size
        output.append(le32: entry.size)  // uncompressed size
        output.append(le16: UInt16(nameBytes.count))
        output.append(le16: 0)  // extra field length
        output.append(contentsOf: nameBytes)
        output.append(data)
        entries.append(entry)
    }

    func finish() -> Data {
        var out = output
        let directoryOffset = UInt32(out.count)
        for e in entries {
            out.append(le32: 0x0201_4B50)  // central directory header
            out.append(le16: 20)  // version made by: 2.0, MS-DOS attributes
            out.append(le16: 20)  // version needed
            out.append(le16: 0x0800)
            out.append(le16: 0)
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: e.crc)
            out.append(le32: e.size)
            out.append(le32: e.size)
            out.append(le16: UInt16(e.name.count))
            out.append(le16: 0)  // extra
            out.append(le16: 0)  // comment
            out.append(le16: 0)  // disk number
            out.append(le16: 0)  // internal attributes
            out.append(le32: 0)  // external attributes
            out.append(le32: e.offset)
            out.append(contentsOf: e.name)
        }
        let directorySize = UInt32(out.count) - directoryOffset
        out.append(le32: 0x0605_4B50)  // end of central directory
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: directorySize)
        out.append(le32: directoryOffset)
        out.append(le16: 0)  // comment length
        return out
    }
}

extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
