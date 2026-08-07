import Foundation

// Dots & Boxes lives entirely outside the card engine — same pattern as
// DiceTypes.swift/DiceGameController: this file is the whole rules world
// (grid geometry, turn/score state, a heuristic bot), pure and Codable, with
// no dependency on GameState/HostEngine/GameRules. The App layer's
// DotsAndBoxesController owns one of these per game, exactly the way
// DiceGameController owns dice rules table-side. Played entirely on the
// iPad (pass-and-play, finger = pencil) — there is no phone/network leg at
// all, so unlike dice there's no client-state wire type here either.

// MARK: - Grid geometry

/// Which way a line segment runs between two adjacent dots.
public enum DotsAndBoxesEdgeOrientation: String, Codable, Sendable, Hashable {
    case horizontal, vertical
}

/// One placeable pencil line between two adjacent dots, addressed by DOT
/// coordinates (not box coordinates). A horizontal edge at `(row, col)` runs
/// from dot `(row, col)` to dot `(row, col+1)`; a vertical edge at
/// `(row, col)` runs from dot `(row, col)` to dot `(row+1, col)`. For an
/// N×N-box grid there are `N+1` dot rows/cols, so horizontal edges have
/// `row` in `0...N, col` in `0..<N`, and vertical edges have `row` in
/// `0..<N, col` in `0...N`.
public struct DotsAndBoxesEdge: Codable, Sendable, Hashable {
    public let orientation: DotsAndBoxesEdgeOrientation
    public let row: Int
    public let col: Int

    public init(orientation: DotsAndBoxesEdgeOrientation, row: Int, col: Int) {
        self.orientation = orientation
        self.row = row
        self.col = col
    }
}

/// One square of the paper, addressed by its top-left dot: box `(row, col)`
/// spans dots `(row, col)…(row+1, col+1)`, both in `0..<gridSize`.
public struct DotsAndBoxesBox: Codable, Sendable, Hashable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// This box's four bounding edges: top, bottom, left, right.
    public func edges() -> [DotsAndBoxesEdge] {
        [
            DotsAndBoxesEdge(orientation: .horizontal, row: row, col: col),
            DotsAndBoxesEdge(orientation: .horizontal, row: row + 1, col: col),
            DotsAndBoxesEdge(orientation: .vertical, row: row, col: col),
            DotsAndBoxesEdge(orientation: .vertical, row: row, col: col + 1),
        ]
    }
}

// MARK: - Players

/// One pencil at the table. `colorIndex` is an index into the App layer's
/// pencil-color palette (same convention as `Seat.colorIndex` for cards) —
/// the engine only remembers WHICH pencil, never the actual `Color`.
public struct DotsAndBoxesPlayer: Codable, Sendable, Equatable {
    public var name: String
    /// What gets written inside a box this player completes — usually the
    /// first letter of `name`, but callers may hand-pick one (e.g. to keep
    /// two "Sam"s apart at the table).
    public var initial: String
    public var colorIndex: Int
    public var isBot: Bool
    public var score: Int

    public init(name: String, initial: String? = nil, colorIndex: Int, isBot: Bool, score: Int = 0) {
        self.name = name
        self.initial = initial ?? String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        self.colorIndex = colorIndex
        self.isBot = isBot
        self.score = score
    }
}

// MARK: - State

/// The whole sheet of paper: grid size, every pencil, every claimed line,
/// every filled-in box, and whose turn it is. Codable so a mid-game demo
/// snapshot (or, later, a save) round-trips exactly like the card engine's
/// `GameState`.
public struct DotsAndBoxesState: Codable, Sendable, Equatable {
    public var gridSize: Int
    public var players: [DotsAndBoxesPlayer]
    /// Edge → the player who drew it. A dictionary (not a Set) because the
    /// paper view needs to know whose pencil color to render each line in.
    public var claimedBy: [DotsAndBoxesEdge: Int]
    /// `boxOwner[row][col]` — the player who completed that box, or nil.
    public var boxOwner: [[Int?]]
    public var turnIndex: Int
    public var isGameOver: Bool
    /// The seed this game was dealt with (for display/debugging only — the
    /// engine's live RNG state isn't persisted, see `DotsAndBoxesEngine`).
    public var seed: UInt64

    public init(gridSize: Int, players: [DotsAndBoxesPlayer], seed: UInt64) {
        self.gridSize = gridSize
        self.players = players
        self.claimedBy = [:]
        self.boxOwner = Array(repeating: Array(repeating: nil, count: gridSize), count: gridSize)
        self.turnIndex = 0
        self.isGameOver = false
        self.seed = seed
    }

    /// Every edge this grid size can hold: `(N+1)·N` horizontal plus
    /// `N·(N+1)` vertical.
    public var totalEdgeCount: Int { 2 * gridSize * (gridSize + 1) }
    public var totalBoxCount: Int { gridSize * gridSize }
}

/// What happened as a result of one `claimEdge` call. The App layer maps
/// these to the felt/paper reactions (draw the stroke, write the initial,
/// flourish the extra turn, flip the turn card, show the scoreboard) — same
/// role `GameEvent` plays for the card engine.
public enum DotsAndBoxesEvent: Equatable, Sendable {
    case edgeClaimed(edge: DotsAndBoxesEdge, by: Int)
    case boxCompleted(box: DotsAndBoxesBox, by: Int)
    /// The mover completed at least one box and goes again — the paper
    /// game's one house rule with real teeth.
    case extraTurn(playerIndex: Int)
    case turnChanged(to: Int)
    case gameOver(winners: [Int])
    case illegalAttempt(reason: String)
}

// MARK: - Engine

/// The reducer. One instance per game, owned by the App layer's
/// `DotsAndBoxesController` (the pass-and-play equivalent of
/// `DiceGameController` — no networking, no phones, just the iPad and
/// whoever's turn it is). `claimEdge` is the single mutating entry point;
/// everything else is read-only geometry/analysis, including the bot.
public final class DotsAndBoxesEngine {
    public private(set) var state: DotsAndBoxesState

    /// Grid sizes the setup overlay offers. The engine itself doesn't
    /// enforce this list — any positive size works — but this is the
    /// contract with the picker.
    public static let allowedGridSizes = [4, 6, 8]

    /// Deterministic bot randomness (tie-breaks among equally-good moves).
    /// Deliberately NOT part of `DotsAndBoxesState`: like `HostEngine`'s
    /// `dealSerial`, it's derived state that only matters within one live
    /// engine's lifetime, not something a save needs to reproduce exactly.
    private var rng: SeededGenerator

    public init(gridSize: Int, players: [DotsAndBoxesPlayer], seed: UInt64) {
        state = DotsAndBoxesState(gridSize: gridSize, players: players, seed: seed)
        rng = SeededGenerator(seed: seed)
    }

    /// Resume from a snapshot (demo harness, or a future save/resume).
    /// The RNG reseeds from the state's original seed — bot play after
    /// resume diverges from an uninterrupted game's, same tradeoff
    /// `HostEngine.init(restoring:)` makes with `dealSerial`.
    public init(restoring state: DotsAndBoxesState) {
        self.state = state
        rng = SeededGenerator(seed: state.seed)
    }

    // MARK: - The one legal move

    /// Draw one pencil line. Returns the events the UI should react to; an
    /// illegal attempt (wrong turn, off-grid, already drawn) changes
    /// nothing and returns a single `.illegalAttempt`.
    @discardableResult
    public func claimEdge(_ edge: DotsAndBoxesEdge, by playerIndex: Int) -> [DotsAndBoxesEvent] {
        guard !state.isGameOver else {
            return [.illegalAttempt(reason: "The game is already over")]
        }
        guard state.players.indices.contains(playerIndex) else {
            return [.illegalAttempt(reason: "No such player")]
        }
        guard playerIndex == state.turnIndex else {
            return [.illegalAttempt(reason: "Not your turn")]
        }
        guard isOnGrid(edge) else {
            return [.illegalAttempt(reason: "That's not a line on this grid")]
        }
        guard state.claimedBy[edge] == nil else {
            return [.illegalAttempt(reason: "That line is already drawn")]
        }

        state.claimedBy[edge] = playerIndex
        var events: [DotsAndBoxesEvent] = [.edgeClaimed(edge: edge, by: playerIndex)]

        // Both boxes on a shared edge can complete in the same stroke — the
        // "multi-box double-claim" case, e.g. the last line inside a 1×2
        // pocket finishes two boxes at once. Both get credited here.
        let completed = adjacentBoxes(to: edge).filter { filledSideCount(of: $0) == 4 && owner(of: $0) == nil }
        for box in completed {
            state.boxOwner[box.row][box.col] = playerIndex
            state.players[playerIndex].score += 1
            events.append(.boxCompleted(box: box, by: playerIndex))
        }

        if state.claimedBy.count == state.totalEdgeCount {
            state.isGameOver = true
            events.append(.gameOver(winners: computeWinners()))
        } else if !completed.isEmpty {
            // Completing a box earns another turn immediately — the turn
            // index does NOT advance, so the same player is asked again.
            events.append(.extraTurn(playerIndex: playerIndex))
        } else {
            state.turnIndex = nextPlayerIndex()
            events.append(.turnChanged(to: state.turnIndex))
        }

        return events
    }

    /// Every line not yet drawn — what the current player (or the setup
    /// picker's legality check) may choose from.
    public func legalEdges() -> [DotsAndBoxesEdge] {
        allEdges().filter { state.claimedBy[$0] == nil }
    }

    private func nextPlayerIndex() -> Int {
        (state.turnIndex + 1) % max(state.players.count, 1)
    }

    private func computeWinners() -> [Int] {
        guard let top = state.players.map(\.score).max() else { return [] }
        return state.players.indices.filter { state.players[$0].score == top }
    }

    // MARK: - Geometry

    private func isOnGrid(_ edge: DotsAndBoxesEdge) -> Bool {
        let n = state.gridSize
        switch edge.orientation {
        case .horizontal: return (0...n).contains(edge.row) && (0..<n).contains(edge.col)
        case .vertical: return (0..<n).contains(edge.row) && (0...n).contains(edge.col)
        }
    }

    private func allEdges() -> [DotsAndBoxesEdge] {
        let n = state.gridSize
        var edges: [DotsAndBoxesEdge] = []
        edges.reserveCapacity(2 * n * (n + 1))
        for row in 0...n {
            for col in 0..<n {
                edges.append(DotsAndBoxesEdge(orientation: .horizontal, row: row, col: col))
            }
        }
        for row in 0..<n {
            for col in 0...n {
                edges.append(DotsAndBoxesEdge(orientation: .vertical, row: row, col: col))
            }
        }
        return edges
    }

    /// The one or two boxes that share `edge` — one on a border edge, two
    /// for an interior one.
    private func adjacentBoxes(to edge: DotsAndBoxesEdge) -> [DotsAndBoxesBox] {
        let n = state.gridSize
        switch edge.orientation {
        case .horizontal:
            var boxes: [DotsAndBoxesBox] = []
            if edge.row - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row - 1, col: edge.col)) } // above
            if edge.row < n { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) } // below
            return boxes
        case .vertical:
            var boxes: [DotsAndBoxesBox] = []
            if edge.col - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col - 1)) } // left
            if edge.col < n { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) } // right
            return boxes
        }
    }

    private func filledSideCount(of box: DotsAndBoxesBox, in claimed: [DotsAndBoxesEdge: Int]? = nil) -> Int {
        let table = claimed ?? state.claimedBy
        return box.edges().filter { table[$0] != nil }.count
    }

    private func owner(of box: DotsAndBoxesBox) -> Int? {
        guard state.boxOwner.indices.contains(box.row), state.boxOwner[box.row].indices.contains(box.col) else {
            return nil
        }
        return state.boxOwner[box.row][box.col]
    }

    // MARK: - Bot

    /// Play the bot's move for `playerIndex` and apply it. No-op (empty
    /// events) if there's nothing legal left or it isn't that seat's turn.
    ///
    /// Heuristic, in priority order — "solid," not perfect:
    /// 1. **Take free boxes.** Any line that completes a box is played;
    ///    among several, the one completing the MOST boxes at once wins
    ///    (the double-box case).
    /// 2. **Play safe.** Among lines that complete nothing, prefer one that
    ///    doesn't hand the opponent a box next turn — i.e. doesn't bring
    ///    any box to 3 filled sides. Chosen at random (seeded) among the
    ///    safe set so bot-vs-bot games don't degenerate into the same
    ///    opening every time.
    /// 3. **Forced to sacrifice.** If every remaining line gives something
    ///    away, open the SHORTEST chain — the one whose forced capture
    ///    cascade (`chainSweepSize`) hands the opponent the fewest boxes.
    ///    This is real chain awareness, not just "avoid 3-siders"; it does
    ///    NOT implement the double-cross (declining the last two boxes of a
    ///    chain to keep turn control) — that's the standard advanced-play
    ///    refinement and is left as a stretch goal, noted rather than
    ///    half-built.
    @discardableResult
    public func performBotMove(for playerIndex: Int) -> [DotsAndBoxesEvent] {
        guard let edge = chooseBotEdge(for: playerIndex) else { return [] }
        return claimEdge(edge, by: playerIndex)
    }

    /// Same selection `performBotMove` plays, exposed separately so tests
    /// can inspect the choice without also mutating the engine.
    func chooseBotEdge(for playerIndex: Int) -> DotsAndBoxesEdge? {
        guard playerIndex == state.turnIndex, !state.isGameOver else { return nil }
        let legal = legalEdges()
        guard !legal.isEmpty else { return nil }

        let capturing = legal.map { edge in (edge, boxesCompleted(ifPlayed: edge).count) }
            .filter { $0.1 > 0 }
        if let bestCount = capturing.map(\.1).max() {
            let best = capturing.filter { $0.1 == bestCount }.map(\.0)
            return pick(among: best)
        }

        let safe = legal.filter { isSafe($0) }
        if !safe.isEmpty {
            return pick(among: safe)
        }

        // Forced: every remaining line gives away at least one box.
        // Minimize the sweep the opponent collects.
        let sweeps = legal.map { ($0, chainSweepSize(openedBy: $0)) }
        guard let minSweep = sweeps.map(\.1).min() else { return pick(among: legal) }
        let shortest = sweeps.filter { $0.1 == minSweep }.map(\.0)
        return pick(among: shortest)
    }

    /// Boxes that would reach 4 filled sides if `edge` were drawn next —
    /// i.e. boxes currently sitting at 3.
    private func boxesCompleted(ifPlayed edge: DotsAndBoxesEdge) -> [DotsAndBoxesBox] {
        adjacentBoxes(to: edge).filter { filledSideCount(of: $0) == 3 }
    }

    /// True when drawing `edge` brings no adjacent box to 3 filled sides —
    /// i.e. it doesn't open a box for the opponent to take next turn. Only
    /// meaningful for non-capturing edges (callers filter those first).
    private func isSafe(_ edge: DotsAndBoxesEdge) -> Bool {
        !adjacentBoxes(to: edge).contains { filledSideCount(of: $0) == 2 }
    }

    /// If `edge` is played, how many boxes fall in the forced capture
    /// cascade that follows — every box pushed to 3 sides gets its last
    /// side claimed immediately, which may push its neighbor to 3, and so
    /// on. This is exactly "how long is the chain this move opens," used
    /// to pick the least-bad sacrifice when no safe move exists.
    private func chainSweepSize(openedBy edge: DotsAndBoxesEdge) -> Int {
        var claimed = state.claimedBy
        claimed[edge] = -1 // sentinel "someone" — the sweeping owner doesn't matter for a count
        var alreadyOwned = Set<DotsAndBoxesBox>()
        for row in 0..<state.gridSize {
            for col in 0..<state.gridSize where state.boxOwner[row][col] != nil {
                alreadyOwned.insert(DotsAndBoxesBox(row: row, col: col))
            }
        }

        var sweepCount = 0
        var changed = true
        while changed {
            changed = false
            for row in 0..<state.gridSize {
                for col in 0..<state.gridSize {
                    let box = DotsAndBoxesBox(row: row, col: col)
                    guard !alreadyOwned.contains(box) else { continue }
                    let filled = filledSideCount(of: box, in: claimed)
                    if filled == 4 {
                        alreadyOwned.insert(box)
                        sweepCount += 1
                        changed = true
                    } else if filled == 3, let missing = box.edges().first(where: { claimed[$0] == nil }) {
                        claimed[missing] = -1
                        alreadyOwned.insert(box)
                        sweepCount += 1
                        changed = true
                    }
                }
            }
        }
        return sweepCount
    }

    /// Deterministic pick from a non-empty candidate list, seeded so a
    /// given game seed always plays the same game.
    private func pick(among candidates: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge {
        guard candidates.count > 1 else { return candidates[0] }
        let index = Int(rng.next() % UInt64(candidates.count))
        return candidates[index]
    }
}
