import Testing
@testable import StockMaskAR

@Suite("DETR duplicate boxes")
struct DETRDeduplicationTests {
    @Test func dropsASecondBoxOnTheSameObject() {
        let a = RawDetection(label: "bottle", score: 0.9, box: SIMD4(0.10, 0.10, 0.20, 0.50))
        let b = RawDetection(label: "bottle", score: 0.57, box: SIMD4(0.101, 0.10, 0.20, 0.50))
        #expect(DETRDecoder.deduplicated([b, a]) == [a])
    }

    @Test func keepsNeighboursAndOtherLabels() {
        let bottle = RawDetection(label: "bottle", score: 0.9, box: SIMD4(0.10, 0.10, 0.20, 0.50))
        let top = RawDetection(label: "bottle_top", score: 0.8, box: SIMD4(0.12, 0.10, 0.18, 0.14))
        let next = RawDetection(label: "bottle", score: 0.7, box: SIMD4(0.21, 0.10, 0.31, 0.50))
        #expect(DETRDecoder.deduplicated([bottle, top, next]).count == 3)
    }
}
