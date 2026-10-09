import Foundation

// Card-choice logic for the computer players of UNO, Crazy Eights and the
// trick-taking games. It lives in the Engine (pure functions of a
// `GameState` plus the seat) so it can be tested headless; the App layer's
// `BotStrategy` types are thin adapters that call these.
//
// Every brain follows the same discipline as the strategies it replaced:
// use ONLY what a player at that seat could see (own hand, the discard
// pile / trick, hand COUNTS), never other hands or the draw pile's order.
// Card counting from the visible discard pile is fair game: unseen cards =
// full deck - own hand - discard pile.
//
// `legacy*` entry points keep the previous heuristics verbatim for A/B tests.

// MARK: - Shared helpers

enum BotCardHelpers {
    /// Cards the ruleset would accept from this seat right now.
    static func legalCards(state: GameState, seat: Int) -> [Card] {
        let hand = state.hands[seat] ?? []
        let trick = state.round?.currentTrick ?? []
        let trump = state.round?.trumpSuit
        let rules = state.gameKind.ruleset
        return hand.filter {
            rules.legality(of: $0, hand: hand, trick: trick, trump: trump, state: state).isLegal
        }
    }

    static func nextSeat(after seat: Int, state: GameState) -> Int {
        let count = max(state.seats.count, 1)
        let direction = state.round?.direction ?? 1
        let raw = (seat + direction) % count
        return raw < 0 ? raw + count : raw
    }

    /// P(at least one of `copies` target cards is among `draws` cards drawn
    /// without replacement from `pool`).
    static func pHoldAtLeastOne(copies: Int, pool: Int, draws: Int) -> Double {
        guard pool > 0, draws > 0, copies > 0 else { return 0 }
        if draws >= pool || copies >= pool { return 1 }
        var pNone = 1.0
        for i in 0..<min(draws, pool) {
            let denom = Double(pool - i)
            pNone *= max(0, denom - Double(copies)) / denom
        }
        return 1 - pNone
    }

    /// Cards neither in `hand` nor on the discard pile, out of `deck`.
    static func unseen(deck: [Card], hand: [Card], discard: [Card]) -> [Card] {
        var seen = Set<String>()
        for c in hand { seen.insert(c.id) }
        for c in discard { seen.insert(c.id) }
        return deck.filter { !seen.contains($0.id) }
    }

    static let unoDeck: [Card] = DeckBuilder.uno108()
    static let standardDeck: [Card] = DeckBuilder.standard52()
}

// MARK: - UNO

public enum UnoBrain {
    /// Tunables (set by measurement against the legacy bot; see tests).
    struct Tuning {
        var cont = 1.0, urgency = 1.0, skipBonus = 0.8, reverseBonus2p = 0.8, reverseBonusN = 0.3
        var drawTwoBonus = 0.9, numberWeight = 0.03, wildHold = -3.0, actionExtra = 0.0
        var coverage = 1.0, singleton = 0.0, actionHoldN = -1.5
    }
    static var tuning = Tuning()

    public static func suit(for color: UnoColor) -> Suit { color.suit }

    private static func symbol(_ c: Card) -> UnoSymbol? {
        if case .uno(_, let s) = c.kind { return s }
        return nil
    }
    private static func color(_ c: Card) -> UnoColor? {
        if case .uno(let col, _) = c.kind { return col }
        return nil
    }
    private static func isWild(_ c: Card) -> Bool {
        let s = symbol(c)
        return s == .wild || s == .wildDrawFour
    }
    private static func isAction(_ c: Card) -> Bool {
        switch symbol(c) {
        case .skip, .reverse, .drawTwo: return true
        default: return false
        }
    }
    private static func numberValue(_ c: Card) -> Int {
        if case .number(let n)? = symbol(c) { return n }
        return isWild(c) ? 50 : 20
    }
    /// Could `next` be played straight after `c` (color or symbol match, or a wild)?
    private static func follows(_ next: Card, _ c: Card) -> Bool {
        if isWild(next) { return true }
        if let a = color(next), a == color(c) { return true }
        if let s = symbol(next), s == symbol(c) { return true }
        return false
    }

    private static func activeColor(state: GameState) -> UnoColor? {
        if let declared = state.round?.trumpSuit { return declared.unoColor }
        guard let top = state.discardPile.last else { return nil }
        return color(top)
    }

    // MARK: Declaring a wild's color

    /// The color to name after a wild: mostly the color I hold the most of,
    /// leaning toward colors the (next) opponent is least likely to hold
    /// (fewest unseen cards of that color), especially when they are close
    /// to going out.
    public static func declare(state: GameState, seat: Int) -> Suit {
        let hand = state.hands[seat] ?? []
        let unseen = BotCardHelpers.unseen(deck: BotCardHelpers.unoDeck, hand: hand, discard: state.discardPile)
        let nextCount = state.hands[BotCardHelpers.nextSeat(after: seat, state: state)]?.count ?? 7
        let weightOpp = nextCount <= 2 ? 0.25 : 0.06
        var best: (UnoColor, Double)?
        for col in UnoColor.allCases {
            let mine = Double(hand.filter { color($0) == col }.count)
            let theirs = Double(unseen.filter { color($0) == col }.count)
            let score = mine * 1.0 - theirs * weightOpp
            if best == nil || score > best!.1 + 1e-9 { best = (col, score) }
        }
        return (best?.0 ?? .red).suit
    }

    // MARK: Playing

    public static func play(state: GameState, seat: Int,
                            personality: BotPersonality = .neutral) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = BotCardHelpers.legalCards(state: state, seat: seat)
        let pending = state.round?.pendingDraw ?? 0

        if pending > 0 {
            // Stack onward if allowed, otherwise absorb the penalty.
            let stacker = legal.first { symbol($0) == .drawTwo } ?? legal.first { symbol($0) == .wildDrawFour }
            if let stacker { return .playCard(cardID: stacker.id, force: false) }
            return .drawCard
        }
        guard !legal.isEmpty else {
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }
        if legal.count == 1 || hand.count == 1 { return .playCard(cardID: legal[0].id, force: false) }

        let unseen = BotCardHelpers.unseen(deck: BotCardHelpers.unoDeck, hand: hand, discard: state.discardPile)
        let next = BotCardHelpers.nextSeat(after: seat, state: state)
        let nextCount = state.hands[next]?.count ?? 7
        let urgency = nextCount <= 2 ? 3.0 : (nextCount <= 4 ? 1.2 : 0.4)
        let active = activeColor(state: state)
        let colored = legal.filter { !isWild($0) }
        let t = tuning

        var bestCard = legal[0]
        var bestScore = -Double.infinity
        for card in legal {
            var score: Double
            if isWild(card) {
                if !colored.isEmpty {
                    // Hold wilds: they are the guaranteed way out later.
                    score = t.wildHold
                    // ... unless the next player is about to win: Wild Draw Four is the stopper.
                    if symbol(card) == .wildDrawFour, nextCount <= 2 { score = 6 }
                } else {
                    // Only wilds are playable. Draw Four if the next player is
                    // close to out, or I'm honest (no card of the active color).
                    let honest = active.map { a in !hand.contains { color($0) == a } } ?? true
                    if symbol(card) == .wildDrawFour { score = (nextCount <= 2 || honest) ? 1 : -1 } else { score = 0 }
                }
            } else {
                let rest = hand.filter { $0.id != card.id }
                let cont = Double(rest.filter { follows($0, card) }.count)
                let col = color(card)
                let sym = symbol(card)
                let matches = unseen.filter { isWild($0) || color($0) == col || symbol($0) == sym }.count
                let pCan = BotCardHelpers.pHoldAtLeastOne(copies: matches, pool: max(unseen.count, 1), draws: nextCount)
                score = t.cont * cont + t.urgency * urgency * (1 - pCan)
                var colorsLeft = Set<UnoColor>()
                for r in rest { if let c = color(r) { colorsLeft.insert(c) } }
                if rest.contains(where: { isWild($0) }) { colorsLeft = Set(UnoColor.allCases) }
                score += t.coverage * Double(colorsLeft.count)
                if let c = col, hand.filter({ color($0) == c }).count == 1 { score += t.singleton }
                switch sym {
                case .skip?:
                    score += t.skipBonus + (nextCount <= 2 ? urgency * 0.5 : 0)
                case .reverse?:
                    score += state.seats.count == 2 ? t.reverseBonus2p : t.reverseBonusN
                case .drawTwo?:
                    score += t.drawTwoBonus + (nextCount <= 4 ? urgency * 0.5 : 0)
                default:
                    score += t.numberWeight * Double(numberValue(card))
                }
                if isAction(card) {
                    score += t.actionExtra + 0.4 * personality.riskBias
                    if state.seats.count > 2, nextCount > 3 { score += t.actionHoldN }
                } // bold dumps action cards sooner
            }
            if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && card.id < bestCard.id) {
                bestScore = score
                bestCard = card
            }
        }
        return .playCard(cardID: bestCard.id, force: false)
    }

    // MARK: Legacy (previous heuristic, verbatim in behavior)

    public static func legacyDeclare(state: GameState, seat: Int) -> Suit {
        let hand = state.hands[seat] ?? []
        var counts: [UnoColor: Int] = [:]
        for card in hand { if let c = color(card) { counts[c, default: 0] += 1 } }
        let best = counts.max { l, r in
            l.value != r.value ? l.value < r.value : l.key.suit.rawValue > r.key.suit.rawValue
        }?.key ?? .red
        return best.suit
    }

    public static func legacyPlay(state: GameState, seat: Int) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = BotCardHelpers.legalCards(state: state, seat: seat)
        let pending = state.round?.pendingDraw ?? 0
        if pending > 0 {
            let stacker = legal.first { symbol($0) == .drawTwo } ?? legal.first { symbol($0) == .wildDrawFour }
            if let stacker { return .playCard(cardID: stacker.id, force: false) }
            return .drawCard
        }
        guard !legal.isEmpty else {
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }
        let neighborCount = state.hands[BotCardHelpers.nextSeat(after: seat, state: state)]?.count ?? Int.max
        let neighborLow = neighborCount <= 2
        var colorDepth: [UnoColor: Int] = [:]
        for card in hand { if let c = color(card) { colorDepth[c, default: 0] += 1 } }
        func depth(_ card: Card) -> Int { color(card).flatMap { colorDepth[$0] } ?? 0 }
        func rankValue(_ card: Card) -> Int {
            switch symbol(card) {
            case .number(let n)?: return n
            case .skip?, .reverse?, .drawTwo?: return 15
            default: return 0
            }
        }
        func best(_ cs: [Card]) -> Card? {
            cs.max { l, r in depth(l) != depth(r) ? depth(l) < depth(r) : rankValue(l) < rankValue(r) }
        }
        let nonWilds = legal.filter { !isWild($0) }
        let numbers = nonWilds.filter { if case .number? = symbol($0) { return true } else { return false } }
        let actions = nonWilds.filter { if case .number? = symbol($0) { return false } else { return true } }
        if neighborLow, let punch = best(actions) { return .playCard(cardID: punch.id, force: false) }
        if let n = best(numbers) { return .playCard(cardID: n.id, force: false) }
        if let a = best(actions) { return .playCard(cardID: a.id, force: false) }
        let wilds = legal.filter { isWild($0) }
        let plain = wilds.first { symbol($0) == .wild }
        let four = wilds.first { symbol($0) == .wildDrawFour }
        let active = activeColor(state: state)
        let honest = active.map { a in !hand.contains { color($0) == a } } ?? true
        if let four, honest || neighborLow {
            if neighborLow { return .playCard(cardID: four.id, force: false) }
            if plain == nil { return .playCard(cardID: four.id, force: false) }
        }
        if let plain { return .playCard(cardID: plain.id, force: false) }
        if let four { return .playCard(cardID: four.id, force: false) }
        return .playCard(cardID: legal[0].id, force: false)
    }
}

// MARK: - Crazy Eights

public enum CrazyEightsBrain {
    struct Tuning { var cont = 0.5, urgency = 3.0, rank = 0.0, spendEight = 0.0 }
    static var tuning = Tuning()

    /// Suit to name after an eight: the suit I hold most of (eights excluded),
    /// leaning away from suits the next player is likely to hold, especially
    /// when they are close to going out.
    public static func declare(state: GameState, seat: Int) -> Suit {
        let hand = state.hands[seat] ?? []
        let unseen = BotCardHelpers.unseen(deck: BotCardHelpers.standardDeck, hand: hand, discard: state.discardPile)
        let nextCount = state.hands[(seat + 1) % max(state.seats.count, 1)]?.count ?? 5
        let weightOpp = nextCount <= 2 ? 0.3 : 0.08
        var best: (Suit, Double)?
        for suit in Suit.allCases {
            let mine = Double(hand.filter { $0.suit == suit && $0.rank != 8 }.count)
            let theirs = Double(unseen.filter { $0.suit == suit && $0.rank != 8 }.count)
            let score = mine - theirs * weightOpp
            if best == nil || score > best!.1 + 1e-9 { best = (suit, score) }
        }
        return best?.0 ?? .hearts
    }

    public static func play(state: GameState, seat: Int,
                            personality: BotPersonality = .neutral) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = BotCardHelpers.legalCards(state: state, seat: seat)
        if legal.isEmpty {
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }
        if legal.count == 1 || hand.count == 1 { return .playCard(cardID: legal[0].id, force: false) }
        let nonEights = legal.filter { $0.rank != 8 }
        // Eights are escape hatches: only spend one when nothing else plays,
        // or when it goes out (handled by hand.count == 1 above).
        if nonEights.isEmpty { return .playCard(cardID: legal[0].id, force: false) }

        let unseen = BotCardHelpers.unseen(deck: BotCardHelpers.standardDeck, hand: hand, discard: state.discardPile)
        let nextCount = state.hands[(seat + 1) % max(state.seats.count, 1)]?.count ?? 5
        let urgency = nextCount <= 2 ? 3.0 : (nextCount <= 3 ? 1.2 : 0.4)

        var best = nonEights[0]
        var bestScore = -Double.infinity
        for card in nonEights {
            let rest = hand.filter { $0.id != card.id }
            let cont = Double(rest.filter { $0.rank == 8 || $0.suit == card.suit || $0.rank == card.rank }.count)
            let matches = unseen.filter { $0.rank == 8 || $0.suit == card.suit || $0.rank == card.rank }.count
            let pCan = BotCardHelpers.pHoldAtLeastOne(copies: matches, pool: max(unseen.count, 1), draws: nextCount)
            let t = tuning
            var score = t.cont * cont + t.urgency * urgency * (1 - pCan)
            score += t.rank * Double(card.rank ?? 0) // shed high cards first
            if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && card.id < best.id) {
                bestScore = score; best = card
            }
        }
        return .playCard(cardID: best.id, force: false)
    }

    // MARK: Legacy

    public static func legacyDeclare(state: GameState, seat: Int) -> Suit {
        var counts: [Suit: Int] = [:]
        for card in state.hands[seat] ?? [] where card.rank != 8 {
            if let s = card.suit { counts[s, default: 0] += 1 }
        }
        return counts.max { l, r in
            l.value != r.value ? l.value < r.value : l.key.rawValue > r.key.rawValue
        }?.key ?? .hearts
    }

    public static func legacyPlay(state: GameState, seat: Int) -> PlayerAction? {
        let hand = state.hands[seat] ?? []
        let legal = BotCardHelpers.legalCards(state: state, seat: seat)
        if legal.isEmpty {
            let canDraw = !state.drawPile.isEmpty || state.discardPile.count > 1
            return canDraw ? .drawCard : nil
        }
        let nonEights = legal.filter { $0.rank != 8 }
        var counts: [Suit: Int] = [:]
        for card in hand where card.rank != 8 { if let s = card.suit { counts[s, default: 0] += 1 } }
        if !nonEights.isEmpty {
            let best = nonEights.max { l, r in
                let ls = l.suit.map { counts[$0] ?? 0 } ?? 0
                let rs = r.suit.map { counts[$0] ?? 0 } ?? 0
                if ls != rs { return ls < rs }
                return (l.rank ?? 0) < (r.rank ?? 0)
            }!
            return .playCard(cardID: best.id, force: false)
        }
        return .playCard(cardID: legal[0].id, force: false)
    }
}

// MARK: - Trick-taking (Wizard, Oh Hell)

public enum TrickBrain {
    /// Tunables, calibrated by self-play against the legacy bot (see tests).
    struct Tuning {
        /// The legacy "sure trick" sum badly UNDER-bids (measured: ~1.6 tricks
        /// low per Wizard round at 3 players), so it is scaled up, by less as
        /// the table grows (each strong card wins fewer tricks against more
        /// opponents): scale = clamp(intercept - slope * players, minScale, maxScale).
        var scaleIntercept = 2.6, scaleSlope = 0.3, minScale = 0.8, maxScale = 2.0
        /// Added before rounding (negative = bid lower).
        var bidBias = 0.0
    }
    static var tuning = Tuning()

    private static func strength(_ card: Card, trump: Suit?) -> Int {
        switch card.kind {
        case .wizard: return 1000
        case .jester: return 0
        case .uno: return 0
        case .standard(let suit, let rank):
            if let trump, suit == trump { return 200 + rank }
            return rank
        }
    }

    // MARK: Bidding

    private static func rawExpected(hand: [Card], trump: Suit?) -> Double {
        var expected = 0.0
        for card in hand {
            switch card.kind {
            case .wizard: expected += 1.0
            case .jester, .uno: break
            case .standard(let suit, let rank):
                if let trump, suit == trump {
                    switch rank {
                    case 14: expected += 0.95
                    case 13: expected += 0.8
                    case 12: expected += 0.6
                    case 9...11: expected += 0.35
                    default: expected += 0.15
                    }
                } else {
                    switch rank {
                    case 14: expected += 0.7
                    case 13: expected += 0.35
                    default: break
                    }
                }
            }
        }
        return expected
    }

    public static func bid(state: GameState, seat: Int, legacy: Bool = false,
                           personality: BotPersonality = .neutral) -> Int {
        guard let round = state.round else { return 0 }
        let hand = state.hands[seat] ?? []
        var expected = rawExpected(hand: hand, trump: round.trumpSuit)
        if !legacy {
            let t = tuning
            let scale = min(t.maxScale, max(t.minScale, t.scaleIntercept - t.scaleSlope * Double(state.seats.count)))
            // Bold bots shade their bids up a touch, cautious ones down.
            expected = expected * scale + t.bidBias + 0.15 * personality.riskBias
        }
        var bid = max(0, min(Int(expected.rounded()), round.cardsPerPlayer))
        if state.rules.screwTheDealer, seat == round.dealerSeat {
            let othersTotal = round.bids.values.reduce(0, +)
            if othersTotal + bid == round.cardsPerPlayer {
                bid = bid > 0 ? bid - 1 : bid + 1
                bid = max(0, min(bid, round.cardsPerPlayer))
            }
        }
        return bid
    }

    public static func chooseTrump(state: GameState, seat: Int) -> Suit {
        var score: [Suit: Int] = [:]
        for card in state.hands[seat] ?? [] {
            if case .standard(let suit, let rank) = card.kind { score[suit, default: 0] += 20 + rank }
        }
        return score.max { l, r in l.value != r.value ? l.value < r.value : l.key.rawValue > r.key.rawValue }?.key ?? .spades
    }

    // MARK: Playing

    public static func play(state: GameState, seat: Int, legacy: Bool = false) -> PlayerAction? {
        guard let round = state.round else { return nil }
        let legal = BotCardHelpers.legalCards(state: state, seat: seat)
        guard !legal.isEmpty else { return nil }

        let trick = round.currentTrick
        let trump = round.trumpSuit
        let rules = state.gameKind.ruleset
        let bid = round.bids[seat] ?? 0
        let won = round.tricksWon[seat] ?? 0
        let wantWin = won < bid
        let amLast = trick.count == state.seats.count - 1
        let lateInTrick = trick.count >= state.seats.count - 2
        let tricksLeft = (state.hands[seat] ?? []).count // cards left == tricks left
        let needed = bid - won

        func currentlyWins(_ card: Card) -> Bool {
            var simulated = trick
            simulated.append(TrickPlay(seat: seat, card: card, wasForced: false))
            return rules.trickWinner(simulated, trump: trump) == seat
        }
        let byStrength = legal.sorted { strength($0, trump: trump) < strength($1, trump: trump) }

        if trick.isEmpty {
            if wantWin {
                let nonWizards = byStrength.filter { !$0.isWizard }
                if !legacy, needed >= tricksLeft, let w = legal.first(where: { $0.isWizard }) {
                    // Every remaining trick must be won: spend a wizard now.
                    return .playCard(cardID: w.id, force: false)
                }
                let lead = nonWizards.last ?? byStrength.last!
                return .playCard(cardID: lead.id, force: false)
            }
            return .playCard(cardID: byStrength.first!.id, force: false)
        }

        if wantWin {
            let standardWinners = byStrength.filter { currentlyWins($0) && !$0.isWizard }
            if let cheapest = standardWinners.first {
                return .playCard(cardID: cheapest.id, force: false)
            }
            if lateInTrick || amLast, let wizard = legal.first(where: { $0.isWizard }) {
                return .playCard(cardID: wizard.id, force: false)
            }
            let dump = byStrength.first { !$0.isWizard } ?? byStrength.first!
            return .playCard(cardID: dump.id, force: false)
        }

        if let jester = legal.first(where: { $0.isJester }) {
            return .playCard(cardID: jester.id, force: false)
        }
        let losers = byStrength.filter { !currentlyWins($0) }
        if let biggestLoser = losers.last {
            return .playCard(cardID: biggestLoser.id, force: false)
        }
        return .playCard(cardID: byStrength.first!.id, force: false)
    }
}
