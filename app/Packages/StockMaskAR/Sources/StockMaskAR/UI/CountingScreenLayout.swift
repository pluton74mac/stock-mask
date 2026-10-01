import SwiftUI

/// The counting screen (PRD §7, FR-11), around any camera view: the ARView on the phone, a
/// placeholder in previews. Camera full screen; yellow outlines on top; banners and the HUD at the
/// top; toast, commit card and thumb-reach controls at the bottom; list, review and naming as sheets.
public struct CountingScreenLayout<Camera: View, HUD: View>: View {
    let session: CountingSession
    let mapping: DisplayMapping?
    let camera: Camera
    let hud: HUD
    let torch: Binding<Bool>?
    @State private var showList = false
    @State private var showReview = false
    @State private var showHUD = false
    @State private var naming: GroupInfo?

    public init(session: CountingSession, mapping: DisplayMapping?, torch: Binding<Bool>? = nil,
                @ViewBuilder camera: () -> Camera, @ViewBuilder hud: () -> HUD) {
        self.session = session
        self.mapping = mapping
        self.torch = torch
        self.camera = camera()
        self.hud = hud()
    }

    public var body: some View {
        ZStack {
            camera.ignoresSafeArea()
            DetectionBoxesView(boxes: session.boxes, innerFrame: session.innerFrame, mapping: mapping).ignoresSafeArea()
            VStack(spacing: 10) {
                if session.driftAlarm {
                    BannerView(text: "Counted shelves look shifted. Point at a shelf you already counted.", alarm: true,
                               action: ("Resume", { session.resumeAfterDrift() }))
                } else if let reason = session.pauseReason {
                    BannerView(text: reason)
                }
                HStack {
                    if let error = session.lastError {
                        Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                    Spacer()
                    if let torch {
                        Button {
                            torch.wrappedValue.toggle()
                        } label: {
                            Image(systemName: torch.wrappedValue ? "flashlight.on.fill" : "flashlight.off.fill")
                                .frame(width: 60, height: 60)
                        }
                        .accessibilityLabel("Torch")
                    }
                    Button {
                        showHUD.toggle()
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.33percent").frame(width: 60, height: 60)
                    }
                    .accessibilityLabel("Debug HUD")
                }
                .foregroundStyle(.white)
                if showHUD { hud }
                Spacer()
                if let toast = session.toast {
                    ToastView(toast: toast) { session.clearToast($0) }
                }
                if let card = session.card {
                    CommitCardView(card: card, onName: { naming = $0 }, onDismiss: { session.dismissCard() })
                }
                CountingControls(session: session) { showList = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showList) {
            LiveListView(session: session) {
                showList = false
                showReview = true
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showReview) { ReviewView(session: session) }
        .sheet(item: $naming) { g in
            ProductPickerView(title: "Name \(g.count) × \(g.cls.displayName)", search: { await session.products(matching: $0) },
                              create: { await session.createProduct($0) }) { product in
                Task { await session.name(group: g, product: product) }
            }
        }
    }
}

/// Shown on iPhones without LiDAR (ADR 001: LiDAR devices only).
public struct UnsupportedDeviceView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward").font(.largeTitle)
            Text("StockMask needs an iPhone or iPad with LiDAR").font(.headline)
            Text("iPhone 12 Pro or later Pro models, or iPad Pro 2020 or later.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
