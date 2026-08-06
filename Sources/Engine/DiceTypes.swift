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
    /// Manual cup loading ("gn.autoCup" off, the default): whether the
    /// dice for `mySeat` are currently loaded and ready to pour. When
    /// `isMyTurn && !cupReady`, the phone should show "load your dice on
    /// the table" instead of the normal shake-to-roll affordance — the
    /// dice have to be dragged into the table's TableCupView first.
    /// Always `true` when auto-cup is on, when it isn't `mySeat`'s turn,
    /// or in free play (no manual-cup gating there). Defaults to `true`
    /// on decode so an old peer's message without this key still reads as
    /// "ready" (the pre-manual-cup behavior — nothing was ever gated).
    public var cupReady: Bool

    public init(kind: DiceGameKind, mySeat: Int, seatNames: [String],
                chips: [Int], centerPot: Int, turnSeat: Int,
                isMyTurn: Bool, gameOver: Bool, winnerSeat: Int?,
                cupReady: Bool = true) {
        self.kind = kind
        self.mySeat = mySeat
        self.seatNames = seatNames
        self.chips = chips
        self.centerPot = centerPot
        self.turnSeat = turnSeat
        self.isMyTurn = isMyTurn
        self.gameOver = gameOver
        self.winnerSeat = winnerSeat
        self.cupReady = cupReady
    }

    /// `cupReady` postdates the first wire format — decodeIfPresent so an
    /// older peer's encode (or a message caught mid-rollout) still parses
    /// instead of dropping the connection over one new field.
    private enum CodingKeys: String, CodingKey {
        case kind, mySeat, seatNames, chips, centerPot, turnSeat, isMyTurn, gameOver, winnerSeat, cupReady
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DiceGameKind.self, forKey: .kind)
        mySeat = try container.decode(Int.self, forKey: .mySeat)
        seatNames = try container.decode([String].self, forKey: .seatNames)
        chips = try container.decode([Int].self, forKey: .chips)
        centerPot = try container.decode(Int.self, forKey: .centerPot)
        turnSeat = try container.decode(Int.self, forKey: .turnSeat)
        isMyTurn = try container.decode(Bool.self, forKey: .isMyTurn)
        gameOver = try container.decode(Bool.self, forKey: .gameOver)
        winnerSeat = try container.decodeIfPresent(Int.self, forKey: .winnerSeat)
        cupReady = try container.decodeIfPresent(Bool.self, forKey: .cupReady) ?? true
    }
}
