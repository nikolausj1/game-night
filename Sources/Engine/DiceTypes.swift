import Foundation

/// Dice games live OUTSIDE the card engine: the iPad-side
/// `DiceGameController` (App layer) owns all rules state, and phones are
/// dice cups. These are the pure Codable wire types only — no rules here.
public enum DiceGameKind: String, Codable, Sendable {
    case leftRightCenter // Farkle / Liar's Dice / Yahtzee later
}

/// One LCR die face. A physical LCR die has six sides: three dots, one L,
/// one R, one C — the dot probability is 1/2, each letter 1/6.
public enum LcrFace: String, Codable, Sendable {
    case left, right, center, dot
}

/// The per-phone view of a dice game, pushed table → phone after every
/// mutation. Mirrors `ClientSnapshot`'s role for card games: redacted to
/// nothing (dice games have no hidden state) but personalized —
/// `mySeat`/`isMyTurn` differ per recipient.
public struct DiceClientState: Codable, Sendable, Equatable {
    public var kind: DiceGameKind
    public var mySeat: Int
    public var seatNames: [String]
    public var chips: [Int]
    public var centerPot: Int
    public var turnSeat: Int
    public var isMyTurn: Bool
    public var gameOver: Bool
    public var winnerSeat: Int?

    public init(kind: DiceGameKind, mySeat: Int, seatNames: [String],
                chips: [Int], centerPot: Int, turnSeat: Int,
                isMyTurn: Bool, gameOver: Bool, winnerSeat: Int?) {
        self.kind = kind
        self.mySeat = mySeat
        self.seatNames = seatNames
        self.chips = chips
        self.centerPot = centerPot
        self.turnSeat = turnSeat
        self.isMyTurn = isMyTurn
        self.gameOver = gameOver
        self.winnerSeat = winnerSeat
    }
}
