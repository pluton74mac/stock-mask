// swift-tools-version: 6.0
// StockMaskCounting: hold-to-count trigger, inner-frame rule, commit engine (ADR 003 strategy S5),
// bottle/top merge and drift alarm. Pure Swift + simd: no ARKit, no third-party dependencies.
import PackageDescription

let package = Package(
    name: "StockMaskCounting",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StockMaskCounting", targets: ["StockMaskCounting"]),
    ],
    targets: [
        .target(name: "StockMaskCounting"),
        .testTarget(
            name: "StockMaskCountingTests",
            dependencies: ["StockMaskCounting"],
            exclude: ["Fixtures"]  // read from the source tree by SimulationParityTests
        ),
    ],
    swiftLanguageModes: [.v6]
)
