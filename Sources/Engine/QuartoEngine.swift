import Foundation

// Quarto: table-only pass-and-play (no MultipeerConnectivity, no seats
// array, no hands) — the two humans at the iPad hand a physical piece back
// and forth, so the engine only needs to track whose turn it is, not who's
// holding which phone. Deliberately standalone from GameState/HostEngine
// (this game has no cards, no dealing, no rounds) — every type here is
// prefixed `Quarto` and lives only in this file, wired up later by
// `Sources/App/BoardGames/Quarto/QuartoView.swift`.

// MARK: - Piece

/// One binary attribute a Quarto piece carries. Every piece has exactly
/// one value (true/false) for each of the four.
public enum QuartoAttribute: Int, CaseIterable, Codable, Sendable {
    case height, shade, shape, fill

    /// The word used in the win callout for this attribute at `valueIsTrue`
    /// — e.g. `.height.label(valueIsTrue: true)` is "tall". Pair this with
    /// the actual winning piece's value; `true` doesn't always mean the
    /// "showier" word (`.fill == true` is hollow, the less common piece).
    public func label(valueIsTrue: Bool) -> String {
        switch self {
        case .height: return valueIsTrue ? "tall" : "short"
        case .shade: return valueIsTrue ? "dark" : "light"
        case .shape: return valueIsTrue ? "round" : "square"
        case .fill: return valueIsTrue ? "hollow" : "solid"
        }
    }
}

/// One of the 16 unique Quarto pieces. `id` (0...15) IS the piece — each of
/// its 4 bits is one attribute, so every attribute combination exists
/// exactly once and `QuartoPiece.all` is just every 4-bit value.
public struct QuartoPiece: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: Int

    public init(id: Int) {
        precondition((0..<16).contains(id), "QuartoPiece id must be 0...15")
        self.id = id
    }

    public var isTall: Bool { id & 0b0001 != 0 }
    public var isDark: Bool { id & 0b0010 != 0 }
    public var isRound: Bool { id & 0b0100 != 0 }
    public var isHollow: Bool { id & 0b1000 != 0 }

    public func value(for attribute: QuartoAttribute) -> Bool {
        switch attribute {
        case .height: return isTall
        case .shade: return isDark
        case .shape: return isRound
        case .fill: return isHollow
        }
    }

    public static let all: [QuartoPiece] = (0..<16).map(QuartoPiece.init(id:))
}

// MARK: - Board geometry

/// The board's 16 cells (row-major, `row * 4 + col`) and the lines a
/// placement can complete: 4 rows, 4 columns, 2 main diagonals, and
/// (variant only) the 9 overlapping 2x2 squares.
public enum QuartoLines {
    public static let rows: [[Int]] = (0..<4).map { r in (0..<4).map { c in r * 4 + c } }
    public static let columns: [[Int]] = (0..<4).map { c in (0..<4).map { r in r * 4 + c } }
    public static let diagonals: [[Int]] = [[0, 5, 10, 15], [3, 6, 9, 12]]
    /// Top-left corner of every 2x2 block: (row, col) for row/col in 0...2.
    public static let squares: [[Int]] = (0..<3).flatMap { r in
        (0..<3).map { c -> [Int] in
            let tl = r * 4 + c
            return [tl, tl + 1, tl + 4, tl + 5]
        }
    }

    public static func lines(includeSquares: Bool) -> [[Int]] {
        includeSquares ? rows + columns + diagonals + squares : rows + columns + diagonals
    }
}

// MARK: - Player, phase, action, event

public struct QuartoPlayer: Codable, Sendable, Equatable {
    public var name: String
    public var isBot: Bool
    public init(name: String, isBot: Bool) {
        self.name = name
        self.isBot = isBot
    }
}

public enum QuartoPhase: Codable, Sendable, Equatable {
    /// `currentPlayer` must choose a remaining piece and hand it to the
    /// opponent. The very first phase of a fresh game — player 0 opens by
    /// giving a piece with nothing yet on the board.
    case selecting
    /// `currentPlayer` must place `heldPiece` on any empty cell.
    case placing
    case gameOver
}

/// One legal move. `from` in `apply(_:from:)` is checked against
/// `state.currentPlayer` — same silent-reject-on-mismatch convention as
/// the card engine's `HostEngine.apply`.
public enum QuartoAction: Codable, Sendable, Equatable {
    case selectPiece(Int)
    case placePiece(Int, at: Int)
}

public enum QuartoEvent: Codable, Sendable, Equatable {
    case gameStarted
    /// `by` gave `piece` to the opponent.
    case pieceSelected(by: Int, piece: Int)
    /// `by` placed `piece` at `cell`.
    case piecePlaced(by: Int, piece: Int, cell: Int)
    case gameWon(seat: Int, line: [Int], attributes: [QuartoAttribute])
    case draw
    case illegalAttempt(seat: Int, reason: String)
}

// MARK: - State

public struct QuartoState: Codable, Sendable, Equatable {
    public var players: [QuartoPlayer] // exactly 2, index 0 and 1
    public var board: [Int?]           // 16 cells, row-major; value = piece id
    public var remainingPieces: [Int]  // piece ids neither on the board nor held
    public var heldPiece: Int?         // the piece `currentPlayer` must place (phase == .placing)
    public var currentPlayer: Int      // 0 or 1 — whoever owes the next action
    public var phase: QuartoPhase
    public var use2x2Variant: Bool
    public var winner: Int?
    public var winningLine: [Int]?
    public var winningAttributes: [QuartoAttribute]
    /// Placements so far — doubles as a stable "how deep is this game"
    /// counter for the bot's win-sooner/lose-later tiebreak.
    public var moveCount: Int

    public init(players: [QuartoPlayer], use2x2Variant: Bool = false, firstPlayer: Int = 0) {
        self.players = players
        board = Array(repeating: nil, count: 16)
        remainingPieces = Array(0..<16)
        heldPiece = nil
        currentPlayer = firstPlayer
        phase = .selecting
        self.use2x2Variant = use2x2Variant
        winner = nil
        winningLine = nil
        winningAttributes = []
        moveCount = 0
    }

    public var emptyCells: [Int] { (0..<16).filter { board[$0] == nil } }
    public var isBoardFull: Bool { board.allSatisfy { $0 != nil } }
    /// Pieces a human at `legalSelections` may hand over — unlike the bot,
    /// a human is free to (accidentally) hand over a losing piece.
    public var legalSelections: [Int] { remainingPieces }
    public var legalCells: [Int] { emptyCells }
}

// MARK: - Rules (pure, stateless — win detection and the reducer step)

public enum QuartoRules {
    /// Attributes shared by all 4 pieces in `cells`. Empty if any cell is
    /// still empty, or if the four pieces share nothing.
    public static func sharedAttributes(_ cells: [Int], board: [Int?]) -> [QuartoAttribute] {
        guard cells.count == 4 else { return [] }
        var pieces: [QuartoPiece] = []
        pieces.reserveCapacity(4)
        for cell in cells {
            guard let id = board[cell] else { return [] }
            pieces.append(QuartoPiece(id: id))
        }
        return QuartoAttribute.allCases.filter { attribute in
            let first = pieces[0].value(for: attribute)
            return pieces.allSatisfy { $0.value(for: attribute) == first }
        }
    }

    /// True when the four cells are all filled and share at least one
    /// attribute. Bitmask form of `sharedAttributes(...).isEmpty == false`:
    /// the AND of the ids has a 1-bit where every piece has the attribute
    /// set, and the NOR has a 1-bit where every piece has it clear. No
    /// allocation, which matters because the bot calls this millions of times.
    @inline(__always)
    static func lineIsComplete(_ line: [Int], board: [Int?]) -> Bool {
        var all = 0xF, any = 0
        for cell in line {
            guard let id = board[cell] else { return false }
            all &= id
            any |= id
        }
        return (all | (~any & 0xF)) != 0
    }

    /// The first complete, attribute-sharing line found on `board`, if any.
    /// Checking all lines (at most 19, 4 cells each) every call is cheap
    /// enough at this board size that there's no need to scope the search
    /// to lines touching the just-placed cell.
    public static func winningLine(board: [Int?], includeSquares: Bool) -> (line: [Int], attributes: [QuartoAttribute])? {
        for line in QuartoLines.lines(includeSquares: includeSquares) where lineIsComplete(line, board: board) {
            return (line, sharedAttributes(line, board: board))
        }
        return nil
    }

    /// Empty cells where placing `piece` on `board` would complete a line —
    /// "is handing over this piece safe?" is `winningPlacements(...).isEmpty`.
    public static func winningPlacements(piece: Int, board: [Int?], includeSquares: Bool) -> [Int] {
        var result: [Int] = []
        var trial = board
        let lines = QuartoLines.lines(includeSquares: includeSquares)
        for cell in 0..<16 where board[cell] == nil {
            trial[cell] = piece
            // Only a line through `cell` can newly complete.
            for line in lines where line.contains(cell) && lineIsComplete(line, board: trial) {
                result.append(cell)
                break
            }
            trial[cell] = nil
        }
        return result
    }

    /// Pure reducer step: applies a *legal* action (callers validate first)
    /// and returns the resulting state. No side effects, no event
    /// construction — `QuartoEngine` wraps this with legality checks and
    /// events for the UI; `QuartoBot`'s search calls it directly on
    /// throwaway states thousands of times per decision.
    public static func apply(_ action: QuartoAction, to state: QuartoState) -> QuartoState {
        var next = state
        switch action {
        case .selectPiece(let piece):
            next.remainingPieces.removeAll { $0 == piece }
            next.heldPiece = piece
            next.currentPlayer = 1 - next.currentPlayer
            next.phase = .placing

        case .placePiece(let piece, let cell):
            next.board[cell] = piece
            next.heldPiece = nil
            next.moveCount += 1
            if let win = winningLine(board: next.board, includeSquares: next.use2x2Variant) {
                next.phase = .gameOver
                next.winner = next.currentPlayer
                next.winningLine = win.line
                next.winningAttributes = win.attributes
            } else if next.remainingPieces.isEmpty {
                next.phase = .gameOver
                next.winner = nil
            } else {
                next.phase = .selecting // same player: they placed, now they give
            }
        }
        return next
    }

    /// "Four tall, four dark!" — every attribute shared by the winning
    /// line, worded from the actual winning piece's values.
    public static func winCallout(attributes: [QuartoAttribute], line: [Int], board: [Int?]) -> String {
        guard let firstCell = line.first, let pieceID = board[firstCell] else { return "Four in a row!" }
        let piece = QuartoPiece(id: pieceID)
        let labels = attributes.map { "four " + $0.label(valueIsTrue: piece.value(for: $0)) }
        return labels.joined(separator: ", ").capitalizedFirst + "!"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Engine (validates + emits events; QuartoBot bypasses this and
// drives QuartoRules.apply directly for speed)

/// The reducer players actually go through. Illegal or out-of-turn actions
/// are silently rejected — one `.illegalAttempt` event, state unchanged —
/// the same convention `HostEngine` uses for the card games.
public final class QuartoEngine {
    public private(set) var state: QuartoState

    public init(players: [QuartoPlayer], use2x2Variant: Bool = false, firstPlayer: Int = 0) {
        state = QuartoState(players: players, use2x2Variant: use2x2Variant, firstPlayer: firstPlayer)
    }

    public init(restoring state: QuartoState) {
        self.state = state
    }

    @discardableResult
    public func restart(players: [QuartoPlayer], use2x2Variant: Bool, firstPlayer: Int = 0) -> [QuartoEvent] {
        state = QuartoState(players: players, use2x2Variant: use2x2Variant, firstPlayer: firstPlayer)
        return [.gameStarted]
    }

    @discardableResult
    public func apply(_ action: QuartoAction, from seat: Int) -> [QuartoEvent] {
        switch action {
        case .selectPiece(let piece): return applySelect(piece, from: seat)
        case .placePiece(let piece, let cell): return applyPlace(piece, at: cell, from: seat)
        }
    }

    private func applySelect(_ piece: Int, from seat: Int) -> [QuartoEvent] {
        guard state.phase == .selecting, state.currentPlayer == seat,
              state.remainingPieces.contains(piece) else {
            return [.illegalAttempt(seat: seat, reason: "Not a legal piece to hand over")]
        }
        state = QuartoRules.apply(.selectPiece(piece), to: state)
        return [.pieceSelected(by: seat, piece: piece)]
    }

    private func applyPlace(_ piece: Int, at cell: Int, from seat: Int) -> [QuartoEvent] {
        guard state.phase == .placing, state.currentPlayer == seat,
              state.heldPiece == piece, (0..<16).contains(cell), state.board[cell] == nil else {
            return [.illegalAttempt(seat: seat, reason: "Not a legal placement")]
        }
        state = QuartoRules.apply(.placePiece(piece, at: cell), to: state)
        var events: [QuartoEvent] = [.piecePlaced(by: seat, piece: piece, cell: cell)]
        if state.phase == .gameOver {
            if let winner = state.winner, let line = state.winningLine {
                events.append(.gameWon(seat: winner, line: line, attributes: state.winningAttributes))
            } else {
                events.append(.draw)
            }
        }
        return events
    }
}

// MARK: - Bot

/// Minimax with alpha-beta pruning over individual actions (select and
/// place are each one ply). Two things keep a full search tractable:
///
/// 1. **Hard safety filter on selections**: a select node's candidate set
///    is never "every remaining piece" — it's every piece that does NOT
///    let the opponent win immediately (checked directly via
///    `QuartoRules.winningPlacements`), falling back to the full remaining
///    set only when every piece is unsafe (a forced loss is coming no
///    matter what's handed over). This alone — never gift a game-ending
///    piece unless there's no other option — is the single highest-value
///    thing a Quarto bot can do; the search on top of it is polish.
/// 2. **Beam width**: once a node's legal-move count exceeds `beamWidth`,
///    only the top-scoring candidates (by a cheap 1-ply heuristic) are
///    expanded. Late-game, legal-move counts naturally fall below the beam
///    and search becomes exact; only the early/mid game — where the exact
///    move barely matters by symmetry — is approximated.
///
/// Depth is measured in **turns** (`targetTurns`, default 3): one turn is
/// two atomic plies (a select and a place), except the game's opening
/// ply, which is select-only. `decide` iterative-deepens from 2 plies up
/// to `targetTurns * 2`, always keeping the last depth's completed result,
/// so a slow device or a wide position still returns *something* well
/// inside `timeLimit` instead of blowing past it.
public enum QuartoBot {
    /// Wall-clock is NOT used to bound the search (that made the chosen move
    /// depend on CPU load). The cap is a deterministic node budget: the
    /// number of search nodes expanded across ALL iterative-deepening
    /// passes. Measured on a Mac (loaded): ~2000 nodes is ~15-30ms in -O and
    /// ~0.4s average / ~0.8s worst unoptimized (Debug); a full depth-6 pass
    /// never exceeds ~10.5k nodes, so 2000 always completes depth 4 and
    /// usually depth 5-6. The same state + seed always searches exactly the
    /// same tree and so yields the same move under any CPU load.
    public static let defaultNodeBudget = 2000
    /// Kept only as a generous SANITY ceiling for tests and callers; it does
    /// not influence the search.
    public static let wallClockSanityLimit: TimeInterval = 2.0
    private static let beamWidth = 6
    public static let targetTurns = 3
    private static let winScore = 100_000

    /// Mutable per-decision search bookkeeping.
    private struct Budget {
        var nodes = 0
        let limit: Int
        var exhausted: Bool { nodes >= limit }
    }

    /// `seed` makes the choice reproducible (tie-breaks and beam order are
    /// seed-derived, never `Bool.random()`/`Array.shuffled()` off the
    /// system RNG) — the same state + seed always yields the same move, so
    /// bot-vs-bot games and regression tests can replay exactly.
    ///
    /// `maxTurns` lets a personality shave or add search depth (default 3
    /// turns = 6 plies); the node budget still caps the real cost.
    public static func decide(state: QuartoState, seed: UInt64,
                              nodeBudget: Int = defaultNodeBudget,
                              maxTurns: Int = targetTurns) -> QuartoAction {
        decideCounting(state: state, seed: seed, nodeBudget: nodeBudget, maxTurns: maxTurns).action
    }

    /// Same as `decide`, also reporting nodes spent and the deepest fully
    /// completed depth (for tests / tuning).
    public static func decideCounting(state: QuartoState, seed: UInt64,
                                      nodeBudget: Int = defaultNodeBudget,
                                      maxTurns: Int = targetTurns)
        -> (action: QuartoAction, nodes: Int, depth: Int) {
        precondition(state.phase != .gameOver, "QuartoBot.decide called on a finished game")
        let maximizingPlayer = state.currentPlayer

        var budget = Budget(limit: max(nodeBudget, 1))
        var bestAction: QuartoAction?
        var completedDepth = 0
        var depth = 2
        let maxDepth = max(1, maxTurns) * 2
        while depth <= maxDepth {
            // Fresh RNG per pass so a pass's move ordering never depends on
            // how many nodes earlier passes consumed.
            var rng = SeededGenerator(seed: seed &+ UInt64(state.moveCount) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(depth))
            let result = search(state: state, depth: depth, alpha: -winScore * 10, beta: winScore * 10,
                                maximizingPlayer: maximizingPlayer, budget: &budget, rng: &rng)
            // A pass cut short by the budget is partial and unreliable: keep
            // the last COMPLETED pass (the shallowest pass always counts so
            // there is always an answer).
            if budget.exhausted && bestAction != nil { break }
            if let action = result.action { bestAction = action; completedDepth = depth }
            if budget.exhausted { break }
            depth += 1
        }
        // candidateActions is never empty for a non-gameOver state, so this
        // fallback is just defensive — search always finds SOME action.
        return (bestAction ?? candidateActions(state: state).first!, budget.nodes, completedDepth)
    }

    // MARK: search

    private static func search(state: QuartoState, depth: Int, alpha: Int, beta: Int,
                               maximizingPlayer: Int, budget: inout Budget,
                               rng: inout SeededGenerator) -> (score: Int, action: QuartoAction?) {
        budget.nodes += 1
        if state.phase == .gameOver || depth == 0 {
            return (evaluate(state: state, maximizingPlayer: maximizingPlayer, plyBudget: depth), nil)
        }
        let candidates = orderedCandidates(state: state, limit: beamWidth, rng: &rng)
        guard !candidates.isEmpty else {
            return (evaluate(state: state, maximizingPlayer: maximizingPlayer, plyBudget: depth), nil)
        }

        let maximizing = state.currentPlayer == maximizingPlayer
        var bestScore = maximizing ? Int.min : Int.max
        var bestAction: QuartoAction?
        var alpha = alpha, beta = beta

        for action in candidates {
            let child = QuartoRules.apply(action, to: state)
            let childResult = search(state: child, depth: depth - 1, alpha: alpha, beta: beta,
                                     maximizingPlayer: maximizingPlayer, budget: &budget, rng: &rng)
            if maximizing {
                if bestAction == nil || childResult.score > bestScore {
                    bestScore = childResult.score; bestAction = action
                }
                alpha = max(alpha, bestScore)
            } else {
                if bestAction == nil || childResult.score < bestScore {
                    bestScore = childResult.score; bestAction = action
                }
                beta = min(beta, bestScore)
            }
            if beta <= alpha { break }
            if budget.exhausted { break }
        }
        return (bestScore, bestAction)
    }

    /// Every legal action from `state`, with the select-phase safety filter
    /// applied: unsafe pieces (ones that let the opponent win on the spot)
    /// are excluded whenever at least one safe piece exists.
    private static func candidateActions(state: QuartoState) -> [QuartoAction] {
        switch state.phase {
        case .selecting:
            let remaining = state.remainingPieces
            let safe = remaining.filter {
                QuartoRules.winningPlacements(piece: $0, board: state.board, includeSquares: state.use2x2Variant).isEmpty
            }
            let pool = safe.isEmpty ? remaining : safe // forced: every piece loses, pick the least-bad below
            return pool.map { .selectPiece($0) }
        case .placing:
            guard let held = state.heldPiece else { return [] }
            return state.emptyCells.map { .placePiece(held, at: $0) }
        case .gameOver:
            return []
        }
    }

    /// Beam-limits `candidateActions` to `limit` by a cheap 1-ply score,
    /// deterministically shuffled (via the seeded `rng`) so ties and
    /// under-the-limit sets don't always explore in the same board order.
    private static func orderedCandidates(state: QuartoState, limit: Int,
                                          rng: inout SeededGenerator) -> [QuartoAction] {
        let actions = candidateActions(state: state).shuffled(using: &rng)
        guard actions.count > limit else { return actions }
        return actions
            .map { ($0, quickScore($0, state: state)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// A cheap, non-recursive score used only to pick which candidates make
    /// the beam — winning placements sort first; everything else is a
    /// rough "how many still-alive lines does this touch" count.
    private static func quickScore(_ action: QuartoAction, state: QuartoState) -> Int {
        switch action {
        case .placePiece(let piece, let cell):
            var trial = state.board
            trial[cell] = piece
            if QuartoRules.winningLine(board: trial, includeSquares: state.use2x2Variant) != nil { return 1_000_000 }
            return QuartoLines.lines(includeSquares: state.use2x2Variant)
                .filter { $0.contains(cell) }
                .reduce(0) { partial, line in
                    partial + (QuartoRules.sharedAttributesIgnoringEmptyCells(line, board: trial).isEmpty ? 0 : 1)
                }
        case .selectPiece:
            return 0 // the safety filter already did the real work; explore in seeded-shuffled order
        }
    }

    // MARK: evaluation

    /// `plyBudget` is the remaining search depth AT the terminal/cutoff
    /// node — used only to prefer a faster win / slower loss among
    /// otherwise-equal terminal scores (a win found with more depth left
    /// happened sooner from the root).
    private static func evaluate(state: QuartoState, maximizingPlayer: Int, plyBudget: Int) -> Int {
        if state.phase == .gameOver {
            guard let winner = state.winner else { return 0 } // draw
            return winner == maximizingPlayer ? winScore + plyBudget : -(winScore + plyBudget)
        }

        // Line-threat counting: 2- and 3-filled lines that still share an
        // attribute are "alive" — weighted steeply toward 3 (one placement
        // from winning). This danger is symmetric (pieces aren't owned by
        // either player), so its SIGN depends on who's on the hook next:
        // the player about to SELECT carries the risk (they might be
        // forced to hand over a winner); the player about to PLACE is
        // comparatively safe (their held piece already passed the safety
        // filter, barring a forced hand-off).
        var danger = 0
        for line in QuartoLines.lines(includeSquares: state.use2x2Variant) {
            let filled = line.compactMap { state.board[$0] }
            guard filled.count == 2 || filled.count == 3 else { continue }
            let pieces = filled.map(QuartoPiece.init(id:))
            let alive = QuartoAttribute.allCases.contains { attribute in
                let first = pieces[0].value(for: attribute)
                return pieces.allSatisfy { $0.value(for: attribute) == first }
            }
            guard alive else { continue }
            danger += filled.count == 3 ? 6 : 2
        }

        let dangerFallsOn = state.phase == .selecting ? state.currentPlayer : (1 - state.currentPlayer)
        return dangerFallsOn == maximizingPlayer ? -danger : danger
    }
}

extension QuartoRules {
    /// Like `sharedAttributes`, but doesn't require all 4 cells filled —
    /// used by the bot's quick-score heuristic on partially-filled lines.
    /// Returns the attributes shared by whichever pieces ARE placed in
    /// `cells`; empty if there are no filled cells or they share nothing.
    fileprivate static func sharedAttributesIgnoringEmptyCells(_ cells: [Int], board: [Int?]) -> [QuartoAttribute] {
        let pieces = cells.compactMap { board[$0] }.map(QuartoPiece.init(id:))
        guard let first = pieces.first else { return [] }
        return QuartoAttribute.allCases.filter { attribute in
            let firstValue = first.value(for: attribute)
            return pieces.allSatisfy { $0.value(for: attribute) == firstValue }
        }
    }
}
