import SwiftUI

/// Owns the pure `CheckersEngine`, the visual `CheckersStage`, the human's
/// step-by-step move assembly, bot pacing and sound.
///
/// HUMAN MOVES are assembled square by square: pick up a piece (`select`),
/// then land it on a glowing square (`attemptStep`). A simple step finishes
/// the move; a jump that has a further jump leaves the piece standing on its
/// landing square (the jumped piece flips away immediately) and the next
/// glowing squares are the following hops, until the path equals a complete
/// legal move, which is then handed to the engine as one `CheckersMove`.
/// This is how a real hand plays a multi-jump, and it means a piece never
/// teleports back to its origin to replay a path it already walked.
///
/// BOT MOVES animate the whole path hop by hop in one plan.
@Observable
final class CheckersController {
    struct Nudge: Equatable {
        var message: String
        var squares: [Int]
        var start: Date
    }

    private(set) var engine: CheckersEngine
    private(set) var stage: CheckersStage
    private(set) var isBusy = false
    private(set) var shownTurn: Int
    /// Human's in-progress path of squares; empty == nothing picked up.
    private(set) var prefix: [Int] = []
    private(set) var nudge: Nudge?
    private(set) var revision = 0
    var reduceMotion = false

    private var token = 0
    private var botScheduled = false

    init(players: [CheckersPlayer], firstPlayer: Int = 0) {
        engine = CheckersEngine(players: players, firstPlayer: firstPlayer)
        stage = CheckersStage()
        shownTurn = firstPlayer
    }

    init(restoring state: CheckersState) {
        engine = CheckersEngine(restoring: state)
        stage = CheckersStage(board: state.board)
        shownTurn = state.currentPlayer
    }

    /// Reads `revision` so views reading `state` re-evaluate when a move
    /// completes (the engine is a plain class Observation can't see into).
    var state: CheckersState { _ = revision; return engine.state }
    var isOver: Bool { !isBusy && state.phase == .gameOver }
    var humanTurn: Bool { !isBusy && state.phase == .playing && !state.players[state.currentPlayer].isBot }
    var selectedSquare: Int? { prefix.last }

    /// Squares the held piece may land on next.
    var targets: [Int] {
        guard humanTurn, !prefix.isEmpty else { return [] }
        let n = prefix.count
        return state.legalMoves
            .filter { $0.path.count > n && Array($0.path.prefix(n)) == prefix }
            .map { $0.path[n] }
    }

    /// Plies left before the no-capture draw.
    var pliesUntilDraw: Int { max(0, state.noCapturePlyLimit - state.pliesSinceCapture) }

    func restart(players: [CheckersPlayer], firstPlayer: Int) {
        token += 1
        botScheduled = false
        isBusy = false
        prefix = []
        nudge = nil
        _ = engine.restart(players: players, firstPlayer: firstPlayer)
        stage = CheckersStage()
        shownTurn = firstPlayer
        revision += 1
        scheduleBotIfNeeded()
    }

    // MARK: - Human input

    /// Pick up the current human's piece on `square`. Returns false (and,
    /// when a capture is compulsory elsewhere, nudges) if it can't move.
    @discardableResult
    func select(square: Int) -> Bool {
        guard humanTurn, prefix.isEmpty else { return false }
        let seat = state.currentPlayer
        guard let piece = state.board[square], piece.owner == seat else { return false }
        let moves = state.legalMoves.filter { $0.from == square }
        if moves.isEmpty {
            if state.forcedCapture, CheckersRules.hasJump(board: state.board, seat: seat) {
                nudgeMustCapture()
            }
            return false
        }
        prefix = [square]
        Haptics.tick()
        return true
    }

    func deselect() {
        guard prefix.count == 1 else { return }   // mid-jump: you finish what you started
        prefix = []
    }

    /// Land the held piece on `square`. Returns true if accepted.
    @discardableResult
    func attemptStep(to square: Int) -> Bool {
        guard humanTurn, let last = prefix.last else { return false }
        if targets.contains(square) {
            let newPrefix = prefix + [square]
            if let complete = state.legalMoves.first(where: { $0.path == newPrefix }) {
                prefix = []
                play(move: complete, doneHops: newPrefix.count - 2)
            } else {
                partialHop(from: last, to: square, newPrefix: newPrefix)
            }
            return true
        }
        // Landed somewhere unglowing. If a step WAS possible but a capture
        // is compulsory, that's the rule talking: say so.
        if prefix.count == 1, state.forcedCapture,
           CheckersRules.hasJump(board: state.board, seat: state.currentPlayer),
           CheckersRules.legalMoves(board: state.board, seat: state.currentPlayer, forcedCapture: false)
            .contains(where: { $0.path == [prefix[0], square] }) {
            nudgeMustCapture()
        }
        return false
    }

    private func nudgeMustCapture() {
        let seat = state.currentPlayer
        let jumpers = Set(CheckersRules.jumpMoves(board: state.board, seat: seat).map(\.from)).sorted()
        let started = Date()
        nudge = Nudge(message: "You must capture", squares: jumpers, start: started)
        Haptics.arm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.nudge?.start == started { self?.nudge = nil }
        }
    }

    // MARK: - Playing moves

    /// First leg(s) of a human multi-jump: the piece hops, the victim flips
    /// away, the engine hears nothing until the path is complete.
    private func partialHop(from: Int, to: Int, newPrefix: [Int]) {
        let seat = state.currentPlayer
        let partial = CheckersMove(path: [from, to], captured: [CheckersGeometry.midpoint(from, to)])
        let plan = CheckersChoreographer.plan(move: partial, crowned: false, seat: seat,
                                              tokens: stage.tokens, pile: stage.pile,
                                              doneHops: 0, animated: !reduceMotion)
        isBusy = true
        token += 1
        let mine = token
        prefix = newPrefix
        stage.begin(plan)
        if reduceMotion { stage.commit() }
        schedule(cues: plan.cues, token: mine)
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.duration) { [weak self] in
            guard let self, self.token == mine else { return }
            self.stage.commit()
            self.isBusy = false
            self.revision += 1
        }
    }

    func play(move: CheckersMove, doneHops: Int = 0) {
        guard !isBusy, engine.state.phase == .playing else { return }
        let seat = engine.state.currentPlayer
        let events = engine.apply(.move(move), from: seat)
        var crowned = false
        var applied = move
        for event in events {
            if case .illegalAttempt = event { prefix = []; return }
            if case .moved(_, let m, let c) = event { applied = m; crowned = c }
        }
        let plan = CheckersChoreographer.plan(move: applied, crowned: crowned, seat: seat,
                                              tokens: stage.tokens, pile: stage.pile,
                                              doneHops: doneHops, animated: !reduceMotion)
        isBusy = true
        token += 1
        let mine = token
        stage.begin(plan)
        if reduceMotion { stage.commit() }
        schedule(cues: plan.cues, token: mine)
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.duration) { [weak self] in
            self?.finish(token: mine)
        }
    }

    private func finish(token mine: Int) {
        guard mine == token else { return }
        stage.commit()
        stage.reconcile(with: engine.state.board)
        isBusy = false
        prefix = []
        shownTurn = engine.state.currentPlayer
        revision += 1
        if engine.state.phase == .gameOver {
            TableSFX.shared.play(engine.state.winner != nil ? .fanfareWin : .softChime)
        }
        scheduleBotIfNeeded()
    }

    private func schedule(cues: [(t: Double, cue: CheckersPlan.Cue)], token mine: Int) {
        for entry in cues {
            DispatchQueue.main.asyncAfter(deadline: .now() + entry.t) { [weak self] in
                guard let self, self.token == mine else { return }
                self.fire(entry.cue)
            }
        }
    }

    private func fire(_ cue: CheckersPlan.Cue) {
        switch cue {
        case .landing: TableSFX.shared.play(.tableKnock, intensity: 0.7)
        case .captureStart: TableSFX.shared.play(.chipPass)
        case .captureLand: TableSFX.shared.playDiceContact(.rail, strength: 0.35)
        case .crown:
            Haptics.play()
            TableSFX.shared.play(.softChime)
        }
    }

    // MARK: - Bots

    func scheduleBotIfNeeded() {
        guard !botScheduled, !isBusy, engine.state.phase == .playing else { return }
        let seat = engine.state.currentPlayer
        guard engine.state.players[seat].isBot else { return }
        botScheduled = true
        let snapshot = engine.state
        let seed = UInt64(snapshot.moveCount) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(seat)
        let mine = token
        let pause = 0.65 + Double.random(in: 0...0.45)
        let begun = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let action = CheckersBot.decide(state: snapshot, seed: seed)
            let wait = max(0, pause - Date().timeIntervalSince(begun))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard let self, self.token == mine else { return }
                self.botScheduled = false
                guard !self.isBusy, self.engine.state.phase == .playing,
                      self.engine.state.moveCount == snapshot.moveCount else { return }
                if case .move(let move) = action { self.play(move: move) }
            }
        }
    }
}
