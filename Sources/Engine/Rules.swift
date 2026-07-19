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

    public init(
        screwTheDealer: Bool = false,
        missScoresTricks: Bool = true,
        softEnforcement: Bool = true
    ) {
        self.screwTheDealer = screwTheDealer
        self.missScoresTricks = missScoresTricks
        self.softEnforcement = softEnforcement
    }
}

/// Result of asking "may this card be played right now?".
/// `reason` is user-facing copy, e.g. "You must follow hearts".
public enum PlayLegality: Sendable, Equatable {
    case legal
    case illegal(reason: String)

    public var isLegal: Bool { self == .legal }
}
