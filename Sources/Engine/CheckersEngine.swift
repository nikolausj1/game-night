import Foundation

// Checkers (American / English draughts): table-only pass-and-play.
// Same house pattern as `QuartoEngine`: pure `CheckersRules` (move generation
// + reducer), validating `CheckersEngine`, deterministic `CheckersBot`.
//
// BOARD: 64 squares, index = row * 8 + col, ROW 0 AT THE TOP (screen order).
// Playable squares are the dark ones: (row + col) % 2 == 1 (the bottom-left
// corner, row 7 col 0, is dark). Seat 0 starts on rows 5...7 (bottom) and
// moves UP (row decreasing); seat 1 starts on rows 0...2 and moves DOWN.
// Seat 0 kings on row 0, seat 1 on row 7. Seat 0 moves first by default.

// MARK: - Piece, move

public struct CheckersPiece: Codable, Sendable, Equatable, Hashable {
    public var owner: Int       // seat 0 or 1
    public var isKing: Bool
    public init(owner: Int, isKing: Bool = false) {
        self.owner = owner
        self.isKing = isKing
    }
}

/// One complete move. A simple step has `path.count == 2` and no captures.
/// A (multi-)jump lists EVERY square the piece lands on: `path[0]` is the
/// origin, `path[k]` the landing of the k-th hop, and `captured[k-1]` is the
/// square of the piece jumped on hop k (so `captured.count == path.count - 1`).
/// A UI animates hop k from `path[k-1]` to `path[k]` and removes
/// `captured[k-1]`. The path alone identifies a move (the jumped square is the
/// midpoint of each hop), so a client may send `captured: []` and the engine
/// canonicalizes against its own generated moves.
public struct CheckersMove: Codable, Sendable, Equatable, Hashable {
    public var path: [Int]
    public var captured: [Int]
    public init(path: [Int], captured: [Int] = []) {
        self.path = path
        self.captured = captured
    }
    public var from: Int { path[0] }
    public var to: Int { path[path.count - 1] }
    public var isJump: Bool { !captured.isEmpty }
}

public enum CheckersAction: Codable, Sendable, Equatable {
    case move(CheckersMove)
}

public enum CheckersEndReason: String, Codable, Sendable, Equatable {
    case noPieces          // the loser has no pieces left
    case noMoves           // the loser is completely blocked
    case noCaptureLimit    // draw: too long without a capture
}

public enum CheckersPhase: Codable, Sendable, Equatable {
    case playing
    case gameOver
}

public enum CheckersEvent: Codable, Sendable, Equatable {
    case gameStarted
    /// The whole move incl. multi-jump (see `CheckersMove`). `crowned` = the
    /// moving man reached the far row on this move (it ended there).
    case moved(seat: Int, move: CheckersMove, crowned: Bool)
    case turnChanged(to: Int)
    case gameWon(seat: Int, reason: CheckersEndReason)
    case draw(reason: CheckersEndReason)
    case illegalAttempt(seat: Int, reason: String)
}

// MARK: - State

public struct CheckersPlayer: Codable, Sendable, Equatable {
    public var name: String
    public var isBot: Bool
    public init(name: String, isBot: Bool) {
        self.name = name
        self.isBot = isBot
    }
}

public struct CheckersState: Codable, Sendable, Equatable {
    public static let kind = "checkers"

    public var players: [CheckersPlayer]   // exactly 2
    public var board: [CheckersPiece?]     // 64
    public var currentPlayer: Int
    public var phase: CheckersPhase
    public var winner: Int?                // nil at .gameOver = draw
    public var endReason: CheckersEndReason?
    public var forcedCapture: Bool         // a jump, when available, must be taken
    /// Plies (single moves by either side) since the last capture.
    public var pliesSinceCapture: Int
    /// Draw once `pliesSinceCapture` reaches this. Default 80 plies = 40
    /// moves by each side without a capture.
    public var noCapturePlyLimit: Int
    public var moveCount: Int              // total plies

    public init(players: [CheckersPlayer], forcedCapture: Bool = true, noCapturePlyLimit: Int = 80, firstPlayer: Int = 0) {
        self.players = players
        self.forcedCapture = forcedCapture
        self.noCapturePlyLimit = noCapturePlyLimit
        board = CheckersRules.initialBoard()
        currentPlayer = firstPlayer
        phase = .playing
        winner = nil
        endReason = nil
        pliesSinceCapture = 0
        moveCount = 0
    }

    public var isGameOver: Bool { phase == .gameOver }

    /// Every legal move for the current player (full jump paths; only jumps
    /// when a jump exists and `forcedCapture` is on).
    public var legalMoves: [CheckersMove] {
        phase == .gameOver ? [] : CheckersRules.legalMoves(board: board, seat: currentPlayer, forcedCapture: forcedCapture)
    }

    public func pieceCount(seat: Int) -> Int { board.reduce(0) { $0 + ($1?.owner == seat ? 1 : 0) } }
}

// MARK: - Rules (pure)

public enum CheckersRules {
    public static func row(_ sq: Int) -> Int { sq >> 3 }
    public static func col(_ sq: Int) -> Int { sq & 7 }
    public static func isPlayable(_ sq: Int) -> Bool { (row(sq) + col(sq)) % 2 == 1 }
    public static func kingRow(of seat: Int) -> Int { seat == 0 ? 0 : 7 }
    /// Row direction a MAN of `seat` moves in.
    public static func forward(of seat: Int) -> Int { seat == 0 ? -1 : 1 }

    public static func initialBoard() -> [CheckersPiece?] {
        var b = [CheckersPiece?](repeating: nil, count: 64)
        for sq in 0..<64 where isPlayable(sq) {
            if row(sq) < 3 { b[sq] = CheckersPiece(owner: 1) }
            else if row(sq) > 4 { b[sq] = CheckersPiece(owner: 0) }
        }
        return b
    }

    private static let kingDirs: [(Int, Int)] = [(-1, -1), (-1, 1), (1, -1), (1, 1)]
    private static let dirs0: [(Int, Int)] = [(-1, -1), (-1, 1)]
    private static let dirs1: [(Int, Int)] = [(1, -1), (1, 1)]

    private static func directions(for piece: CheckersPiece) -> [(Int, Int)] {
        if piece.isKing { return kingDirs }
        return piece.owner == 0 ? dirs0 : dirs1
    }

    public static func legalMoves(board: [CheckersPiece?], seat: Int, forcedCapture: Bool) -> [CheckersMove] {
        let jumps = jumpMoves(board: board, seat: seat)
        if !jumps.isEmpty && forcedCapture { return jumps }
        return jumps + stepMoves(board: board, seat: seat)
    }

    public static func hasJump(board: [CheckersPiece?], seat: Int) -> Bool {
        for sq in 0..<64 {
            guard let p = board[sq], p.owner == seat else { continue }
            for (dr, dc) in directions(for: p) {
                let r = row(sq), c = col(sq)
                let or = r + dr, oc = c + dc, lr = r + 2 * dr, lc = c + 2 * dc
                guard lr >= 0, lr < 8, lc >= 0, lc < 8 else { continue }
                if let o = board[or * 8 + oc], o.owner != seat, board[lr * 8 + lc] == nil { return true }
            }
        }
        return false
    }

    public static func stepMoves(board: [CheckersPiece?], seat: Int) -> [CheckersMove] {
        var result: [CheckersMove] = []
        for sq in 0..<64 {
            guard let p = board[sq], p.owner == seat else { continue }
            let r = row(sq), c = col(sq)
            for (dr, dc) in directions(for: p) {
                let nr = r + dr, nc = c + dc
                guard nr >= 0, nr < 8, nc >= 0, nc < 8 else { continue }
                if board[nr * 8 + nc] == nil { result.append(CheckersMove(path: [sq, nr * 8 + nc])) }
            }
        }
        return result
    }

    /// All complete jump sequences (each a full path). Captured pieces stay on
    /// the board until the move ends (no jumping the same piece twice, and
    /// their squares block landing); the origin square counts as vacated.
    public static func jumpMoves(board: [CheckersPiece?], seat: Int) -> [CheckersMove] {
        var result: [CheckersMove] = []
        for sq in 0..<64 {
            guard let p = board[sq], p.owner == seat else { continue }
            var path = [sq], captured: [Int] = []
            extend(board: board, piece: p, origin: sq, at: sq, path: &path, captured: &captured, into: &result)
        }
        return result
    }

    private static func extend(board: [CheckersPiece?], piece: CheckersPiece, origin: Int, at sq: Int,
                               path: inout [Int], captured: inout [Int], into result: inout [CheckersMove]) {
        var extended = false
        let r = row(sq), c = col(sq)
        for (dr, dc) in directions(for: piece) {
            let or = r + dr, oc = c + dc, lr = r + 2 * dr, lc = c + 2 * dc
            guard lr >= 0, lr < 8, lc >= 0, lc < 8 else { continue }
            let over = or * 8 + oc, land = lr * 8 + lc
            guard let victim = board[over], victim.owner != piece.owner, !captured.contains(over) else { continue }
            guard board[land] == nil || land == origin else { continue }
            extended = true
            path.append(land); captured.append(over)
            if !piece.isKing && lr == kingRow(of: piece.owner) {
                // Kinging ends the move, even if more jumps would exist.
                result.append(CheckersMove(path: path, captured: captured))
            } else {
                extend(board: board, piece: piece, origin: origin, at: land, path: &path, captured: &captured, into: &result)
            }
            path.removeLast(); captured.removeLast()
        }
        if !extended && !captured.isEmpty {
            result.append(CheckersMove(path: path, captured: captured))
        }
    }

    /// Applies `move` to a board (no turn bookkeeping). Returns whether the
    /// moving man was crowned.
    @discardableResult
    public static func applyMove(_ move: CheckersMove, to board: inout [CheckersPiece?]) -> Bool {
        guard var piece = board[move.from] else { return false }
        board[move.from] = nil
        for sq in move.captured { board[sq] = nil }
        var crowned = false
        if !piece.isKing && row(move.to) == kingRow(of: piece.owner) {
            piece.isKing = true
            crowned = true
        }
        board[move.to] = piece
        return crowned
    }

    /// Pure reducer step: applies a *legal* move, advances the turn, and
    /// resolves end of game (no pieces / no moves / no-capture draw).
    public static func apply(_ action: CheckersAction, to state: CheckersState) -> (state: CheckersState, crowned: Bool) {
        guard case .move(let move) = action else { return (state, false) }
        var next = state
        let mover = state.currentPlayer
        let crowned = applyMove(move, to: &next.board)
        next.moveCount += 1
        next.pliesSinceCapture = move.isJump ? 0 : state.pliesSinceCapture + 1
        let opponent = 1 - mover
        if next.pieceCount(seat: opponent) == 0 {
            next.phase = .gameOver; next.winner = mover; next.endReason = .noPieces
        } else if legalMoves(board: next.board, seat: opponent, forcedCapture: next.forcedCapture).isEmpty {
            next.phase = .gameOver; next.winner = mover; next.endReason = .noMoves
        } else if next.pliesSinceCapture >= next.noCapturePlyLimit {
            next.phase = .gameOver; next.winner = nil; next.endReason = .noCaptureLimit
        } else {
            next.currentPlayer = opponent
        }
        return (next, crowned)
    }
}

// MARK: - Engine

public final class CheckersEngine {
    public static let kind = CheckersState.kind

    public private(set) var state: CheckersState

    public init(players: [CheckersPlayer], forcedCapture: Bool = true, noCapturePlyLimit: Int = 80, firstPlayer: Int = 0) {
        state = CheckersState(players: players, forcedCapture: forcedCapture, noCapturePlyLimit: noCapturePlyLimit, firstPlayer: firstPlayer)
    }

    public init(restoring state: CheckersState) {
        self.state = state
    }

    @discardableResult
    public func restart(players: [CheckersPlayer], forcedCapture: Bool = true, noCapturePlyLimit: Int = 80, firstPlayer: Int = 0) -> [CheckersEvent] {
        state = CheckersState(players: players, forcedCapture: forcedCapture, noCapturePlyLimit: noCapturePlyLimit, firstPlayer: firstPlayer)
        return [.gameStarted]
    }

    /// Convenience for a UI that has just the tapped squares.
    @discardableResult
    public func move(path: [Int], from seat: Int) -> [CheckersEvent] {
        apply(.move(CheckersMove(path: path)), from: seat)
    }

    @discardableResult
    public func apply(_ action: CheckersAction, from seat: Int) -> [CheckersEvent] {
        guard case .move(let requested) = action else {
            return [.illegalAttempt(seat: seat, reason: "Unknown action")]
        }
        guard state.phase == .playing else {
            return [.illegalAttempt(seat: seat, reason: "The game is over")]
        }
        guard seat == state.currentPlayer else {
            return [.illegalAttempt(seat: seat, reason: "Not your turn")]
        }
        let legal = state.legalMoves
        guard let move = legal.first(where: { $0.path == requested.path }) else {
            if state.forcedCapture,
               CheckersRules.hasJump(board: state.board, seat: seat),
               CheckersRules.legalMoves(board: state.board, seat: seat, forcedCapture: false).contains(where: { $0.path == requested.path }) {
                return [.illegalAttempt(seat: seat, reason: "You must capture")]
            }
            return [.illegalAttempt(seat: seat, reason: "Not a legal move")]
        }
        let result = CheckersRules.apply(.move(move), to: state)
        state = result.state
        var events: [CheckersEvent] = [.moved(seat: seat, move: move, crowned: result.crowned)]
        if state.phase == .gameOver {
            if let w = state.winner, let reason = state.endReason {
                events.append(.gameWon(seat: w, reason: reason))
            } else {
                events.append(.draw(reason: state.endReason ?? .noCaptureLimit))
            }
        } else {
            events.append(.turnChanged(to: state.currentPlayer))
        }
        return events
    }
}

// MARK: - Bot

/// Negamax + alpha-beta, iterative deepening to `maxDepth` (6), with a capture
/// quiescence extension (a side that must jump keeps searching jumps past the
/// horizon, capped at `quiescenceCap` extra plies). Bounded by a NODE budget,
/// never the wall clock: a decision is a pure function of (state, seed,
/// budget). An iteration that runs out of budget is discarded for the last
/// completed one (depth 1 always completes).
/// Heuristic (per side): man 100, king 150; +4 per row a man has advanced;
/// +3 per piece in the centre 4x4; +5 for a man still on the back rank
/// (guards against kings). Win/loss = +-(WIN - ply).
public enum CheckersBot {
    public static let defaultMaxDepth = 6
    public static let defaultNodeBudget = 40_000
    public static let quiescenceCap = 6
    private static let win = 100_000
    private static let inf = 10_000_000

    public struct Decision {
        public var action: CheckersAction
        public var nodes: Int
        public var depthReached: Int
    }

    public static func decide(state: CheckersState, seed: UInt64,
                              maxDepth: Int = defaultMaxDepth,
                              nodeBudget: Int = defaultNodeBudget) -> CheckersAction {
        decideDetailed(state: state, seed: seed, maxDepth: maxDepth, nodeBudget: nodeBudget).action
    }

    public static func decideDetailed(state: CheckersState, seed: UInt64,
                                      maxDepth: Int = defaultMaxDepth,
                                      nodeBudget: Int = defaultNodeBudget) -> Decision {
        precondition(state.phase == .playing, "CheckersBot.decide called on a finished game")
        var rootMoves = state.legalMoves
        precondition(!rootMoves.isEmpty, "CheckersBot.decide: no legal moves")
        if rootMoves.count == 1 { return Decision(action: .move(rootMoves[0]), nodes: 0, depthReached: 0) }

        var rng = SeededGenerator(seed: seed &+ UInt64(state.moveCount) &* 0x9E37_79B9_7F4A_7C15)
        var ctx = Context(budget: nodeBudget, forced: state.forcedCapture, plyLimit: state.noCapturePlyLimit)
        rootMoves = ordered(rootMoves, board: state.board, seat: state.currentPlayer)
        var chosen = rootMoves[0]
        var depthReached = 0
        let seat = state.currentPlayer

        for depth in 1...max(1, maxDepth) {
            ctx.enforce = depth > 1
            ctx.aborted = false
            var bestScore = Int.min
            var tied: [CheckersMove] = []
            var scored: [CheckersMove] = []
            for move in rootMoves {
                var b = state.board
                CheckersRules.applyMove(move, to: &b)
                let plies = move.isJump ? 0 : state.pliesSinceCapture + 1
                let alpha = bestScore == Int.min ? -inf : bestScore - 1
                let score = -search(board: b, seat: 1 - seat, depth: depth - 1, ply: 1, plies: plies,
                                    alpha: -inf, beta: -alpha, ctx: &ctx)
                if ctx.aborted { break }
                scored.append(move)
                if score > bestScore { bestScore = score; tied = [move] }
                else if score == bestScore { tied.append(move) }
            }
            if ctx.aborted { break }
            depthReached = depth
            chosen = tied.count == 1 ? tied[0] : tied[Int(rng.next() % UInt64(tied.count))]
            rootMoves = [chosen] + scored.filter { $0 != chosen }
            if abs(bestScore) >= win - 64 { break } // forced result found
        }
        return Decision(action: .move(chosen), nodes: ctx.nodes, depthReached: depthReached)
    }

    private struct Context {
        var nodes = 0
        let budget: Int
        let forced: Bool
        let plyLimit: Int
        var enforce = false
        var aborted = false
        init(budget: Int, forced: Bool, plyLimit: Int) { self.budget = budget; self.forced = forced; self.plyLimit = plyLimit }
    }

    /// Value for the side to move (`seat`).
    private static func search(board: [CheckersPiece?], seat: Int, depth: Int, ply: Int, plies: Int,
                               alpha: Int, beta: Int, ctx: inout Context) -> Int {
        if ctx.enforce && ctx.nodes >= ctx.budget { ctx.aborted = true; return 0 }
        ctx.nodes += 1
        if plies >= ctx.plyLimit { return 0 }

        let jumps = CheckersRules.jumpMoves(board: board, seat: seat)
        var moves: [CheckersMove]
        if !jumps.isEmpty && ctx.forced {
            moves = jumps
        } else {
            moves = jumps + CheckersRules.stepMoves(board: board, seat: seat)
        }
        if moves.isEmpty { return -(win - ply) } // blocked or wiped out: side to move loses

        let quiescing = depth <= 0
        if quiescing {
            // Only keep going while the side to move is forced to capture.
            if jumps.isEmpty || !ctx.forced || depth <= -quiescenceCap { return evaluate(board: board, seat: seat) }
        }
        moves = ordered(moves, board: board, seat: seat)
        var alpha = alpha
        var best = -inf
        for move in moves {
            var b = board
            CheckersRules.applyMove(move, to: &b)
            let score = -search(board: b, seat: 1 - seat, depth: depth - 1, ply: ply + 1,
                                plies: move.isJump ? 0 : plies + 1, alpha: -beta, beta: -alpha, ctx: &ctx)
            if ctx.aborted { return 0 }
            if score > best { best = score }
            if best > alpha { alpha = best }
            if alpha >= beta { break }
        }
        return best
    }

    /// Cheap static ordering: more captures, crowning, then central/advanced.
    private static func ordered(_ moves: [CheckersMove], board: [CheckersPiece?], seat: Int) -> [CheckersMove] {
        func key(_ m: CheckersMove) -> Int {
            var k = m.captured.count * 100
            if let p = board[m.from], !p.isKing, CheckersRules.row(m.to) == CheckersRules.kingRow(of: seat) { k += 50 }
            let c = CheckersRules.col(m.to), r = CheckersRules.row(m.to)
            if (2...5).contains(c) && (2...5).contains(r) { k += 5 }
            return k
        }
        return moves.enumerated().sorted {
            let ka = key($0.element), kb = key($1.element)
            return ka != kb ? ka > kb : $0.offset < $1.offset
        }.map(\.element)
    }

    private static func evaluate(board: [CheckersPiece?], seat: Int) -> Int {
        var score = 0
        for sq in 0..<64 {
            guard let p = board[sq] else { continue }
            let r = CheckersRules.row(sq), c = CheckersRules.col(sq)
            var v: Int
            if p.isKing {
                v = 150
            } else {
                v = 100
                let advanced = p.owner == 0 ? 7 - r : r
                v += advanced * 4
                if advanced == 0 { v += 5 }
            }
            if (2...5).contains(r) && (2...5).contains(c) { v += 3 }
            score += p.owner == seat ? v : -v
        }
        return score
    }
}
