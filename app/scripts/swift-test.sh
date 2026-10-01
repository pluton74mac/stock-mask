#!/bin/sh
# Run a Swift package's tests: ./app/scripts/swift-test.sh app/Packages/StockMaskCore [extra swift test args]
# Works with Xcode, or with the Command Line Tools alone (they ship Swift Testing, but swift test
# needs its framework path spelled out).
set -e
pkg="${1:?usage: swift-test.sh PACKAGE_DIR [args]}"; shift
cd "$pkg"
dev="$(xcode-select -p)"
case "$dev" in
  *CommandLineTools*)
    F="$dev/Library/Developer/Frameworks"; L="$dev/Library/Developer/usr/lib"
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
      -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@" ;;
  *) exec swift test "$@" ;;
esac
