import Foundation

// Connect Four: table-only pass-and-play, 7 columns x 6 rows with gravity.
// Same house pattern as `QuartoEngine`: pure `ConnectFourRules`, validating
// `ConnectFourEngine`, deterministic `ConnectFourBot` (bitboard search).
//
// GRID: `cells` is row-major, index = row * 7 + col, with ROW 0 AT THE TOP
// (screen order). A dropped disc lands in the LARGEST empty row of its column
// (row 5 is the floor). Cell value = seat (0 or 1) that owns the disc.

// MARK: - Players, phase, action, event

public struct ConnectFourPlayer: Codable, Sendable, Equatable {
    public var name: String
    public var isBot: Bool
    public init(name: String, isBot: Bool) {
        self.name = name
        self.isBot = isBot
    }
}

public enum ConnectFourPhase: Codable, Sendable, Equatable {
    case playing
    case gameOver
}

public enum ConnectFourAction: Codable, Sendable, Equatable {
    case drop(column: Int)
}

public enum ConnectFourEvent: Codable, Sendable, Equatable {
    case gameStarted
    /// `seat` dropped a disc down `column`; it settled at `row` (0 = top, 5 = floor).
    /// `cell` = row * 7 + column, for UIs that animate by flat index.
    case discDropped(seat: Int, column: Int, row: Int, cell: Int)
    case turnChanged(to: Int)
    /// `line` = every cell of the winning run (4 or more, row-major indices,
    /// ordered along the run).
    case gameWon(seat: Int, line: [Int])
    case draw
    case illegalAttempt(seat: Int, reason: String)
}

// MARK: - State

public struct ConnectFourState: Codable, Sendable, Equatable {
    public static let kind = "connectFour"
    public static let columns = 7
    public static let rows = 6

    public var players: [ConnectFourPlayer]  // exactly 2
    public var cells: [Int?]                 // 42, see GRID above
    public var currentPlayer: Int
    public var phase: ConnectFourPhase
    public var winner: Int?                  // nil at .gameOver = draw
    public var winningLine: [Int]?
    public var moveCount: Int                // discs on the board

    public init(players: [ConnectFourPlayer], firstPlayer: Int = 0) {
        self.players = players
        cells = Array(repeating: nil, count: 42)
        currentPlayer = firstPlayer
        phase = .playing
        winner = nil
        winningLine = nil
        moveCount = 0
    }

    public var isGameOver: Bool { phase == .gameOver }
    public var legalColumns: [Int] { phase == .gameOver ? [] : ConnectFourRules.legalColumns(cells: cells) }
    /// The seat that made the first move of this game.
    public var firstPlayer: Int { moveCount % 2 == 0 ? currentPlayer : 1 - currentPlayer }
}

// MARK: - Rules (pure)

public enum ConnectFourRules {
    public static func index(row: Int, column: Int) -> Int { row * 7 + column }

    public static func legalColumns(cells: [Int?]) -> [Int] {
        (0..<7).filter { cells[$0] == nil }
    }

    /// Row a disc dropped in `column` would settle at; nil if the column is full.
    public static func landingRow(cells: [Int?], column: Int) -> Int? {
        guard (0..<7).contains(column) else { return nil }
        var row = 5
        while row >= 0 {
            if cells[row * 7 + column] == nil { return row }
            row -= 1
        }
        return nil
    }

    /// The winning run through `cell` for the disc's owner, if any: all cells
    /// of the longest run (>= 4) in the first direction that qualifies.
    public static func winningLine(cells: [Int?], through cell: Int) -> [Int]? {
        guard let owner = cells[cell] else { return nil }
        let r0 = cell / 7, c0 = cell % 7
        for (dr, dc) in [(0, 1), (1, 0), (1, 1), (1, -1)] {
            var run = [cell]
            var r = r0 + dr, c = c0 + dc
            while (0..<6).contains(r), (0..<7).contains(c), cells[r * 7 + c] == owner {
                run.append(r * 7 + c); r += dr; c += dc
            }
            r = r0 - dr; c = c0 - dc
            while (0..<6).contains(r), (0..<7).contains(c), cells[r * 7 + c] == owner {
                run.insert(r * 7 + c, at: 0); r -= dr; c -= dc
            }
            if run.count >= 4 { return run }
        }
        return nil
    }

    /// Pure reducer step. Caller guarantees the column is legal.
    public static func apply(_ action: ConnectFourAction, to state: ConnectFourState) -> ConnectFourState {
        guard case .drop(let column) = action, let row = landingRow(cells: state.cells, column: column) else { return state }
        var next = state
        let cell = row * 7 + column
        next.cells[cell] = state.currentPlayer
        next.moveCount += 1
        if let line = winningLine(cells: next.cells, through: cell) {
            next.phase = .gameOver
            next.winner = state.currentPlayer
            next.winningLine = line
        } else if next.moveCount == 42 {
            next.phase = .gameOver
        } else {
            next.currentPlayer = 1 - state.currentPlayer
        }
        return next
    }
}

// MARK: - Engine

public final class ConnectFourEngine {
    public static let kind = ConnectFourState.kind

    public private(set) var state: ConnectFourState

    public init(players: [ConnectFourPlayer], firstPlayer: Int = 0) {
        state = ConnectFourState(players: players, firstPlayer: firstPlayer)
    }

    public init(restoring state: ConnectFourState) {
        self.state = state
    }

    @discardableResult
    public func restart(players: [ConnectFourPlayer], firstPlayer: Int = 0) -> [ConnectFourEvent] {
        state = ConnectFourState(players: players, firstPlayer: firstPlayer)
        return [.gameStarted]
    }

    @discardableResult
    public func apply(_ action: ConnectFourAction, from seat: Int) -> [ConnectFourEvent] {
        guard case .drop(let column) = action else {
            return [.illegalAttempt(seat: seat, reason: "Unknown action")]
        }
        guard state.phase == .playing else {
            return [.illegalAttempt(seat: seat, reason: "The game is over")]
        }
        guard seat == state.currentPlayer else {
            return [.illegalAttempt(seat: seat, reason: "Not your turn")]
        }
        guard let row = ConnectFourRules.landingRow(cells: state.cells, column: column) else {
            return [.illegalAttempt(seat: seat, reason: "That column is full")]
        }
        state = ConnectFourRules.apply(action, to: state)
        var events: [ConnectFourEvent] = [.discDropped(seat: seat, column: column, row: row, cell: row * 7 + column)]
        if state.phase == .gameOver {
            if let w = state.winner, let line = state.winningLine {
                events.append(.gameWon(seat: w, line: line))
            } else {
                events.append(.draw)
            }
        } else {
            events.append(.turnChanged(to: state.currentPlayer))
        }
        return events
    }
}

// MARK: - Bot

/// Negamax + alpha-beta on bitboards, iterative deepening to `maxDepth` (8),
/// bounded by a NODE budget (never the clock), so a decision is a pure
/// function of (state, seed, budget). Safety rules, in order: (1) empty board
/// -> centre column; (2) take an immediate win; (3) block an immediate loss
/// (inside the search a double threat is a lost position and a single threat
/// forces the reply). Heuristic: 4-windows (open twos/threes), centre
/// control, and odd/even threat parity (first player wants odd-row threats,
/// second player even-row, rows counted 1-based from the floor).
public enum ConnectFourBot {
    public static let defaultMaxDepth = 8
    public static let defaultNodeBudget = 150_000

    public struct Decision {
        public var action: ConnectFourAction
        public var nodes: Int
        public var depthReached: Int
    }

    public static func decide(state: ConnectFourState, seed: UInt64,
                              maxDepth: Int = defaultMaxDepth,
                              nodeBudget: Int = defaultNodeBudget) -> ConnectFourAction {
        decideDetailed(state: state, seed: seed, maxDepth: maxDepth, nodeBudget: nodeBudget).action
    }

    public static func decideDetailed(state: ConnectFourState, seed: UInt64,
                                      maxDepth: Int = defaultMaxDepth,
                                      nodeBudget: Int = defaultNodeBudget) -> Decision {
        precondition(state.phase == .playing, "ConnectFourBot.decide called on a finished game")
        let legal = state.legalColumns
        precondition(!legal.isEmpty, "ConnectFourBot.decide: no legal columns")
        if state.moveCount == 0 { return Decision(action: .drop(column: 3), nodes: 0, depthReached: 0) }

        let s = Search(state: state, budget: nodeBudget)
        // (2) immediate win, (3) forced block.
        let me = state.currentPlayer
        for col in order where legal.contains(col) {
            s.play(col)
            let won = s.hasWon(s.bb[me])
            s.undo(col)
            if won { return Decision(action: .drop(column: col), nodes: 0, depthReached: 0) }
        }
        let opp = 1 - me
        for col in order where legal.contains(col) {
            let bit = UInt64(1) << UInt64(s.heights[col])
            if s.hasWon(s.bb[opp] | bit) { return Decision(action: .drop(column: col), nodes: 0, depthReached: 0) }
        }
        if legal.count == 1 { return Decision(action: .drop(column: legal[0]), nodes: 0, depthReached: 0) }

        var rng = SeededGenerator(seed: seed &+ UInt64(state.moveCount) &* 0x9E37_79B9_7F4A_7C15)
        var rootOrder = order.filter { legal.contains($0) }
        var chosen = rootOrder[0]
        var depthReached = 0
        for depth in 1...max(1, maxDepth) {
            s.enforce = depth > 1
            s.aborted = false
            var bestScore = Int.min
            var tied: [Int] = []
            var scored: [Int] = []
            for col in rootOrder {
                s.play(col)
                let alpha = bestScore == Int.min ? -Search.inf : bestScore - 1
                let score = -s.negamax(depth: depth - 1, alpha: -Search.inf, beta: -alpha)
                s.undo(col)
                if s.aborted { break }
                scored.append(col)
                if score > bestScore { bestScore = score; tied = [col] }
                else if score == bestScore { tied.append(col) }
            }
            if s.aborted { break }
            depthReached = depth
            chosen = tied.count == 1 ? tied[0] : tied[Int(rng.next() % UInt64(tied.count))]
            rootOrder = [chosen] + scored.filter { $0 != chosen }
            if abs(bestScore) >= Search.win - 64 { break } // forced result found
        }
        return Decision(action: .drop(column: chosen), nodes: s.nodes, depthReached: depthReached)
    }

    private static let order = [3, 2, 4, 1, 5, 0, 6]

    // MARK: bitboard search

    private final class Search {
        static let inf = 1_000_000
        static let win = 100_000
        static let boardMask: UInt64 = (0..<7).reduce(0) { $0 | (UInt64(0b111111) << UInt64($1 * 7)) }
        static let oddRows: UInt64 = (0..<7).reduce(0) { $0 | (UInt64(0b010101) << UInt64($1 * 7)) }   // rows 1,3,5 from floor
        static let evenRows: UInt64 = (0..<7).reduce(0) { $0 | (UInt64(0b101010) << UInt64($1 * 7)) }
        static let centreCol: UInt64 = UInt64(0b111111) << 21
        static let windows: [UInt64] = {
            var w: [UInt64] = []
            func bit(_ c: Int, _ r: Int) -> UInt64 { UInt64(1) << UInt64(c * 7 + r) }
            for r in 0..<6 { for c in 0..<4 { w.append((0..<4).reduce(0) { $0 | bit(c + $1, r) }) } }
            for c in 0..<7 { for r in 0..<3 { w.append((0..<4).reduce(0) { $0 | bit(c, r + $1) }) } }
            for c in 0..<4 { for r in 0..<3 { w.append((0..<4).reduce(0) { $0 | bit(c + $1, r + $1) }) } }
            for c in 0..<4 { for r in 3..<6 { w.append((0..<4).reduce(0) { $0 | bit(c + $1, r - $1) }) } }
            return w
        }()

        var bb: [UInt64] = [0, 0]
        var heights = [Int](repeating: 0, count: 7)  // next free bit per column
        var turn: Int
        var moves: Int
        let rootMoves: Int
        let firstPlayer: Int
        var nodes = 0
        let budget: Int
        var enforce = false
        var aborted = false
        private let order = ConnectFourBot.order

        init(state: ConnectFourState, budget: Int) {
            self.budget = budget
            turn = state.currentPlayer
            moves = state.moveCount
            rootMoves = state.moveCount
            firstPlayer = state.firstPlayer
            for c in 0..<7 {
                heights[c] = c * 7
                for r in stride(from: 5, through: 0, by: -1) {
                    if let owner = state.cells[r * 7 + c] {
                        bb[owner] |= UInt64(1) << UInt64(c * 7 + (5 - r))
                        heights[c] += 1
                    }
                }
            }
        }

        func play(_ col: Int) {
            bb[turn] |= UInt64(1) << UInt64(heights[col])
            heights[col] += 1
            turn = 1 - turn
            moves += 1
        }

        func undo(_ col: Int) {
            turn = 1 - turn
            moves -= 1
            heights[col] -= 1
            bb[turn] &= ~(UInt64(1) << UInt64(heights[col]))
        }

        func hasWon(_ b: UInt64) -> Bool {
            var m = b & (b >> 6); if m & (m >> 12) != 0 { return true }
            m = b & (b >> 7); if m & (m >> 14) != 0 { return true }
            m = b & (b >> 8); if m & (m >> 16) != 0 { return true }
            m = b & (b >> 1); return m & (m >> 2) != 0
        }

        /// Empty cells that would complete four for `p` (reachable or not).
        func winningCells(_ p: UInt64, _ mask: UInt64) -> UInt64 {
            var r = (p << 1) & (p << 2) & (p << 3)
            for shift in [UInt64(7), 6, 8] {
                var t = (p << shift) & (p << (2 * shift))
                r |= t & (p << (3 * shift))
                r |= t & (p >> shift)
                t = (p >> shift) & (p >> (2 * shift))
                r |= t & (p << shift)
                r |= t & (p >> (3 * shift))
            }
            return r & (Search.boardMask ^ mask)
        }

        func playableMask() -> UInt64 {
            var m: UInt64 = 0
            for c in 0..<7 where heights[c] < c * 7 + 6 { m |= UInt64(1) << UInt64(heights[c]) }
            return m
        }

        func negamax(depth: Int, alpha: Int, beta: Int) -> Int {
            if enforce && nodes >= budget { aborted = true; return 0 }
            nodes += 1
            if moves == 42 { return 0 }
            let ply = moves - rootMoves
            let me = bb[turn], opp = bb[1 - turn]
            let mask = me | opp
            let playable = playableMask()
            let myWins = winningCells(me, mask)
            if myWins & playable != 0 { return Search.win - ply }
            let oppWins = winningCells(opp, mask) & playable
            var forced: UInt64 = 0
            if oppWins != 0 {
                if oppWins & (oppWins &- 1) != 0 { return -(Search.win - ply - 1) } // double threat
                forced = oppWins
            }
            if moves + 1 == 42 { return 0 }
            if depth == 0 { return evaluate(me: me, opp: opp, myWins: myWins, oppWins: winningCells(opp, mask)) }

            var alpha = alpha
            var best = -Search.inf
            for col in order {
                if heights[col] >= col * 7 + 6 { continue }
                let bit = UInt64(1) << UInt64(heights[col])
                if forced != 0 && bit != forced { continue }
                play(col)
                let score = -negamax(depth: depth - 1, alpha: -beta, beta: -alpha)
                undo(col)
                if aborted { return 0 }
                if score > best { best = score }
                if best > alpha { alpha = best }
                if alpha >= beta { break }
            }
            return best
        }

        /// From the view of the side to move (`me`).
        func evaluate(me: UInt64, opp: UInt64, myWins: UInt64, oppWins: UInt64) -> Int {
            var score = 0
            for w in Search.windows {
                let m = (me & w).nonzeroBitCount, o = (opp & w).nonzeroBitCount
                if o == 0 { if m == 3 { score += 5 } else if m == 2 { score += 2 } }
                else if m == 0 { if o == 3 { score -= 5 } else if o == 2 { score -= 2 } }
            }
            score += ((me & Search.centreCol).nonzeroBitCount - (opp & Search.centreCol).nonzeroBitCount) * 3
            // Threat parity. Rows are 1-based from the floor: bit position % 7 == 0 is row 1 (odd).
            let iAmFirst = turn == firstPlayer
            func parity(_ wins: UInt64, first: Bool) -> Int {
                let good = first ? Search.oddRows : Search.evenRows
                let bad = first ? Search.evenRows : Search.oddRows
                return (wins & good).nonzeroBitCount * 12 + (wins & bad).nonzeroBitCount * 3
            }
            score += parity(myWins, first: iAmFirst)
            score -= parity(oppWins, first: !iAmFirst)
            return score
        }
    }
}
