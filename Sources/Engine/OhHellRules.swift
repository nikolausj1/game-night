import Foundation

/// Oh Hell: standard 52-card deck, same trick rules as Wizard minus the
/// wizard/jester special cases (which never occur with this deck). Trump is
/// the flipped card's suit.
public struct OhHellRules: GameRules {
    public init() {}

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        TrickMath.followSuitLegality(of: card, hand: hand, trick: trick)
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        TrickMath.standardWinner(trick, trump: trump)
    }
}
