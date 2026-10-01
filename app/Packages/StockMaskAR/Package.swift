// swift-tools-version: 6.0
// StockMaskAR: the AR session, the detector, 3D lifting, live tracks, overlays, capture mode and the
// SwiftUI screens. Everything that doesn't need ARKit or UIKit builds and is tested on macOS:
//     app/scripts/swift-test.sh app/Packages/StockMaskAR
// The ARKit / UIKit parts are behind `#if os(iOS)` (see README, "Not compiled yet").
import PackageDescription

let package = Package(
    name: "StockMaskAR",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "StockMaskAR", targets: ["StockMaskAR"])],
    dependencies: [
        .package(path: "../StockMaskCounting"),
        .package(path: "../StockMaskCore"),
    ],
    targets: [
        .target(
            name: "StockMaskAR",
            dependencies: [
                .product(name: "StockMaskCounting", package: "StockMaskCounting"),
                .product(name: "StockMaskCore", package: "StockMaskCore"),
            ]
        ),
        .testTarget(name: "StockMaskARTests", dependencies: ["StockMaskAR"]),
    ]
)
