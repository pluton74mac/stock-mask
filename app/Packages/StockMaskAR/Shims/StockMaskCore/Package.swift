// swift-tools-version: 6.0
// SHIM: remove at integration.
// A minimal, in-memory stand-in for app/Packages/StockMaskCore, which is written on another branch
// (claude/app-core) with GRDB persistence and CSV/XLSX export. Record names follow the tables in
// docs/mvp-test-app.md and PRD §11. At integration, point StockMaskAR's Package.swift at
// "../StockMaskCore", rewrite Sources/StockMaskAR/Integration/CoreStockStore.swift against the real
// API, and delete the Shims folder.
import PackageDescription

let package = Package(
    name: "StockMaskCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "StockMaskCore", targets: ["StockMaskCore"])],
    targets: [.target(name: "StockMaskCore")]
)
