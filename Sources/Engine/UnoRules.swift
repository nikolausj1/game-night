import Foundation

/// UNO: match the active color or the top discard's symbol; wilds are always
/// playable. The active color is the top card's printed color, or — when the
/// top is a wild — the color declared via `declareSuit`, stored in
/// `round.trumpSuit` through the fixed Suit↔UnoColor mapping (red↔hearts,
/// yellow↔diamonds, green↔clubs, blue↔spades).
///
/// While a draw penalty is pending (`round.pendingDraw > 0`) every other
/// play is illegal — the player must draw instead (one card at a time in
/// manual mode, `rules.autoDrawPenalty == false`, the default). If
/// `stackDrawCards` is also on, a draw-two may be stacked on a draw-two
/// chain, and a wild-draw-four may be stacked on either chain, passing the
/// accumulated penalty on instead of absorbing it. This is a hard rule: it
/// is checked before soft-enforcement/`force`, so a pending penalty can
/// never be played through.
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
        if pending > 0 {
            if state.rules.stackDrawCards {
                if symbol == .wildDrawFour { return .legal }
                if symbol == .drawTwo, topSymbol == .drawTwo { return .legal }
                return .illegal(reason: "Stack a draw card or draw \(pending)")
            }
            // Stacking off: nothing answers a pending penalty, not even a
            // color/symbol match — draw is the only legal action.
            return .illegal(reason: "Draw \(pending) first")
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
