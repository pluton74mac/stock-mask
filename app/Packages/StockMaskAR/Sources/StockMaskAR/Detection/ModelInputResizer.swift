import CoreGraphics
import CoreVideo
import Foundation

/// Makes the model's input image the way rfdetr's `predict()` makes it: the upright image
/// stretched to the input size with **bilinear interpolation, no antialiasing, half-pixel centres**
/// (`torch.nn.functional.interpolate(..., align_corners=False)`), which is also how RF-DETR is
/// trained. Vision's own resize is antialiased, and on the parity frames that alone moves the
/// count: 34 bottles instead of 38 (`ml/coreml/RESULTS.md`).
///
/// It turns the image upright in the same pass (quarter turns map pixel centres onto pixel
/// centres, so turning and resampling commute), and converts ARKit's YCbCr camera buffers with
/// the buffer's own matrix (BT.601 unless it says BT.709).
public enum ModelInputResizer {
    public enum Problem: Error, Equatable {
        case unsupportedPixelFormat(OSType)
        case cannotAllocate
    }

    /// A new 32BGRA buffer of `size` holding the upright image, stretched.
    public static func resize(_ input: DetectorInput, to size: SIMD2<Int>) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, size.x, size.y, kCVPixelFormatType_32BGRA, attrs, &out) == kCVReturnSuccess,
              let out else { throw Problem.cannotAllocate }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let dst = Destination(base: CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self),
                              rowBytes: CVPixelBufferGetBytesPerRow(out), width: size.x, height: size.y)
        switch input.source {
        case .pixelBuffer(let b): try resize(b, input.orientation, dst)
        case .image(let image): try resize(image, input.orientation, dst)
        }
        return out
    }

    struct Destination {
        let base: UnsafeMutablePointer<UInt8>
        let rowBytes: Int
        let width: Int
        let height: Int
    }

    /// Calls `body(i, j, xs, ys)` for each output pixel with the sensor-image sample point (index
    /// space: pixel k's centre is k) that torch's bilinear resize of the upright image would use.
    @inline(__always)
    static func forEachSample(_ o: FrameOrientation, sensorWidth w: Int, sensorHeight h: Int, _ dst: Destination,
                              _ body: (Int, Int, Float, Float) -> Void) {
        let up = o.uprightSize(sensor: SIMD2(Float(w), Float(h)))
        let sx = up.x / Float(dst.width), sy = up.y / Float(dst.height)
        let maxX = Float(w - 1), maxY = Float(h - 1)
        for j in 0..<dst.height {
            let v = max(0, (Float(j) + 0.5) * sy - 0.5)          // upright row
            for i in 0..<dst.width {
                let u = max(0, (Float(i) + 0.5) * sx - 0.5)      // upright column
                var xs: Float, ys: Float
                switch o {
                case .up: (xs, ys) = (u, v)
                case .right: (xs, ys) = (v, maxY - u)
                case .down: (xs, ys) = (maxX - u, maxY - v)
                case .left: (xs, ys) = (maxX - v, u)
                }
                body(i, j, min(max(xs, 0), maxX), min(max(ys, 0), maxY))
            }
        }
    }

    @inline(__always)
    static func bilinear(_ p: UnsafePointer<UInt8>, rowBytes: Int, stride: Int, channel: Int, width: Int, height: Int,
                         _ x: Float, _ y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        @inline(__always) func at(_ xx: Int, _ yy: Int) -> Float { Float(p[yy * rowBytes + xx * stride + channel]) }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * fx
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * fx
        return top + (bottom - top) * fy
    }

    @inline(__always)
    static func store(_ dst: Destination, _ i: Int, _ j: Int, r: Float, g: Float, b: Float) {
        let px = dst.base + j * dst.rowBytes + i * 4
        px[0] = UInt8(min(max(b, 0), 255).rounded())
        px[1] = UInt8(min(max(g, 0), 255).rounded())
        px[2] = UInt8(min(max(r, 0), 255).rounded())
        px[3] = 255
    }

    static func resize(_ buffer: CVPixelBuffer, _ o: FrameOrientation, _ dst: Destination) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        switch format {
        case kCVPixelFormatType_32BGRA:
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let p = UnsafePointer(CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self))
            let rb = CVPixelBufferGetBytesPerRow(buffer)
            forEachSample(o, sensorWidth: w, sensorHeight: h, dst) { i, j, x, y in
                store(dst, i, j, r: bilinear(p, rowBytes: rb, stride: 4, channel: 2, width: w, height: h, x, y),
                      g: bilinear(p, rowBytes: rb, stride: 4, channel: 1, width: w, height: h, x, y),
                      b: bilinear(p, rowBytes: rb, stride: 4, channel: 0, width: w, height: h, x, y))
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
            let yp = UnsafePointer(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self))
            let cp = UnsafePointer(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self))
            let yrb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let m = YCbCrMatrix(buffer)
            let cmaxX = Float(cw - 1), cmaxY = Float(ch - 1)
            forEachSample(o, sensorWidth: w, sensorHeight: h, dst) { i, j, x, y in
                var luma = bilinear(yp, rowBytes: yrb, stride: 1, channel: 0, width: w, height: h, x, y)
                // Chroma is sited at the centre of each 2 x 2 block.
                let cx = min(max((x + 0.5) / 2 - 0.5, 0), cmaxX), cy = min(max((y + 0.5) / 2 - 0.5, 0), cmaxY)
                var cb = bilinear(cp, rowBytes: crb, stride: 2, channel: 0, width: cw, height: ch, cx, cy) - 128
                var cr = bilinear(cp, rowBytes: crb, stride: 2, channel: 1, width: cw, height: ch, cx, cy) - 128
                if !full {
                    luma = (luma - 16) * (255 / 219)
                    cb *= 255 / 224
                    cr *= 255 / 224
                }
                store(dst, i, j, r: luma + m.rCr * cr, g: luma - m.gCb * cb - m.gCr * cr, b: luma + m.bCb * cb)
            }
        default:
            throw Problem.unsupportedPixelFormat(format)
        }
    }

    static func resize(_ image: CGImage, _ o: FrameOrientation, _ dst: Destination) throws {
        // Draw once at full size (no scaling, so no resampling), then sample like a BGRA buffer.
        // The image's own RGB colour space avoids a colour conversion on the way.
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        try pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw Problem.cannotAllocate }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            forEachSample(o, sensorWidth: w, sensorHeight: h, dst) { i, j, x, y in
                store(dst, i, j, r: bilinear(p, rowBytes: w * 4, stride: 4, channel: 0, width: w, height: h, x, y),
                      g: bilinear(p, rowBytes: w * 4, stride: 4, channel: 1, width: w, height: h, x, y),
                      b: bilinear(p, rowBytes: w * 4, stride: 4, channel: 2, width: w, height: h, x, y))
            }
        }
    }

    /// Full-range YCbCr -> RGB coefficients for the buffer's colour matrix.
    struct YCbCrMatrix {
        var rCr: Float, gCb: Float, gCr: Float, bCb: Float

        init(_ buffer: CVPixelBuffer) {
            let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {
                (rCr, gCb, gCr, bCb) = (1.5748, 0.1873, 0.4681, 1.8556)
            } else {
                (rCr, gCb, gCr, bCb) = (1.402, 0.344136, 0.714136, 1.772)   // BT.601, as ARKit's own samples use
            }
        }
    }
}
