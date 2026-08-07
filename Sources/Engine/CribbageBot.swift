import Foundation

/// Pure heuristic functions the UI-side bot calls against a
/// `CribbageEngine`'s public state — no engine access, no side effects,
/// deterministic given the caller's `rng` (only used to break exact ties
/// reproducibly).
public enum CribbageBot {
    /// Picks 2 of the 6 dealt cards to send to the crib. Maximizes the
    /// expected show value of the kept 4-card hand (averaged over every
    /// unseen card as a hypothetical starter — cheap: 15 discard choices ×
    /// 46 starters), then nudges the choice by a static crib-friendliness
    /// heuristic on the two discarded cards: keep them out of the
    /// opponent's crib (avoid pairs, adjacent ranks, 5s, matching suit) or
    /// lean into them for your own (the same signals, inverted).
    public static func discard(hand: [Card], isDealer: Bool, rng: inout SeededGenerator) -> [Card] {
        guard hand.count == 6 else { return Array(hand.prefix(2)) }

        let unseen = DeckBuilder.standard52().filter { card in
            !hand.contains { $0.id == card.id }
        }

        var bestScore = -Double.infinity
        var bestDiscard: [Card] = Array(hand.prefix(2))

        for (discard, kept) in discardChoices(hand) {
            var total = 0
            for starter in unseen {
                total += CribbageScoring.scoreShow(cards: kept, starter: starter, isCrib: false).points
            }
            let avgHandValue = Double(total) / Double(unseen.count)
            let cribBias = cribFriendliness(discard)
            let score = avgHandValue + (isDealer ? cribBias : -cribBias)

            if score > bestScore || (score == bestScore && Bool.random(using: &rng)) {
                bestScore = score
                bestDiscard = discard
            }
        }
        return bestDiscard
    }

    /// Picks one legal card to peg, or `nil` if none is legal (the engine's
    /// auto-go handles that turn from here). Prioritizes immediate pegging
    /// points (15/31/pair/run), then avoids leaving the count at 5 or 21
    /// (a free 15-for-two or 31 handed to the opponent on a 10-value card),
    /// then avoids leading a 5 into an empty count (an easy 15 for the
    /// opponent's very next card).
    public static func pegPlay(hand: [Card], sequence: [Card], count: Int, rng: inout SeededGenerator) -> Card? {
        let legal = hand.filter { CribbageScoring.pegValue($0) + count <= 31 }
        guard !legal.isEmpty else { return nil }

        var bestCard: Card?
        var bestScore = Int.min
        for card in legal {
            let projectedCount = count + CribbageScoring.pegValue(card)
            let projectedSequence = sequence + [card]
            let entries = CribbageScoring.peggingScore(sequence: projectedSequence, count: projectedCount)
            var score = entries.reduce(0) { $0 + $1.points } * 10

            if projectedCount == 5 || projectedCount == 21 { score -= 3 }
            if count == 0 && card.rank == 5 { score -= 2 }

            if score > bestScore || (score == bestScore && Bool.random(using: &rng)) {
                bestScore = score
                bestCard = card
            }
        }
        return bestCard
    }

    // MARK: - Helpers

    /// All 15 ways to split a 6-card hand into (2 discarded, 4 kept).
    private static func discardChoices(_ hand: [Card]) -> [(discard: [Card], kept: [Card])] {
        var result: [(discard: [Card], kept: [Card])] = []
        for i in 0..<hand.count {
            for j in (i + 1)..<hand.count {
                var kept = hand
                let second = kept.remove(at: j)
                let first = kept.remove(at: i)
                result.append((discard: [first, second], kept: kept))
            }
        }
        return result
    }

    /// Static crib-fodder heuristic for a candidate discard pair — higher
    /// means "more likely to score well in whoever's crib it lands in".
    private static func cribFriendliness(_ pair: [Card]) -> Double {
        guard let r0 = pair[0].rank, let r1 = pair[1].rank else { return 0 }
        var value = 0.0
        if r0 == r1 { value += 2 } // a pair discarded together
        let gap = abs(r0 - r1)
        if gap == 1 { value += 1 } // adjacent ranks: run potential
        if gap == 2 { value += 0.5 }
        if CribbageScoring.pegValue(pair[0]) + CribbageScoring.pegValue(pair[1]) == 15 { value += 1 }
        if r0 == 5 || r1 == 5 { value += 0.5 } // 5s pair with every 10-value card
        if pair[0].suit == pair[1].suit { value += 0.3 } // minor flush potential
        return value
    }
}
