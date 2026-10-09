import Foundation

// Mancala (Kalah rules): table-only pass-and-play, two players at the iPad.
// Same house pattern as `QuartoEngine`: a pure, stateless `MancalaRules`
// reducer, a thin validating `MancalaEngine` that emits UI events, and a
// deterministic `MancalaBot` that drives the rules directly. No dependency on
// GameState/HostEngine; every type is prefixed `Mancala`.
//
// BOARD LAYOUT (absolute indices 0...13, the ring sowing travels around):
//   0...5   seat 0's pits   (left -> right along the BOTTOM row)
//   6       seat 0's store  (right end)
//   7...12  seat 1's pits   (right -> left along the TOP row, so abs 7 is top-right)
//   13      seat 1's store  (left end)
// Sowing is counterclockwise = increasing absolute index, wrapping 13 -> 0,
// skipping the OPPONENT's store. The pit opposite absolute pit `i` is `12 - i`.
// An action names a pit by LOCAL index 0...5 (0 = farthest from your own
// store, 5 = the pit next to it) so a UI never has to know which seat is which.

// MARK: - Players, phase, action

public struct MancalaPlayer: Codable, Sendable, Equatable {
    public var name: String
    public var isBot: Bool
    public init(name: String, isBot: Bool) {
        self.name = name
        self.isBot = isBot
    }
}

public enum MancalaPhase: Codable, Sendable, Equatable {
    case playing
    case gameOver
}

/// `pit` is the LOCAL index 0...5 on the acting seat's own side.
public enum MancalaAction: Codable, Sendable, Equatable {
    case sow(pit: Int)
}

// MARK: - Events

public enum MancalaEvent: Codable, Sendable, Equatable {
    case gameStarted
    /// The whole sowing, stone by stone. `from` is the ABSOLUTE pit emptied;
    /// `path[k]` is the ABSOLUTE index (pit or store) that received the k-th
    /// stone, in drop order. `path.count` == the number of stones lifted. The
    /// opponent's store never appears. With 13+ stones the path laps the
    /// board and may repeat indices (including `from` itself).
    case sowed(seat: Int, from: Int, path: [Int])
    /// The last stone ended in `seat`'s own store: they move again.
    case extraTurn(seat: Int)
    /// Last stone ended in `seat`'s own empty pit `pit` with `opposite`
    /// holding stones. `stones` = everything banked (opposite's stones plus
    /// the capturing stone) into `seat`'s store.
    case captured(seat: Int, pit: Int, opposite: Int, stones: Int)
    /// End-of-game sweep: `stones` left in `seat`'s `pits` (absolute) went
    /// into `seat`'s store. Emitted once per seat that still had stones.
    case swept(seat: Int, pits: [Int], stones: Int)
    case turnChanged(to: Int)
    case gameWon(seat: Int, finalScores: [Int])
    case draw(finalScores: [Int])
    case illegalAttempt(seat: Int, reason: String)
}

// MARK: - State

public struct MancalaState: Codable, Sendable, Equatable {
    public static let kind = "mancala"

    public var players: [MancalaPlayer]   // exactly 2
    public var board: [Int]               // 14 slots, see layout above
    public var currentPlayer: Int
    public var phase: MancalaPhase
    public var winner: Int?               // nil at .gameOver means a draw
    public var emptyCapture: Bool        // variant: capture even if the opposite pit is empty
    public var stonesPerPit: Int
    public var moveCount: Int            // sowings so far (extra-turn sowings count)

    public init(players: [MancalaPlayer], stonesPerPit: Int = 4, emptyCapture: Bool = false, firstPlayer: Int = 0) {
        self.players = players
        self.stonesPerPit = stonesPerPit
        self.emptyCapture = emptyCapture
        board = (0..<14).map { MancalaRules.isStore($0) ? 0 : stonesPerPit }
        currentPlayer = firstPlayer
        phase = .playing
        winner = nil
        moveCount = 0
    }

    public var scores: [Int] { [board[MancalaRules.store(of: 0)], board[MancalaRules.store(of: 1)]] }
    public var isGameOver: Bool { phase == .gameOver }

    /// LOCAL pit indices (0...5) the current player may sow.
    public var legalPits: [Int] {
        phase == .gameOver ? [] : MancalaRules.legalPits(board: board, seat: currentPlayer)
    }
}

// MARK: - Rules (pure)

public enum MancalaRules {
    public static func store(of seat: Int) -> Int { seat == 0 ? 6 : 13 }
    public static func isStore(_ index: Int) -> Bool { index == 6 || index == 13 }
    /// Absolute index of `seat`'s LOCAL pit `local` (0...5).
    public static func absolutePit(seat: Int, local: Int) -> Int { seat == 0 ? local : 7 + local }
    public static func opposite(of absolute: Int) -> Int { 12 - absolute }
    public static func owner(ofPit absolute: Int) -> Int? {
        if (0...5).contains(absolute) { return 0 }
        if (7...12).contains(absolute) { return 1 }
        return nil
    }

    public static func legalPits(board: [Int], seat: Int) -> [Int] {
        (0..<6).filter { board[absolutePit(seat: seat, local: $0)] > 0 }
    }

    public static func sideTotal(board: [Int], seat: Int) -> Int {
        var total = 0
        for local in 0..<6 { total += board[absolutePit(seat: seat, local: local)] }
        return total
    }

    public struct Step {
        public var board: [Int]            // final board, sweep already applied when `ended`
        public var from: Int               // absolute
        public var path: [Int]             // absolute, one per stone
        public var extraTurn: Bool
        public var capture: (pit: Int, opposite: Int, stones: Int)?
        public var sweeps: [(seat: Int, pits: [Int], stones: Int)]
        public var ended: Bool
    }

    /// Applies one sowing. Caller guarantees the pit is non-empty.
    public static func step(board: [Int], seat: Int, localPit: Int, emptyCapture: Bool) -> Step {
        var b = board
        let from = absolutePit(seat: seat, local: localPit)
        let skip = store(of: 1 - seat)
        let own = store(of: seat)
        var stones = b[from]
        b[from] = 0
        var path: [Int] = []
        path.reserveCapacity(stones)
        var idx = from
        while stones > 0 {
            idx = (idx + 1) % 14
            if idx == skip { idx = (idx + 1) % 14 }
            b[idx] += 1
            path.append(idx)
            stones -= 1
        }
        let last = idx
        var extra = false
        var capture: (pit: Int, opposite: Int, stones: Int)?
        if last == own {
            extra = true
        } else if owner(ofPit: last) == seat, b[last] == 1 {
            let opp = opposite(of: last)
            if b[opp] > 0 || emptyCapture {
                let gained = b[opp] + 1
                b[own] += gained
                b[opp] = 0
                b[last] = 0
                capture = (last, opp, gained)
            }
        }
        // End of game: either side has no stones left in its pits.
        var sweeps: [(seat: Int, pits: [Int], stones: Int)] = []
        let ended = sideTotal(board: b, seat: 0) == 0 || sideTotal(board: b, seat: 1) == 0
        if ended {
            for s in 0..<2 {
                var pits: [Int] = []
                var total = 0
                for local in 0..<6 {
                    let a = absolutePit(seat: s, local: local)
                    if b[a] > 0 { pits.append(a); total += b[a]; b[a] = 0 }
                }
                if total > 0 {
                    b[store(of: s)] += total
                    sweeps.append((s, pits, total))
                }
            }
        }
        return Step(board: b, from: from, path: path, extraTurn: extra, capture: capture, sweeps: sweeps, ended: ended)
    }

    /// Pure reducer step: applies a *legal* action and returns the new state.
    public static func apply(_ action: MancalaAction, to state: MancalaState) -> MancalaState {
        guard case .sow(let pit) = action else { return state }
        var next = state
        let result = step(board: state.board, seat: state.currentPlayer, localPit: pit, emptyCapture: state.emptyCapture)
        next.board = result.board
        next.moveCount += 1
        if result.ended {
            next.phase = .gameOver
            let s = next.scores
            next.winner = s[0] == s[1] ? nil : (s[0] > s[1] ? 0 : 1)
        } else if !result.extraTurn {
            next.currentPlayer = 1 - state.currentPlayer
        }
        return next
    }
}

// MARK: - Engine

/// Validates + emits events. Illegal / out-of-turn actions return one
/// `.illegalAttempt` and leave state untouched (house convention).
public final class MancalaEngine {
    public static let kind = MancalaState.kind

    public private(set) var state: MancalaState

    public init(players: [MancalaPlayer], stonesPerPit: Int = 4, emptyCapture: Bool = false, firstPlayer: Int = 0) {
        state = MancalaState(players: players, stonesPerPit: stonesPerPit, emptyCapture: emptyCapture, firstPlayer: firstPlayer)
    }

    public init(restoring state: MancalaState) {
        self.state = state
    }

    @discardableResult
    public func restart(players: [MancalaPlayer], stonesPerPit: Int = 4, emptyCapture: Bool = false, firstPlayer: Int = 0) -> [MancalaEvent] {
        state = MancalaState(players: players, stonesPerPit: stonesPerPit, emptyCapture: emptyCapture, firstPlayer: firstPlayer)
        return [.gameStarted]
    }

    @discardableResult
    public func apply(_ action: MancalaAction, from seat: Int) -> [MancalaEvent] {
        guard case .sow(let pit) = action else {
            return [.illegalAttempt(seat: seat, reason: "Unknown action")]
        }
        guard state.phase == .playing else {
            return [.illegalAttempt(seat: seat, reason: "The game is over")]
        }
        guard seat == state.currentPlayer else {
            return [.illegalAttempt(seat: seat, reason: "Not your turn")]
        }
        guard (0..<6).contains(pit), state.board[MancalaRules.absolutePit(seat: seat, local: pit)] > 0 else {
            return [.illegalAttempt(seat: seat, reason: "That pit is empty")]
        }
        let result = MancalaRules.step(board: state.board, seat: seat, localPit: pit, emptyCapture: state.emptyCapture)
        state = MancalaRules.apply(action, to: state)

        var events: [MancalaEvent] = [.sowed(seat: seat, from: result.from, path: result.path)]
        if let c = result.capture {
            events.append(.captured(seat: seat, pit: c.pit, opposite: c.opposite, stones: c.stones))
        }
        if result.extraTurn && !result.ended { events.append(.extraTurn(seat: seat)) }
        for sweep in result.sweeps {
            events.append(.swept(seat: sweep.seat, pits: sweep.pits, stones: sweep.stones))
        }
        if state.phase == .gameOver {
            if let w = state.winner {
                events.append(.gameWon(seat: w, finalScores: state.scores))
            } else {
                events.append(.draw(finalScores: state.scores))
            }
        } else if !result.extraTurn {
            events.append(.turnChanged(to: state.currentPlayer))
        }
        return events
    }
}

// MARK: - Bot

/// Alpha-beta over individual sowings (an extra-turn sowing is its own ply by
/// the SAME player). Iterative deepening to `maxDepth`; the search is bounded
/// by a NODE budget, never the wall clock, so a decision is a pure function of
/// (state, seed, budget): identical on every device and every run. A depth
/// iteration that runs out of budget is discarded in favour of the last
/// completed one (depth 1 always completes).
public enum MancalaBot {
    public static let defaultMaxDepth = 8
    public static let defaultNodeBudget = 120_000
    private static let winBase = 10_000

    public struct Decision {
        public var action: MancalaAction
        public var nodes: Int
        public var depthReached: Int
    }

    public static func decide(state: MancalaState, seed: UInt64,
                              maxDepth: Int = defaultMaxDepth,
                              nodeBudget: Int = defaultNodeBudget) -> MancalaAction {
        decideDetailed(state: state, seed: seed, maxDepth: maxDepth, nodeBudget: nodeBudget).action
    }

    public static func decideDetailed(state: MancalaState, seed: UInt64,
                                      maxDepth: Int = defaultMaxDepth,
                                      nodeBudget: Int = defaultNodeBudget) -> Decision {
        precondition(state.phase == .playing, "MancalaBot.decide called on a finished game")
        let legal = state.legalPits
        precondition(!legal.isEmpty, "MancalaBot.decide: no legal pits")
        var rng = SeededGenerator(seed: seed &+ UInt64(state.moveCount) &* 0x9E37_79B9_7F4A_7C15)
        let me = state.currentPlayer
        let total = state.board.reduce(0, +)
        var ctx = Context(budget: nodeBudget, maximizer: me, total: total, emptyCapture: state.emptyCapture)

        var best = orderedRoot(legal, board: state.board, seat: me)
        var depthReached = 0
        var chosen = best[0]
        if legal.count == 1 { return Decision(action: .sow(pit: chosen), nodes: 0, depthReached: 0) }

        for depth in 1...max(1, maxDepth) {
            ctx.enforceBudget = depth > 1
            ctx.aborted = false
            var bestScore = Int.min
            var tied: [Int] = []
            var scored: [(pit: Int, score: Int)] = []
            for pit in best {
                let r = MancalaRules.step(board: state.board, seat: me, localPit: pit, emptyCapture: state.emptyCapture)
                let alpha = bestScore == Int.min ? -Int.max / 2 : bestScore - 1
                let score = childScore(r, seat: me, depth: depth - 1, alpha: alpha, beta: Int.max / 2, ctx: &ctx)
                if ctx.aborted { break }
                scored.append((pit, score))
                if score > bestScore { bestScore = score; tied = [pit] }
                else if score == bestScore { tied.append(pit) }
            }
            if ctx.aborted { break }
            depthReached = depth
            chosen = tied.count == 1 ? tied[0] : tied[Int(rng.next() % UInt64(tied.count))]
            // PV-first ordering for the next iteration.
            best = [chosen] + scored.map(\.pit).filter { $0 != chosen }
            if bestScore >= winBase || bestScore <= -winBase { break } // decided
        }
        return Decision(action: .sow(pit: chosen), nodes: ctx.nodes, depthReached: depthReached)
    }

    // MARK: search

    private struct Context {
        var nodes = 0
        var budget: Int
        var aborted = false
        var enforceBudget = false
        let maximizer: Int
        let total: Int
        let emptyCapture: Bool
        init(budget: Int, maximizer: Int, total: Int, emptyCapture: Bool) {
            self.budget = budget; self.maximizer = maximizer; self.total = total; self.emptyCapture = emptyCapture
        }
    }

    private static func orderedRoot(_ pits: [Int], board: [Int], seat: Int) -> [Int] {
        order(pits, board: board, seat: seat)
    }

    /// Extra-turn sowings first (stones == distance to store), then pits
    /// nearest the store. Pure function of the position.
    private static func order(_ pits: [Int], board: [Int], seat: Int) -> [Int] {
        pits.sorted { a, b in
            let ea = board[MancalaRules.absolutePit(seat: seat, local: a)] == 6 - a
            let eb = board[MancalaRules.absolutePit(seat: seat, local: b)] == 6 - b
            if ea != eb { return ea }
            return a > b
        }
    }

    private static func childScore(_ r: MancalaRules.Step, seat: Int, depth: Int, alpha: Int, beta: Int,
                                   ctx: inout Context) -> Int {
        if r.ended { return terminal(board: r.board, depth: depth, ctx: ctx) }
        let next = r.extraTurn ? seat : 1 - seat
        return search(board: r.board, seat: next, depth: depth, alpha: alpha, beta: beta, ctx: &ctx)
    }

    private static func terminal(board: [Int], depth: Int, ctx: Context) -> Int {
        let diff = board[MancalaRules.store(of: ctx.maximizer)] - board[MancalaRules.store(of: 1 - ctx.maximizer)]
        if diff == 0 { return 0 }
        return diff > 0 ? winBase + diff + depth : -(winBase + -diff + depth)
    }

    private static func search(board: [Int], seat: Int, depth: Int, alpha: Int, beta: Int,
                               ctx: inout Context) -> Int {
        if ctx.enforceBudget && ctx.nodes >= ctx.budget { ctx.aborted = true; return 0 }
        ctx.nodes += 1
        let me = ctx.maximizer
        let myStore = board[MancalaRules.store(of: me)], oppStore = board[MancalaRules.store(of: 1 - me)]
        // Majority banked: the game is decided whatever happens next.
        if myStore * 2 > ctx.total { return winBase + (myStore - oppStore) + depth }
        if oppStore * 2 > ctx.total { return -(winBase + (oppStore - myStore) + depth) }
        if depth == 0 { return evaluate(board: board, maximizer: me) }

        let legal = MancalaRules.legalPits(board: board, seat: seat)
        if legal.isEmpty { return evaluate(board: board, maximizer: me) } // unreachable: side-empty ends the game
        let maximizing = seat == me
        var alpha = alpha, beta = beta
        var value = maximizing ? Int.min : Int.max
        for pit in order(legal, board: board, seat: seat) {
            let r = MancalaRules.step(board: board, seat: seat, localPit: pit, emptyCapture: ctx.emptyCapture)
            let score = childScore(r, seat: seat, depth: depth - 1, alpha: alpha, beta: beta, ctx: &ctx)
            if ctx.aborted { return 0 }
            if maximizing {
                value = max(value, score); alpha = max(alpha, value)
            } else {
                value = min(value, score); beta = min(beta, value)
            }
            if alpha >= beta { break }
        }
        return value
    }

    /// Heuristic from `maximizer`'s view: store difference (dominant) +
    /// mobility + extra-turn potential + stones kept on own side.
    private static func evaluate(board: [Int], maximizer: Int) -> Int {
        func side(_ seat: Int) -> (store: Int, mobility: Int, extras: Int, held: Int) {
            var mobility = 0, extras = 0, held = 0
            for local in 0..<6 {
                let n = board[MancalaRules.absolutePit(seat: seat, local: local)]
                if n > 0 {
                    mobility += 1
                    held += n
                    if n == 6 - local { extras += 1 }
                }
            }
            return (board[MancalaRules.store(of: seat)], mobility, extras, held)
        }
        let a = side(maximizer), b = side(1 - maximizer)
        return (a.store - b.store) * 10 + (a.mobility - b.mobility) * 2 + (a.extras - b.extras) * 5 + (a.held - b.held)
    }
}
