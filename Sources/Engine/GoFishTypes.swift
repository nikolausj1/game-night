import Foundation

/// Go Fish (2-4 players, family rules). Seats are 0..<playerCount; there is
/// no lobby concept — `GoFishEngine` is a standalone reducer like
/// `CribbageEngine` (not a `GameKind`/`HostEngine` game).
///
/// Rules implemented:
/// - 2 players deal 7 each, 3-4 players deal 5 each; the rest is the pool.
/// - On your turn you ask ONE other player for a rank you hold.
/// - They hand over every card of that rank and you go again. If they have
///   none: "Go Fish" - you draw the top pool card. If that card is the rank
///   you asked for you go again, otherwise the turn passes to the next seat.
/// - Four of a rank are laid down automatically as a public book.
/// - A player on turn with an empty hand refills (up to the deal size) from
///   the pool; if the pool is empty they are skipped.
/// - The game ends when all 13 books are made. Most books wins; ties share.
public enum GoFishPhase: String, Codable, Sendable, Equatable {
    case playing, gameOver
}

public enum GoFishAction: Codable, Sendable, Equatable {
    /// Ask `target` for every card of `rank` (2...14, ace = 14). Legal only
    /// on the caller's turn, only for a rank the caller holds, and never
    /// aimed at yourself.
    case ask(target: Int, rank: Int)
}

/// One public ask, kept in `GoFishState.askLog` so bots (and the UI) can
/// remember what everyone has been asking for. Asking for a rank proves the
/// asker held it at that moment.
public struct GoFishAskRecord: Codable, Sendable, Equatable {
    public let asker: Int
    public let target: Int
    public let rank: Int
    /// How many cards the target handed over (0 = "Go Fish").
    public let gave: Int

    public init(asker: Int, target: Int, rank: Int, gave: Int) {
        self.asker = asker
        self.target = target
        self.rank = rank
        self.gave = gave
    }
}

public enum GoFishEvent: Codable, Sendable, Equatable {
    /// Initial deal complete (after any opening books were laid).
    case dealt(handCounts: [Int: Int], poolCount: Int)
    /// "Chase asks Vinny for sevens."
    case asked(asker: Int, target: Int, rank: Int)
    /// The target handed over cards (publicly shown).
    case gave(from: Int, to: Int, rank: Int, cards: [Card])
    /// The target had none: "Go Fish!"
    case goFish(seat: Int, rank: Int)
    /// `seat` drew from the pool. `card` is revealed ONLY when it matched the
    /// asked rank (the "I got my wish" moment); otherwise nil - the drawer
    /// sees the card in their own snapshot.
    case fished(seat: Int, matched: Bool, card: Card?)
    /// Went fishing but the pool was empty.
    case poolEmpty(seat: Int)
    /// `seat` keeps the turn (got cards, or fished their wish).
    case goesAgain(seat: Int)
    case bookLaid(seat: Int, rank: Int, cards: [Card])
    /// `seat` had an empty hand on turn and drew `count` fresh cards.
    case refilled(seat: Int, count: Int)
    case turnChanged(seat: Int)
    /// All 13 books are made. `winners` has more than one entry on a tie.
    case gameOver(winners: [Int], books: [Int: Int])
    case illegalAttempt(seat: Int, reason: String)
}

public struct GoFishState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var playerCount: Int
    /// Cards dealt to each player (7 for 2 players, else 5); also the refill size.
    public var handSize: Int
    public var hands: [Int: [Card]]
    /// Draw pile; the next card drawn is `pool.first`.
    public var pool: [Card]
    /// Ranks each seat has laid down (public).
    public var books: [Int: [Int]]
    public var turnSeat: Int
    public var phase: GoFishPhase
    /// Empty until the game ends; more than one seat on a tie.
    public var winners: [Int]
    /// Chronological public asks (capped to the latest 80).
    public var askLog: [GoFishAskRecord]

    public init(seed: UInt64, playerCount: Int, handSize: Int, hands: [Int: [Card]], pool: [Card],
                books: [Int: [Int]], turnSeat: Int, phase: GoFishPhase = .playing,
                winners: [Int] = [], askLog: [GoFishAskRecord] = []) {
        self.seed = seed
        self.playerCount = playerCount
        self.handSize = handSize
        self.hands = hands
        self.pool = pool
        self.books = books
        self.turnSeat = turnSeat
        self.phase = phase
        self.winners = winners
        self.askLog = askLog
    }
}

/// What one seat is allowed to know: its own hand, everyone's hand COUNT and
/// laid books, and the pool size.
public struct GoFishSnapshot: Codable, Sendable, Equatable {
    public let seat: Int
    public let playerCount: Int
    public let hand: [Card]
    public let handCounts: [Int: Int]
    public let books: [Int: [Int]]
    public let poolCount: Int
    public let turnSeat: Int
    public let phase: GoFishPhase
    public let winners: [Int]
    public let askLog: [GoFishAskRecord]
    /// Ranks this seat could legally ask for right now (ascending), empty when
    /// it isn't their turn.
    public let askableRanks: [Int]
    /// Seats this seat could legally ask right now, empty when it isn't their turn.
    public let askableTargets: [Int]

    public init(seat: Int, playerCount: Int, hand: [Card], handCounts: [Int: Int], books: [Int: [Int]],
                poolCount: Int, turnSeat: Int, phase: GoFishPhase, winners: [Int],
                askLog: [GoFishAskRecord], askableRanks: [Int], askableTargets: [Int]) {
        self.seat = seat
        self.playerCount = playerCount
        self.hand = hand
        self.handCounts = handCounts
        self.books = books
        self.poolCount = poolCount
        self.turnSeat = turnSeat
        self.phase = phase
        self.winners = winners
        self.askLog = askLog
        self.askableRanks = askableRanks
        self.askableTargets = askableTargets
    }

    public var bookCounts: [Int: Int] { books.mapValues(\.count) }
}

/// Narration helpers shared by the UI.
public enum GoFishText {
    /// "sevens", "jacks", "aces" ...
    public static func plural(_ rank: Int) -> String {
        let names = [2: "twos", 3: "threes", 4: "fours", 5: "fives", 6: "sixes", 7: "sevens",
                     8: "eights", 9: "nines", 10: "tens", 11: "jacks", 12: "queens",
                     13: "kings", 14: "aces"]
        return names[rank] ?? "\(rank)s"
    }
}
