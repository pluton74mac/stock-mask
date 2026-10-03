import SwiftUI
import StockMaskCounting

// The 2D layer over the camera (PRD §9): yellow outlines, the inner frame, banners, the +N toast,
// the undo snackbar and the thumb-reach controls. Cross-platform SwiftUI: built and previewed on a
// Mac, used over the ARView on the phone.

/// Yellow outlines: thin = candidate, dashed = low confidence (FR-18), bold = stable; and the
/// inner frame (FR-14) as a dashed white rectangle.
public struct DetectionBoxesView: View {
    let boxes: [BoxOverlay]
    let innerFrame: SIMD4<Float>
    let mapping: DisplayMapping?

    public init(boxes: [BoxOverlay], innerFrame: SIMD4<Float>, mapping: DisplayMapping?) {
        self.boxes = boxes
        self.innerFrame = innerFrame
        self.mapping = mapping
    }

    public var body: some View {
        Canvas { ctx, size in
            guard let mapping else { return }
            ctx.stroke(Path(mapping.rect(innerFrame, in: size)), with: .color(.white.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [10, 7]))
            for b in boxes {
                let path = Path(roundedRect: mapping.rect(b.box, in: size), cornerRadius: 4)
                switch b.style {
                case .lowConfidence:
                    ctx.stroke(path, with: .color(.yellow.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                case .candidate:
                    ctx.stroke(path, with: .color(.yellow), lineWidth: 1.5)
                case .stable:
                    ctx.stroke(path, with: .color(.yellow), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A full-width message at the top: red for the drift alarm (FR-23), dark for other pauses (FR-20).
public struct BannerView: View {
    let text: String
    let alarm: Bool
    let action: (title: String, run: () -> Void)?

    public init(text: String, alarm: Bool = false, action: (title: String, run: () -> Void)? = nil) {
        self.text = text
        self.alarm = alarm
        self.action = action
    }

    public var body: some View {
        HStack {
            Image(systemName: alarm ? "exclamationmark.triangle.fill" : "pause.circle.fill")
            Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action.title, action: action.run).buttonStyle(.bordered).tint(.white) }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(alarm ? Color.red.opacity(0.9) : Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The `+14` toast (FR-15): one per commit.
public struct ToastView: View {
    let toast: Toast
    let onDone: (UUID) -> Void

    public init(toast: Toast, onDone: @escaping (UUID) -> Void) {
        self.toast = toast
        self.onDone = onDone
    }

    public var body: some View {
        Text(toast.text)
            .font(toast.text.hasPrefix("+") ? .system(size: 44, weight: .bold, design: .rounded) : .headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color.green.opacity(toast.text.hasPrefix("+") ? 0.85 : 0), in: Capsule())
            .background(.black.opacity(0.6), in: Capsule())
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(1.5))
                onDone(toast.id)
            }
    }
}

/// The hold ring (FR-13): counting is automatic, so this only shows how far a hold has got
/// (yellow), and turns green when the view is counted. Not a button: there is no shutter (the
/// owner's decision of 2 October; the debug panel keeps a "count now" for testing).
public struct HoldRing: View {
    let hold: HoldState
    let paused: Bool

    public init(hold: HoldState, paused: Bool) {
        self.hold = hold
        self.paused = paused
    }

    var progress: Double {
        switch hold {
        case .idle: 0
        case .holding(let p): p
        case .counted: 1
        }
    }

    public var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(paused ? 0.2 : 0.4), lineWidth: 6).frame(width: 72, height: 72)
            Circle().trim(from: 0, to: progress)
                .stroke(hold == .counted ? Color.green : Color.yellow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 72, height: 72)
            Image(systemName: hold == .counted ? "checkmark" : "hand.raised")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(paused ? 0.4 : 0.9))
        }
        .animation(.linear(duration: 0.1), value: progress)
        .accessibilityLabel(hold == .counted ? "Counted: move on" : "Hold still to count")
    }
}

/// Thumb-reach controls (FR-11): the list (badge "units · products"), the hold ring, undo.
public struct CountingControls: View {
    let session: CountingSession
    let onList: () -> Void

    public init(session: CountingSession, onList: @escaping () -> Void) {
        self.session = session
        self.onList = onList
    }

    public var body: some View {
        HStack(alignment: .center) {
            Button(action: onList) {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle").font(.title2)
                    Text(session.badge).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(width: 96, height: 64)
            }
            Spacer()
            HoldRing(hold: session.hold, paused: session.isPaused || session.detector == nil)
            Spacer()
            Button {
                Task { await session.undo() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.title2)
                    Text("Undo").font(.caption2)
                }
                .frame(width: 96, height: 64)
            }
            .disabled(session.undoDeadline == nil)
            .opacity(session.undoDeadline == nil ? 0.4 : 1)
            .task(id: session.undoDeadline) {
                guard let deadline = session.undoDeadline else { return }
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                session.undoExpired()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 22))
    }
}

extension ObjectClass {
    /// How a class reads on the card and in the list.
    public var displayName: String {
        switch self {
        case .bottle: "bottle"
        case .can: "can"
        case .case: "case"
        case .bottleTop: "bottle (by its top)"
        case .carton: "carton"
        case .bag: "bag"
        }
    }
}
