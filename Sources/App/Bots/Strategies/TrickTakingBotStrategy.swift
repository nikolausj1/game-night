import Foundation

/// Wizard and Oh Hell: bid what the hand looks like it can take, then steer
/// toward that bid — chase tricks cheaply while short, duck loudly once
/// level. Competent family opponent, not a solver.
struct TrickTakingBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .bid:
            return .placeBid(bid(state: state, seat: seat))
        case .chooseTrump:
            return .chooseTrump(bestTrumpSuit(state: state, seat: seat))
        case .play:
            return playCard(state: state, seat: seat)
        case .declareSuit:
            return nil // not a trick-game decision
        }
    }

    // MARK: - Bidding

    /// Sure-winners heuristic: wizards are tricks, trump honors are most of
    /// a trick, off-suit aces and kings are partial tricks. Sum, round,
    /// clamp to the legal range, and dodge the screw-the-dealer trap.
    private func bid(state: GameState, seat: Int) -> Int {
        guard let round = state.round else { return 0 }
        let hand = state.hands[seat] ?? []
        let trump = round.trumpSuit

        var expected = 0.0
        for card in hand {
            switch card.kind {
            case .wizard:
                expected += 1.0
            case .jester:
                break
            case .uno:
                break // UNO cards never appear in trick games
            case .standard(let suit, let rank):
                if let trump, suit == trump {
                    switch rank {
                    case 14: expected += 0.95
                    case 13: expected += 0.8
                    case 12: expected += 0.6
                    case 9...11: expected += 0.35
                    default: expected += 0.15
                    }
                } else {
                    switch rank {
                    case 14: expected += 0.7
                    case 13: expected += 0.35
                    default: break
                    }
                }
            }
        }

        var bid = max(0, min(Int(expected.rounded()), round.cardsPerPlayer))
        if state.rules.screwTheDealer, seat == round.dealerSeat {
            let othersTotal = round.bids.values.reduce(0, +)
            if othersTotal + bid == round.cardsPerPlayer {
                // Nudge off the forbidden total, staying in range. Prefer
                // down (underbidding is the cheaper miss in both games).
                bid = bid > 0 ? bid - 1 : bid + 1
                bid = max(0, min(bid, round.cardsPerPlayer))
            }
        }
        return bid
    }

    /// Dealer flipped a wizard: trump the longest suit, rank-weighted so a
    /// suit of honors beats a suit of spot cards on ties.
    private func bestTrumpSuit(state: GameState, seat: Int) -> Suit {
        let hand = state.hands[seat] ?? []
        var score: [Suit: Int] = [:]
        for card in hand {
            if case .standard(let suit, let rank) = card.kind {
                score[suit, default: 0] += 20 + rank // length dominates, rank breaks ties
            }
        }
        return score.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.rawValue > rhs.key.rawValue
        }?.key ?? .spades
    }

    // MARK: - Card play

    private func playCard(state: GameState, seat: Int) -> PlayerAction? {
        guard let round = state.round else { return nil }
        let legal = legalCards(state: state, seat: seat)
        guard !legal.isEmpty else { return nil } // can't happen in trick games

        let trick = round.currentTrick
        let trump = round.trumpSuit
        let rules = state.gameKind.ruleset
        let bid = round.bids[seat] ?? 0
        let won = round.tricksWon[seat] ?? 0
        let wantWin = won < bid
        let amLast = trick.count == state.seats.count - 1
        let lateInTrick = trick.count >= state.seats.count - 2

        /// Rough card power for ordering choices (winner-ness itself comes
        /// from the real ruleset below, never from this number).
        func strength(_ card: Card) -> Int {
            switch card.kind {
            case .wizard: return 1000
            case .jester: return 0
            case .uno: return 0 // never appears in trick games
            case .standard(let suit, let rank):
                if let trump, suit == trump { return 200 + rank }
                return rank
            }
        }

        /// Would this card hold the trick as played so far? Exact when
        /// we're last; a "currently winning" proxy otherwise.
        func currentlyWins(_ card: Card) -> Bool {
            var simulated = trick
            simulated.append(TrickPlay(seat: seat, card: card, wasForced: false))
            return rules.trickWinner(simulated, trump: trump) == seat
        }

        let byStrength = legal.sorted { strength($0) < strength($1) }

        // Leading a trick
        if trick.isEmpty {
            if wantWin {
                // Lead our best standard card; keep wizards in the pocket
                // unless they're all we have.
                let nonWizards = byStrength.filter { !$0.isWizard }
                let lead = nonWizards.last ?? byStrength.last!
                return .playCard(cardID: lead.id, force: false)
            }
            // Ducking: lead the weakest thing we own (jester counts as 0).
            return .playCard(cardID: byStrength.first!.id, force: false)
        }

        // Following, still hungry for tricks
        if wantWin {
            let standardWinners = byStrength.filter { currentlyWins($0) && !$0.isWizard }
            if let cheapest = standardWinners.first {
                return .playCard(cardID: cheapest.id, force: false)
            }
            // No standard card takes it. Spend a wizard only late in the
            // trick, when "currently winning" is (nearly) final.
            if lateInTrick || amLast, let wizard = legal.first(where: { $0.isWizard }) {
                return .playCard(cardID: wizard.id, force: false)
            }
            // Can't win this one: dump the weakest and wait.
            let dump = byStrength.first { !$0.isWizard } ?? byStrength.first!
            return .playCard(cardID: dump.id, force: false)
        }

        // Following, at (or over) bid: duck. Jester is the perfect duck;
        // otherwise shed the strongest card that still loses.
        if let jester = legal.first(where: { $0.isJester }) {
            return .playCard(cardID: jester.id, force: false)
        }
        let losers = byStrength.filter { !currentlyWins($0) }
        if let biggestLoser = losers.last {
            return .playCard(cardID: biggestLoser.id, force: false)
        }
        // Forced to win: do it as cheaply as possible.
        return .playCard(cardID: byStrength.first!.id, force: false)
    }
}
