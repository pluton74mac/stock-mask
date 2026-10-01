import Foundation

public enum DeviceInfo {
    /// The hardware model identifier, e.g. "iPhone14,2" (iPhone 13 Pro); "arm64" on a Mac. Capture
    /// manifests record it so P0-3/P0-9 numbers can be tied to a device. Never a location.
    public static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
