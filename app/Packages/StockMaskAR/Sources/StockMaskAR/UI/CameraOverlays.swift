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

/// The shutter, with the hold ring around it (FR-13).
public struct ShutterButton: View {
    let hold: HoldState
    let disabled: Bool
    let action: () -> Void

    public init(hold: HoldState, disabled: Bool, action: @escaping () -> Void) {
        self.hold = hold
        self.disabled = disabled
        self.action = action
    }

    var progress: Double {
        switch hold {
        case .idle: 0
        case .holding(let p): p
        case .counted: 1
        }
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(disabled ? 0.35 : 0.95)).frame(width: 64, height: 64)
                Circle().stroke(.white.opacity(0.4), lineWidth: 5).frame(width: 80, height: 80)
                Circle().trim(from: 0, to: progress)
                    .stroke(hold == .counted ? Color.green : Color.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 80, height: 80)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Count this view")
    }
}

/// Thumb-reach controls (FR-11): list (badge "units · products"), shutter, undo.
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
            // Without a detector a commit would only mark an empty counted zone: keep the shutter off.
            ShutterButton(hold: session.hold, disabled: session.isPaused || session.isCommitting || session.detector == nil) {
                session.shutter()
            }
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
        }
    }
}
