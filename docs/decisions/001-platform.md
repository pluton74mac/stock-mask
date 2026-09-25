# ADR 001: Platform and AR stack

Status: **Accepted** · 2026-09-25

## Decision

- **Native iOS app:**
  - Swift 6 and SwiftUI;
  - ARKit world tracking with LiDAR scene depth;
  - RealityKit `ARView` for overlays;
  - Vision and Core ML for inference.
- **Minimum iOS 18.** Every LiDAR device can run it.
- **LiDAR devices only for the MVP:** iPhone 12 Pro through 18 Pro (Pro and Pro Max), and iPad Pro 2020 or later.
  - Excluded: the standard iPhone 17, 17e, Air and Duo, and every non-Pro iPad.
- **Pilot venues get a phone from us:** a used iPhone 12, 13 or 14 Pro, set up and locked to StockMask.
- **Android comes after the pilot proves value,** as a separate native Kotlin app using ARCore. The
  double-count design (ADR 003) already works with printed rack tags, which is the part that
  carries over to ARCore.

## Options compared

| | Native Swift (chosen) | Unity AR Foundation 6.2 + Sentis | Flutter | React Native (ViroReact 3) | Kotlin Multiplatform |
|---|---|---|---|---|---|
| LiDAR depth and scene mesh | Full | Depth yes; meshing iOS-only | `arkit_plugin` only (iOS, SceneKit-based) | LiDAR and mesh supported | Native |
| Save / restore the room map (ARWorldMap) | Yes | "ARKit-specific" wrapper | Not documented | Not documented | Native |
| Core ML on the Neural Engine | Yes | **No.** Sentis runs ONNX on CPU/GPU; Core ML is not mentioned | LiteRT's Core ML delegate is experimental | You write a native module | Native |
| Cost of the later Android port | Rewrite UI, AR and ML in Kotlin | Shared AR code, but the same map and meshing gaps; Unity Pro is $2,310 per seat per year above $200k revenue | Serious AR/ML ends up as native views embedded in Flutter anyway | JS UI shared; AR/ML native per platform | Logic and DB shared; Swift export still Alpha |
| Fit for "simple is king" | One language and toolchain; Apple samples map 1:1 to our pipeline | A game engine inside a list-and-camera app | Plugin risk exactly where the product is hard | Same | Adds a build system for little gain in a one-platform MVP |

The hard parts of this product are all Apple-native: frame-accurate ARKit poses, `sceneDepth`,
world-map persistence, and Core ML on the Neural Engine. Every cross-platform layer either lacks
one of these or wraps it with extra risk. The shared UI they would give us is the easy part.

## Why LiDAR-only

| Need | With LiDAR | Without LiDAR |
|---|---|---|
| Place a detected bottle in 3D to within a few cm | `sceneDepth` at 256×192, 60 Hz, about ±1 cm on matte objects over 10 cm ([Luetzenburg 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8593014/)) | Raycasts to estimated planes, or a monocular depth net (Depth Anything V2 S, about 26 ms) that needs metric-scale alignment |
| Stay registered when returning to a shelf | LiDAR iPhone Pro: revisit error ≤ 1.5 cm at marker revisits ([MobileEgo 2026](https://arxiv.org/abs/2605.05945)) | iPhone 11, ARKit 4: walk about 7 m away and back gave **25 cm** mean drift; a larger study gave 43 cm ([Scargill 2021](https://arxiv.org/abs/2109.14757)) |
| Occlusion of overlays; mesh for coverage | Scene reconstruction | Not available |

Our double-count logic tolerates about 5 cm of revisit error (ADR 003). Non-LiDAR phones
are five to eight times beyond that.

## Consequences

- **Market fit is a real cost.**
  - Argentina is 82–88% Android (StatCounter, 2025 to Aug 2026). iOS was 17.9% in Aug 2026,
    rising after the phone import tariff went to 0% in January 2026. Only Pro iPhones have LiDAR.
  - For the pilot we remove the problem by providing the device, which also standardises the
    hardware we validate on.
  - For scale, see open question Q1 in the PRD: which market first, or an Android port.
- **Rendering:**
  - Use RealityKit `ARView`, which exposes the `ARSession` and every `ARFrame`.
  - Do not use SceneKit / `ARSCNView`: deprecated in iOS 26, maintenance-only.
  - Do not use SwiftUI `RealityView` camera mode yet: developers report missing `ARFrame` access.
    Revisit it after the MVP.
- **ML runtime:** Core ML with `.cpuAndNeuralEngine`, so the GPU stays free for rendering. One
  frame in flight. Never retain `ARFrame`s, because the camera's buffer pool is finite.
- **Apple Core AI (`.aimodel`, iOS 27+):** available in both detector toolchains. It is still
  young, and our iOS 18 floor rules it out for the MVP.
- **Relocalization:** implement `sessionShouldAttemptRelocalization` → `true`. Otherwise ARKit
  resets the world origin a few seconds after tracking is lost, and every anchor is invalidated.
