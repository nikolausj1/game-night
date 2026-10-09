import Foundation

/// Pure functions the UI-side bot calls against a `CribbageEngine`'s public
/// state — no engine access, no side effects, deterministic given the
/// caller's `rng` (only used to break exact ties reproducibly).
///
/// Two generations live here. `discard` / `pegPlay` are the current,
/// expectation-based bot; `legacyDiscard` / `legacyPegPlay` are the original
/// one-ply heuristics, kept verbatim so tests can measure the gain.
public enum CribbageBot {

    // MARK: - Discard (expected value over every starter + the crib)

    /// Picks 2 of the 6 dealt cards to send to the crib by maximizing
    ///
    ///     E[kept-hand show over all 46 starters]  +/-  E[crib show]
    ///
    /// The hand term is exact (15 splits x 46 unseen starters, scored by the
    /// real `CribbageScoring.scoreShow`). The crib term is the same
    /// expectation estimated over `cribScenarios` seeded rollouts of
    /// "opponent's 2 discards + starter" (common random numbers across all 15
    /// splits so the comparison between them is low-noise). Each rollout
    /// deals the opponent a plausible 6-card hand from the unseen cards and
    /// has them keep their best 4 by a no-starter score, so the discards that
    /// reach the crib look like a real opponent's (they rarely feed 5s and
    /// pairs unless they are the dealer, who keeps the crib for themselves —
    /// that is `isDealer == false` here, and the rollout flips accordingly).
    /// The crib term is added when `isDealer` and subtracted when not.
    ///
    /// Everything except tie-breaks is a pure function of `hand` and
    /// `isDealer`, independent of `rng` state and of call order.
    public static func discard(hand: [Card], isDealer: Bool, rng: inout SeededGenerator) -> [Card] {
        guard hand.count == 6 else { return Array(hand.prefix(2)) }
        let eval = evaluateDiscards(hand: hand, isDealer: isDealer)
        guard let top = eval.map(\.total).max() else { return Array(hand.prefix(2)) }
        let best = eval.filter { top - $0.total < 1e-9 }
        let pick = best.count == 1 ? best[0] : best[Int(rng.next() % UInt64(best.count))]
        return pick.discard
    }

    public struct DiscardEvaluation {
        public let discard: [Card]
        public let kept: [Card]
        public let handEV: Double
        public let cribEV: Double
        public let total: Double
    }

    /// Per-split breakdown (used by tests and tuning).
    public static func evaluateDiscards(hand: [Card], isDealer: Bool) -> [DiscardEvaluation] {
        let unseen = DeckBuilder.standard52().filter { card in !hand.contains { $0.id == card.id } }
        let choices = discardChoices(hand)
        let scenarios = cribScenarios(hand: hand, unseen: unseen, isDealer: isDealer)

        return choices.map { choice in
            var handTotal = 0
            for starter in unseen {
                handTotal += CribbageScoring.scoreShow(cards: choice.kept, starter: starter, isCrib: false).points
            }
            let handEV = Double(handTotal) / Double(unseen.count)

            var cribTotal = 0
            for s in scenarios {
                cribTotal += CribbageScoring.scoreShow(cards: choice.discard + s.opponentDiscard,
                                                       starter: s.starter, isCrib: true).points
            }
            let cribEV = scenarios.isEmpty ? 0 : Double(cribTotal) / Double(scenarios.count)
            let total = handEV + cribWeight * (isDealer ? cribEV : -cribEV)
            return DiscardEvaluation(discard: choice.discard, kept: choice.kept,
                                     handEV: handEV, cribEV: cribEV, total: total)
        }
    }

    public static let cribScenarioCount = 240
    /// Weight on the crib term (1.0 = exact expectation).
    static let cribWeight = 1.0

    private struct CribScenario {
        let opponentDiscard: [Card]
        let starter: Card
    }

    private static func cribScenarios(hand: [Card], unseen: [Card], isDealer: Bool) -> [CribScenario] {
        // Seed from the hand's identity so the same hand always evaluates
        // identically no matter what the caller's rng has done.
        var h: UInt64 = 0xC21B_BA6E_5EED_0001
        for id in hand.map(\.id).sorted() {
            for u in id.utf8 { h = (h ^ UInt64(u)) &* 0x100_0000_01B3 }
        }
        var local = SeededGenerator(seed: h)
        var result: [CribScenario] = []
        result.reserveCapacity(cribScenarioCount)
        for _ in 0..<cribScenarioCount {
            // 6 opponent cards + 1 starter, all distinct, from the unseen 46.
            var pool = unseen
            for i in 0..<7 {
                let j = i + Int(local.next() % UInt64(pool.count - i))
                pool.swapAt(i, j)
            }
            let oppHand = Array(pool[0..<6])
            let starter = pool[6]
            // The opponent keeps their best 4 by a no-starter score, adding a
            // mild crib lean for whoever owns the crib.
            var bestScore = -Double.infinity
            var bestDiscard = [oppHand[0], oppHand[1]]
            for i in 0..<6 {
                for j in (i + 1)..<6 {
                    let kept = oppHand.enumerated().filter { $0.offset != i && $0.offset != j }.map(\.element)
                    let pair = [oppHand[i], oppHand[j]]
                    // Opponent owns the crib when WE are not the dealer.
                    let oppIsDealer = !isDealer
                    let lean = cribFriendliness(pair)
                    let s = Double(noStarterValue(kept)) + (oppIsDealer ? lean : -lean)
                    if s > bestScore { bestScore = s; bestDiscard = pair }
                }
            }
            result.append(CribScenario(opponentDiscard: bestDiscard, starter: starter))
        }
        return result
    }

    /// Show value of four cards with no starter: fifteens, pairs, runs of 3+
    /// (via the engine's own scorer on the 4-card set so conventions match),
    /// and a 4-card flush. Cheap proxy for how an opponent ranks keeps.
    private static func noStarterValue(_ cards: [Card]) -> Int {
        var points = 0
        for mask in 1..<(1 << 4) where mask.nonzeroBitCount >= 2 {
            var sum = 0
            for i in 0..<4 where mask & (1 << i) != 0 { sum += CribbageScoring.pegValue(cards[i]) }
            if sum == 15 { points += 2 }
        }
        let ranks = cards.compactMap(\.rank)
        var counts: [Int: Int] = [:]
        for r in ranks { counts[r, default: 0] += 1 }
        points += counts.values.reduce(0) { $0 + $1 * ($1 - 1) }
        let distinct = Array(Set(ranks)).sorted()
        var i = 0
        while i < distinct.count {
            var j = i
            while j + 1 < distinct.count, distinct[j + 1] == distinct[j] + 1 { j += 1 }
            let len = j - i + 1
            if len >= 3 {
                let combos = distinct[i...j].reduce(1) { $0 * (counts[$1] ?? 1) }
                points += len * combos
            }
            i = j + 1
        }
        if let s = cards.first?.suit, cards.allSatisfy({ $0.suit == s }) { points += 4 }
        return points
    }

    // MARK: - Pegging (2-ply lookahead on the visible count)

    /// Picks one legal card to peg, or `nil` if none is legal (the engine's
    /// auto-go handles that turn from here).
    ///
    /// For each legal card the bot looks two plies ahead on the visible
    /// count: my immediate points, then the opponent's expected best reply
    /// (their hand is unknown, so each unseen rank is weighted by the chance
    /// they hold it, from the cards visible to me), then my own best
    /// follow-up from the cards I'd still hold. It also values the go point
    /// when the new count leaves the opponent probably stuck, and prefers to
    /// spend high cards early and keep low cards for the end of a count.
    ///
    /// - Parameters:
    ///   - hand: my unplayed pegging cards.
    ///   - sequence: cards played in the current count segment, in order.
    ///   - count: the running count.
    ///   - seen: any other cards known to me and no longer live in the
    ///     opponent's hand (starter, cards from earlier segments this hand).
    ///     Optional: more information sharpens the estimate of what the
    ///     opponent can hold; omitting it only costs a little accuracy.
    ///   - opponentCards: how many unplayed cards the opponent holds
    ///     (defaults to my own count, right at the start of a segment).
    public static func pegPlay(hand: [Card], sequence: [Card], count: Int, rng: inout SeededGenerator,
                               seen: [Card] = [], opponentCards: Int? = nil) -> Card? {
        let legal = hand.filter { CribbageScoring.pegValue($0) + count <= 31 }
        guard !legal.isEmpty else { return nil }
        if legal.count == 1 { return legal[0] }

        // Rank weights for the opponent's unknown cards: 4 of each rank minus
        // every copy I can see.
        var unseenByRank = [Int: Int]()
        for r in 2...14 { unseenByRank[r] = 4 }
        for c in hand + sequence + seen { if let r = c.rank { unseenByRank[r, default: 0] -= 1 } }
        var unseenTotal = 0
        for r in 2...14 { unseenByRank[r] = max(0, unseenByRank[r] ?? 0); unseenTotal += unseenByRank[r] ?? 0 }
        let oppN = max(0, min(4, opponentCards ?? hand.count))

        var bestCard: Card?
        var bestScore = -Double.infinity
        for card in legal {
            let value = pegValueOf(card, from: hand, sequence: sequence, count: count,
                                   unseenByRank: unseenByRank, unseenTotal: unseenTotal, opponentCards: oppN)
            if value > bestScore + 1e-9 || (abs(value - bestScore) <= 1e-9 && Bool.random(using: &rng)) {
                bestScore = value
                bestCard = card
            }
        }
        return bestCard
    }

    private static func dummyCard(rank: Int) -> Card {
        Card(id: "peg\(rank)", kind: .standard(suit: .spades, rank: rank))
    }

    private static func pegValueOf(_ card: Card, from hand: [Card], sequence: [Card], count: Int,
                                   unseenByRank: [Int: Int], unseenTotal: Int, opponentCards: Int) -> Double {
        let newCount = count + CribbageScoring.pegValue(card)
        let newSeq = sequence + [card]
        let mine = CribbageScoring.peggingScore(sequence: newSeq, count: newCount).reduce(0) { $0 + $1.points }
        var value = Double(mine)
        let rest = hand.filter { $0.id != card.id }

        // Opponent replies: scoring ranks, best first, probability that they
        // hold at least one copy given `opponentCards` cards from the pool.
        struct Reply { let rank: Int; let points: Int; let pHold: Double }
        var replies: [Reply] = []
        var pNoPlay = 1.0 // probability they hold nothing playable (stuck)
        for r in 2...14 {
            let have = unseenByRank[r] ?? 0
            guard have > 0, unseenTotal > 0 else { continue }
            let pv = r == 14 ? 1 : min(r, 10)
            guard newCount + pv <= 31 else { continue }
            let p = pHoldAtLeastOne(copies: have, pool: unseenTotal, draws: opponentCards)
            pNoPlay *= (1 - p)
            let pts = CribbageScoring.peggingScore(sequence: newSeq + [dummyCard(rank: r)], count: newCount + pv)
                .reduce(0) { $0 + $1.points }
            if pts > 0 { replies.append(Reply(rank: r, points: pts, pHold: p)) }
        }
        replies.sort { $0.points > $1.points }
        var pRemaining = 1.0
        var oppLoss = 0.0
        var myFollow = 0.0
        for rep in replies {
            let p = pRemaining * rep.pHold
            pRemaining *= (1 - rep.pHold)
            oppLoss += p * Double(rep.points)
            // My best reply to their reply, from the cards I keep.
            let seqAfter = newSeq + [dummyCard(rank: rep.rank)]
            let cntAfter = newCount + (rep.rank == 14 ? 1 : min(rep.rank, 10))
            var bestMine = 0
            for c in rest where cntAfter + CribbageScoring.pegValue(c) <= 31 {
                let pts = CribbageScoring.peggingScore(sequence: seqAfter + [c],
                                                       count: cntAfter + CribbageScoring.pegValue(c))
                    .reduce(0) { $0 + $1.points }
                bestMine = max(bestMine, pts)
            }
            myFollow += p * Double(bestMine)
        }
        value -= oppLoss
        value += 0.6 * myFollow

        // Go point: the opponent is probably stuck and I keep the count.
        if newCount < 31 { value += 0.8 * pNoPlay }
        // Landing exactly on 31 already scored above (2); nothing more.

        // Spend high cards early, keep low ones for the end of a count.
        value += 0.03 * Double(CribbageScoring.pegValue(card))
        // Leading: a 5 into an empty count hands a 15 to any ten-card; a pair
        // lead from a held pair sets up a pair royal.
        if count == 0, card.rank == 5 { value -= 0.4 }
        if !rest.isEmpty, rest.contains(where: { $0.rank == card.rank }), sequence.isEmpty { value += 0.25 }
        return value
    }

    /// P(at least one of `copies` target cards is among `draws` cards drawn
    /// without replacement from `pool`).
    private static func pHoldAtLeastOne(copies: Int, pool: Int, draws: Int) -> Double {
        guard pool > 0, draws > 0, copies > 0 else { return 0 }
        if draws >= pool { return 1 }
        var pNone = 1.0
        for i in 0..<min(draws, pool) {
            let denom = Double(pool - i)
            pNone *= max(0, (denom - Double(copies))) / denom
        }
        return 1 - pNone
    }

    // MARK: - Legacy (original heuristics, unchanged — for A/B tests)

    public static func legacyDiscard(hand: [Card], isDealer: Bool, rng: inout SeededGenerator) -> [Card] {
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

    public static func legacyPegPlay(hand: [Card], sequence: [Card], count: Int, rng: inout SeededGenerator) -> Card? {
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
    /// (Used by the legacy bot, and as the opponent model's mild lean.)
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
