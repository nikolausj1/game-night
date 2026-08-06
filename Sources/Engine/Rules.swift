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

    /// UNO only: keep drawing until a playable card appears (vs. strict
    /// draw-one-then-pass). Default on — the table's house rule: "you have
    /// to keep drawing until you find a playable card". All drawn cards join
    /// the hand; the turn stays with the drawer, who then plays.
    public var drawUntilPlayable: Bool

    /// Free Play only: which deck the table gets dealt from. Default is the
    /// standard 52 — the tray lets the player switch live once seated.
    public var freePlayDeck: FreePlayDeck

    public init(
        screwTheDealer: Bool = false,
        missScoresTricks: Bool = true,
        softEnforcement: Bool = true,
        stackDrawCards: Bool = true,
        drawUntilPlayable: Bool = true,
        freePlayDeck: FreePlayDeck = .standard52
    ) {
        self.screwTheDealer = screwTheDealer
        self.missScoresTricks = missScoresTricks
        self.softEnforcement = softEnforcement
        self.stackDrawCards = stackDrawCards
        self.drawUntilPlayable = drawUntilPlayable
        self.freePlayDeck = freePlayDeck
    }

    /// Older encodes predate the UNO flags and the free-play deck picker;
    /// default them on decode so saved games and old peers still parse.
    private enum CodingKeys: String, CodingKey {
        case screwTheDealer, missScoresTricks, softEnforcement, stackDrawCards, drawUntilPlayable, freePlayDeck
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screwTheDealer = try container.decode(Bool.self, forKey: .screwTheDealer)
        missScoresTricks = try container.decode(Bool.self, forKey: .missScoresTricks)
        softEnforcement = try container.decode(Bool.self, forKey: .softEnforcement)
        stackDrawCards = try container.decodeIfPresent(Bool.self, forKey: .stackDrawCards) ?? true
        drawUntilPlayable = try container.decodeIfPresent(Bool.self, forKey: .drawUntilPlayable) ?? true
        freePlayDeck = try container.decodeIfPresent(FreePlayDeck.self, forKey: .freePlayDeck) ?? .standard52
    }
}

/// Result of asking "may this card be played right now?".
/// `reason` is user-facing copy, e.g. "You must follow hearts".
public enum PlayLegality: Sendable, Equatable {
    case legal
    case illegal(reason: String)

    public var isLegal: Bool { self == .legal }
}
