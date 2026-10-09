import Foundation

/// Launch-arg demo states for screenshot verification (`-demoTable`,
/// `-demoHand`). Everything flows through the REAL engine — these script
/// inputs, they never fake render state.
enum DemoData {
    static var wantsTableDemo: Bool { CommandLine.arguments.contains("-demoTable") }
    /// Any offline hand demo: the generic Wizard one plus the hearts /
    /// spades variants below. Everything that gates "no Multipeer session"
    /// keys off this, so the variants stay offline too.
    static var wantsHandDemo: Bool {
        CommandLine.arguments.contains("-demoHand") || wantsHandHeartsDemo || wantsHandSpadesDemo
    }
    static var wantsFreePlayDemo: Bool { CommandLine.arguments.contains("-demoFreePlay") }

    /// Hearts/Spades UI wave: `-demoHandHearts` puts seat 0's phone in the
    /// round-1 passing phase (pass left, nothing committed yet). Add
    /// `-demoHandHeartsPassed` to have seats 1 and 2 already committed, so
    /// the hand shows the "Waiting for ..." state with one seat still out
    /// (seat 0 itself still picks; the screenshot covers the per-seat
    /// progress copy). `-demoHandSpades` lands on seat 0's own bid turn
    /// with blind nil ON and the other three bids already in, so the bid
    /// sheet shows the face-down "Blind Nil / Peek" choice plus the
    /// partner's bid line.
    static var wantsHandHeartsDemo: Bool { CommandLine.arguments.contains("-demoHandHearts") }
    static var wantsHandSpadesDemo: Bool { CommandLine.arguments.contains("-demoHandSpades") }

    /// Wave-4 fan-layout screenshot verification hook: `-demoHandCount N`
    /// forces exactly N cards into the `-demoHand` snapshot instead of
    /// whatever count round 5 of the scripted Wizard game naturally leaves
    /// seat 0 holding. Lets us shoot a 3-card, 7-card, or 13-card fan on
    /// demand (see `makeHandSnapshot`) without hand-tuning the scripted
    /// game to land on a specific count. Real play never sets this — it's
    /// read only by the demo path.
    static var demoHandCountOverride: Int? {
        guard let idx = CommandLine.arguments.firstIndex(of: "-demoHandCount"),
              CommandLine.arguments.indices.contains(idx + 1) else { return nil }
        return Int(CommandLine.arguments[idx + 1])
    }

    /// Wave-5 gesture-freeze screenshot hook: `-demoDragProgress <0...1>`
    /// (with `-demoHand`) asks HandView to render a fan card as if a real
    /// finger had it selected and lifted that fraction of the way to the
    /// play threshold — a static frozen frame, not an animation, so a
    /// screenshot taken any time after launch is deterministic. Nil (the
    /// flag absent) means "no demo gesture," the normal case. See
    /// HandView.applyDemoGestureIfAsked for the math that turns this into
    /// `dragState.translation`. Real play never sets this — read only by
    /// the demo path, same convention as `demoHandCountOverride` above.
    static var demoDragProgress: Double? {
        guard let idx = CommandLine.arguments.firstIndex(of: "-demoDragProgress"),
              CommandLine.arguments.indices.contains(idx + 1) else { return nil }
        return Double(CommandLine.arguments[idx + 1])
    }

    /// Optional companion to `demoDragProgress`: which card in the fan gets
    /// frozen, expressed as a lateral position (0 = leftmost, 1 = rightmost,
    /// 0.5 default = the middle card) rather than a raw index — so it stays
    /// meaningful across `-demoHandCount` values without the caller having
    /// to know the hand size. Lets edge cards (under the wide-hand fade
    /// cue) get screenshot-tested, not just the middle one.
    static var demoDragX: Double {
        guard let idx = CommandLine.arguments.firstIndex(of: "-demoDragX"),
              CommandLine.arguments.indices.contains(idx + 1),
              let value = Double(CommandLine.arguments[idx + 1]) else { return 0.5 }
        return value
    }

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

    /// 4-seat hearts, round 1 (pass left), seat 0 still to pass. With
    /// `-demoHandHeartsPassed`, seats 1 and 2 have committed via the real
    /// engine bot so the waiting copy names exactly one outstanding seat.
    static func makeHeartsHandEngine() -> HostEngine {
        let seats = names.enumerated().map {
            Seat(id: $0.offset, playerName: $0.element, colorIndex: $0.offset,
                 isConnected: true, isHost: false)
        }
        let engine = HostEngine(seats: seats, gameKind: .hearts,
                                rules: RulesConfig(), seed: 20261009)
        _ = engine.apply(.startGame(.hearts, RulesConfig(), seed: 20261009))
        if CommandLine.arguments.contains("-demoHandHeartsPassed") {
            for seat in [1, 2] {
                if let action = TrickBots.action(for: engine.state, seat: seat) {
                    _ = engine.apply(action, from: seat)
                }
            }
        }
        return engine
    }

    /// 4-seat partnership spades with blind nil on, bids from seats 1-3
    /// already in (the engine bots' own picks), seat 0 on turn.
    static func makeSpadesHandEngine() -> HostEngine {
        let seats = names.enumerated().map {
            Seat(id: $0.offset, playerName: $0.element, colorIndex: $0.offset,
                 isConnected: true, isHost: false)
        }
        let rules = RulesConfig(spadesBlindNil: true)
        let engine = HostEngine(seats: seats, gameKind: .spades, rules: rules, seed: 20261009)
        _ = engine.apply(.startGame(.spades, rules, seed: 20261009))
        var guardCount = 0
        while engine.state.phase == .bidding, let turn = engine.state.round?.turnSeat, turn != 0 {
            guardCount += 1; if guardCount > 8 { break }
            guard let action = TrickBots.action(for: engine.state, seat: turn) else { break }
            _ = engine.apply(action, from: turn)
        }
        return engine
    }

    /// A hand-screen snapshot: seat 0's real view of that same table state.
    /// Honors `demoHandCountOverride` (see above) by refilling `myHand`
    /// from the same real engine's remaining cards — drawn hands, the draw
    /// pile, and the discard, deduped by id — instead of the natural
    /// mid-round count. Every other field (phase, round, turn) is the real
    /// snapshot untouched, so the rest of HandView behaves exactly as it
    /// would mid-game; only the fan's card count is under test.
    static func makeHandSnapshot() -> ClientSnapshot {
        if wantsHandHeartsDemo { return makeHeartsHandEngine().state.snapshot(for: 0) }
        if wantsHandSpadesDemo { return makeSpadesHandEngine().state.snapshot(for: 0) }
        let engine = makeTableEngine()
        let base = engine.state.snapshot(for: 0)
        guard let count = demoHandCountOverride, count >= 0 else { return base }

        var pool: [Card] = []
        var seenIDs = Set<String>()
        let allKnownCards = engine.state.hands.values.flatMap { $0 }
            + engine.state.drawPile
            + engine.state.discardPile
        for card in allKnownCards where seenIDs.insert(card.id).inserted {
            pool.append(card)
        }

        return ClientSnapshot(
            gameKind: base.gameKind,
            rules: base.rules,
            seats: base.seats,
            phase: base.phase,
            round: base.round,
            roundHistory: base.roundHistory,
            mySeat: base.mySeat,
            myHand: Array(pool.prefix(count)),
            handCounts: base.handCounts,
            drawCount: base.drawCount,
            discardPile: base.discardPile,
            myPendingDraw: base.myPendingDraw
        )
    }
}
