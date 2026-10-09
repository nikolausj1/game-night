import Foundation

/// Which way Hearts passes this round. `left` = the next seat in turn order
/// (seat + 1, clockwise), `right` = the previous seat, `across` = half the
/// table away (seat + playerCount / 2), `hold` = no pass this round.
public enum PassDirection: String, Codable, CaseIterable, Sendable {
    case left, right, across, hold

    public var displayName: String {
        switch self {
        case .left: return "Pass left"
        case .right: return "Pass right"
        case .across: return "Pass across"
        case .hold: return "Hold"
        }
    }
}

/// Hearts (3-5 players, 4 standard): avoid the point cards. Every heart is
/// 1 point, the queen of spades 13, so a round always deals out 26.
///
/// - 3 players drop the 2♦ (17 cards each); 5 players drop the 2♦ and 2♠
///   (10 cards each). The 2♣ always stays in and always leads trick one.
/// - Before play, every seat passes 3 cards (left / right / across / hold,
///   cycling by round; 3 players cycle left / right / hold). See
///   `PlayerAction.passCards`.
/// - Hearts can't be led until a heart has been played ("broken"), unless
///   the leader holds nothing but hearts.
/// - House default (`heartsNoPointsFirstTrick`): no hearts / queen of
///   spades on the first trick unless a void seat holds nothing else.
/// - Shooting the moon: one seat takes all 26. Everyone else scores 26 (or,
///   with `heartsMoonSubtracts`, the shooter scores -26 and the rest 0).
/// - The game ends once any total reaches `heartsTargetScore`; the lowest
///   total wins (a tie for lowest plays on).
///
/// There is no trump, so trick resolution is plain highest-of-the-led-suit.
public struct HeartsRules: GameRules {
    public init() {}

    public static let passCount = 3
    public static let twoOfClubsID = "c2"
    public static let queenOfSpadesID = "s12"

    // MARK: - GameRules

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        let round = state.round
        let firstTrick = round?.completedTricks.isEmpty ?? true

        if trick.isEmpty {
            // Trick one is always opened by the 2♣ (the dealt holder leads).
            if firstTrick, hand.contains(where: { $0.id == Self.twoOfClubsID }) {
                return card.id == Self.twoOfClubsID ? .legal : .illegal(reason: "Lead the 2♣ to start")
            }
            if card.suit == .hearts, !(round?.heartsBroken ?? false),
               hand.contains(where: { $0.suit != .hearts }) {
                return .illegal(reason: "Hearts haven't been broken yet")
            }
            return .legal
        }

        guard let led = TrickMath.ledSuit(in: trick) else { return .legal }
        if card.suit == led { return .legal }
        if hand.contains(where: { $0.suit == led }) {
            return .illegal(reason: "You must follow \(led.rawValue)")
        }
        if firstTrick, state.rules.heartsNoPointsFirstTrick,
           Self.pointValue(of: card) > 0,
           hand.contains(where: { Self.pointValue(of: $0) == 0 }) {
            return .illegal(reason: "No points on the first trick")
        }
        return .legal
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        TrickMath.standardWinner(trick, trump: nil)
    }

    // MARK: - Deck & passing

    /// The freshly-built deck for this table size (see the type docs).
    public static func deck(playerCount: Int) -> [Card] {
        let dropped: Set<String>
        switch playerCount {
        case 3: dropped = ["d2"]
        case 5: dropped = ["d2", "s2"]
        default: dropped = []
        }
        return DeckBuilder.standard52().filter { !dropped.contains($0.id) }
    }

    /// Passing direction for a round (1-based). With passing off every round
    /// is a hold.
    public static func passDirection(roundNumber: Int, playerCount: Int, passingEnabled: Bool) -> PassDirection {
        guard passingEnabled, roundNumber >= 1 else { return .hold }
        let cycle: [PassDirection] = playerCount >= 4
            ? [.left, .right, .across, .hold]
            : [.left, .right, .hold]
        return cycle[(roundNumber - 1) % cycle.count]
    }

    /// The seat INDEX that `seat` hands its cards to (seats are 0..<count).
    public static func passTarget(from seat: Int, direction: PassDirection, playerCount: Int) -> Int {
        guard playerCount > 0 else { return seat }
        switch direction {
        case .left: return (seat + 1) % playerCount
        case .right: return (seat - 1 + playerCount) % playerCount
        case .across: return (seat + playerCount / 2) % playerCount
        case .hold: return seat
        }
    }

    // MARK: - Scoring

    /// 1 per heart, 13 for the queen of spades, 0 otherwise.
    public static func pointValue(of card: Card) -> Int {
        if card.suit == .hearts { return 1 }
        if card.id == queenOfSpadesID { return 13 }
        return 0
    }

    /// Point-card points each seat has captured over `tricks` (any list of
    /// completed tricks, e.g. `round.completedTricks`). Seats that took
    /// nothing are absent from the result.
    public static func pointsTaken(in tricks: [[TrickPlay]]) -> [Int: Int] {
        var taken: [Int: Int] = [:]
        for trick in tricks where !trick.isEmpty {
            let winner = TrickMath.standardWinner(trick, trump: nil)
            let points = trick.reduce(0) { $0 + pointValue(of: $1.card) }
            if points > 0 { taken[winner, default: 0] += points }
        }
        return taken
    }

    /// Converts raw captured points into per-seat round deltas, applying
    /// the shoot-the-moon rule. `seatIDs` lists every seat at the table.
    public static func scoreRound(
        points: [Int: Int],
        seatIDs: [Int],
        moonSubtracts: Bool
    ) -> (deltas: [Int: Int], moonShooter: Int?) {
        if let shooter = seatIDs.first(where: { (points[$0] ?? 0) == 26 }) {
            var deltas: [Int: Int] = [:]
            for seat in seatIDs {
                if seat == shooter {
                    deltas[seat] = moonSubtracts ? -26 : 0
                } else {
                    deltas[seat] = moonSubtracts ? 0 : 26
                }
            }
            return (deltas, shooter)
        }
        var deltas: [Int: Int] = [:]
        for seat in seatIDs { deltas[seat] = points[seat] ?? 0 }
        return (deltas, nil)
    }

    /// The winner once the game is over: some total has reached `target`
    /// and the lowest total is held by exactly one seat. nil = play on.
    public static func winner(totals: [Int: Int], target: Int) -> Int? {
        guard let high = totals.values.max(), high >= target,
              let low = totals.values.min() else { return nil }
        let lowest = totals.filter { $0.value == low }.keys.sorted()
        return lowest.count == 1 ? lowest[0] : nil
    }

    /// The Hearts running total per seat (convenience over `Scoring.totals`).
    public static func totals(history: [CompletedRound]) -> [Int: Int] {
        Scoring.totals(history: history, kind: .hearts)
    }
}
