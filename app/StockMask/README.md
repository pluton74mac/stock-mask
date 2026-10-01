# StockMask: the thin app target

Everything the app does is in the local packages under [`app/Packages`](../Packages):
**StockMaskAR** (camera, detector, overlays, screens), which brings **StockMaskCounting** and
**StockMaskCore** with it. This folder only holds the app target's own files:

| File | What |
|---|---|
| `StockMaskApp.swift` | `@main`: shows `StockMaskRootView` (LiDAR check, start or continue a count, the counting screen) |
| `Info.plist` | The keys Xcode doesn't generate: camera use, `arkit`, portrait only, file sharing |
| `README.md` | These steps. Not part of the app: untick its target membership (step 4) |

There is no `.xcodeproj` in the repository: it can't be made or checked without Xcode. These steps
create it once Xcode is installed. They take about 15 minutes.

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

## 3. Create the project

1. Xcode → **File → New → Project…** → **iOS** → **App** → Next.
2. Fill in:
   - Product Name: **StockMask**
   - Team: your Apple ID's team (a free personal team is enough to run on your own iPhone)
   - Organization Identifier: e.g. `com.yourname`, so the bundle id is `com.yourname.StockMask`
   - Interface: **SwiftUI**; Language: **Swift**; Testing System: **None**; Storage: **None**
3. Save it **outside the repository**, e.g. in `~/Desktop/scratch`, with "Create Git repository"
   unticked. Xcode makes `~/Desktop/scratch/StockMask/StockMask.xcodeproj` and a source folder
   `~/Desktop/scratch/StockMask/StockMask/`.
4. Quit Xcode. Then move two things into the repository and throw the rest away:
   ```sh
   mv ~/Desktop/scratch/StockMask/StockMask.xcodeproj app/StockMask.xcodeproj
   mv ~/Desktop/scratch/StockMask/StockMask/Assets.xcassets app/StockMask/Assets.xcassets
   rm -rf ~/Desktop/scratch/StockMask     # its ContentView.swift and StockMaskApp.swift are replaced by ours
   ```
   The project refers to its source folder as `StockMask` next to the `.xcodeproj`, so it now
   uses this folder, `app/StockMask/`. If the template also made a `Preview Content` folder, move it
   too, or clear the target's **Development Assets** build setting.

## 4. Set up the target

Open `app/StockMask.xcodeproj` and select the **StockMask** target.

1. **General:**
   - Minimum Deployments: **iOS 18.0**.
   - Supported Destinations: iPhone (keep iPad if you want iPad Pro).
   - Deployment Info: tick **Portrait** only, for iPhone and for iPad.
2. **Build Settings** (All, Combined):
   - **Info.plist File** (`INFOPLIST_FILE`): `StockMask/Info.plist`. Leave **Generate Info.plist
     File** on: Xcode merges our keys into the ones it generates.
   - **Swift Language Version**: Swift 6.
   - **CoreML Model Class Generation Language**: None. The app loads the model by its URL, so the
     generated class would go unused.
3. **Target membership:** in the project navigator, select `README.md` and `Info.plist` in the
   StockMask group, and untick the StockMask target in the File inspector. This keeps them out of
   Copy Bundle Resources. If a build later fails with "Multiple commands produce …/Info.plist",
   this is the step that was missed.

What `Info.plist` adds:

| Key | Value | Why |
|---|---|---|
| `NSCameraUsageDescription` | "StockMask uses the camera and LiDAR to count …" | Camera permission prompt |
| `UIRequiredDeviceCapabilities` | `arkit` | No install on devices without ARKit. There is no LiDAR capability key, so the app checks LiDAR itself at launch (`ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`) and shows "needs LiDAR" otherwise |
| `UISupportedInterfaceOrientations` (and `~ipad`) | portrait | The camera code assumes portrait (`FrameOrientation.right`) |
| `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` | YES | Documents (captures, models to try) show in Finder and in the Files app |
| `UILaunchScreen` | empty | The default launch screen |

## 5. Add the local packages

1. **File → Add Package Dependencies…** → **Add Local…** → choose `app/Packages/StockMaskAR` →
   **Add Package**.
2. In the dialog, add the product **StockMaskAR** to the **StockMask** target.

StockMaskCounting and StockMaskCore come in as StockMaskAR's own local dependencies, and GRDB
(pinned at 7.11.1) is fetched once from GitHub. Don't add them separately.

## 6. Bundle the model

1. Drag `ml/coreml/out/StockMaskDetector.mlpackage` into the StockMask group in Xcode.
2. In the dialog, **untick "Copy items if needed"**, so the project keeps a reference to the
   git-ignored export instead of a 54 MB copy, and tick the **StockMask** target.

Xcode compiles it into `StockMaskDetector.mlmodelc` inside the app, which `DetectorModelLocator`
loads. To try another model without rebuilding (e.g. a fine-tuned one), copy its `.mlpackage` into
the app's **Documents/Models** folder (Finder → the iPhone → Files → StockMask). The newest one
there wins; it is compiled on the phone at the next start. Without any model the app still runs,
and the HUD says the detector is missing.

## 7. Run it

1. Plug in a LiDAR iPhone (12 Pro or a later Pro model; ADR 001) and choose it as the run
   destination.
2. **Product → Run**. On the first run, trust the developer certificate on the phone: Settings →
   General → VPN & Device Management.
3. Start a count, hold the phone still on a shelf for about a second, and check:
   - yellow outlines, then green shapes, a `+N` and the card;
   - the gauge button (top right) opens the HUD: tracking, FPS, detector ms, thermal, battery,
     and the capture switch.

## 8. After the first device run

- Run `app/scripts/typecheck-ios.sh` once more to make sure nothing drifted. It compiled the
  iOS-only code for Mac Catalyst before Xcode was here. Read the iOS build's warnings too.
- Things only the phone can show are listed in
  [StockMaskAR's README](../Packages/StockMaskAR/README.md#not-run-yet). Check them first.
- Phase 0 measurements this build supports: P0-3 (the HUD's detector p50/p95, GPU against Neural
  Engine), P0-4 (capture walks, then `research/capture_replay`), P0-9 (the torch button during AR).
