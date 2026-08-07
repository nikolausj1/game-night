import SwiftUI

/// Owns the pure `QuartoEngine` and drives the two things a view can't:
/// turning game events into table sound, and scheduling a bot's move after
/// a humanlike pause. Drag/gesture state (what's being dragged, which cell
/// is hovered) stays in `QuartoView` as transient `@State` — that's
/// presentation, not game state, and doesn't belong here. Mirrors
/// `BotDirector`'s shape (event-driven + a fallback timer) but simpler:
/// Quarto is strictly two players passing one physical object, so there's
/// never more than one pending bot move to track.
@Observable
final class QuartoController {
    private(set) var engine: QuartoEngine
    /// Bumped on every apply so views relying on plain `@Observable`
    /// tracking (reading `engine.state` through a computed var) still
    /// invalidate — `engine` itself is a class, so mutating its internal
    /// `state` doesn't trigger observation on its own.
    private(set) var revision = 0
    /// The most recent event batch, for one-shot UI reactions (e.g. the
    /// win overlay deciding whether to play its entrance transition).
    private(set) var lastEvents: [QuartoEvent] = []

    private var botMoveScheduled = false

    init(players: [QuartoPlayer], use2x2Variant: Bool, firstPlayer: Int = 0) {
        engine = QuartoEngine(players: players, use2x2Variant: use2x2Variant, firstPlayer: firstPlayer)
    }

    /// Adopts an already-in-progress state without replaying it through
    /// `perform` — used by the `-demoQuarto` harness (`QuartoDemo.swift`)
    /// so scripting a mid-game position doesn't fire table sound for every
    /// setup step on launch.
    init(restoring state: QuartoState) {
        engine = QuartoEngine(restoring: state)
    }

    var state: QuartoState { engine.state }

    /// Dispatches `action` as the CURRENT player (drag gestures and the bot
    /// both route through here — neither ever needs to name a seat, since
    /// in local pass-and-play "whoever's turn it is" is unambiguous).
    func perform(_ action: QuartoAction) {
        let seat = engine.state.currentPlayer
        let events = engine.apply(action, from: seat)
        guard !events.contains(where: { if case .illegalAttempt = $0 { return true }; return false }) else {
            return // a gesture mis-hit a taken cell or stale piece id — no-op, no sound, no state bump
        }
        lastEvents = events
        revision += 1
        playSound(for: events)
        scheduleBotIfNeeded()
    }

    func restart(players: [QuartoPlayer], use2x2Variant: Bool, firstPlayer: Int = 0) {
        botMoveScheduled = false
        lastEvents = engine.restart(players: players, use2x2Variant: use2x2Variant, firstPlayer: firstPlayer)
        revision += 1
        scheduleBotIfNeeded()
    }

    private func playSound(for events: [QuartoEvent]) {
        for event in events {
            switch event {
            case .piecePlaced:
                TableSFX.shared.play(.tableKnock, intensity: 0.85)
            case .pieceSelected:
                TableSFX.shared.play(.chipPass)
            case .gameWon:
                TableSFX.shared.play(.fanfareWin)
            case .draw:
                TableSFX.shared.play(.softChime)
            case .gameStarted, .illegalAttempt:
                break
            }
        }
    }

    // MARK: - Bot scheduling

    /// If it's a bot's turn and nothing is already scheduled, run its move
    /// after a humanlike pause. Everything is re-checked at fire time, so a
    /// stale schedule (a restart mid-delay) fizzles safely instead of
    /// acting on a game that's moved on.
    func scheduleBotIfNeeded() {
        guard !botMoveScheduled, engine.state.phase != .gameOver else { return }
        let seat = engine.state.currentPlayer
        guard engine.state.players[seat].isBot else { return }
        botMoveScheduled = true
        let generation = revision
        let pause = 0.55 + Double.random(in: 0...0.45)
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            self?.runBotMove(expectedGeneration: generation)
        }
    }

    private func runBotMove(expectedGeneration: Int) {
        botMoveScheduled = false
        guard revision == expectedGeneration, engine.state.phase != .gameOver else { return }
        let seat = engine.state.currentPlayer
        guard engine.state.players[seat].isBot else { return }
        // Seed derived from move count + seat so a replayed/resumed game
        // (same position reached twice) still picks the same move, while
        // different positions across one game naturally get different seeds.
        let seed = UInt64(engine.state.moveCount) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(seat)
        let action = QuartoBot.decide(state: engine.state, seed: seed)
        perform(action)
    }
}
