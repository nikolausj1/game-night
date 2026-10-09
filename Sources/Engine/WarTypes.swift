import Foundation

/// War (2 players). Deal the whole deck, both flip, higher card takes both;
/// a tie is a WAR: each player lays 3 cards face down and flips another, and
/// ties recurse. Aces are high. A player short on cards lays down as many as
/// they can while keeping one to flip; a player with nothing to flip loses
/// the war. Captured cards go to the bottom of the winner's pile in a seeded
/// shuffled order (prevents endless loops). The game ends when one player
/// holds every card, or after `maxRounds` battles (default 200), when the
/// player with more cards leads (equal = draw).
///
/// One `flip` action (or `autoStep()`) resolves one whole battle - including
/// any wars - and narrates it with events.
public enum WarPhase: String, Codable, Sendable, Equatable {
    case playing, gameOver
}

public enum WarEndReason: String, Codable, Sendable, Equatable {
    case allCards, roundCap
}

public enum WarAction: Codable, Sendable, Equatable {
    /// Both players flip. Either seat may send it.
    case flip
}

/// One card turned over (or laid face down) during a battle.
public struct WarFlip: Codable, Sendable, Equatable {
    public let seat: Int
    /// nil when the card was laid face down (its identity is never revealed).
    public let card: Card?
    public let faceDown: Bool
    /// 0 for the opening flip, then 1 for the first war's flip, etc.
    public let depth: Int

    public init(seat: Int, card: Card?, faceDown: Bool, depth: Int) {
        self.seat = seat
        self.card = card
        self.faceDown = faceDown
        self.depth = depth
    }
}

public struct WarBattle: Codable, Sendable, Equatable {
    public let round: Int
    public let flips: [WarFlip]
    /// Number of wars fought inside this battle (0 = plain flip).
    public let wars: Int
    /// nil only if both players ran out simultaneously (pot split).
    public let winner: Int?
    public let captured: Int

    public init(round: Int, flips: [WarFlip], wars: Int, winner: Int?, captured: Int) {
        self.round = round
        self.flips = flips
        self.wars = wars
        self.winner = winner
        self.captured = captured
    }
}

public enum WarEvent: Codable, Sendable, Equatable {
    case dealt(handCounts: [Int: Int])
    /// A face-up flip. `depth` 0 is the opening flip.
    case flipped(seat: Int, card: Card, round: Int, depth: Int)
    case warDeclared(round: Int, depth: Int)
    /// `count` cards laid face down by `seat` for the war.
    case faceDownPlaced(seat: Int, count: Int)
    case captured(seat: Int, count: Int, round: Int)
    /// A player could not continue a war and forfeits the pot.
    case forfeited(seat: Int, round: Int)
    /// `winner` is nil on a draw (only possible at the round cap).
    case gameOver(winner: Int?, reason: WarEndReason, counts: [Int: Int])
    case illegalAttempt(seat: Int, reason: String)
}

public struct WarState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var maxRounds: Int
    /// Each pile: index 0 is the next card to flip.
    public var hands: [Int: [Card]]
    /// Battles completed so far.
    public var round: Int
    public var phase: WarPhase
    public var winner: Int?
    public var endReason: WarEndReason?
    public var lastBattle: WarBattle?

    public init(seed: UInt64, maxRounds: Int, hands: [Int: [Card]], round: Int = 0,
                phase: WarPhase = .playing, winner: Int? = nil, endReason: WarEndReason? = nil,
                lastBattle: WarBattle? = nil) {
        self.seed = seed
        self.maxRounds = maxRounds
        self.hands = hands
        self.round = round
        self.phase = phase
        self.winner = winner
        self.endReason = endReason
        self.lastBattle = lastBattle
    }
}

public struct WarSnapshot: Codable, Sendable, Equatable {
    public let seat: Int
    public let myCount: Int
    public let opponentCount: Int
    public let round: Int
    public let maxRounds: Int
    public let phase: WarPhase
    public let winner: Int?
    public let endReason: WarEndReason?
    public let lastBattle: WarBattle?

    public init(seat: Int, myCount: Int, opponentCount: Int, round: Int, maxRounds: Int,
                phase: WarPhase, winner: Int?, endReason: WarEndReason?, lastBattle: WarBattle?) {
        self.seat = seat
        self.myCount = myCount
        self.opponentCount = opponentCount
        self.round = round
        self.maxRounds = maxRounds
        self.phase = phase
        self.winner = winner
        self.endReason = endReason
        self.lastBattle = lastBattle
    }
}
