import Foundation

/// Launch-arg demo states for screenshot verification (`-demoTable`,
/// `-demoHand`). Everything flows through the REAL engine — these script
/// inputs, they never fake render state.
enum DemoData {
    static var wantsTableDemo: Bool { CommandLine.arguments.contains("-demoTable") }
    static var wantsHandDemo: Bool { CommandLine.arguments.contains("-demoHand") }
    static var wantsFreePlayDemo: Bool { CommandLine.arguments.contains("-demoFreePlay") }

    /// Solo free-play: one seat, a few cards drawn, a few played to the felt.
    static func makeFreePlayEngine() -> HostEngine {
        let seat = Seat(id: 0, playerName: "Justin", colorIndex: 0,
                        isConnected: true, isHost: false)
        let engine = HostEngine(seats: [seat], gameKind: .freePlay,
                                rules: RulesConfig(), seed: 42)
        _ = engine.apply(.startGame(.freePlay, RulesConfig(), seed: 42))
        for _ in 0..<7 { _ = engine.apply(.drawCard, from: 0) }
        for _ in 0..<4 {
            if let card = engine.state.hands[0]?.first {
                _ = engine.apply(.playCard(cardID: card.id, force: false), from: 0)
            }
        }
        return engine
    }

    static let names = ["Justin", "Sarah", "Vinny", "Chase"]

    /// Drive a real 4-player Wizard game to round 5, mid-trick.
    static func makeTableEngine() -> HostEngine {
        let seats = names.enumerated().map {
            Seat(id: $0.offset, playerName: $0.element, colorIndex: $0.offset,
                 isConnected: true, isHost: false)
        }
        let engine = HostEngine(seats: seats, gameKind: .wizard,
                                rules: RulesConfig(), seed: 20260719)
        _ = engine.apply(.startGame(.wizard, RulesConfig(), seed: 20260719))

        for round in 1...5 {
            runBidding(engine)
            if round < 5 {
                runAllTricks(engine)
                _ = engine.apply(.nextRound)
            } else {
                // Leave a 3-card trick on the felt for the screenshot.
                playTrickPlays(engine, count: 3)
            }
        }
        return engine
    }

    private static func runBidding(_ engine: HostEngine) {
        var guardCount = 0
        while engine.state.phase == .bidding || isChoosingTrump(engine.state.phase) {
            guardCount += 1; if guardCount > 40 { return }
            if case .choosingTrump(let seat) = engine.state.phase {
                _ = engine.apply(.chooseTrump(.hearts), from: seat)
                continue
            }
            guard let turn = engine.state.round?.turnSeat else { return }
            let cards = engine.state.round?.cardsPerPlayer ?? 1
            _ = engine.apply(.placeBid(min(1, cards)), from: turn)
        }
    }

    private static func runAllTricks(_ engine: HostEngine) {
        var guardCount = 0
        while engine.state.phase == .playing || isTrickComplete(engine.state.phase) {
            guardCount += 1; if guardCount > 400 { return }
            if isTrickComplete(engine.state.phase) {
                _ = engine.apply(.nextTrick)
                continue
            }
            playOneLegalCard(engine)
        }
    }

    private static func playTrickPlays(_ engine: HostEngine, count: Int) {
        for _ in 0..<count where engine.state.phase == .playing {
            playOneLegalCard(engine)
        }
    }

    private static func playOneLegalCard(_ engine: HostEngine) {
        guard let turn = engine.state.round?.turnSeat,
              let hand = engine.state.hands[turn] else { return }
        for card in hand {
            let events = engine.apply(.playCard(cardID: card.id, force: false), from: turn)
            let rejected = events.contains { if case .illegalAttempt = $0 { return true }; return false }
            if !rejected { return }
        }
    }

    private static func isChoosingTrump(_ phase: Phase) -> Bool {
        if case .choosingTrump = phase { return true }; return false
    }

    private static func isTrickComplete(_ phase: Phase) -> Bool {
        if case .trickComplete = phase { return true }; return false
    }

    /// A hand-screen snapshot: seat 0's real view of that same table state.
    static func makeHandSnapshot() -> ClientSnapshot {
        makeTableEngine().state.snapshot(for: 0)
    }
}
