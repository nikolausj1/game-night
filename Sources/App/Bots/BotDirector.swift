import Foundation

/// Watches the host and plays the bots' turns. Two triggers, same
/// evaluation: the host's onEvents chain (wired exactly like
/// AnnouncerDirectorHolder in TableRootView) and a heartbeat timer — the
/// timer matters because some transitions emit no events at all
/// (`.nextTrick` returns [] and hands the lead to the trick winner).
///
/// Bots only ever perform PlayerActions through `host.botAction`; table
/// actions (nextTrick, nextRound, undo approval) stay with the humans at
/// the iPad, so the table keeps its rhythm.
@MainActor
final class BotDirector {
    private weak var host: GameHostController?
    private var heartbeat: Timer?

    /// Re-entrancy guard: at most one bot action is ever scheduled. Since
    /// play is strictly turn-based, one pending action is also all that can
    /// legally exist.
    private var scheduledSeat: Int?

    /// Seats that just won a trick get an extra half-second before leading —
    /// even a bot should savor it.
    private var savoringSeats: Set<Int> = []

    /// Chain onto the host's event stream (preserving whoever is already
    /// listening) and start the heartbeat. Safe to call once per director.
    func wire(to host: GameHostController) {
        guard self.host == nil else { return }
        self.host = host
        let previous = host.onEvents
        host.onEvents = { [weak self] events in
            previous?(events)
            // Session callbacks can arrive off-main; decisions happen on main.
            Task { @MainActor in self?.observe(events) }
        }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    func unwire() {
        heartbeat?.invalidate()
        heartbeat = nil
        scheduledSeat = nil
        savoringSeats = []
        host = nil
    }

    deinit {
        heartbeat?.invalidate()
    }

    // MARK: - Event intake

    private func observe(_ events: [GameEvent]) {
        if let host {
            for case .trickWon(let seat) in events where host.botSeats.contains(seat) {
                savoringSeats.insert(seat)
            }
        }
        evaluate()
    }

    // MARK: - Decision loop

    /// If it's a bot's turn and nothing is scheduled, schedule its move
    /// after a humanlike pause. Everything is re-checked at fire time, so a
    /// stale schedule (undo, new deal, humans racing ahead) fizzles safely.
    private func evaluate() {
        guard scheduledSeat == nil,
              let host,
              let state = host.state,
              let (seat, decision) = Self.pendingDecision(in: state),
              host.botSeats.contains(seat)
        else { return }

        scheduledSeat = seat
        var delay = Double.random(in: 0.9...2.0)
        if savoringSeats.remove(seat) != nil { delay += 0.5 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fire(seat: seat, decision: decision)
        }
    }

    private func fire(seat: Int, decision: BotDecision) {
        scheduledSeat = nil
        guard let host, let state = host.state else { return }
        // The world may have moved on while we "thought" — only act if this
        // exact decision is still the one the engine is waiting on.
        guard let (currentSeat, currentDecision) = Self.pendingDecision(in: state),
              currentSeat == seat,
              currentDecision == decision,
              host.botSeats.contains(seat)
        else {
            evaluate() // maybe a different bot is up now
            return
        }
        guard let strategy = BotStrategyFactory.strategy(for: state.gameKind),
              let action = strategy.action(decision, state: state, seat: seat)
        else { return }
        host.botAction(action, from: seat)
        evaluate() // back-to-back bot turns shouldn't wait for the heartbeat
    }

    /// What is the engine waiting on, and from whom? nil covers lobby,
    /// dealing, trickComplete/roundComplete (table-driven), and gameOver.
    static func pendingDecision(in state: GameState) -> (seat: Int, decision: BotDecision)? {
        switch state.phase {
        case .bidding:
            guard let round = state.round else { return nil }
            return (round.turnSeat, .bid)
        case .choosingTrump(let seat):
            return (seat, state.gameKind == .wizard ? .chooseTrump : .declareSuit)
        case .playing:
            guard state.gameKind != .freePlay, let round = state.round else { return nil }
            return (round.turnSeat, .play)
        case .lobby, .dealing, .trickComplete, .roundComplete, .gameOver:
            return nil
        }
    }
}
