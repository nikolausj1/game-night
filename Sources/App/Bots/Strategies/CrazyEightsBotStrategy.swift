import Foundation

/// Crazy Eights: bleed the suit you're longest in, spend high cards first,
/// and treat eights as escape hatches — never fuel.
struct CrazyEightsBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .play:
            return play(state: state, seat: seat)
        case .declareSuit:
            return .declareSuit(mostHeldSuit(in: state.hands[seat] ?? []))
        case .bid, .chooseTrump:
            return nil // not Crazy Eights decisions
        }
    }

    private func play(state: GameState, seat: Int) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = legalCards(state: state, seat: seat)

        if legal.isEmpty {
            // Stuck: draw voluntarily — but only if the engine actually has
            // cards to give (draw pile, or a discard pile it can recycle).
            // Otherwise stand pat instead of spamming rejects.
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }

        // Hold eights until stuck: prefer any legal non-eight.
        let nonEights = legal.filter { $0.rank != 8 }
        if let best = bestNonEight(from: nonEights, hand: hand) {
            return .playCard(cardID: best.id, force: false)
        }
        // Only eights are playable — that's what they're for.
        if let eight = legal.first {
            return .playCard(cardID: eight.id, force: false)
        }
        return nil
    }

    /// Play from the suit we hold most of (keeps future options open),
    /// shedding the highest rank first within it.
    private func bestNonEight(from candidates: [Card], hand: [Card]) -> Card? {
        guard !candidates.isEmpty else { return nil }
        let counts = suitCounts(in: hand)
        return candidates.max { lhs, rhs in
            let lhsSuit = lhs.suit.map { counts[$0] ?? 0 } ?? 0
            let rhsSuit = rhs.suit.map { counts[$0] ?? 0 } ?? 0
            if lhsSuit != rhsSuit { return lhsSuit < rhsSuit }
            return (lhs.rank ?? 0) < (rhs.rank ?? 0)
        }
    }

    /// Declared suit after an eight: whatever the remaining hand is longest
    /// in (eights excluded — they match anything anyway).
    private func mostHeldSuit(in hand: [Card]) -> Suit {
        let counts = suitCounts(in: hand)
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.rawValue > rhs.key.rawValue
        }?.key ?? .hearts
    }

    private func suitCounts(in hand: [Card]) -> [Suit: Int] {
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank != 8 {
            if let suit = card.suit { counts[suit, default: 0] += 1 }
        }
        return counts
    }
}
