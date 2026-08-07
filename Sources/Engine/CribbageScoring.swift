import Foundation

/// Pure cribbage score math — pegging (running-count, order-sensitive) and
/// the show (combinatorial, order-insensitive). No engine state here; every
/// function is a straight function of the cards handed to it.
public enum CribbageScoring {
    /// Card's point value toward the count / a fifteen: 2...10 as printed,
    /// face cards (J/Q/K, rank 11...13) count 10, Ace (rank 14) counts 1.
    public static func pegValue(_ card: Card) -> Int {
        guard let rank = card.rank else { return 0 }
        return rank == 14 ? 1 : min(rank, 10)
    }

    // MARK: - Pegging

    /// Scoring for the card that was just appended to `sequence` (the
    /// current count segment, in play order — `sequence.last` is the card
    /// that was just played), given the resulting running `count`.
    /// Does NOT handle go/thirty-one/last-card turn mechanics — those are
    /// segment-level concerns the engine resolves around this call.
    public static func peggingScore(sequence: [Card], count: Int) -> [CribbageScoreEntry] {
        guard let last = sequence.last else { return [] }
        var entries: [CribbageScoreEntry] = []

        if count == 15 { entries.append(CribbageScoreEntry(reason: .fifteen, points: 2)) }
        if count == 31 { entries.append(CribbageScoreEntry(reason: .thirtyOne, points: 2)) }

        // Pair/trips/quads: the longest run of matching rank at the tail of
        // the segment, ending at the just-played card.
        var streak = 0
        for c in sequence.reversed() {
            if c.rank == last.rank { streak += 1 } else { break }
        }
        if streak >= 2 {
            entries.append(CribbageScoreEntry(reason: .pair, points: streak * (streak - 1)))
        }

        // Run of 3+: the longest suffix of the segment whose ranks, as a
        // set, are exactly N consecutive distinct integers — order within
        // that suffix doesn't matter, only recency.
        let n = sequence.count
        if n >= 3 {
            for length in stride(from: n, through: 3, by: -1) {
                let window = sequence.suffix(length)
                let ranks = window.compactMap { $0.rank }
                let distinct = Set(ranks)
                if distinct.count == length, let mn = distinct.min(), let mx = distinct.max(), mx - mn == length - 1 {
                    entries.append(CribbageScoreEntry(reason: .run(length), points: length))
                    break
                }
            }
        }

        return entries
    }

    // MARK: - The show

    /// Full combinatorial count of a 4-card hand (or 4-card crib) against
    /// the starter. `isCrib` gates the flush rule: a crib flush needs all
    /// 5 cards (hand flush needs only the 4, starter is a bonus 5th).
    /// Every category is counted exactly — double/triple runs and multi-way
    /// fifteens fall out of enumerating combinations, not special-cased.
    public static func scoreShow(cards: [Card], starter: Card, isCrib: Bool) -> (points: Int, breakdown: [CribbageScoreEntry]) {
        let all = cards + [starter]
        var breakdown: [CribbageScoreEntry] = []

        let fifteenCombos = countFifteens(all)
        if fifteenCombos > 0 {
            breakdown.append(CribbageScoreEntry(reason: .showFifteen, points: fifteenCombos * 2))
        }

        let pairPoints = countPairPoints(all)
        if pairPoints > 0 {
            breakdown.append(CribbageScoreEntry(reason: .showPair, points: pairPoints))
        }

        if let (length, combos) = longestRun(all) {
            breakdown.append(CribbageScoreEntry(reason: .showRun(length), points: length * combos))
        }

        if let flush = flushPoints(hand: cards, starter: starter, isCrib: isCrib) {
            breakdown.append(CribbageScoreEntry(reason: .flush(flush), points: flush))
        }

        if cards.contains(where: { $0.rank == 11 && $0.suit == starter.suit }) {
            breakdown.append(CribbageScoreEntry(reason: .nobs, points: 1))
        }

        let total = breakdown.reduce(0) { $0 + $1.points }
        return (total, breakdown)
    }

    /// Every subset of size >= 2 that sums to 15 (brute force over <= 32
    /// subsets for a 5-card hand — trivial cost, and the only way to get
    /// multi-way fifteens exactly right without a special-cased table).
    private static func countFifteens(_ cards: [Card]) -> Int {
        let n = cards.count
        var count = 0
        for mask in 1..<(1 << n) {
            if mask.nonzeroBitCount < 2 { continue }
            var sum = 0
            for i in 0..<n where mask & (1 << i) != 0 {
                sum += pegValue(cards[i])
            }
            if sum == 15 { count += 1 }
        }
        return count
    }

    /// C(m,2) × 2 for every rank present m >= 2 times — 1 pair = 2, 3-of-a-
    /// kind = 6 (3 pairs), 4-of-a-kind = 12 (6 pairs).
    private static func countPairPoints(_ cards: [Card]) -> Int {
        var byRank: [Int: Int] = [:]
        for c in cards {
            if let r = c.rank { byRank[r, default: 0] += 1 }
        }
        return byRank.values.reduce(0) { $0 + $1 * ($1 - 1) }
    }

    /// The longest run of consecutive distinct ranks present (length >= 3),
    /// plus how many distinct card combinations form it (the product of
    /// each rank's multiplicity in the run — this is what makes double/
    /// triple runs fall out naturally: a run of 4 with one duplicated rank
    /// is 2 combinations, scored as length × combos).
    /// A 5-card hand can only ever contain one such run (two disjoint runs
    /// of length >= 3 would need >= 6 distinct ranks).
    private static func longestRun(_ cards: [Card]) -> (length: Int, combos: Int)? {
        let ranks = cards.compactMap { $0.rank }
        let distinct = Array(Set(ranks)).sorted()
        guard distinct.count >= 3 else { return nil }

        var bestStart = 0, bestLen = 1
        var curStart = 0, curLen = 1
        for i in 1..<distinct.count {
            if distinct[i] == distinct[i - 1] + 1 {
                curLen += 1
            } else {
                curStart = i
                curLen = 1
            }
            if curLen > bestLen {
                bestLen = curLen
                bestStart = curStart
            }
        }
        guard bestLen >= 3 else { return nil }

        let runRanks = distinct[bestStart..<(bestStart + bestLen)]
        let combos = runRanks.reduce(1) { acc, r in acc * ranks.filter { $0 == r }.count }
        return (bestLen, combos)
    }

    /// 4 cards, same suit → 4. Starter also matches → 5. Crib requires all
    /// 5 (4 cards + starter) to match, or it scores nothing.
    private static func flushPoints(hand: [Card], starter: Card, isCrib: Bool) -> Int? {
        guard let firstSuit = hand.first?.suit, hand.allSatisfy({ $0.suit == firstSuit }) else { return nil }
        if starter.suit == firstSuit { return 5 }
        return isCrib ? nil : 4
    }
}
