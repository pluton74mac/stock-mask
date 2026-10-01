#!/bin/sh
# Type-check StockMaskAR's iOS-only code (#if os(iOS): ARKit, RealityKit's ARView, UIKit) without
# Xcode, by compiling for Mac Catalyst: the macOS SDK carries the iOS frameworks for it, and
# os(iOS) is true there. It only type-checks; it builds nothing. Errors about APIs "unavailable in
# Mac Catalyst" are not errors on iOS. The real check is an iOS build in Xcode.
#     app/scripts/typecheck-ios.sh
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${TMPDIR:-/tmp}/stockmask-catalyst"
target="arm64-apple-ios18.0-macabi"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$out"
# The Mac Catalyst copies of UIKit, ARKit and RealityKit live under iOSSupport; name them explicitly.
ios="$sdk/System/iOSSupport"
flags="-target $target -sdk $sdk -Fsystem $ios/System/Library/Frameworks -I $ios/usr/lib/swift -swift-version 6"
flags="$flags -parse-as-library -I $out"

swiftc $flags -emit-module -module-name StockMaskCounting -emit-module-path "$out/StockMaskCounting.swiftmodule" \
    "$here"/Packages/StockMaskCounting/Sources/StockMaskCounting/*.swift
core="$here/Packages/StockMaskCore/Sources/StockMaskCore"
[ -d "$core" ] || core="$here/Packages/StockMaskAR/Shims/StockMaskCore/Sources/StockMaskCore"
swiftc $flags -emit-module -module-name StockMaskCore -emit-module-path "$out/StockMaskCore.swiftmodule" "$core"/*.swift
swiftc $flags -typecheck -module-name StockMaskAR $(find "$here/Packages/StockMaskAR/Sources" -name '*.swift')
echo "StockMaskAR type-checks for $target (iOS-only code included)"
