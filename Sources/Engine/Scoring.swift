import Foundation

/// Pure score math, matching the Wizard Keeper engine semantics:
/// - Wizard: exact bid → 20 + 10×bid; miss → −10 per trick over or under.
/// - Oh Hell: exact bid → 10 + tricks taken; miss → 1 per trick taken
///   (or zero on a miss when `missScoresTricks` is off).
/// Totals and placements are always derived from round history, never stored.
public enum Scoring {
    public static func roundScore(kind: GameKind, bid: Int, tricksTaken: Int, missScoresTricks: Bool = true) -> Int {
        switch kind {
        case .wizard:
            return bid == tricksTaken ? 20 + 10 * bid : -10 * abs(bid - tricksTaken)
        case .ohHell:
            if bid == tricksTaken { return 10 + tricksTaken }
            return missScoresTricks ? tricksTaken : 0
        case .crazyEights, .freePlay:
            return 0
        }
    }

    /// Running totals per seat over a completed-round history.
    public static func totals(
        history: [CompletedRound],
        kind: GameKind = .wizard,
        missScoresTricks: Bool = true
    ) -> [Int: Int] {
        var totals: [Int: Int] = [:]
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
    /// Sorted by place, then seat.
    public static func placements(totals: [Int: Int]) -> [(seat: Int, place: Int)] {
        totals
            .map { seat, total in
                (seat: seat, place: 1 + totals.values.filter { $0 > total }.count)
            }
            .sorted { $0.place == $1.place ? $0.seat < $1.seat : $0.place < $1.place }
    }
}
