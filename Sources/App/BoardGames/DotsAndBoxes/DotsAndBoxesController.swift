import SwiftUI
import Observation

/// iPad-side owner of one Dots & Boxes game. Wraps the pure
/// `DotsAndBoxesEngine` and drives bot turns on a humanlike delay — the
/// role `BotDirector` plays for card games and `DiceGameController` plays
/// for dice, folded into one small class here since there's no multi-phase
/// turn machine to watch, just "whose turn is it, and are they a bot."
/// This is pass-and-play on a single iPad: no `GameHostController`, no
/// phones, no network — claims arrive either from the paper's own gesture
/// (a human's turn) or from `runBotMove` (a bot's turn), never both at once.
@Observable
final class DotsAndBoxesController {
    private(set) var engine: DotsAndBoxesEngine

    /// Boxes whose initial should currently show the extra-turn underline
    /// flourish (`DotsAndBoxesPaperView`'s `ExtraTurnFlourish`). Cleared a
    /// couple seconds after the claim that set it — long enough for the
    /// flourish's own fade-in/hold/fade-out to finish before the view
    /// backing it is removed.
    private(set) var extraTurnFlourishBoxes: Set<DotsAndBoxesBox> = []

    private var botTimer: Timer?
    private var flourishClearWorkItem: DispatchWorkItem?

    var state: DotsAndBoxesState { engine.state }

    init(gridSize: Int, players: [DotsAndBoxesPlayer], seed: UInt64) {
        engine = DotsAndBoxesEngine(gridSize: gridSize, players: players, seed: seed)
        scheduleBotIfNeeded()
    }

    /// Demo-harness constructor: wrap an already-scripted engine (see
    /// `DotsAndBoxesDemoData`) instead of dealing a fresh one.
    init(engine: DotsAndBoxesEngine) {
        self.engine = engine
        scheduleBotIfNeeded()
    }

    deinit {
        botTimer?.invalidate()
        flourishClearWorkItem?.cancel()
    }

    /// The single entry point for a HUMAN claim (bots go through
    /// `runBotMove`). Quietly no-ops on an illegal attempt — the paper's
    /// gesture layer already restricts taps/drags to `legalEdges()`, so in
    /// practice this only guards a stale drag landing just as the turn
    /// moved on (e.g. a bot's extra-turn chain finishing mid-gesture).
    func claim(_ edge: DotsAndBoxesEdge, by playerIndex: Int) {
        handle(engine.claimEdge(edge, by: playerIndex))
    }

    /// Restart with a fresh board, same players and grid size, a new seed
    /// (so "Play Again" isn't the identical game on repeat).
    func playAgain() {
        botTimer?.invalidate()
        flourishClearWorkItem?.cancel()
        extraTurnFlourishBoxes = []
        let players = engine.state.players.map { DotsAndBoxesPlayer(name: $0.name, initial: $0.initial, colorIndex: $0.colorIndex, isBot: $0.isBot) }
        engine = DotsAndBoxesEngine(gridSize: engine.state.gridSize, players: players, seed: .random(in: .min ... .max))
        scheduleBotIfNeeded()
    }

    private func runBotMove() {
        handle(engine.performBotMove(for: engine.state.turnIndex))
    }

    private func handle(_ events: [DotsAndBoxesEvent]) {
        guard !events.isEmpty else { return }
        let wasIllegal = events.contains { if case .illegalAttempt = $0 { return true }; return false }
        guard !wasIllegal else {
            Haptics.tick() // "that's not a line" — nothing else changes
            return
        }

        var completedThisClaim: [DotsAndBoxesBox] = []
        var grantedExtraTurn = false
        var didGameEnd = false
        for event in events {
            switch event {
            case .boxCompleted(let box, _): completedThisClaim.append(box)
            case .extraTurn: grantedExtraTurn = true
            case .gameOver: didGameEnd = true
            default: break
            }
        }

        if !completedThisClaim.isEmpty {
            Haptics.tick()
            flourishClearWorkItem?.cancel()
            extraTurnFlourishBoxes = Set(completedThisClaim)
            if grantedExtraTurn {
                let clear = DispatchWorkItem { [weak self] in self?.extraTurnFlourishBoxes = [] }
                flourishClearWorkItem = clear
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: clear)
            }
        }

        if didGameEnd {
            Haptics.play()
            botTimer?.invalidate()
            botTimer = nil
        } else {
            scheduleBotIfNeeded()
        }
    }

    /// If it's a bot's turn, schedule its move after a humanlike pause.
    /// Re-checked at fire time (same guard-everything-at-fire-time pattern
    /// as `BotDirector.evaluate`), so a stale timer from a since-
    /// superseded state (a "Play Again" mid-flight) just fizzles instead
    /// of firing into the new game.
    private func scheduleBotIfNeeded() {
        botTimer?.invalidate()
        botTimer = nil
        guard !engine.state.isGameOver else { return }
        let mover = engine.state.turnIndex
        guard engine.state.players.indices.contains(mover), engine.state.players[mover].isBot else { return }
        let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            self?.runBotMove()
        }
        RunLoop.main.add(timer, forMode: .common)
        botTimer = timer
    }
}
