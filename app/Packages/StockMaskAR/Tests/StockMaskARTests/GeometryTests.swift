import CoreVideo
import Foundation
import Testing
import simd
@testable import StockMaskAR

/// A rotation about the world's y axis (yaw), in degrees.
func yaw(_ degrees: Float, at position: SIMD3<Float> = .zero) -> simd_float4x4 {
    var m = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
    m.columns.3 = SIMD4(position, 1)
    return m
}

@Suite("Orientation and camera")
struct GeometryTests {
    @Test(arguments: FrameOrientation.allCases)
    func pointsRoundTrip(_ o: FrameOrientation) {
        for p in [SIMD2<Float>(0.1, 0.2), SIMD2(0.9, 0.35), SIMD2(0.5, 0.5)] {
            let back = o.sensorPoint(upright: o.uprightPoint(sensor: p))
            #expect(simd_distance(back, p) < 1e-6)
        }
    }

    @Test func rightTurnsClockwise() {
        // Sensor top-left goes to upright top-right when the image turns 90° clockwise.
        #expect(FrameOrientation.right.uprightPoint(sensor: SIMD2(0, 0)) == SIMD2(1, 0))
        #expect(FrameOrientation.right.uprightSize(sensor: SIMD2(1920, 1440)) == SIMD2(1440, 1920))
    }

    /// Projecting with the sensor camera, then turning the point upright, must equal projecting
    /// with the upright camera: intrinsics, image size and axes all agree.
    @Test(arguments: FrameOrientation.allCases)
    func uprightCameraAgreesWithSensorCamera(_ o: FrameOrientation) throws {
        var k = matrix_identity_float3x3
        k[0][0] = 1450; k[1][1] = 1460; k[2][0] = 955; k[2][1] = 725
        let sensor = CameraModel(intrinsics: k, imageSize: SIMD2(1920, 1440), transform: yaw(20, at: SIMD3(0.3, 1.4, 0.2)))
        let upright = sensor.upright(o)
        for p in [SIMD3<Float>(0.1, 1.2, -1.0), SIMD3(-0.4, 1.7, -1.5), SIMD3(0.6, 0.9, -0.8)] {
            let s = try #require(sensor.project(p))
            let u = try #require(upright.project(p))
            #expect(simd_distance(o.uprightPoint(sensor: s.point), u.point) < 1e-4)
            #expect(abs(s.depth - u.depth) < 1e-4)
        }
    }

    @Test(arguments: FrameOrientation.allCases)
    func sensorCameraInvertsUpright(_ o: FrameOrientation) {
        var k = matrix_identity_float3x3
        k[0][0] = 1450; k[1][1] = 1460; k[2][0] = 955; k[2][1] = 725
        let sensor = CameraModel(intrinsics: k, imageSize: SIMD2(1920, 1440), transform: yaw(20, at: SIMD3(0.3, 1.4, 0.2)))
        let back = sensor.upright(o).sensor(o)
        #expect(back.imageSize == sensor.imageSize)
        #expect(simd_almost_equal_elements(back.intrinsics, sensor.intrinsics, 1e-3))
        #expect(simd_almost_equal_elements(back.transform, sensor.transform, 1e-5))
    }

    @Test func unprojectInvertsProject() throws {
        let cam = CameraModel(fx: 1000, imageSize: SIMD2(1440, 1920), transform: yaw(-35, at: SIMD3(1, 1.5, 2)))
        let world = SIMD3<Float>(0.4, 1.1, 0.9)
        let p = try #require(cam.project(world))
        #expect(simd_distance(cam.worldPoint(normalized: p.point, depth: p.depth), world) < 1e-4)
        #expect(cam.project(cam.position - cam.forward) == nil)  // behind the camera
    }

    @Test func depthMapTurnsUpright() {
        // 3 x 2 sensor map with distinct values; turned right it becomes 2 x 3.
        let m = DepthMap(width: 3, height: 2, depth: [1, 2, 3, 4, 5, 6], confidence: [0, 1, 2, 0, 1, 2])
        let u = m.upright(.right)
        #expect(u.width == 2 && u.height == 3)
        // Upright top-left is the sensor's bottom-left (clockwise turn).
        #expect(u.depth == [4, 1, 5, 2, 6, 3])
        #expect(u.confidence == [0, 0, 1, 1, 2, 2])
        #expect(m.upright(.left).upright(.left).upright(.left).upright(.left) == m)
    }

    @Test func depthMapCopiesFromPixelBuffers() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 3, kCVPixelFormatType_DepthFloat32, nil, &buffer)
        var conf: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 3, kCVPixelFormatType_OneComponent8, nil, &conf)
        let b = try #require(buffer), c = try #require(conf)
        CVPixelBufferLockBaseAddress(b, []); CVPixelBufferLockBaseAddress(c, [])
        for y in 0..<3 {
            let row = (CVPixelBufferGetBaseAddress(b)! + y * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(to: Float.self)
            let crow = (CVPixelBufferGetBaseAddress(c)! + y * CVPixelBufferGetBytesPerRow(c)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<4 { row[x] = Float(y * 4 + x); crow[x] = UInt8((y + x) % 3) }
        }
        CVPixelBufferUnlockBaseAddress(b, []); CVPixelBufferUnlockBaseAddress(c, [])
        let m = try #require(DepthMap(depthBuffer: b, confidenceBuffer: c))
        #expect(m.depth == (0..<12).map(Float.init))
        #expect(m.confidenceAt(3, 2) == 2)
        let raw = try #require(DepthMap(width: 4, height: 3, depthData: m.depthData, confidenceData: m.confidenceData))
        #expect(raw == m)
    }

    @Test func planeIntersectionRespectsExtent() throws {
        let shelf = SupportPlane.level(height: 0.8, center: SIMD2(0, -1), extent: SIMD2(1.0, 0.4))
        let down = simd_normalize(SIMD3<Float>(0, -0.5, -1))
        let hit = try #require(shelf.intersect(origin: SIMD3(0, 1.3, 0), direction: down))
        #expect(abs(hit.point.y - 0.8) < 1e-5 && abs(hit.point.z + 1) < 1e-5)
        #expect(shelf.intersect(origin: SIMD3(0, 1.3, 0), direction: simd_normalize(SIMD3(0, -0.1, -1))) == nil)
    }
}
