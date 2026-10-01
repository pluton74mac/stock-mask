// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockMaskCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StockMaskCore", targets: ["StockMaskCore"]),
    ],
    dependencies: [
        // ADR 005: SQLite through GRDB 7 (MIT). Pinned to one release.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "StockMaskCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Test helper, not a product: writes commits until CrashTests kills it with SIGKILL.
        .executableTarget(
            name: "CrashProbe",
            dependencies: ["StockMaskCore"]
        ),
        .testTarget(
            name: "StockMaskCoreTests",
            dependencies: ["StockMaskCore", .target(name: "CrashProbe", condition: .when(platforms: [.macOS]))]
        ),
    ],
    swiftLanguageModes: [.v6]
)
