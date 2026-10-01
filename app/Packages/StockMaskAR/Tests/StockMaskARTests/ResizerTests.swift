import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import StockMaskAR

@Suite("Model input resizer")
struct ResizerTests {
    /// BGRA pixel (b, g, r) at (x, y) of a buffer.
    func pixel(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return [p[0], p[1], p[2]]
    }

    /// An RGB image from a function of (x, y).
    func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = f(x, y); px[(y * w + x) * 4] = c.0; px[(y * w + x) * 4 + 1] = c.1; px[(y * w + x) * 4 + 2] = c.2 } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func halvingAveragesPairsLikeTorch() throws {
        // A horizontal ramp 0, 10, 20, ... halved: torch's bilinear (align_corners=False) samples
        // at 2i + 0.5, the mean of each pair: 5, 25, 45, ...
        let img = image(8, 2) { x, _ in (UInt8(x * 10), 0, 0) }
        let out = try ModelInputResizer.resize(DetectorInput(image: img), to: SIMD2(4, 1))
        #expect((0..<4).map { pixel(out, $0, 0)[2] } == [5, 25, 45, 65])
    }

    @Test func downscalingByThreeUsesTheCentreSample() throws {
        // Factor 3: output i samples source 3i + 1 exactly (no antialiasing, unlike Vision).
        let img = image(9, 3) { x, _ in (0, UInt8(x * 20), 0) }
        let out = try ModelInputResizer.resize(DetectorInput(image: img), to: SIMD2(3, 1))
        #expect((0..<3).map { pixel(out, $0, 0)[1] } == [20, 80, 140])
    }

    @Test func turnsUpright() throws {
        // Sensor image 4 x 2 (landscape) with a red top-left pixel. Turned right (portrait), it is
        // 2 x 4 and the red pixel is top-right.
        let img = image(4, 2) { x, y in x == 0 && y == 0 ? (255, 0, 0) : (0, 0, 255) }
        let out = try ModelInputResizer.resize(DetectorInput(image: img, orientation: .right), to: SIMD2(2, 4))
        #expect(pixel(out, 1, 0) == [0, 0, 255])   // BGRA: red
        #expect(pixel(out, 0, 0) == [255, 0, 0])   // blue
        let left = try ModelInputResizer.resize(DetectorInput(image: img, orientation: .left), to: SIMD2(2, 4))
        #expect(pixel(left, 0, 3) == [0, 0, 255])  // anticlockwise: top-left goes bottom-left
    }

    @Test func convertsARKitYCbCr() throws {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &b)
        let buffer = try #require(b)
        CVPixelBufferLockBaseAddress(buffer, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 { for col in 0..<8 { y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + col] = 100 } }
        for row in 0..<2 {
            for col in 0..<4 {
                let p = c + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + col * 2
                p[0] = 128; p[1] = 178   // Cb neutral, Cr +50: reddish
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let out = try ModelInputResizer.resize(DetectorInput(pixelBuffer: buffer, orientation: .up), to: SIMD2(4, 2))
        // BT.601 full range: R = 100 + 1.402 * 50 = 170.1, G = 100 - 0.714 * 50 = 64.3, B = 100.
        #expect(pixel(out, 1, 1) == [100, 64, 170])
    }
}
