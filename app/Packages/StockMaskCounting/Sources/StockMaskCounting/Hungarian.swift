/// Minimum-cost one-to-one assignment (the Hungarian method, as scipy's `linear_sum_assignment`).
public enum Hungarian {
    /// Assigns rows to columns so that the total cost is minimal. Every row gets a column when there
    /// are at least as many columns as rows; otherwise every column gets a row and the other rows get
    /// nil.
    ///
    /// Costs must be finite. To forbid a pair, give it a cost larger than any sum of allowed costs
    /// (ADR 003's simulation uses 1e3) and drop it from the result afterwards: the assignment then
    /// uses as many allowed pairs as possible, at the least total cost.
    ///
    /// Shortest augmenting paths with potentials, O(n² m) for n ≤ m.
    /// - Parameter cost: `cost[row][column]`, a rectangular matrix.
    /// - Returns: for each row, its column or nil.
    public static func assign(_ cost: [[Double]]) -> [Int?] {
        let n = cost.count
        guard n > 0 else { return [] }
        let m = cost[0].count
        precondition(cost.allSatisfy { $0.count == m }, "Hungarian.assign: rows of different lengths")
        precondition(cost.allSatisfy { $0.allSatisfy(\.isFinite) }, "Hungarian.assign: costs must be finite")
        guard m > 0 else { return Array(repeating: nil, count: n) }
        if n > m {  // solve the transpose: every column gets a row
            let transposed = (0..<m).map { j in (0..<n).map { i in cost[i][j] } }
            var rows = [Int?](repeating: nil, count: n)
            for (j, i) in assign(transposed).enumerated() {
                if let i { rows[i] = j }
            }
            return rows
        }
        // 1-based, column 0 is a sentinel. u, v: potentials; p[j]: the row on column j; way: the
        // previous column on the augmenting path.
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1)
        var way = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m where !used[j] {
                    let reduced = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if reduced < minv[j] {
                        minv[j] = reduced
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...m {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var rows = [Int?](repeating: nil, count: n)
        for j in 1...m where p[j] != 0 {
            rows[p[j] - 1] = j - 1
        }
        return rows
    }
}
