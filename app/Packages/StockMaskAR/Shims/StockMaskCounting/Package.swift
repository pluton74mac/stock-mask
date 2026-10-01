// swift-tools-version: 6.0
// SHIM: remove at integration.
// A minimal stand-in for app/Packages/StockMaskCounting, which is written on another branch
// (claude/app-counting). It has the contract's names from docs/mvp-test-app.md so StockMaskAR
// compiles and its tests run before the real package is merged. At integration, point
// StockMaskAR's Package.swift at "../StockMaskCounting" and delete the Shims folder.
import PackageDescription

let package = Package(
    name: "StockMaskCounting",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "StockMaskCounting", targets: ["StockMaskCounting"])],
    targets: [.target(name: "StockMaskCounting")]
)
