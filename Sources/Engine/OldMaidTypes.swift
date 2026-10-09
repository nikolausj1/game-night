import Foundation

/// Old Maid (2-4 players, family rules).
///
/// - Deck: standard 52 minus the queen of clubs (`c12`), so exactly three
///   queens remain; whichever queen ends up unpaired is the Old Maid.
/// - Everything is dealt out; matching pairs (same rank, any suits) are laid
///   down automatically on the deal and whenever a draw makes a pair.
/// - On your turn you draw one card, by INDEX, from the fanned hand of the
///   next player (seat + 1, skipping players who are already out).
/// - A player with no cards is out (safe). The last player holding a card
///   (the odd queen) is the loser.
public enum OldMaidPhase: String, Codable, Sendable, Equatable {
    case playing, gameOver
}

public enum OldMaidAction: Codable, Sendable, Equatable {
    /// Draw the card at `index` (0-based position in the neighbor's fan) from
    /// `snapshot.drawTarget`. Legal only on the caller's turn.
    case draw(index: Int)
    /// Shuffle your own hand's order (any time during play). Seeded, so
    /// replays stay deterministic.
    case shuffleMyHand
}

/// Public record of the most recent draw.
public struct OldMaidDrawRecord: Codable, Sendable, Equatable {
    public let drawer: Int
    public let from: Int
    /// Index in the source's fan that was picked.
    public let index: Int
    /// True when the drawn card completed a pair (and was laid down at once).
    public let matched: Bool

    public init(drawer: Int, from: Int, index: Int, matched: Bool) {
        self.drawer = drawer
        self.from = from
        self.index = index
        self.matched = matched
    }
}

public enum OldMaidEvent: Codable, Sendable, Equatable {
    case dealt(handCounts: [Int: Int])
    /// Pairs laid down. `onDeal` is true for the opening discard.
    case pairsDiscarded(seat: Int, pairs: [[Card]], onDeal: Bool)
    /// `seat` picked card `index` of `from`'s fan. The card's identity is NOT
    /// revealed here (the drawer sees it in their snapshot); a match shows up
    /// as a following `pairsDiscarded`.
    case drew(seat: Int, from: Int, index: Int)
    case handShuffled(seat: Int)
    /// `seat` has no cards left and is safe.
    case playerOut(seat: Int)
    case turnChanged(seat: Int)
    case gameOver(loser: Int)
    case illegalAttempt(seat: Int, reason: String)
}

public struct OldMaidState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var playerCount: Int
    public var hands: [Int: [Card]]
    /// Public pairs laid down, per seat, in order.
    public var laid: [Int: [[Card]]]
    public var turnSeat: Int
    public var phase: OldMaidPhase
    public var loser: Int?
    /// Seats that went out, in the order they did.
    public var outSeats: [Int]
    public var lastDraw: OldMaidDrawRecord?
    /// ID of the card the last drawer drew (only when it stayed in hand).
    public var lastDrawnCardID: String?
    /// Counter feeding the seeded RNG for `.shuffleMyHand`.
    public var shuffleCounter: Int

    public init(seed: UInt64, playerCount: Int, hands: [Int: [Card]], laid: [Int: [[Card]]] = [:],
                turnSeat: Int = 0, phase: OldMaidPhase = .playing, loser: Int? = nil,
                outSeats: [Int] = [], lastDraw: OldMaidDrawRecord? = nil,
                lastDrawnCardID: String? = nil, shuffleCounter: Int = 0) {
        self.seed = seed
        self.playerCount = playerCount
        self.hands = hands
        self.laid = laid
        self.turnSeat = turnSeat
        self.phase = phase
        self.loser = loser
        self.outSeats = outSeats
        self.lastDraw = lastDraw
        self.lastDrawnCardID = lastDrawnCardID
        self.shuffleCounter = shuffleCounter
    }
}

public struct OldMaidSnapshot: Codable, Sendable, Equatable {
    public let seat: Int
    public let playerCount: Int
    /// Own hand in true fan order (the order other players pick indexes from).
    public let hand: [Card]
    public let handCounts: [Int: Int]
    public let laidPairs: [Int: [[Card]]]
    public let turnSeat: Int
    /// Seat the current drawer is drawing from (nil once the game is over).
    public let drawTarget: Int?
    public let outSeats: [Int]
    public let phase: OldMaidPhase
    public let loser: Int?
    public let lastDraw: OldMaidDrawRecord?
    /// Set only for the seat that just drew and kept the card.
    public let lastDrawnCardID: String?

    public init(seat: Int, playerCount: Int, hand: [Card], handCounts: [Int: Int],
                laidPairs: [Int: [[Card]]], turnSeat: Int, drawTarget: Int?, outSeats: [Int],
                phase: OldMaidPhase, loser: Int?, lastDraw: OldMaidDrawRecord?, lastDrawnCardID: String?) {
        self.seat = seat
        self.playerCount = playerCount
        self.hand = hand
        self.handCounts = handCounts
        self.laidPairs = laidPairs
        self.turnSeat = turnSeat
        self.drawTarget = drawTarget
        self.outSeats = outSeats
        self.phase = phase
        self.loser = loser
        self.lastDraw = lastDraw
        self.lastDrawnCardID = lastDrawnCardID
    }
}
