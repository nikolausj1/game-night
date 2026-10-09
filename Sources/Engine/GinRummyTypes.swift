import Foundation

/// Gin Rummy, 2 players, played to 100 with line (box) and game bonuses.
/// Seats are always exactly 0 and 1; `GinRummyEngine` is a standalone
/// reducer in the same family as `CribbageEngine` (not a `GameKind`).
///
/// Cards are the standard 52 (`DeckBuilder.standard52()`); aces are low.

public enum GinRummyRules {
    public static let handSize = 10
    public static let knockMax = 10
    public static let ginBonus = 25
    public static let undercutBonus = 25
    public static let targetScore = 100
    public static let gameBonus = 100
    public static let boxBonus = 25
    /// A discard that leaves the stock at this size or smaller (without a
    /// knock) voids the hand.
    public static let stockFloor = 2
}

public enum GinRummyPhase: String, Codable, Sendable, Equatable {
    /// The opening upcard is being offered: non-dealer first, then dealer.
    /// Legal: `drawUpcard` (take it) or `passUpcard`.
    case firstUpcard
    /// `turnSeat` must draw (`drawStock` / `drawUpcard`).
    case draw
    /// `turnSeat` holds 11 cards and must `discard` or `knock`.
    case discard
    /// A (non-gin) knock was made; the defender (`turnSeat`) may lay off.
    case layoff
    /// Hand scored (or drawn); waiting on `advance`.
    case handComplete
    /// Someone reached 100 and the game bonuses are paid. Terminal.
    case gameOver
}

public enum GinRummyAction: Codable, Sendable, Equatable {
    /// Decline the opening upcard (only in `.firstUpcard`).
    case passUpcard
    case drawStock
    /// Take the top of the discard pile (also "accept" in `.firstUpcard`).
    case drawUpcard
    /// Discard a card (by ID) to end the turn. Not the card just taken from the discard pile.
    case discard(cardID: String)
    /// Knock (deadwood <= 10 after `discard`) or go gin (deadwood 0).
    /// `melds` (lists of card IDs) is optional: nil lets the engine pick the
    /// minimum-deadwood arrangement that gives the opponent the fewest
    /// layoffs. If given, they must be valid, disjoint melds from the
    /// remaining 10 cards; everything else is deadwood.
    case knock(discard: String, melds: [[String]]?)
    /// Defender lays one card onto the knocker's meld `meldIndex`.
    case layOff(cardID: String, meldIndex: Int)
    /// Defender plays the optimal layoff for them and finishes.
    case autoLayoff
    /// Defender is done laying off.
    case finishLayoff
    /// Deal the next hand (from `.handComplete`).
    case advance
}

public enum GinMoveKind: Codable, Sendable, Equatable {
    case passedUpcard
    case drewStock
    case tookUpcard(Card)
    case discarded(Card)
}

/// One public move this hand (what a player at a real table could see).
public struct GinMove: Codable, Sendable, Equatable {
    public let seat: Int
    public let kind: GinMoveKind

    public init(seat: Int, kind: GinMoveKind) {
        self.seat = seat
        self.kind = kind
    }
}

public struct GinLayoff: Codable, Sendable, Equatable {
    public let seat: Int
    public let card: Card
    public let meldIndex: Int

    public init(seat: Int, card: Card, meldIndex: Int) {
        self.seat = seat
        self.card = card
        self.meldIndex = meldIndex
    }
}

/// The knocker's revealed hand. `melds` grow as the defender lays off.
public struct GinKnockInfo: Codable, Sendable, Equatable {
    public let knockerSeat: Int
    public let discard: Card
    public var melds: [GinMeld]
    public let deadwood: [Card]
    public let deadwoodPoints: Int
    public let isGin: Bool

    public init(knockerSeat: Int, discard: Card, melds: [GinMeld], deadwood: [Card], deadwoodPoints: Int, isGin: Bool) {
        self.knockerSeat = knockerSeat
        self.discard = discard
        self.melds = melds
        self.deadwood = deadwood
        self.deadwoodPoints = deadwoodPoints
        self.isGin = isGin
    }
}

public enum GinHandOutcome: String, Codable, Sendable, Equatable {
    /// Knocker's deadwood beat the defender's.
    case knock
    /// Knocker went out with zero deadwood.
    case gin
    /// Defender's deadwood tied or beat the knocker's after layoffs.
    case undercut
    /// Stock ran down; nobody scores.
    case drawn
}

/// Full showdown breakdown for one hand.
public struct GinHandResult: Codable, Sendable, Equatable {
    public let handNumber: Int
    public let outcome: GinHandOutcome
    public let knockerSeat: Int?
    /// nil for a drawn hand.
    public let winnerSeat: Int?
    /// Points awarded to `winnerSeat` (0 if drawn).
    public let points: Int
    public let deadwoodDifference: Int
    public let ginBonus: Int
    public let undercutBonus: Int
    public let knockerMelds: [GinMeld]
    public let knockerDeadwood: [Card]
    public let knockerDeadwoodPoints: Int
    public let defenderMelds: [GinMeld]
    /// Defender's deadwood AFTER layoffs.
    public let defenderDeadwood: [Card]
    public let defenderDeadwoodPoints: Int
    public let layoffs: [GinLayoff]
    public let scoresAfter: [Int: Int]

    public init(
        handNumber: Int, outcome: GinHandOutcome, knockerSeat: Int?, winnerSeat: Int?, points: Int,
        deadwoodDifference: Int, ginBonus: Int, undercutBonus: Int, knockerMelds: [GinMeld],
        knockerDeadwood: [Card], knockerDeadwoodPoints: Int, defenderMelds: [GinMeld],
        defenderDeadwood: [Card], defenderDeadwoodPoints: Int, layoffs: [GinLayoff], scoresAfter: [Int: Int]
    ) {
        self.handNumber = handNumber
        self.outcome = outcome
        self.knockerSeat = knockerSeat
        self.winnerSeat = winnerSeat
        self.points = points
        self.deadwoodDifference = deadwoodDifference
        self.ginBonus = ginBonus
        self.undercutBonus = undercutBonus
        self.knockerMelds = knockerMelds
        self.knockerDeadwood = knockerDeadwood
        self.knockerDeadwoodPoints = knockerDeadwoodPoints
        self.defenderMelds = defenderMelds
        self.defenderDeadwood = defenderDeadwood
        self.defenderDeadwoodPoints = defenderDeadwoodPoints
        self.layoffs = layoffs
        self.scoresAfter = scoresAfter
    }
}

/// End-of-game payout: 100 game bonus (doubled for a shutout, i.e. the
/// loser won no hands) to the winner, plus 25 per hand won (box/line) to each seat.
public struct GinGameResult: Codable, Sendable, Equatable {
    public let winnerSeat: Int
    /// Running hand-score totals at the moment someone reached 100.
    public let handScores: [Int: Int]
    public let handsWon: [Int: Int]
    public let gameBonus: Int
    public let shutout: Bool
    public let boxBonus: [Int: Int]
    public let finalTotals: [Int: Int]

    public init(winnerSeat: Int, handScores: [Int: Int], handsWon: [Int: Int], gameBonus: Int, shutout: Bool, boxBonus: [Int: Int], finalTotals: [Int: Int]) {
        self.winnerSeat = winnerSeat
        self.handScores = handScores
        self.handsWon = handsWon
        self.gameBonus = gameBonus
        self.shutout = shutout
        self.boxBonus = boxBonus
        self.finalTotals = finalTotals
    }
}

public enum GinRummyEvent: Codable, Sendable, Equatable {
    /// A new hand was dealt; `upcard` is the opening upcard.
    case dealt(dealerSeat: Int, upcard: Card)
    case upcardPassed(seat: Int)
    /// Card identity deliberately hidden.
    case drewStock(seat: Int)
    case tookUpcard(seat: Int, card: Card)
    case discarded(seat: Int, card: Card)
    /// `seat` knocked/ginned; their hand is laid face up.
    case knocked(seat: Int, info: GinKnockInfo)
    case laidOff(seat: Int, card: Card, meldIndex: Int)
    /// Hand scored, with the full breakdown.
    case showdown(GinHandResult)
    /// The stock ran down with no knock.
    case handDrawn(handNumber: Int)
    case gameWon(GinGameResult)
    case illegalAttempt(seat: Int, reason: String)
}

/// Authoritative table state (host-side: holds both hands and the stock).
public struct GinRummyState: Codable, Sendable, Equatable {
    public var seed: UInt64
    /// Running hand scores (no bonuses until game end).
    public var scores: [Int: Int]
    public var handsWon: [Int: Int]
    public var dealerSeat: Int
    public var phase: GinRummyPhase
    public var turnSeat: Int
    public var hands: [Int: [Card]]
    /// Top of the stock is index 0.
    public var stock: [Card]
    /// Bottom ... top (last element is the upcard).
    public var discardPile: [Card]
    /// In `.firstUpcard`: seats that have passed.
    public var firstPasses: Set<Int>
    /// True after both seats refused the opening upcard, until the first discard covers it.
    public var upcardRefused: Bool
    /// Card ID just taken from the discard pile this turn (can't be discarded back).
    public var drawnFromDiscardID: String?
    public var moves: [GinMove]
    public var knock: GinKnockInfo?
    public var layoffs: [GinLayoff]
    public var lastResult: GinHandResult?
    public var handNumber: Int
    public var winnerSeat: Int?
    public var gameResult: GinGameResult?

    public init(
        seed: UInt64, scores: [Int: Int], handsWon: [Int: Int], dealerSeat: Int, phase: GinRummyPhase,
        turnSeat: Int, hands: [Int: [Card]], stock: [Card], discardPile: [Card], firstPasses: Set<Int>,
        upcardRefused: Bool, drawnFromDiscardID: String?, moves: [GinMove], knock: GinKnockInfo?,
        layoffs: [GinLayoff], lastResult: GinHandResult?, handNumber: Int, winnerSeat: Int?, gameResult: GinGameResult?
    ) {
        self.seed = seed
        self.scores = scores
        self.handsWon = handsWon
        self.dealerSeat = dealerSeat
        self.phase = phase
        self.turnSeat = turnSeat
        self.hands = hands
        self.stock = stock
        self.discardPile = discardPile
        self.firstPasses = firstPasses
        self.upcardRefused = upcardRefused
        self.drawnFromDiscardID = drawnFromDiscardID
        self.moves = moves
        self.knock = knock
        self.layoffs = layoffs
        self.lastResult = lastResult
        self.handNumber = handNumber
        self.winnerSeat = winnerSeat
        self.gameResult = gameResult
    }
}

/// What the shared table shows: no hands at all.
public struct GinRummyTableSnapshot: Codable, Sendable, Equatable {
    public let dealerSeat: Int
    public let phase: GinRummyPhase
    public let turnSeat: Int
    public let scores: [Int: Int]
    public let handsWon: [Int: Int]
    public let handCounts: [Int: Int]
    public let stockCount: Int
    public let upcard: Card?
    public let discardPile: [Card]
    public let moves: [GinMove]
    public let knock: GinKnockInfo?
    public let layoffs: [GinLayoff]
    public let lastResult: GinHandResult?
    public let handNumber: Int
    public let winnerSeat: Int?
    public let gameResult: GinGameResult?

    public init(
        dealerSeat: Int, phase: GinRummyPhase, turnSeat: Int, scores: [Int: Int], handsWon: [Int: Int],
        handCounts: [Int: Int], stockCount: Int, upcard: Card?, discardPile: [Card], moves: [GinMove],
        knock: GinKnockInfo?, layoffs: [GinLayoff], lastResult: GinHandResult?, handNumber: Int,
        winnerSeat: Int?, gameResult: GinGameResult?
    ) {
        self.dealerSeat = dealerSeat
        self.phase = phase
        self.turnSeat = turnSeat
        self.scores = scores
        self.handsWon = handsWon
        self.handCounts = handCounts
        self.stockCount = stockCount
        self.upcard = upcard
        self.discardPile = discardPile
        self.moves = moves
        self.knock = knock
        self.layoffs = layoffs
        self.lastResult = lastResult
        self.handNumber = handNumber
        self.winnerSeat = winnerSeat
        self.gameResult = gameResult
    }
}

/// One seat's redacted view.
public struct GinRummySnapshot: Codable, Sendable, Equatable {
    public let mySeat: Int
    public let dealerSeat: Int
    public let phase: GinRummyPhase
    public let turnSeat: Int
    public let isMyTurn: Bool
    public let scores: [Int: Int]
    public let handsWon: [Int: Int]
    public let myHand: [Card]
    public let opponentHandCount: Int
    /// Top of the discard pile (nil only if the pile is empty).
    public let upcard: Card?
    public let stockCount: Int
    /// The whole discard pile, bottom to top. UI should normally show only `upcard`.
    public let discardPile: [Card]
    /// Public moves this hand, in order (what a bot "remembers").
    public let moves: [GinMove]
    /// Cards the opponent took from the discard pile and has not yet discarded
    /// (so they are known to be in their hand).
    public let opponentKnownCards: [Card]
    /// True while the upcard may not be taken (both refused it, non-dealer must draw stock).
    public let upcardRefused: Bool
    public let drawnFromDiscardID: String?
    /// During my `.discard` phase: card IDs I could discard and legally knock with.
    public let knockDiscards: [String]
    /// Subset of `knockDiscards` that leave zero deadwood (gin).
    public let ginDiscards: [String]
    public let knock: GinKnockInfo?
    public let layoffs: [GinLayoff]
    public let lastResult: GinHandResult?
    public let handNumber: Int
    public let winnerSeat: Int?
    public let gameResult: GinGameResult?

    public init(
        mySeat: Int, dealerSeat: Int, phase: GinRummyPhase, turnSeat: Int, isMyTurn: Bool, scores: [Int: Int],
        handsWon: [Int: Int], myHand: [Card], opponentHandCount: Int, upcard: Card?, stockCount: Int,
        discardPile: [Card], moves: [GinMove], opponentKnownCards: [Card], upcardRefused: Bool,
        drawnFromDiscardID: String?, knockDiscards: [String], ginDiscards: [String], knock: GinKnockInfo?,
        layoffs: [GinLayoff], lastResult: GinHandResult?, handNumber: Int, winnerSeat: Int?, gameResult: GinGameResult?
    ) {
        self.mySeat = mySeat
        self.dealerSeat = dealerSeat
        self.phase = phase
        self.turnSeat = turnSeat
        self.isMyTurn = isMyTurn
        self.scores = scores
        self.handsWon = handsWon
        self.myHand = myHand
        self.opponentHandCount = opponentHandCount
        self.upcard = upcard
        self.stockCount = stockCount
        self.discardPile = discardPile
        self.moves = moves
        self.opponentKnownCards = opponentKnownCards
        self.upcardRefused = upcardRefused
        self.drawnFromDiscardID = drawnFromDiscardID
        self.knockDiscards = knockDiscards
        self.ginDiscards = ginDiscards
        self.knock = knock
        self.layoffs = layoffs
        self.lastResult = lastResult
        self.handNumber = handNumber
        self.winnerSeat = winnerSeat
        self.gameResult = gameResult
    }
}

public extension GinRummyState {
    func snapshot(for seat: Int) -> GinRummySnapshot {
        let opp = 1 - seat
        let hand = hands[seat] ?? []
        var knockDiscards: [String] = []
        var ginDiscards: [String] = []
        if phase == .discard, turnSeat == seat, hand.count == GinRummyRules.handSize + 1 {
            for c in hand where c.id != drawnFromDiscardID {
                let dw = GinMelds.minDeadwood(hand.filter { $0 != c })
                if dw <= GinRummyRules.knockMax { knockDiscards.append(c.id) }
                if dw == 0 { ginDiscards.append(c.id) }
            }
        }
        return GinRummySnapshot(
            mySeat: seat, dealerSeat: dealerSeat, phase: phase, turnSeat: turnSeat,
            isMyTurn: turnSeat == seat && phase != .handComplete && phase != .gameOver,
            scores: scores, handsWon: handsWon, myHand: hand, opponentHandCount: hands[opp]?.count ?? 0,
            upcard: discardPile.last, stockCount: stock.count, discardPile: discardPile, moves: moves,
            opponentKnownCards: knownCards(of: opp), upcardRefused: upcardRefused,
            drawnFromDiscardID: turnSeat == seat ? drawnFromDiscardID : nil,
            knockDiscards: knockDiscards, ginDiscards: ginDiscards, knock: knock, layoffs: layoffs,
            lastResult: lastResult, handNumber: handNumber, winnerSeat: winnerSeat, gameResult: gameResult
        )
    }

    func tableSnapshot() -> GinRummyTableSnapshot {
        GinRummyTableSnapshot(
            dealerSeat: dealerSeat, phase: phase, turnSeat: turnSeat, scores: scores, handsWon: handsWon,
            handCounts: [0: hands[0]?.count ?? 0, 1: hands[1]?.count ?? 0], stockCount: stock.count,
            upcard: discardPile.last, discardPile: discardPile, moves: moves, knock: knock, layoffs: layoffs,
            lastResult: lastResult, handNumber: handNumber, winnerSeat: winnerSeat, gameResult: gameResult
        )
    }

    /// Cards `seat` took from the discard pile this hand and still holds.
    func knownCards(of seat: Int) -> [Card] {
        var known: [Card] = []
        for move in moves where move.seat == seat {
            switch move.kind {
            case .tookUpcard(let c): known.append(c)
            case .discarded(let c): known.removeAll { $0 == c }
            default: break
            }
        }
        return known
    }
}
