import Foundation

/// Free Play's dev/design test bed: which deck the table gets dealt from.
/// Free Play has no rules or player-count limits — this is the one knob
/// that shapes what's on the felt.
public enum FreePlayDeck: String, Codable, CaseIterable, Sendable {
    case standard52, wizard60, uno108

    /// The freshly-built (unshuffled) deck for this selection.
    public func buildDeck() -> [Card] {
        switch self {
        case .standard52: return DeckBuilder.standard52()
        case .wizard60: return DeckBuilder.wizard60()
        case .uno108: return DeckBuilder.uno108()
        }
    }
}

/// House-rule toggles, snapshotted into the game at start.
public struct RulesConfig: Codable, Sendable, Equatable {
    /// When on, the dealer may not place a bid that makes the bids sum to the
    /// number of tricks in the round ("screw the dealer"). Default off.
    public var screwTheDealer: Bool

    /// Oh Hell only: a missed bid still scores 1 point per trick taken
    /// (vs. zero on a miss). Default on.
    public var missScoresTricks: Bool

    /// When on (default), an illegal card play is blocked with a user-facing
    /// reason but can be pushed through with `playCard(force: true)` — the
    /// table stays social, the app just asks "are you sure?". When off,
    /// illegal plays are always blocked.
    public var softEnforcement: Bool

    /// UNO only: draw-two / wild-draw-four penalties may be stacked onto the
    /// next player instead of drawn immediately. Default on.
    public var stackDrawCards: Bool

    /// UNO only: when a draw penalty lands on a seat (stacking exhausted, or
    /// stacking off), pull every card in one instant `drawCard` call and
    /// skip the victim's turn — the pre-realism "fast mode" behavior.
    /// Default off: the victim instead holds a `pendingDraw` count and must
    /// call `drawCard` once per card (or stack, if `stackDrawCards` allows
    /// it), same as physically drawing one card at a time off the pile.
    public var autoDrawPenalty: Bool

    /// UNO only: keep drawing until a playable card appears (vs. strict
    /// draw-one-then-pass). Default on — the table's house rule: "you have
    /// to keep drawing until you find a playable card". All drawn cards join
    /// the hand; the turn stays with the drawer, who then plays.
    public var drawUntilPlayable: Bool

    /// Free Play only: which deck the table gets dealt from. Default is the
    /// standard 52 — the tray lets the player switch live once seated.
    public var freePlayDeck: FreePlayDeck

    /// When on (default), the engine populates every hand at round start.
    /// When off (UNO / Wizard / Oh Hell / Crazy Eights), the deal phase
    /// builds and shuffles the pile but leaves hands empty — the round's
    /// dealer distributes cards one at a time via `TableAction.dealCardTo`,
    /// and the engine auto-completes (starter/trump flip, phase transition)
    /// the moment every hand reaches the round's target count.
    public var autoDeal: Bool

    /// Hearts only: run the 3-card passing phase (left / right / across /
    /// hold rotation). Off = every round is a "hold" round. Default on.
    public var heartsPassing: Bool

    /// Hearts only: nobody may play a point card (any heart or the queen of
    /// spades) on the first trick unless they hold nothing else. Default on
    /// (the house rule).
    public var heartsNoPointsFirstTrick: Bool

    /// Hearts only: when a seat shoots the moon, the shooter scores -26
    /// instead of every other seat scoring +26. Default off (+26 to others).
    public var heartsMoonSubtracts: Bool

    /// Hearts only: the game ends once any total reaches this score (and
    /// the lowest total is not tied). Default 100.
    public var heartsTargetScore: Int

    /// Spades only: a seat may bid blind nil (before looking at its cards)
    /// via `PlayerAction.bidBlindNil`. Worth +/-200. Default off.
    public var spadesBlindNil: Bool

    /// Spades only: individual (no partnerships) play. Always in effect with
    /// 2 or 3 players; with 4 players this flag turns partnerships off.
    /// Default off (4 players = N/S vs E/W partnerships).
    public var spadesCutthroat: Bool

    /// Spades only: the game ends once a team/seat reaches this score (the
    /// highest total wins; ties continue). Default 500.
    public var spadesTargetScore: Int

    public init(
        screwTheDealer: Bool = false,
        missScoresTricks: Bool = true,
        softEnforcement: Bool = true,
        stackDrawCards: Bool = true,
        drawUntilPlayable: Bool = true,
        freePlayDeck: FreePlayDeck = .standard52,
        autoDeal: Bool = true,
        autoDrawPenalty: Bool = false,
        heartsPassing: Bool = true,
        heartsNoPointsFirstTrick: Bool = true,
        heartsMoonSubtracts: Bool = false,
        heartsTargetScore: Int = 100,
        spadesBlindNil: Bool = false,
        spadesCutthroat: Bool = false,
        spadesTargetScore: Int = 500
    ) {
        self.screwTheDealer = screwTheDealer
        self.missScoresTricks = missScoresTricks
        self.softEnforcement = softEnforcement
        self.stackDrawCards = stackDrawCards
        self.drawUntilPlayable = drawUntilPlayable
        self.freePlayDeck = freePlayDeck
        self.autoDeal = autoDeal
        self.autoDrawPenalty = autoDrawPenalty
        self.heartsPassing = heartsPassing
        self.heartsNoPointsFirstTrick = heartsNoPointsFirstTrick
        self.heartsMoonSubtracts = heartsMoonSubtracts
        self.heartsTargetScore = heartsTargetScore
        self.spadesBlindNil = spadesBlindNil
        self.spadesCutthroat = spadesCutthroat
        self.spadesTargetScore = spadesTargetScore
    }

    /// Older encodes predate the UNO flags and the free-play deck picker;
    /// default them on decode so saved games and old peers still parse.
    private enum CodingKeys: String, CodingKey {
        case screwTheDealer, missScoresTricks, softEnforcement, stackDrawCards, drawUntilPlayable, freePlayDeck, autoDeal, autoDrawPenalty
        case heartsPassing, heartsNoPointsFirstTrick, heartsMoonSubtracts, heartsTargetScore
        case spadesBlindNil, spadesCutthroat, spadesTargetScore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screwTheDealer = try container.decode(Bool.self, forKey: .screwTheDealer)
        missScoresTricks = try container.decode(Bool.self, forKey: .missScoresTricks)
        softEnforcement = try container.decode(Bool.self, forKey: .softEnforcement)
        stackDrawCards = try container.decodeIfPresent(Bool.self, forKey: .stackDrawCards) ?? true
        drawUntilPlayable = try container.decodeIfPresent(Bool.self, forKey: .drawUntilPlayable) ?? true
        freePlayDeck = try container.decodeIfPresent(FreePlayDeck.self, forKey: .freePlayDeck) ?? .standard52
        autoDeal = try container.decodeIfPresent(Bool.self, forKey: .autoDeal) ?? true
        autoDrawPenalty = try container.decodeIfPresent(Bool.self, forKey: .autoDrawPenalty) ?? false
        heartsPassing = try container.decodeIfPresent(Bool.self, forKey: .heartsPassing) ?? true
        heartsNoPointsFirstTrick = try container.decodeIfPresent(Bool.self, forKey: .heartsNoPointsFirstTrick) ?? true
        heartsMoonSubtracts = try container.decodeIfPresent(Bool.self, forKey: .heartsMoonSubtracts) ?? false
        heartsTargetScore = try container.decodeIfPresent(Int.self, forKey: .heartsTargetScore) ?? 100
        spadesBlindNil = try container.decodeIfPresent(Bool.self, forKey: .spadesBlindNil) ?? false
        spadesCutthroat = try container.decodeIfPresent(Bool.self, forKey: .spadesCutthroat) ?? false
        spadesTargetScore = try container.decodeIfPresent(Int.self, forKey: .spadesTargetScore) ?? 500
    }
}

/// Result of asking "may this card be played right now?".
/// `reason` is user-facing copy, e.g. "You must follow hearts".
public enum PlayLegality: Sendable, Equatable {
    case legal
    case illegal(reason: String)

    public var isLegal: Bool { self == .legal }
}
