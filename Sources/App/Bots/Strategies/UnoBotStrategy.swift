import Foundation

/// UNO: shed the color you're deepest in, numbers first, saving action
/// cards to punish a neighbor who's nearly out and wilds for when nothing
/// else fits. Wild Draw Four stays official-honest (no active-color match
/// in hand) unless the next player is about to win.
///
/// Coded against the UNO engine contract:
/// `CardKind.uno(color: UnoColor?, symbol: UnoSymbol)` (wilds carry nil
/// color), `RoundState.pendingDraw`, and wild color declared via
/// `.declareSuit` with red↔hearts, yellow↔diamonds, green↔clubs,
/// blue↔spades.
struct UnoBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .play:
            return play(state: state, seat: seat)
        case .declareSuit:
            let color = mostHeldColor(in: state.hands[seat] ?? [])
            return .declareSuit(Self.suit(for: color))
        case .bid, .chooseTrump:
            return nil // not UNO decisions
        }
    }

    // MARK: - Main play decision

    private func play(state: GameState, seat: Int) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = legalCards(state: state, seat: seat)
        let pending = state.round?.pendingDraw ?? 0

        // A draw penalty is pointed at us: stack another Draw Two / Wild
        // Draw Four if the rules let us, otherwise absorb it. The engine
        // interprets `.drawCard` under pendingDraw as taking the penalty.
        if pending > 0 {
            let stacker = legal.first { symbol(of: $0) == .drawTwo }
                ?? legal.first { symbol(of: $0) == .wildDrawFour }
            if let stacker {
                return .playCard(cardID: stacker.id, force: false)
            }
            return .drawCard
        }

        // Nothing playable: draw voluntarily — but only if the engine has
        // cards to give (draw pile, or a recyclable discard pile), so a
        // truly dry table never turns into reject spam.
        guard !legal.isEmpty else {
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }

        let neighborCount = state.hands[nextSeat(after: seat, state: state)]?.count ?? Int.max
        let neighborLow = neighborCount <= 2
        let colorDepth = colorCounts(in: hand)

        /// How much of our hand shares this card's color — deeper is better.
        func depth(_ card: Card) -> Int {
            guard let c = color(of: card) else { return 0 }
            return colorDepth[c] ?? 0
        }

        let nonWilds = legal.filter { !isWild($0) }
        let numbers = nonWilds.filter { if case .number = symbol(of: $0) { return true } else { return false } }
        let actions = nonWilds.filter { if case .number = symbol(of: $0) { return false } else { return true } }

        // Neighbor is about to go out: hit them with skip/reverse/drawTwo now.
        if neighborLow, let punch = best(actions, depth: depth) {
            return .playCard(cardID: punch.id, force: false)
        }

        // Normal shedding: numbers first (hold action cards for later),
        // from our deepest color, biggest number first.
        if let number = best(numbers, depth: depth) {
            return .playCard(cardID: number.id, force: false)
        }

        // Only action cards match — play one rather than touch a wild.
        if let action = best(actions, depth: depth) {
            return .playCard(cardID: action.id, force: false)
        }

        // Wilds are all that's legal. Wild Draw Four only if we're honest
        // (no non-wild card of the active color in hand) or the neighbor is
        // about to win; otherwise the plain wild.
        let wilds = legal.filter { isWild($0) }
        let plainWild = wilds.first { symbol(of: $0) == .wild }
        let drawFour = wilds.first { symbol(of: $0) == .wildDrawFour }

        let active = activeColor(state: state)
        let honest = active.map { a in !hand.contains { color(of: $0) == a } } ?? true

        if let drawFour, honest || neighborLow {
            if neighborLow { return .playCard(cardID: drawFour.id, force: false) }
            if plainWild == nil { return .playCard(cardID: drawFour.id, force: false) }
        }
        if let plainWild { return .playCard(cardID: plainWild.id, force: false) }
        if let drawFour { return .playCard(cardID: drawFour.id, force: false) }

        // Shouldn't happen (legal was non-empty), but never stall the table.
        return .playCard(cardID: legal[0].id, force: false)
    }

    /// Deepest color first; among equals, shed the highest number (actions
    /// tie at the top).
    private func best(_ candidates: [Card], depth: (Card) -> Int) -> Card? {
        candidates.max { lhs, rhs in
            let l = depth(lhs), r = depth(rhs)
            if l != r { return l < r }
            return rankValue(lhs) < rankValue(rhs)
        }
    }

    private func rankValue(_ card: Card) -> Int {
        switch symbol(of: card) {
        case .number(let n): return n
        case .skip, .reverse, .drawTwo: return 15
        case .wild, .wildDrawFour: return 0
        case nil: return 0
        }
    }

    // MARK: - Card anatomy

    private func symbol(of card: Card) -> UnoSymbol? {
        if case .uno(_, let symbol) = card.kind { return symbol }
        return nil
    }

    private func color(of card: Card) -> UnoColor? {
        if case .uno(let color, _) = card.kind { return color }
        return nil
    }

    private func isWild(_ card: Card) -> Bool {
        switch symbol(of: card) {
        case .wild, .wildDrawFour: return true
        default: return false
        }
    }

    private func colorCounts(in hand: [Card]) -> [UnoColor: Int] {
        var counts: [UnoColor: Int] = [:]
        for card in hand {
            if let c = color(of: card) { counts[c, default: 0] += 1 }
        }
        return counts
    }

    /// Wild declaration: the color we hold most of (wilds don't count).
    private func mostHeldColor(in hand: [Card]) -> UnoColor {
        colorCounts(in: hand).max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : Self.suit(for: lhs.key).rawValue > Self.suit(for: rhs.key).rawValue
        }?.key ?? .red
    }

    /// The color that must currently be matched: a declared wild color
    /// (round.trumpSuit, per the crazy-eights convention) beats the top
    /// discard's own color.
    private func activeColor(state: GameState) -> UnoColor? {
        if let declared = state.round?.trumpSuit { return Self.color(for: declared) }
        guard let top = state.discardPile.last else { return nil }
        return color(of: top)
    }

    // MARK: - UnoColor ↔ Suit contract mapping

    static func suit(for color: UnoColor) -> Suit {
        switch color {
        case .red: return .hearts
        case .yellow: return .diamonds
        case .green: return .clubs
        case .blue: return .spades
        }
    }

    static func color(for suit: Suit) -> UnoColor {
        switch suit {
        case .hearts: return .red
        case .diamonds: return .yellow
        case .clubs: return .green
        case .spades: return .blue
        }
    }
}
