# StockMask: the thin app target

Everything the app does is in the local packages under [`app/Packages`](../Packages):
**StockMaskAR** (camera, detector, overlays, screens), which brings **StockMaskCounting** and
**StockMaskCore** with it. This folder only holds the app target's own files:

| File | What |
|---|---|
| `StockMaskApp.swift` | `@main`: shows `StockMaskRootView` (LiDAR check, start or continue a count, the counting screen) |
| `Info.plist` | The keys Xcode doesn't generate: camera use, `arkit`, portrait only, full screen, file sharing |
| `Assets.xcassets` | App icon and accent colour |
| `README.md` | These steps. Kept out of the app bundle by the project's membership exceptions |

The Xcode project is `app/StockMask.xcodeproj`. These steps get it running on an iPhone.

## 1. Install Xcode

1. Install Xcode 26 or later from the App Store. It needs the iOS 18 SDK or later.
2. Point the command line at it, and accept the licence:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```
3. Check that the packages still pass with Xcode's toolchain:
   ```sh
   app/scripts/swift-test.sh app/Packages/StockMaskAR      # 57 tests
   app/scripts/swift-test.sh app/Packages/StockMaskCounting
   app/scripts/swift-test.sh app/Packages/StockMaskCore
   ```

## 2. Export the detector

The model is about 54 MB, so it is git-ignored and made locally (details in
[`ml/coreml/README.md`](../../ml/coreml/README.md)):

```sh
cd ml/coreml
uv venv --python 3.11 .venv          # or: python3.11 -m venv .venv
uv pip install --python .venv/bin/python torch==2.7.0 torchvision==0.22.0 \
    coremltools==9.0 rfdetr==1.11.0 "numpy<=2.3.5" opencv-python-headless==5.0.0.93 pillow
.venv/bin/python export_detector.py        # writes ml/coreml/out/StockMaskDetector.mlpackage
```

## 3. The project

`app/StockMask.xcodeproj` is in the repository (created 3 October 2026, Xcode 27). It holds:
- the app target, iOS 18, portrait only;
- `Info.plist` merged into the generated one;
- `app/Packages/StockMaskAR` as a local package, which brings StockMaskCounting and StockMaskCore with it;
- GRDB 7.11.1, fetched from GitHub on the first build;
- a reference to the git-ignored `ml/coreml/out/StockMaskDetector.mlpackage`. Export it first (step 2), or the build fails on the missing file.

It builds from the command line without signing:

```sh
xcodebuild -project app/StockMask.xcodeproj -scheme StockMask -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build
```

**Signing.** Signing is automatic, with no team stored in the repository.
1. In Xcode, select the StockMask target → **Signing & Capabilities** → **Team**.
2. Choose your Apple ID's team; a free personal team is enough for your own iPhone.
3. If Xcode says the bundle id `com.pluton74mac.stockmask` is taken, change it to something unique.

To try another model without rebuilding (e.g. a fine-tuned one), copy its `.mlpackage` into the app's
**Documents/Models** folder: Finder → the iPhone → Files → StockMask. The newest one there wins, and
it is compiled on the phone at the next start. Without any model the app still runs, and the HUD says
the detector is missing.

## 4. Run it

1. Plug in a LiDAR iPhone (12 Pro or a later Pro model; ADR 001) and choose it as the run
   destination.
2. **Product → Run**. On the first run, trust the developer certificate on the phone: Settings →
   General → VPN & Device Management.
3. Start a count, hold the phone still on a shelf for about a second, and check:
   - yellow outlines, then green shapes, a `+N` and the card;
   - the gauge button (top right) opens the HUD: tracking, FPS, detector ms, thermal, battery,
     and the capture switch.

## 5. After the first device run

- Run `app/scripts/typecheck-ios.sh` once more to make sure nothing drifted. It compiled the
  iOS-only code for Mac Catalyst before Xcode was here. Read the iOS build's warnings too.
- Things only the phone can show are listed in
  [StockMaskAR's README](../Packages/StockMaskAR/README.md#not-run-yet). Check them first.
- Phase 0 measurements this build supports: P0-3 (the HUD's detector p50/p95, GPU against Neural
  Engine), P0-4 (capture walks, then `research/capture_replay`), P0-9 (the torch button during AR).
