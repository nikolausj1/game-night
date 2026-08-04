import Foundation

/// UNO: match the active color or the top discard's symbol; wilds are always
/// playable. The active color is the top card's printed color, or — when the
/// top is a wild — the color declared via `declareSuit`, stored in
/// `round.trumpSuit` through the fixed Suit↔UnoColor mapping (red↔hearts,
/// yellow↔diamonds, green↔clubs, blue↔spades).
///
/// While a draw penalty is pending (`round.pendingDraw > 0`, stacking on):
/// only a draw-two may be stacked on a draw-two chain, and a wild-draw-four
/// may be stacked on either chain. Everything else is illegal — the player
/// draws to absorb instead.
public struct UnoRules: GameRules {
    public init() {}

    public func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality {
        guard case .uno(let color, let symbol) = card.kind else {
            return .illegal(reason: "That card doesn't belong to an UNO deck")
        }
        guard let top = state.discardPile.last, case .uno(let topColor, let topSymbol) = top.kind else {
            return .legal
        }

        let pending = state.round?.pendingDraw ?? 0
        if pending > 0, state.rules.stackDrawCards {
            if symbol == .wildDrawFour { return .legal }
            if symbol == .drawTwo, topSymbol == .drawTwo { return .legal }
            return .illegal(reason: "Stack a draw card or draw \(pending)")
        }

        if symbol == .wild || symbol == .wildDrawFour { return .legal }

        // Top is a wild → the declared color (trumpSuit-mapped) is active.
        let activeColor = topColor ?? state.round?.trumpSuit?.unoColor
        if let activeColor, color == activeColor { return .legal }
        if symbol == topSymbol { return .legal }

        let colorName = activeColor?.rawValue ?? "the declared color"
        return .illegal(reason: "Play \(colorName), match the card, or play a wild")
    }

    public func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        trick.first?.seat ?? -1
    }
}
