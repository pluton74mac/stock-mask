import Testing
import StockMaskCounting

@Suite("Hold-to-count (FR-13)")
struct HoldTriggerTests {
    /// Frames at 30 fps from `start` for `seconds`, at a constant speed (degrees per second).
    func frames(from start: Double, seconds: Double, speed: Double, candidate: Bool = true, tracking: Bool = true,
                shift: SIMD2<Double>? = nil) -> [HoldTrigger.Frame] {
        (0..<Int((seconds * 30).rounded())).map {
            HoldTrigger.Frame(timestamp: start + Double($0) / 30, angularSpeed: speed, hasStableCandidate: candidate,
                              trackingNormal: tracking, viewShift: shift)
        }
    }

    /// Feeds frames; returns the timestamps at which the trigger committed.
    func run(_ trigger: inout HoldTrigger, _ frames: [HoldTrigger.Frame]) -> [Double] {
        frames.compactMap { trigger.update($0) == .commit ? $0.timestamp : nil }
    }

    @Test("Commits once the view has been under 10°/s for 0.8 s")
    func commitsAfterHold() {
        var t = HoldTrigger()
        let fired = run(&t, frames(from: 0, seconds: 2, speed: 4))
        #expect(fired.count == 1)
        #expect(abs(fired[0] - 0.8) < 0.02)
    }

    @Test("Progress runs from 0 to 1 over the hold")
    func progress() {
        var t = HoldTrigger()
        var last = -1.0
        for f in frames(from: 0, seconds: 0.7, speed: 4) {
            guard case .holding(let p) = t.update(f) else { Issue.record("expected holding"); return }
            #expect(p >= last)
            last = p
        }
        #expect(last > 0.8 && last < 1)
    }

    @Test("Moving at 10°/s or more never commits, and restarts the hold")
    func fastMotionResets() {
        var t = HoldTrigger()
        #expect(run(&t, frames(from: 0, seconds: 2, speed: 15)).isEmpty)
        var u = HoldTrigger()
        let fired = run(&u, frames(from: 0, seconds: 0.6, speed: 3) + frames(from: 0.6, seconds: 0.3, speed: 25)
                        + frames(from: 0.9, seconds: 1.2, speed: 3))
        #expect(fired.count == 1)
        #expect(fired[0] > 0.9 + 0.75)  // a fresh 0.8 s after the motion, not 0.8 s from the start
    }

    @Test("A single fast frame is filtered out (0.1 s median)")
    func spikeFiltered() {
        var t = HoldTrigger()
        var f = frames(from: 0, seconds: 1.5, speed: 3)
        f[10].angularSpeed = 40
        let fired = run(&t, f)
        #expect(fired.count == 1)
        #expect(abs(fired[0] - 0.8) < 0.02)
    }

    @Test("Waits for a stable candidate, then commits at once")
    func needsCandidate() {
        var t = HoldTrigger()
        let waiting = frames(from: 0, seconds: 1.2, speed: 3, candidate: false)
        #expect(run(&t, waiting).isEmpty)
        #expect(t.update(.init(timestamp: 1.2, angularSpeed: 3, hasStableCandidate: false, trackingNormal: true))
                == .holding(progress: 1))
        #expect(t.update(.init(timestamp: 1.25, angularSpeed: 3, hasStableCandidate: true, trackingNormal: true))
                == .commit)
    }

    @Test("Never commits while tracking is limited; the hold restarts after")
    func trackingLimited() {
        var t = HoldTrigger()
        let fired = run(&t, frames(from: 0, seconds: 0.6, speed: 2) + frames(from: 0.6, seconds: 1, speed: 2, tracking: false)
                        + frames(from: 1.6, seconds: 1, speed: 2))
        #expect(fired.count == 1)
        #expect(fired[0] > 1.6 + 0.75)
    }

    @Test("After a commit, holding still doesn't count the same view again")
    func disarmedAfterCommit() {
        var t = HoldTrigger()
        let fired = run(&t, frames(from: 0, seconds: 4, speed: 0, shift: .zero))
        #expect(fired.count == 1)
        #expect(t.update(.init(timestamp: 4, angularSpeed: 0, hasStableCandidate: true, trackingNormal: true,
                               viewShift: .zero)) == .counted)
    }

    @Test("Re-arms after the view has moved 5° (net), then needs a fresh hold")
    func rearmsAfterMove() {
        var t = HoldTrigger()
        var f = frames(from: 0, seconds: 1, speed: 0, shift: .zero)
        // Move 6° to the side in 0.3 s (20°/s), then hold again.
        f += frames(from: 1, seconds: 0.3, speed: 20, shift: SIMD2(6.0 / 9, 0))
        f += frames(from: 1.3, seconds: 1.5, speed: 1, shift: .zero)
        let fired = run(&t, f)
        #expect(fired.count == 2)
        #expect(fired[1] > 1.3 + 0.75)
    }

    @Test("Jitter back and forth is not a move when shifts are given")
    func jitterIsNotAMove() {
        var t = HoldTrigger()
        var f = frames(from: 0, seconds: 1, speed: 2, shift: .zero)
        for k in 0..<60 {  // 2 s of ±0.3° shakes: 18° travelled, nowhere net
            f.append(.init(timestamp: 1 + Double(k) / 30, angularSpeed: 9, hasStableCandidate: true,
                           trackingNormal: true, viewShift: SIMD2(k % 2 == 0 ? 0.3 : -0.3, 0)))
        }
        #expect(run(&t, f).count == 1)
    }

    @Test("Without shifts, re-arming uses the angle travelled (speed × time)")
    func rearmsByTravel() {
        var t = HoldTrigger()
        let fired = run(&t, frames(from: 0, seconds: 1, speed: 0) + frames(from: 1, seconds: 0.4, speed: 20)
                        + frames(from: 1.4, seconds: 1.2, speed: 0))
        #expect(fired.count == 2)
    }

    @Test("The shutter always commits, and disarms the hold")
    func shutter() {
        var t = HoldTrigger()
        #expect(t.update(.init(timestamp: 0, angularSpeed: 50, hasStableCandidate: false, trackingNormal: true)) == .idle)
        #expect(t.shutter() == .commit)
        #expect(!t.isArmed)
        #expect(run(&t, frames(from: 0.1, seconds: 2, speed: 0, shift: .zero)).isEmpty)
    }

    @Test("Auto-count off: holds never commit, the shutter still does")
    func autoCountOff() {
        var t = HoldTrigger()
        t.isAutoCountEnabled = false
        #expect(run(&t, frames(from: 0, seconds: 2, speed: 0)).isEmpty)
        #expect(t.shutter() == .commit)
    }
}
