import SwiftUI

/// The VISUAL model of the board: which numbered glass stone is in which
/// slot, plus the plan currently being played over it. The engine only knows
/// counts; the stage knows identities, which is what lets a particular ruby
/// be lifted from one pit and dropped into the next.
@Observable
final class MancalaStage {
    /// Stone ids resting in each absolute slot (0...13), in landing order.
    /// While a plan plays, this is still the position BEFORE the move; the
    /// plan overrides the poses of the stones it moves.
    private(set) var slots: [[Int]]
    private(set) var plan: MancalaPlan?
    private(set) var startDate = Date()

    var isPlaying: Bool { plan != nil }

    /// Fresh board: four stones per pit (ids 0...47 dealt in slot order).
    convenience init() {
        self.init(board: (0..<14).map { MancalaRules.isStore($0) ? 0 : 4 })
    }

    /// Stage matching an arbitrary engine board (used by the demo, which
    /// restores a mid-game state).
    init(board: [Int]) {
        var next = 0
        var built: [[Int]] = []
        for slot in 0..<14 {
            let count = board[slot]
            built.append(Array(next..<(next + count)))
            next += count
        }
        slots = built
    }

    func begin(_ plan: MancalaPlan) {
        self.plan = plan
        startDate = Date()
    }

    /// Lands the plan: every moved stone is now at rest where the plan said.
    func commit() {
        if let plan { slots = plan.finalSlots }
        plan = nil
    }

    /// Belt and braces: if the visual counts ever disagree with the engine
    /// (they never should), rebuild from the engine so the board is honest.
    func reconcile(with board: [Int]) {
        let counts = slots.map(\.count)
        guard counts != board else { return }
        var pool = slots.flatMap { $0 }
        var next = (pool.max() ?? -1) + 1
        var rebuilt: [[Int]] = []
        for slot in 0..<14 {
            var column: [Int] = []
            for _ in 0..<board[slot] {
                if pool.isEmpty {
                    column.append(next)
                    next += 1
                } else {
                    column.append(pool.removeFirst())
                }
            }
            rebuilt.append(column)
        }
        slots = rebuilt
    }
}
