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
///
/// **Speed.** The source coordinates are precomputed per output row and column ("taps"), and the
/// per-pixel work is plain pointer arithmetic, because Debug builds don't optimise: the first,
/// closure-based version took 64 ms per 1920 x 1440 frame unoptimised on an M5 (3 ms optimised),
/// most of a detector period on a phone.
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

    /// For each output index along one upright axis: the two source indices along the sensor axis it
    /// maps to, and the weight of the second. torch's rule: source = (k + 0.5) * scale - 0.5, at
    /// least 0, on the upright axis; `flip` mirrors it onto the sensor axis (quarter turns).
    struct Taps {
        var i0: [Int]
        var i1: [Int]
        var w: [Float]

        init(outCount: Int, sourceCount n: Int, flip: Bool) {
            i0 = [Int](repeating: 0, count: outCount)
            i1 = [Int](repeating: 0, count: outCount)
            w = [Float](repeating: 0, count: outCount)
            let scale = Float(n) / Float(outCount)
            for k in 0..<outCount {
                var s = max(0, (Float(k) + 0.5) * scale - 0.5)
                if flip { s = Float(n - 1) - s }
                s = min(max(s, 0), Float(n - 1))
                let a = Int(s)
                i0[k] = a
                i1[k] = min(a + 1, n - 1)
                w[k] = s - Float(a)
            }
        }

        /// The chroma taps of a 2 x 2-subsampled plane for the same samples (chroma sited at the
        /// centre of each 2 x 2 block): chroma coordinate = (luma + 0.5) / 2 - 0.5.
        func chroma(lumaCount: Int, chromaCount: Int) -> Taps {
            var t = self
            for k in 0..<i0.count {
                let luma = Float(i0[k]) + w[k]
                let c = min(max((luma + 0.5) / 2 - 0.5, 0), Float(chromaCount - 1))
                let a = Int(c)
                t.i0[k] = a
                t.i1[k] = min(a + 1, chromaCount - 1)
                t.w[k] = c - Float(a)
            }
            return t
        }
    }

    /// The taps for output columns and rows, and whether columns run along the sensor's y axis
    /// (a quarter turn) instead of its x axis.
    static func taps(_ o: FrameOrientation, sensorWidth w: Int, sensorHeight h: Int, _ dst: Destination)
        -> (cols: Taps, rows: Taps, swapped: Bool) {
        switch o {
        case .up:
            return (Taps(outCount: dst.width, sourceCount: w, flip: false), Taps(outCount: dst.height, sourceCount: h, flip: false), false)
        case .down:
            return (Taps(outCount: dst.width, sourceCount: w, flip: true), Taps(outCount: dst.height, sourceCount: h, flip: true), false)
        case .right:   // upright x runs down the sensor's y axis (flipped); upright y along its x axis
            return (Taps(outCount: dst.width, sourceCount: h, flip: true), Taps(outCount: dst.height, sourceCount: w, flip: false), true)
        case .left:
            return (Taps(outCount: dst.width, sourceCount: h, flip: false), Taps(outCount: dst.height, sourceCount: w, flip: true), true)
        }
    }

    static func resize(_ buffer: CVPixelBuffer, _ o: FrameOrientation, _ dst: Destination) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        switch format {
        case kCVPixelFormatType_32BGRA:
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let p = UnsafePointer(CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self))
            sample4(p, rowBytes: CVPixelBufferGetBytesPerRow(buffer), width: w, height: h, r: 2, g: 1, b: 0, o, dst)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            sampleYCbCr(buffer, full: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, o, dst)
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
            sample4(buf.baseAddress!, rowBytes: w * 4, width: w, height: h, r: 0, g: 1, b: 2, o, dst)
        }
    }

    /// Runs `row` for every row, in parallel chunks of rows. Rows are independent: each call writes
    /// its own row of the destination only, which is what makes sharing `row` across threads safe.
    static func inChunks(_ rows: Int, _ row: (Int) -> Void) {
        let chunk = 32
        withoutActuallyEscaping(row) { row in
            let shared = RowWriter(write: row)
            DispatchQueue.concurrentPerform(iterations: (rows + chunk - 1) / chunk) { k in
                for j in (k * chunk)..<min(rows, (k + 1) * chunk) { shared.write(j) }
            }
        }
    }

    private struct RowWriter: @unchecked Sendable { let write: (Int) -> Void }

    /// A sample rounded to a byte. Written out rather than with `min`/`max`, which an unoptimised
    /// build calls generically for every pixel.
    @inline(__always)
    static func byte(_ v: Float) -> UInt8 { v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v.rounded())) }

    /// Bilinear samples of a 4-byte-per-pixel image (channel offsets r, g, b) into BGRA.
    static func sample4(_ p: UnsafePointer<UInt8>, rowBytes rb: Int, width w: Int, height h: Int, r: Int, g: Int, b: Int,
                        _ o: FrameOrientation, _ dst: Destination) {
        let (cols, rows, swapped) = taps(o, sensorWidth: w, sensorHeight: h, dst)
        cols.i0.withUnsafeBufferPointer { c0b in cols.i1.withUnsafeBufferPointer { c1b in cols.w.withUnsafeBufferPointer { cwb in
        rows.i0.withUnsafeBufferPointer { r0b in rows.i1.withUnsafeBufferPointer { r1b in rows.w.withUnsafeBufferPointer { rwb in
            // Raw pointers: buffer subscripts are bounds-checked in Debug builds.
            let c0 = c0b.baseAddress!, c1 = c1b.baseAddress!, cw = cwb.baseAddress!
            let r0 = r0b.baseAddress!, r1 = r1b.baseAddress!, rw = rwb.baseAddress!
            inChunks(dst.height) { j in
                var px = dst.base + j * dst.rowBytes
                for i in 0..<dst.width {
                    // Source column (x) and row (y) taps: columns follow the sensor's y axis after a quarter turn.
                    let x0: Int, x1: Int, fx: Float, y0: Int, y1: Int, fy: Float
                    if swapped {
                        (x0, x1, fx, y0, y1, fy) = (r0[j], r1[j], rw[j], c0[i], c1[i], cw[i])
                    } else {
                        (x0, x1, fx, y0, y1, fy) = (c0[i], c1[i], cw[i], r0[j], r1[j], rw[j])
                    }
                    let top = p + y0 * rb, bottom = p + y1 * rb
                    let a0 = x0 * 4, a1 = x1 * 4
                    // Blue, green, red into BGRA: three unrolled bilinear samples.
                    var t = Float(top[a0 + b]) + (Float(top[a1 + b]) - Float(top[a0 + b])) * fx
                    var u = Float(bottom[a0 + b]) + (Float(bottom[a1 + b]) - Float(bottom[a0 + b])) * fx
                    px[0] = byte(t + (u - t) * fy)
                    t = Float(top[a0 + g]) + (Float(top[a1 + g]) - Float(top[a0 + g])) * fx
                    u = Float(bottom[a0 + g]) + (Float(bottom[a1 + g]) - Float(bottom[a0 + g])) * fx
                    px[1] = byte(t + (u - t) * fy)
                    t = Float(top[a0 + r]) + (Float(top[a1 + r]) - Float(top[a0 + r])) * fx
                    u = Float(bottom[a0 + r]) + (Float(bottom[a1 + r]) - Float(bottom[a0 + r])) * fx
                    px[2] = byte(t + (u - t) * fy)
                    px[3] = 255
                    px += 4
                }
            }
        } } } } } }
    }

    /// Bilinear samples of ARKit's biplanar YCbCr 4:2:0 into BGRA.
    static func sampleYCbCr(_ buffer: CVPixelBuffer, full: Bool, _ o: FrameOrientation, _ dst: Destination) {
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cwid = CVPixelBufferGetWidthOfPlane(buffer, 1), chgt = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let yp = UnsafePointer(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self))
        let cp = UnsafePointer(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self))
        let yrb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let m = YCbCrMatrix(buffer)
        let (cols, rows, swapped) = taps(o, sensorWidth: w, sensorHeight: h, dst)
        // Chroma taps along the same sensor axes as the luma ones.
        let ccols = cols.chroma(lumaCount: swapped ? h : w, chromaCount: swapped ? chgt : cwid)
        let crows = rows.chroma(lumaCount: swapped ? w : h, chromaCount: swapped ? cwid : chgt)
        // Video range: Y 16-235 and C 16-240 expand to the full 0-255 range.
        let lumaScale: Float = full ? 1 : 255 / 219, lumaOffset: Float = full ? 0 : 16, chromaScale: Float = full ? 1 : 255 / 224
        let (rCr, gCb, gCr, bCb) = (m.rCr, m.gCb, m.gCr, m.bCb)

        cols.i0.withUnsafeBufferPointer { c0b in cols.i1.withUnsafeBufferPointer { c1b in cols.w.withUnsafeBufferPointer { cwb in
        rows.i0.withUnsafeBufferPointer { r0b in rows.i1.withUnsafeBufferPointer { r1b in rows.w.withUnsafeBufferPointer { rwb in
        ccols.i0.withUnsafeBufferPointer { k0b in ccols.i1.withUnsafeBufferPointer { k1b in ccols.w.withUnsafeBufferPointer { kwb in
        crows.i0.withUnsafeBufferPointer { q0b in crows.i1.withUnsafeBufferPointer { q1b in crows.w.withUnsafeBufferPointer { qwb in
            // Raw pointers: buffer subscripts are bounds-checked in Debug builds.
            let c0 = c0b.baseAddress!, c1 = c1b.baseAddress!, cw = cwb.baseAddress!
            let r0 = r0b.baseAddress!, r1 = r1b.baseAddress!, rw = rwb.baseAddress!
            let k0 = k0b.baseAddress!, k1 = k1b.baseAddress!, kw = kwb.baseAddress!
            let q0 = q0b.baseAddress!, q1 = q1b.baseAddress!, qw = qwb.baseAddress!
            inChunks(dst.height) { j in
                var px = dst.base + j * dst.rowBytes
                for i in 0..<dst.width {
                    // Luma (x, y) and chroma (u, v) taps; after a quarter turn, columns run along the sensor's y axis.
                    let x0: Int, x1: Int, fx: Float, y0: Int, y1: Int, fy: Float
                    let u0: Int, u1: Int, fu: Float, v0: Int, v1: Int, fv: Float
                    if swapped {
                        (x0, x1, fx, y0, y1, fy) = (r0[j], r1[j], rw[j], c0[i], c1[i], cw[i])
                        (u0, u1, fu, v0, v1, fv) = (q0[j], q1[j], qw[j], k0[i], k1[i], kw[i])
                    } else {
                        (x0, x1, fx, y0, y1, fy) = (c0[i], c1[i], cw[i], r0[j], r1[j], rw[j])
                        (u0, u1, fu, v0, v1, fv) = (k0[i], k1[i], kw[i], q0[j], q1[j], qw[j])
                    }

                    let ya = yp + y0 * yrb, yb = yp + y1 * yrb
                    let lt = Float(ya[x0]) + (Float(ya[x1]) - Float(ya[x0])) * fx
                    let lb = Float(yb[x0]) + (Float(yb[x1]) - Float(yb[x0])) * fx
                    let luma = (lt + (lb - lt) * fy - lumaOffset) * lumaScale

                    let ca = cp + v0 * crb, cb = cp + v1 * crb
                    let ua = u0 * 2, ub = u1 * 2
                    let bt = Float(ca[ua]) + (Float(ca[ub]) - Float(ca[ua])) * fu
                    let bb = Float(cb[ua]) + (Float(cb[ub]) - Float(cb[ua])) * fu
                    let rt = Float(ca[ua + 1]) + (Float(ca[ub + 1]) - Float(ca[ua + 1])) * fu
                    let rbt = Float(cb[ua + 1]) + (Float(cb[ub + 1]) - Float(cb[ua + 1])) * fu
                    let blue = (bt + (bb - bt) * fv - 128) * chromaScale
                    let red = (rt + (rbt - rt) * fv - 128) * chromaScale

                    px[0] = byte(luma + bCb * blue)
                    px[1] = byte(luma - gCb * blue - gCr * red)
                    px[2] = byte(luma + rCr * red)
                    px[3] = 255
                    px += 4
                }
            }
        } } } } } } } } } } } }
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
