import Foundation

/// Free Play: no rules at all — the table is just shared felt. Any card can
/// be moved or played by anyone at any time.
public struct FreePlayRules: GameRules {
    public init() {}

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        .legal
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        trick.first?.seat ?? -1
    }
}
