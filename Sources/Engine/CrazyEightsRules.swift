import Foundation

/// Crazy Eights: match the top discard's suit or rank, or play an eight
/// (wild — the player then declares a suit). Draw from the pile when stuck.
/// First player to empty their hand wins.
public struct CrazyEightsRules: GameRules {
    public init() {}

    /// After an eight, the declared suit (stored in `round.trumpSuit`) must
    /// be matched instead of the top card's own suit.
    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        guard let top = state.discardPile.last else { return .legal }
        if card.rank == 8 { return .legal }
        if let declared = state.round?.trumpSuit {
            if card.suit == declared { return .legal }
            return .illegal(reason: "You must play \(declared.rawValue) or an eight")
        }
        if card.suit == top.suit { return .legal }
        if let rank = card.rank, rank == top.rank { return .legal }
        let suitName = top.suit?.rawValue ?? "the suit"
        let rankName = top.rank.map(String.init) ?? "the rank"
        return .illegal(reason: "Play \(suitName), match the \(rankName), or play an eight")
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        trick.first?.seat ?? -1
    }
}
