import Foundation

/// Exact expected-score play for Shut the Box (lowest total of standing tiles
/// wins; shutting the whole box scores 0).
///
/// `V[mask]` is the expected final score from a board `mask` (bit `i` set =
/// tile `i + 1` standing), assuming optimal play from there. It is solved
/// once for all 512 boards, ascending (a move only ever removes tiles, so a
/// resulting board is always a smaller number):
///
///     rollValue(mask, sum) = min over legal sets T of V[mask - T], or the
///                            sum of the standing tiles when no set exists (bust)
///     V2[mask] = sum over the 36 two-dice outcomes of rollValue / 36
///     V1[mask] = sum over the six one-die outcomes of rollValue / 6
///     V[mask]  = min(V2, V1) once tiles 7, 8, 9 are down (the one-die option
///                is unlocked), else V2.
///
/// The two choices the controller needs both fall out of it directly:
/// which set to flip for a given roll, and whether to switch to one die.
public enum ShutBoxStrategy {
    private static let twoDiceWays: [Int] = {
        var ways = [Int](repeating: 0, count: 13)
        for a in 1...6 { for b in 1...6 { ways[a + b] += 1 } }
        return ways
    }()

    private static func tileSum(_ mask: Int) -> Int {
        var s = 0
        for i in 0..<9 where mask & (1 << i) != 0 { s += i + 1 }
        return s
    }

    /// Bitmask of the tiles with sum `target` that are submasks of `mask`.
    private static func sets(of mask: Int, summing target: Int) -> [Int] {
        var result: [Int] = []
        var sub = mask
        while sub > 0 {
            if tileSum(sub) == target { result.append(sub) }
            sub = (sub - 1) & mask
        }
        return result
    }

    private struct Solution {
        var v: [Double] = Array(repeating: 0, count: 512)
        var v1: [Double] = Array(repeating: 0, count: 512)
        var v2: [Double] = Array(repeating: 0, count: 512)
        let tiles789: Int = (1 << 6) | (1 << 7) | (1 << 8)

        init() {
            for mask in 1..<512 {
                let standingSum = Double(ShutBoxStrategy.tileSum(mask))
                func rollValue(_ s: Int) -> Double {
                    var best = Double.infinity
                    for t in ShutBoxStrategy.sets(of: mask, summing: s) { best = min(best, v[mask & ~t]) }
                    return best == .infinity ? standingSum : best
                }
                var e2 = 0.0
                for s in 2...12 { e2 += Double(ShutBoxStrategy.twoDiceWays[s]) * rollValue(s) }
                v2[mask] = e2 / 36.0
                var e1 = 0.0
                for f in 1...6 { e1 += rollValue(f) }
                v1[mask] = e1 / 6.0
                v[mask] = (mask & tiles789 == 0) ? min(v1[mask], v2[mask]) : v2[mask]
            }
        }
    }

    private static let solution = Solution()

    private static func mask(of standing: [Bool]) -> Int {
        var m = 0
        for i in 0..<min(9, standing.count) where standing[i] { m |= 1 << i }
        return m
    }

    /// Expected final score from this board with optimal play (exposed for tests).
    public static func expectedScore(standing: [Bool]) -> Double {
        solution.v[mask(of: standing)]
    }

    /// The tiles (values 1...9) to flip for `sum`, or nil when no set exists:
    /// the set whose resulting board has the lowest expected final score
    /// (ties go to the numerically smallest set mask, so it is deterministic).
    public static func chooseSet(standing: [Bool], sum: Int) -> [Int]? {
        let m = mask(of: standing)
        let options = sets(of: m, summing: sum)
        guard !options.isEmpty else { return nil }
        var bestMask = options[0]
        var bestValue = Double.infinity
        for t in options.sorted() {
            let value = solution.v[m & ~t]
            if value < bestValue - 1e-9 { bestValue = value; bestMask = t }
        }
        return (0..<9).filter { bestMask & (1 << $0) != 0 }.map { $0 + 1 }
    }

    /// True when the one-die option is unlocked AND strictly better by
    /// expected final score than two dice on the current board.
    public static func shouldUseOneDie(standing: [Bool]) -> Bool {
        let m = mask(of: standing)
        guard m & solution.tiles789 == 0, m != 0 else { return false }
        return solution.v1[m] < solution.v2[m] - 1e-12
    }
}
