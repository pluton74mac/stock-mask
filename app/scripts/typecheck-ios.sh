#!/bin/sh
# Compile StockMaskAR, iOS-only code included (#if os(iOS): ARKit, RealityKit's ARView, UIKit),
# without Xcode, by building for Mac Catalyst: the macOS SDK carries the iOS frameworks for it,
# and os(iOS) is true there. It compiles the package and its dependencies (StockMaskCounting,
# StockMaskCore, GRDB); it doesn't link or run an app. APIs "unavailable in Mac Catalyst" would be
# false alarms for iOS. The real check is an iOS build in Xcode.
#     app/scripts/typecheck-ios.sh
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
ios="$sdk/System/iOSSupport"
cd "$here/Packages/StockMaskAR"
# The Mac Catalyst copies of UIKit, ARKit and RealityKit live under iOSSupport; name them explicitly.
# SwiftPM derives each package's target from its own minimum (GRDB: iOS 13, which isn't a valid
# Catalyst version), so the target is forced on every compile.
target="arm64-apple-ios18.0-macabi"
swift build --target StockMaskAR --triple "$target" --sdk "$sdk" \
    --scratch-path "${TMPDIR:-/tmp}/stockmask-catalyst-build" \
    -Xswiftc -target -Xswiftc "$target" -Xcc -target -Xcc "$target" \
    -Xswiftc -Fsystem -Xswiftc "$ios/System/Library/Frameworks" -Xswiftc -I -Xswiftc "$ios/usr/lib/swift" \
    -Xcc -iframework -Xcc "$ios/System/Library/Frameworks" "$@"
echo "StockMaskAR compiles for $target (iOS-only code included)"

# The thin app target's sources, against that build (GRDB's SQLite module map comes along).
build="${TMPDIR:-/tmp}/stockmask-catalyst-build"
swiftc -typecheck -parse-as-library -target "$target" -sdk "$sdk" -swift-version 6 -I "$build/arm64-apple-ios-macabi/debug/Modules" \
    -Xcc -fmodule-map-file="$build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap" \
    -Fsystem "$ios/System/Library/Frameworks" -I "$ios/usr/lib/swift" "$here"/StockMask/*.swift
echo "app/StockMask type-checks against it"
