import Testing
import StockMaskCounting

@Suite("Hungarian assignment")
struct HungarianTests {
    @Test func emptyMatrices() {
        #expect(Hungarian.assign([]).isEmpty)
        #expect(Hungarian.assign([[], []]) == [nil, nil])
    }

    @Test func squareExample() {
        let cost: [[Double]] = [[4, 1, 3], [2, 0, 5], [3, 2, 2]]
        let a = Hungarian.assign(cost)
        #expect(a == [1, 0, 2])
        #expect(total(cost, a) == 5)
    }

    @Test func moreColumnsThanRows() {
        let cost: [[Double]] = [[9, 1, 9, 9], [9, 9, 9, 2]]
        #expect(Hungarian.assign(cost) == [1, 3])
    }

    @Test func moreRowsThanColumns() {
        // Two rows compete for column 0; the cheaper keeps it and the third row is left out.
        let cost: [[Double]] = [[0.03], [0.01], [5]]
        #expect(Hungarian.assign(cost) == [nil, 0, nil])
    }

    @Test("Forbidden pairs (1e3) are used only when nothing else is left")
    func forbiddenPairs() {
        let f = 1e3
        // Row 0 could take column 0 cheaply, but then row 1 would have only a forbidden pair.
        let cost: [[Double]] = [[0.01, 0.03], [0.02, f]]
        #expect(Hungarian.assign(cost) == [1, 0])
    }

    @Test("Matches brute force on random matrices", arguments: [(2, 2), (3, 3), (3, 5), (5, 3), (4, 6), (6, 6)])
    func randomAgainstBruteForce(_ shape: (Int, Int)) {
        var rng = SplitMix64(state: UInt64(shape.0 * 31 + shape.1))
        for _ in 0..<40 {
            let cost = (0..<shape.0).map { _ in (0..<shape.1).map { _ in Double.random(in: 0..<10, using: &rng).rounded() } }
            let a = Hungarian.assign(cost)
            #expect(Set(a.compactMap { $0 }).count == min(shape.0, shape.1))
            #expect(abs(total(cost, a) - bruteForce(cost)) < 1e-9)
        }
    }

    private func total(_ cost: [[Double]], _ a: [Int?]) -> Double {
        var sum = 0.0
        for (row, column) in a.enumerated() {
            if let column { sum += cost[row][column] }
        }
        return sum
    }

    /// The least total over every way of giving min(rows, cols) rows distinct columns.
    private func bruteForce(_ cost: [[Double]]) -> Double {
        let n = cost.count, m = cost[0].count
        var best = Double.infinity
        func go(_ i: Int, _ used: Set<Int>, _ sum: Double, _ assigned: Int) {
            if i == n {
                if assigned == min(n, m) { best = min(best, sum) }
                return
            }
            if n - i > m - used.count { go(i + 1, used, sum, assigned) }  // leave row i out
            for j in 0..<m where !used.contains(j) {
                go(i + 1, used.union([j]), sum + cost[i][j], assigned + 1)
            }
        }
        go(0, [], 0, 0)
        return best
    }
}
