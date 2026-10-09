import Foundation

/// Spades: spades are always trump. Bid the tricks you expect, make the
/// contract, and don't pile up bags.
///
/// - 4 players play partnerships: seats 0 and 2 ("North/South", team 0)
///   against seats 1 and 3 ("East/West", team 1). 2 or 3 players play
///   individual "cutthroat" (3 players drop the 2♦, 17 cards each; 2 players
///   get 13 each and the rest of the deck sits unused). `spadesCutthroat`
///   also makes a 4-player table individual.
/// - Bidding: each seat bids 0...hand size, left of the dealer first. A bid
///   of 0 IS nil (`placeBid(0)`): +100 if the bidder takes no tricks, -100
///   if they take any. Blind nil (`PlayerAction.bidBlindNil`, behind
///   `spadesBlindNil`) is the same bet before looking: +/-200.
/// - Spades can't be led until a spade has been played ("broken") unless
///   the leader holds only spades.
/// - A team's contract is the sum of its non-nil bids. Made (tricks >= bid)
///   = 10 per bid trick plus 1 per overtrick; every overtrick is also a bag.
///   Set (tricks < bid) = -10 per bid trick. A nil bidder who fails still
///   contributes the tricks they took toward the team's contract. A contract
///   of 0 (every member nil) scores no contract points; the team's tricks
///   are all bags.
/// - Every 10 bags cost 100 points and reset by 10 (bags carry across
///   rounds in `CompletedRound.bagsAfter`).
/// - The game ends when a team reaches `spadesTargetScore`; the highest
///   total wins (a tie at the top plays on).
public struct SpadesRules: GameRules {
    public init() {}

    public static let nilBonus = 100
    public static let blindNilBonus = 200
    public static let bagLimit = 10
    public static let bagPenalty = 100

    // MARK: - GameRules

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        if trick.isEmpty {
            if card.suit == .spades, !(state.round?.spadesBroken ?? false),
               hand.contains(where: { $0.suit != .spades }) {
                return .illegal(reason: "Spades haven't been broken yet")
            }
            return .legal
        }
        guard let led = TrickMath.ledSuit(in: trick) else { return .legal }
        if card.suit == led { return .legal }
        let canFollow = hand.contains { $0.suit == led }
        return canFollow ? .illegal(reason: "You must follow \(led.rawValue)") : .legal
    }

    /// Spades is always trump, regardless of what the engine passes in.
    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        TrickMath.standardWinner(trick, trump: .spades)
    }

    // MARK: - Deck

    /// 3 players drop the 2♦; 2 and 4 play the full 52.
    public static func deck(playerCount: Int) -> [Card] {
        let dropped: Set<String> = playerCount == 3 ? ["d2"] : []
        return DeckBuilder.standard52().filter { !dropped.contains($0.id) }
    }

    /// Cards dealt to each seat.
    public static func handSize(playerCount: Int) -> Int {
        playerCount == 3 ? 17 : 13
    }

    // MARK: - Teams

    /// True when partners play together (exactly 4 seats, cutthroat off).
    public static func isPartnership(seatCount: Int, cutthroat: Bool) -> Bool {
        seatCount == 4 && !cutthroat
    }

    /// Teams as arrays of seat IDs, in seat order. Partnership: [[0, 2],
    /// [1, 3]] (positions i and i+2 are partners). Individual: one
    /// single-seat team per seat.
    public static func teams(seatIDs: [Int], cutthroat: Bool) -> [[Int]] {
        if isPartnership(seatCount: seatIDs.count, cutthroat: cutthroat) {
            return [[seatIDs[0], seatIDs[2]], [seatIDs[1], seatIDs[3]]]
        }
        return seatIDs.map { [$0] }
    }

    public static func teams(for state: GameState) -> [[Int]] {
        teams(seatIDs: state.seats.map(\.id), cutthroat: state.rules.spadesCutthroat)
    }

    /// `seat`'s partner, or nil in individual play.
    public static func partner(of seat: Int, in state: GameState) -> Int? {
        teams(for: state).first(where: { $0.contains(seat) })?.first(where: { $0 != seat })
    }

    // MARK: - Scoring

    /// One team's (or lone seat's) round, itemised for the recap.
    public struct TeamResult: Sendable, Equatable {
        public let members: [Int]
        /// Sum of the members' non-nil bids.
        public let contract: Int
        /// Tricks taken by all members (a failed nil bidder's included).
        public let tricks: Int
        public let madeContract: Bool
        /// +10 per bid trick if made, -10 per bid trick if set, plus overtricks.
        public let contractPoints: Int
        public let bagsGained: Int
        /// -100 per 10 bags crossed this round (0 or a negative number).
        public let bagPenalty: Int
        /// Sum of nil / blind nil bonuses and penalties.
        public let nilPoints: Int
        /// contractPoints + bagPenalty + nilPoints: the change to the score.
        public let delta: Int
        public let bagsAfter: Int
    }

    /// Scores one round. `bagsBefore` is keyed by seat (partners equal);
    /// missing seats start at 0. Returns one result per team plus whether
    /// each nil / blind nil bidder made it.
    public static func scoreRound(
        bids: [Int: Int],
        tricksWon: [Int: Int],
        blindNilSeats: [Int],
        teams: [[Int]],
        bagsBefore: [Int: Int]
    ) -> (results: [TeamResult], nilMade: [Int: Bool]) {
        var results: [TeamResult] = []
        var nilMade: [Int: Bool] = [:]
        for members in teams {
            var contract = 0
            var tricks = 0
            var nilPoints = 0
            for seat in members {
                let bid = bids[seat] ?? 0
                let taken = tricksWon[seat] ?? 0
                tricks += taken
                if bid == 0 {
                    let blind = blindNilSeats.contains(seat)
                    let stake = blind ? blindNilBonus : nilBonus
                    let made = taken == 0
                    nilMade[seat] = made
                    nilPoints += made ? stake : -stake
                } else {
                    contract += bid
                }
            }
            let made = tricks >= contract
            var contractPoints = 0
            var bagsGained = 0
            if made {
                bagsGained = tricks - contract
                contractPoints = 10 * contract + bagsGained
            } else {
                contractPoints = -10 * contract
            }
            var bags = (members.first.flatMap { bagsBefore[$0] } ?? 0) + bagsGained
            var penalty = 0
            while bags >= bagLimit {
                bags -= bagLimit
                penalty -= bagPenalty
            }
            results.append(TeamResult(
                members: members, contract: contract, tricks: tricks, madeContract: made,
                contractPoints: contractPoints, bagsGained: bagsGained, bagPenalty: penalty,
                nilPoints: nilPoints, delta: contractPoints + penalty + nilPoints, bagsAfter: bags
            ))
        }
        return (results, nilMade)
    }

    /// Bags currently carried per seat (the latest completed round's
    /// `bagsAfter`; empty before the first round ends).
    public static func currentBags(history: [CompletedRound]) -> [Int: Int] {
        history.last?.bagsAfter ?? [:]
    }

    /// The winning seat (lowest ID on the winning team) once some team has
    /// reached `target` and holds the sole highest total. nil = play on.
    public static func winner(totals: [Int: Int], teams: [[Int]], target: Int) -> Int? {
        let teamTotals = teams.map { members in (members: members, total: totals[members[0]] ?? 0) }
        guard let high = teamTotals.map(\.total).max(), high >= target else { return nil }
        let leaders = teamTotals.filter { $0.total == high }
        guard leaders.count == 1 else { return nil }
        return leaders[0].members.min()
    }
}
