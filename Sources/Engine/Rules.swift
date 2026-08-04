import Foundation

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
    /// draw-one-then-pass). The v1 engine treats this as always false; the
    /// flag exists so the setting can ship without a wire change.
    public var drawUntilPlayable: Bool

    public init(
        screwTheDealer: Bool = false,
        missScoresTricks: Bool = true,
        softEnforcement: Bool = true,
        stackDrawCards: Bool = true,
        drawUntilPlayable: Bool = false
    ) {
        self.screwTheDealer = screwTheDealer
        self.missScoresTricks = missScoresTricks
        self.softEnforcement = softEnforcement
        self.stackDrawCards = stackDrawCards
        self.drawUntilPlayable = drawUntilPlayable
    }

    /// Older encodes predate the UNO flags; default them on decode so saved
    /// games and old peers still parse.
    private enum CodingKeys: String, CodingKey {
        case screwTheDealer, missScoresTricks, softEnforcement, stackDrawCards, drawUntilPlayable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screwTheDealer = try container.decode(Bool.self, forKey: .screwTheDealer)
        missScoresTricks = try container.decode(Bool.self, forKey: .missScoresTricks)
        softEnforcement = try container.decode(Bool.self, forKey: .softEnforcement)
        stackDrawCards = try container.decodeIfPresent(Bool.self, forKey: .stackDrawCards) ?? true
        drawUntilPlayable = try container.decodeIfPresent(Bool.self, forKey: .drawUntilPlayable) ?? false
    }
}

/// Result of asking "may this card be played right now?".
/// `reason` is user-facing copy, e.g. "You must follow hearts".
public enum PlayLegality: Sendable, Equatable {
    case legal
    case illegal(reason: String)

    public var isLegal: Bool { self == .legal }
}
