import Foundation

/// Pure, deterministic Battleship AI. No engine access: feed it a seat's
/// `BattleshipSnapshot` (or the raw shot history) and it returns a legal,
/// never-repeated target. Salvo: call once per shot (re-snapshot between).
///
/// Strategy
/// - Hunt: only cells on the parity lattice `(row + col) % minLen == 0`,
///   where `minLen` is the shortest ship still afloat (checkerboard while a
///   destroyer lives), ranked by placement density (how many remaining ships
///   could still cover the cell given misses and sunk ships).
/// - Target: once any hit isn't accounted for by a sunk ship, the "target
///   stack" is every unshot cell on a ship placement that covers those hits,
///   weighted 4^(hits covered - 1) so collinear hits pull the search along
///   the line and orthogonal neighbours of a lone hit come first. The stack
///   is re-derived statelessly from the shot history each call.
/// - Ties are broken with the caller's seeded `rng`.
public enum BattleshipBot {
    /// A full random fleet for the bot's seat.
    public static func placement(seed: UInt64) -> [BattleshipShip] {
        BattleshipRules.randomPlacement(seed: seed)
    }

    public static func chooseShot(snapshot: BattleshipSnapshot, rng: inout SeededGenerator) -> BattleshipCell? {
        chooseShot(shots: snapshot.myShots, sunkShips: snapshot.opponentSunk, rng: &rng)
    }

    public static func chooseShot(
        shots: [BattleshipShot], sunkShips: [BattleshipShip], rng: inout SeededGenerator
    ) -> BattleshipCell? {
        let n = BattleshipRules.boardSize
        var fired = Set<BattleshipCell>()
        var misses = Set<BattleshipCell>()
        var hits = Set<BattleshipCell>()
        for s in shots {
            fired.insert(s.cell)
            if s.result.isHit { hits.insert(s.cell) } else { misses.insert(s.cell) }
        }
        let sunkCells = Set(sunkShips.flatMap(\.cells))
        let unresolved = hits.subtracting(sunkCells)
        let sunkKinds = Set(sunkShips.map(\.kind))
        let remaining = BattleshipRules.fleet.filter { !sunkKinds.contains($0) }
        guard !remaining.isEmpty else { return firstUnfired(fired, rng: &rng) }

        // Placement-density map.
        var density = [Int](repeating: 0, count: n * n)
        for kind in remaining {
            for orientation in [BattleshipOrientation.horizontal, .vertical] {
                for row in 0..<n {
                    for col in 0..<n {
                        let cells = BattleshipShip(kind: kind, row: row, col: col, orientation: orientation).cells
                        guard cells.allSatisfy({ BattleshipRules.inBounds($0.row, $0.col) }) else { continue }
                        if cells.contains(where: { misses.contains($0) || sunkCells.contains($0) }) { continue }
                        let covered = cells.filter { unresolved.contains($0) }.count
                        if !unresolved.isEmpty {
                            if covered == 0 { continue }
                            let weight = 1 << (2 * (covered - 1))
                            for c in cells where !fired.contains(c) { density[c.row * n + c.col] += weight }
                        } else {
                            for c in cells where !fired.contains(c) { density[c.row * n + c.col] += 1 }
                        }
                    }
                }
            }
        }

        var candidates: [BattleshipCell] = []
        if !unresolved.isEmpty {
            for r in 0..<n {
                for c in 0..<n where density[r * n + c] > 0 && !fired.contains(BattleshipCell(row: r, col: c)) {
                    candidates.append(BattleshipCell(row: r, col: c))
                }
            }
        } else {
            let minLen = remaining.map(\.length).min() ?? 2
            for r in 0..<n {
                for c in 0..<n where (r + c) % minLen == 0 && density[r * n + c] > 0 {
                    candidates.append(BattleshipCell(row: r, col: c))
                }
            }
            if candidates.isEmpty { // parity lattice exhausted
                for r in 0..<n {
                    for c in 0..<n where density[r * n + c] > 0 { candidates.append(BattleshipCell(row: r, col: c)) }
                }
            }
        }
        if candidates.isEmpty { return firstUnfired(fired, rng: &rng) }
        let best = candidates.map { density[$0.row * n + $0.col] }.max() ?? 0
        let top = candidates.filter { density[$0.row * n + $0.col] == best }
        return top[Int.random(in: 0..<top.count, using: &rng)]
    }

    private static func firstUnfired(_ fired: Set<BattleshipCell>, rng: inout SeededGenerator) -> BattleshipCell? {
        var open: [BattleshipCell] = []
        for r in 0..<BattleshipRules.boardSize {
            for c in 0..<BattleshipRules.boardSize where !fired.contains(BattleshipCell(row: r, col: c)) {
                open.append(BattleshipCell(row: r, col: c))
            }
        }
        return open.isEmpty ? nil : open[Int.random(in: 0..<open.count, using: &rng)]
    }
}
