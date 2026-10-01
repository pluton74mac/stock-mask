import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import StockMaskAR

@Suite("Screens and keyframes", .serialized)
@MainActor
struct ScreenTests {
    @Test func keyframesAreSavedUpright() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)/Keyframes")
        let store = try KeyframeStore(folder: folder)
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let id = UUID()
        let path = try await store.save(DetectorInput(image: ctx.makeImage()!, orientation: .right), id: id)
        #expect(path == "Keyframes/\(id.uuidString).jpg")
        let src = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("\(id.uuidString).jpg") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == 32 && image.height == 64)   // portrait, as the user saw it
    }

    /// Renders the counting screen offscreen with a counted shelf, a card and the HUD: the whole
    /// view hierarchy is built and drawn (sheets aside), on a Mac.
    @Test func countingScreenRenders() async throws {
        let walk = try await Walk(SessionTests.shelf)
        await walk.hold(1.2)
        let session = walk.session
        #expect(session.card != nil)
        let size = CGSize(width: 393, height: 852)
        let mapping = DisplayMapping.aspectFill(upright: CGSize(width: 1440, height: 1920), view: size, orientation: .right)
        let screen = CountingScreenLayout(session: session, mapping: mapping, torch: .constant(false)) {
            Color.gray
        } hud: {
            HUDView(hud: session.hud, autoCount: .constant(true), useNeuralEngine: .constant(false), capture: nil,
                    manifest: { CaptureManifest(app: "", device: "", system: "", rateHz: 2, orientation: .right, detector: "") })
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 393 && image.height == 852)

        let card = ImageRenderer(content: CommitCardView(card: session.card!, onName: { _ in }, onDismiss: {}).frame(width: 360))
        #expect(card.cgImage != nil)
        let start = ImageRenderer(content: StartView { _, _ in }.frame(width: 393, height: 600))
        #expect(start.cgImage != nil)

        // STOCKMASK_SCREENSHOT_DIR=... writes the renders as PNG, to look at the layout on a Mac.
        if let dir = ProcessInfo.processInfo.environment["STOCKMASK_SCREENSHOT_DIR"] {
            for (name, img) in [("counting", image), ("card", card.cgImage!)] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png") as CFURL
                let dest = try #require(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, img, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }
}
