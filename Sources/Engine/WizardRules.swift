import Foundation

/// Wizard: follow the led suit if able; wizards and jesters are always
/// playable. First wizard in a trick wins; an all-jester trick goes to the
/// first jester; a jester lead means the first non-jester sets the led suit;
/// a wizard lead means no led suit at all.
public struct WizardRules: GameRules {
    public init() {}

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        TrickMath.followSuitLegality(of: card, hand: hand, trick: trick)
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        TrickMath.standardWinner(trick, trump: trump)
    }
}
