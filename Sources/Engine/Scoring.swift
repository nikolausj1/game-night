import Foundation

/// Pure score math, matching the Wizard Keeper engine semantics:
/// - Wizard: exact bid → 20 + 10×bid; miss → −10 per trick over or under.
/// - Oh Hell: exact bid → 10 + tricks taken; miss → 1 per trick taken
///   (or zero on a miss when `missScoresTricks` is off).
/// - Hearts / Spades: score-limit games. Each round's per-seat delta is
///   computed by `HeartsRules` / `SpadesRules` when the round ends and
///   recorded in `CompletedRound.scoreDeltas` (spades bags carry across
///   rounds, so a round's score depends on history and can't be recomputed
///   from one round alone); totals sum those deltas.
/// Totals and placements are always derived from round history, never stored.
public enum Scoring {
    public static func roundScore(kind: GameKind, bid: Int, tricksTaken: Int, missScoresTricks: Bool = true) -> Int {
        switch kind {
        case .wizard:
            return bid == tricksTaken ? 20 + 10 * bid : -10 * abs(bid - tricksTaken)
        case .ohHell:
            if bid == tricksTaken { return 10 + tricksTaken }
            return missScoresTricks ? tricksTaken : 0
        case .crazyEights, .uno, .freePlay, .hearts, .spades:
            return 0 // hearts/spades: see `roundScores(for:kind:)`
        }
    }

    /// Per-seat score for one completed round, for every kind. Wizard / Oh
    /// Hell derive it from bid vs. tricks; hearts / spades read the deltas the
    /// engine recorded (partners share the same spades delta). The recap UI
    /// should prefer this over calling `roundScore` seat by seat.
    public static func roundScores(
        for round: CompletedRound,
        kind: GameKind,
        missScoresTricks: Bool = true
    ) -> [Int: Int] {
        if kind.isScoreLimitGame { return round.scoreDeltas }
        var scores: [Int: Int] = [:]
        for (seat, bid) in round.bids {
            scores[seat] = roundScore(
                kind: kind, bid: bid, tricksTaken: round.tricksWon[seat] ?? 0, missScoresTricks: missScoresTricks
            )
        }
        return scores
    }

    /// Running totals per seat over a completed-round history.
    public static func totals(
        history: [CompletedRound],
        kind: GameKind = .wizard,
        missScoresTricks: Bool = true
    ) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        if kind.isScoreLimitGame {
            for round in history {
                for (seat, delta) in round.scoreDeltas { totals[seat, default: 0] += delta }
            }
            return totals
        }
        for round in history {
            for (seat, bid) in round.bids {
                let taken = round.tricksWon[seat] ?? 0
                totals[seat, default: 0] += roundScore(
                    kind: kind, bid: bid, tricksTaken: taken, missScoresTricks: missScoresTricks
                )
            }
        }
        return totals
    }

    /// Standard competition ranking ("1-2-2-4"): tied totals share a
    /// placement and the next distinct total skips the shared slots.
    /// Sorted by place, then seat. `lowerIsBetter` (hearts: pass
    /// `kind.lowestScoreWins`) ranks the smallest total first.
    public static func placements(totals: [Int: Int], lowerIsBetter: Bool = false) -> [(seat: Int, place: Int)] {
        totals
            .map { seat, total in
                (seat: seat, place: 1 + totals.values.filter { lowerIsBetter ? $0 < total : $0 > total }.count)
            }
            .sorted { $0.place == $1.place ? $0.seat < $1.seat : $0.place < $1.place }
    }
}
