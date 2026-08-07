import Foundation

/// Dice games live OUTSIDE the card engine: the iPad-side
/// `DiceGameController` (App layer) owns all rules state, and phones are
/// dice cups. These are the pure Codable wire types only — no rules here.
///
/// Platform-wave note: this is the WIRE tag riding inside
/// `DiceClientState.kind` (see that struct's doc for how it differs from
/// the app-layer `DiceKind` config-lookup key). `.yahtzee`/`.zilch`/
/// `.shutTheBox` added alongside LCR so all three new controllers can ride
/// the same `DiceClientState` broadcast shape as LCR does — each game's own
/// controller fills the generalized `statusLine`/`rollsLeft`/
/// `standingsLines` fields below rather than the game inventing its own
/// wire type.
public enum DiceGameKind: String, Codable, Sendable {
    case leftRightCenter
    case yahtzee
    case zilch
    case shutTheBox
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
    /// LCR: literal chip counts. Non-LCR games are free to repurpose this
    /// slot rather than send an unused all-zero array — `DiceCupView`
    /// (the only reader that treats it generically, via `myDiceCount`)
    /// only ever asks "how many dice does `chips[mySeat]` say I'm about to
    /// roll," clamped against that kind's `DiceGameConfig.diceCount`
    /// instead of LCR's hardcoded 3. `YahtzeeController` sets
    /// `chips[turnSeat]` to how many of the 5 pool dice are still unheld
    /// (the ones actually about to fly on the next roll) and leaves every
    /// other seat at the game's full dice count, since only the roller's
    /// entry is ever read. A future kind with no dice-count concept at all
    /// can just leave this at the config's constant `diceCount` everywhere.
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
    /// How many of `mySeat`'s required dice are currently sitting in the
    /// table's on-screen cup — 0 until the first one lands, ticking up by
    /// one on every die dragged in (manual) or auto-glided (auto-cup) —
    /// see `DiceGameController.loadDie`/`GameHostController.
    /// setFreePlayLoadedDice`, the two table-side writers. Resets to 0 at
    /// the start of every new roll (LCR: `finishTurn`; free play: whenever
    /// a fresh `Roll` launches, from either source — the Roll button or a
    /// remote pour). Only meaningful while `cupReady` is false — once ready
    /// the phone just shows the full required count instead (see
    /// `DiceCupView.cupSceneDiceCount`). `decodeIfPresent ?? 0` so an older
    /// peer's message without this key still reads as "none loaded", the
    /// pre-loading-mirror behavior (the phone showed the full cup the
    /// instant `cupReady` flipped true — this field simply wasn't consulted
    /// yet).
    public var loadedDice: Int
    /// Free-text status the remote shows under "Your roll!" in place of the
    /// LCR-specific "Rolling N dice" line — e.g. Yahtzee's "Tap dice on the
    /// table to keep, then shake for roll 2 of 3." Each non-LCR controller
    /// fills this every broadcast; LCR never sets it (stays `nil`), so
    /// `DiceCupView` keeps showing its own `rollingDiceLabel` for LCR and
    /// only swaps to `statusLine` when a game actually provides one.
    /// `nil` on decode for any peer that predates this field.
    public var statusLine: String?
    /// How many rolls remain this turn (Yahtzee: 3 minus rolls used, 0 once
    /// a category must be picked instead of rolling again). Informational —
    /// no current view reads it directly, but it rides the wire so a game's
    /// own phone UI (or a future one) can show a roll counter without
    /// re-deriving it from `statusLine` text. `nil` for LCR and on decode
    /// for any peer that predates this field.
    public var rollsLeft: Int?
    /// Free-text standings for the "not your turn" screen, one line per
    /// seat (same order as `seatNames`) — e.g. Yahtzee's "Hank: 145". Lets
    /// `DiceCupView`'s generalized standings panel show a non-LCR game's
    /// running scores without that panel needing to know each game's own
    /// scoring rules. LCR never sets it (keeps its own chip-dots/pot UI);
    /// `nil` on decode for any peer that predates this field.
    public var standingsLines: [String]?

    public init(kind: DiceGameKind, mySeat: Int, seatNames: [String],
                chips: [Int], centerPot: Int, turnSeat: Int,
                isMyTurn: Bool, gameOver: Bool, winnerSeat: Int?,
                cupReady: Bool = true, loadedDice: Int = 0,
                statusLine: String? = nil, rollsLeft: Int? = nil,
                standingsLines: [String]? = nil) {
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
        self.loadedDice = loadedDice
        self.statusLine = statusLine
        self.rollsLeft = rollsLeft
        self.standingsLines = standingsLines
    }

    /// `cupReady`/`loadedDice`/`statusLine`/`rollsLeft`/`standingsLines`
    /// all postdate the first wire format — decodeIfPresent so an older
    /// peer's encode (or a message caught mid-rollout) still parses instead
    /// of dropping the connection over a new field.
    private enum CodingKeys: String, CodingKey {
        case kind, mySeat, seatNames, chips, centerPot, turnSeat, isMyTurn, gameOver, winnerSeat, cupReady, loadedDice
        case statusLine, rollsLeft, standingsLines
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
        loadedDice = try container.decodeIfPresent(Int.self, forKey: .loadedDice) ?? 0
        statusLine = try container.decodeIfPresent(String.self, forKey: .statusLine)
        rollsLeft = try container.decodeIfPresent(Int.self, forKey: .rollsLeft)
        standingsLines = try container.decodeIfPresent([String].self, forKey: .standingsLines)
    }
}
