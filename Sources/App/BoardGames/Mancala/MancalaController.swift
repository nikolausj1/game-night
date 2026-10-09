import SwiftUI

/// Owns the pure `MancalaEngine`, the visual `MancalaStage`, the bot's
/// pacing, and the table sound. Same shape as `QuartoController`, plus one
/// idea Quarto doesn't need: a move is not "done" when the engine says so but
/// when its animation has played out. While `isBusy`, input is ignored and
/// nobody (human or bot) may start the next sowing, so a bot's move and a
/// human's move are animated identically and can never overlap.
@Observable
final class MancalaController {
    private(set) var engine: MancalaEngine
    private(set) var stage: MancalaStage
    private(set) var revision = 0
    private(set) var isBusy = false
    /// Whose turn the TABLE shows. The engine flips `currentPlayer` the
    /// instant a move is applied; the plaques wait until the stones settle.
    private(set) var shownTurn: Int
    /// Non-nil while the "Go again" flourish is up.
    private(set) var goAgainSeat: Int?
    /// Set by the view from `accessibilityReduceMotion`.
    var reduceMotion = false

    private var token = 0
    private var botScheduled = false

    init(players: [MancalaPlayer], firstPlayer: Int = 0) {
        engine = MancalaEngine(players: players, firstPlayer: firstPlayer)
        stage = MancalaStage()
        shownTurn = firstPlayer
    }

    /// Adopts an in-progress state without replaying it (demo harness).
    init(restoring state: MancalaState) {
        engine = MancalaEngine(restoring: state)
        stage = MancalaStage(board: state.board)
        shownTurn = state.currentPlayer
    }

    /// Reads `revision` so any view that reads `state` is invalidated when a
    /// move completes (the engine is a plain class; Observation can't see
    /// inside it).
    var state: MancalaState { _ = revision; return engine.state }
    var isOver: Bool { !isBusy && state.phase == .gameOver }

    func restart(players: [MancalaPlayer], firstPlayer: Int) {
        token += 1
        botScheduled = false
        isBusy = false
        goAgainSeat = nil
        _ = engine.restart(players: players, firstPlayer: firstPlayer)
        stage = MancalaStage()   // fresh identities, fresh pits
        shownTurn = firstPlayer
        revision += 1
        scheduleBotIfNeeded()
    }

    // MARK: - Moves

    /// Sow LOCAL pit `pit` as whoever's turn it is (humans and bots both
    /// come through here).
    func sow(localPit pit: Int) {
        guard !isBusy, engine.state.phase == .playing else { return }
        let seat = engine.state.currentPlayer
        let events = engine.apply(.sow(pit: pit), from: seat)
        if events.contains(where: { if case .illegalAttempt = $0 { return true }; return false }) { return }

        let plan = MancalaChoreographer.plan(events: events, slots: stage.slots, animated: !reduceMotion)
        isBusy = true
        token += 1
        let mine = token
        stage.begin(plan)
        // Reduce Motion: no flight at all. The stones are simply there, and
        // the short beat that follows is only turn pacing.
        if reduceMotion { stage.commit() }
        schedule(cues: plan.cues, token: mine)
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.duration) { [weak self] in
            self?.finishMove(token: mine)
        }
    }

    private func finishMove(token mine: Int) {
        guard mine == token else { return }
        stage.commit()
        stage.reconcile(with: engine.state.board)
        isBusy = false
        goAgainSeat = nil
        shownTurn = engine.state.currentPlayer
        revision += 1
        scheduleBotIfNeeded()
    }

    private func schedule(cues: [(t: Double, cue: MancalaPlan.Cue)], token mine: Int) {
        for entry in cues {
            DispatchQueue.main.asyncAfter(deadline: .now() + entry.t) { [weak self] in
                guard let self, self.token == mine else { return }
                self.fire(entry.cue)
            }
        }
    }

    private func fire(_ cue: MancalaPlan.Cue) {
        switch cue {
        case .lift:
            TableSFX.shared.playDiceContact(.settle, strength: 1.0)
        case .pitTick:
            // The glass "tick": the dice-settle sample, quiet, with a random
            // strength so successive stones never ring identically.
            TableSFX.shared.playDiceContact(.settle, strength: Double.random(in: 0.55...1.0))
        case .storeTick:
            TableSFX.shared.playDiceContact(.die, strength: Double.random(in: 0.0...0.12))
        case .captureFlash:
            TableSFX.shared.play(.chipPass)
        case .goAgain(let seat):
            Haptics.arm()
            TableSFX.shared.play(.softChime)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { goAgainSeat = seat }
        case .clearGoAgain:
            withAnimation(.easeOut(duration: 0.3)) { goAgainSeat = nil }
        case .chime:
            if engine.state.winner != nil { TableSFX.shared.play(.fanfareWin) } else { TableSFX.shared.play(.softChime) }
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
        let pause = 0.60 + Double.random(in: 0...0.40)
        let begun = Date()
        // Think off the main thread so the animation never hitches, but
        // still keep a humanlike pause.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let action = MancalaBot.decide(state: snapshot, seed: seed)
            let wait = max(0, pause - Date().timeIntervalSince(begun))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard let self, self.token == mine else { return }
                self.botScheduled = false
                guard !self.isBusy, self.engine.state.phase == .playing,
                      self.engine.state.moveCount == snapshot.moveCount else { return }
                if case .sow(let pit) = action { self.sow(localPit: pit) }
            }
        }
    }
}
