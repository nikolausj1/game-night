import Foundation

/// Tunable bot temperament.
public struct GinBotPersonality: Codable, Sendable, Equatable {
    /// Knock as soon as deadwood after discarding is at most this (<= 10).
    public var knockThreshold: Int
    /// Gin-chase hook. 0 = never chase. Otherwise, when deadwood after
    /// discarding is <= `ginChase`, the stock still has 8+ cards, and the
    /// hand is one card from gin with at least 2 live outs, keep playing
    /// instead of knocking.
    public var ginChase: Int

    public init(knockThreshold: Int = 10, ginChase: Int = 0) {
        self.knockThreshold = max(0, min(10, knockThreshold))
        self.ginChase = max(0, ginChase)
    }

    /// Knocks the moment it legally can.
    public static let eager = GinBotPersonality(knockThreshold: 10, ginChase: 0)
    /// Waits for a tidy hand (<= 6) and chases gin when nearly there.
    public static let balanced = GinBotPersonality(knockThreshold: 6, ginChase: 3)
    /// Only knocks very low and chases gin hard.
    public static let ginChaser = GinBotPersonality(knockThreshold: 4, ginChase: 6)
}

/// Pure, deterministic Gin Rummy AI over a seat's `GinRummySnapshot`.
///
/// - Draw: takes the upcard when doing so (with the best follow-up discard)
///   lowers deadwood, or ties it while the upcard sits in a meld; otherwise
///   the stock. First-upcard offer uses the same test.
/// - Discard: for each legal discard, score = deadwood left, minus 0.35 per
///   "out" (unseen card that would meld with what remains), plus a danger
///   penalty for feeding cards the opponent is known to want (they took a
///   same-rank / same-suit-neighbour card from the pile), minus a small
///   bonus for dumping high cards. Lowest score wins; exact ties break on
///   the caller's seeded `rng`.
/// - Knock: gin always; else per `GinBotPersonality`.
/// - Layoff: `.autoLayoff` (the optimal play).
public enum GinRummyBot {
    /// The next legal action for the seat in `snapshot`, or nil if it is not
    /// that seat's move (including `.handComplete`: use `.advance` yourself,
    /// or pass `advanceIfComplete: true`).
    public static func nextAction(
        snapshot: GinRummySnapshot, personality: GinBotPersonality = .balanced,
        rng: inout SeededGenerator, advanceIfComplete: Bool = false
    ) -> GinRummyAction? {
        switch snapshot.phase {
        case .gameOver:
            return nil
        case .handComplete:
            return advanceIfComplete ? .advance : nil
        case .firstUpcard, .draw:
            guard snapshot.isMyTurn else { return nil }
            return chooseDraw(snapshot: snapshot)
        case .discard:
            guard snapshot.isMyTurn else { return nil }
            return chooseDiscardOrKnock(snapshot: snapshot, personality: personality, rng: &rng)
        case .layoff:
            return snapshot.isMyTurn ? .autoLayoff : nil
        }
    }

    // MARK: - Draw

    public static func chooseDraw(snapshot: GinRummySnapshot) -> GinRummyAction {
        let first = snapshot.phase == .firstUpcard
        guard let up = snapshot.upcard, !snapshot.upcardRefused else { return .drawStock }
        let hand = snapshot.myHand
        let current = GinMelds.minDeadwood(hand)
        let plus = hand + [up]
        var bestAfter = Int.max
        for c in plus where c != up {
            bestAfter = min(bestAfter, GinMelds.minDeadwood(plus.filter { $0 != c }))
        }
        var take = bestAfter < current
        if !take && bestAfter == current {
            // Tie: take it if the upcard actually joins a meld in the best partition.
            take = GinMelds.bestArrangement(plus).melds.contains { $0.cards.contains(up) }
                && GinMelds.bestArrangement(plus).deadwoodPoints <= current
        }
        if take { return .drawUpcard }
        return first ? .passUpcard : .drawStock
    }

    // MARK: - Discard / knock

    struct Candidate {
        let card: Card
        let deadwood: Int
        let score: Double
        let outs: Int
    }

    public static func chooseDiscardOrKnock(
        snapshot: GinRummySnapshot, personality: GinBotPersonality, rng: inout SeededGenerator
    ) -> GinRummyAction {
        let hand = snapshot.myHand
        let legal = hand.filter { $0.id != snapshot.drawnFromDiscardID }
        let unseen = unseenCards(snapshot)
        let known = snapshot.opponentKnownCards
        let opponentDiscards = snapshot.moves.compactMap { m -> Card? in
            if m.seat != snapshot.mySeat, case .discarded(let c) = m.kind { return c }
            return nil
        }

        // Deadwood per candidate first (cheap), then outs only for near-best.
        let dws = legal.map { c in GinMelds.minDeadwood(hand.filter { $0 != c }) }
        let minDw = dws.min() ?? 0
        var cands: [Candidate] = []
        for (i, c) in legal.enumerated() {
            let dw = dws[i]
            var outs = 0
            if dw <= minDw + 4 {
                outs = countOuts(rest: hand.filter { $0 != c }, deadwood: dw, unseen: unseen)
            }
            let danger = dangerScore(c, known: known, opponentDiscards: opponentDiscards)
            let score = Double(dw) - 0.35 * Double(outs) + 0.8 * Double(danger) - 0.01 * Double(GinRummyCards.points(c))
            cands.append(Candidate(card: c, deadwood: dw, score: score, outs: outs))
        }

        // Knock?
        if minDw <= GinRummyRules.knockMax {
            let knockers = cands.filter { $0.deadwood == minDw && snapshot.knockDiscards.contains($0.card.id) }
            if let pick = knockers.min(by: { $0.score < $1.score }) {
                if minDw == 0 { return .knock(discard: pick.card.id, melds: nil) }
                if minDw <= personality.knockThreshold {
                    if personality.ginChase > 0, minDw <= personality.ginChase, snapshot.stockCount >= 8,
                       let chase = ginChaseCandidate(hand: hand, cands: cands.filter { $0.deadwood == minDw }, unseen: unseen) {
                        return .discard(cardID: chase.card.id)
                    }
                    return .knock(discard: pick.card.id, melds: nil)
                }
            }
        }
        let best = cands.map(\.score).min() ?? 0
        let top = cands.filter { abs($0.score - best) < 1e-9 }
        return .discard(cardID: top[Int.random(in: 0..<top.count, using: &rng)].card.id)
    }

    /// Cards not in my hand, not in the visible discard pile, and not known to be in the opponent's hand.
    static func unseenCards(_ s: GinRummySnapshot) -> [Card] {
        let gone = Set(s.myHand).union(s.discardPile)
        return DeckBuilder.standard52().filter { !gone.contains($0) && !s.opponentKnownCards.contains($0) }
    }

    /// Unseen cards that would meld usefully with a 10-card remainder.
    static func countOuts(rest: [Card], deadwood: Int, unseen: [Card]) -> Int {
        var outs = 0
        for u in unseen {
            // Cheap prefilter: same rank in hand, or same suit within 2 ranks.
            let r = GinRummyCards.rank(u)
            let near = rest.contains { c in
                let cr = GinRummyCards.rank(c)
                return cr == r || (c.suit == u.suit && abs(cr - r) <= 2)
            }
            guard near else { continue }
            if GinMelds.minDeadwood(rest + [u]) < deadwood + GinRummyCards.points(u) { outs += 1 }
        }
        return outs
    }

    static func dangerScore(_ c: Card, known: [Card], opponentDiscards: [Card]) -> Int {
        var danger = 0
        let r = GinRummyCards.rank(c)
        for k in known {
            let kr = GinRummyCards.rank(k)
            if kr == r { danger += 2 }
            else if k.suit == c.suit, abs(kr - r) == 1 { danger += 2 }
            else if k.suit == c.suit, abs(kr - r) == 2 { danger += 1 }
        }
        // Echoing something the opponent already threw away is safe.
        for d in opponentDiscards {
            let dr = GinRummyCards.rank(d)
            if dr == r || (d.suit == c.suit && abs(dr - r) == 1) { danger -= 1; break }
        }
        return max(0, danger)
    }

    /// A discard that leaves a one-card-from-gin hand with >= 2 live outs.
    static func ginChaseCandidate(hand: [Card], cands: [Candidate], unseen: [Card]) -> Candidate? {
        var best: (Candidate, Int)?
        for cand in cands {
            let rest = hand.filter { $0 != cand.card }
            guard GinMelds.minDeadwood(rest) > 0 else { continue }
            var ginOuts = 0
            for u in unseen {
                let all = rest + [u]
                if all.contains(where: { x in GinMelds.minDeadwood(all.filter { $0 != x }) == 0 }) { ginOuts += 1 }
            }
            if ginOuts >= 2, ginOuts > (best?.1 ?? 0) { best = (cand, ginOuts) }
        }
        return best?.0
    }
}
