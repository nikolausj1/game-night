import Foundation

/// Blackjack for 1-5 family players against the house dealer. Chips only,
/// never real money. Pure Foundation: `BlackjackEngine` is the reducer,
/// `BlackjackBot` the basic-strategy player, this file the Codable wire
/// and state types plus the pure hand-value rules.
///
/// Seats are 0..<seatCount. The dealer is NOT a seat.

// MARK: - Config

public struct BlackjackConfig: Codable, Sendable, Equatable {
    /// Decks in the shoe (default 6).
    public var deckCount: Int
    /// Fraction of the shoe dealt before the cut card ends it. The round in
    /// progress always finishes; the shoe is reshuffled before the NEXT round.
    public var cutCardPenetration: Double
    public var minBet: Int
    public var maxBet: Int
    /// Bets must be a multiple of this. With the default of 2 a 3:2
    /// blackjack always pays a whole number of chips; an odd step floors
    /// the half chip.
    public var betStep: Int
    public var startingChips: Int
    /// true = H17 (dealer hits soft 17). Default false = S17.
    public var dealerHitsSoft17: Bool
    /// Insurance is OFF by default (kids' table).
    public var insuranceEnabled: Bool
    /// Late surrender (first decision only, never after a split). OFF.
    public var surrenderEnabled: Bool
    /// When the dealer shows an ace or ten-value card, the hole card is
    /// checked immediately and a dealer blackjack ends the round before
    /// anyone can double or split into it (US rules).
    public var dealerPeeks: Bool
    /// Doubling allowed on a hand created by a split.
    public var doubleAfterSplit: Bool
    /// Numerator/denominator of the natural blackjack payout (3:2).
    public var blackjackPayoutNumerator: Int
    public var blackjackPayoutDenominator: Int

    public init(deckCount: Int = 6, cutCardPenetration: Double = 0.75,
                minBet: Int = 10, maxBet: Int = 100, betStep: Int = 2,
                startingChips: Int = 500, dealerHitsSoft17: Bool = false,
                insuranceEnabled: Bool = false, surrenderEnabled: Bool = false,
                dealerPeeks: Bool = true, doubleAfterSplit: Bool = true,
                blackjackPayoutNumerator: Int = 3, blackjackPayoutDenominator: Int = 2) {
        self.deckCount = max(1, deckCount)
        self.cutCardPenetration = min(max(cutCardPenetration, 0.3), 0.95)
        self.minBet = max(1, minBet)
        self.maxBet = max(max(1, minBet), maxBet)
        self.betStep = max(1, betStep)
        self.startingChips = max(0, startingChips)
        self.dealerHitsSoft17 = dealerHitsSoft17
        self.insuranceEnabled = insuranceEnabled
        self.surrenderEnabled = surrenderEnabled
        self.dealerPeeks = dealerPeeks
        self.doubleAfterSplit = doubleAfterSplit
        self.blackjackPayoutNumerator = max(1, blackjackPayoutNumerator)
        self.blackjackPayoutDenominator = max(1, blackjackPayoutDenominator)
    }
}

// MARK: - Values and rules

public enum BlackjackOutcome: String, Codable, Sendable, Equatable {
    case blackjack, win, push, lose, bust, surrender
}

public struct BlackjackValue: Codable, Sendable, Equatable {
    public let total: Int
    /// true when an ace is currently counting as 11.
    public let isSoft: Bool
    public var isBust: Bool { total > 21 }

    public init(total: Int, isSoft: Bool) {
        self.total = total
        self.isSoft = isSoft
    }
}

public enum BlackjackRules {
    /// 2...10 face value, J/Q/K = 10, A = 11 (the soft/hard downgrade is
    /// handled in `value(of:)`). Non-standard cards are worth 0.
    public static func cardValue(_ card: Card) -> Int {
        guard let rank = card.rank else { return 0 }
        if rank == 14 { return 11 }
        if rank >= 11 { return 10 }
        return rank
    }

    public static func value(of cards: [Card]) -> BlackjackValue {
        var total = 0
        var softAces = 0
        for card in cards {
            let v = cardValue(card)
            total += v
            if v == 11 { softAces += 1 }
        }
        while total > 21 && softAces > 0 {
            total -= 10
            softAces -= 1
        }
        return BlackjackValue(total: total, isSoft: softAces > 0)
    }

    /// Two-card 21. (Whether it PAYS as a blackjack also depends on the
    /// hand not coming from a split; see `BlackjackHand.isNatural`.)
    public static func isTwoCard21(_ cards: [Card]) -> Bool {
        cards.count == 2 && value(of: cards).total == 21
    }

    /// Splittable pair: two cards of equal blackjack VALUE (so K-Q splits).
    public static func isPair(_ cards: [Card]) -> Bool {
        cards.count == 2 && cardValue(cards[0]) == cardValue(cards[1])
    }

    public static func dealerShouldHit(_ cards: [Card], hitsSoft17: Bool) -> Bool {
        let v = value(of: cards)
        if v.total < 17 { return true }
        if v.total == 17 && v.isSoft && hitsSoft17 { return true }
        return false
    }
}

// MARK: - Shoe

public enum BlackjackShoe {
    /// `deckCount` standard decks, shuffled deterministically by `seed`.
    /// Card IDs are unique across the shoe: the first copy of each card keeps
    /// its standard ID ("s14"); later copies get a deck suffix ("s14#1" ...
    /// "s14#5") so SwiftUI identity never collides. `kind` is always the
    /// standard rank/suit, so rendering by `kind` is unaffected.
    public static func make(deckCount: Int, seed: UInt64) -> [Card] {
        var cards: [Card] = []
        cards.reserveCapacity(deckCount * 52)
        for d in 0..<deckCount {
            for c in DeckBuilder.standard52() {
                cards.append(d == 0 ? c : Card(id: "\(c.id)#\(d)", kind: c.kind))
            }
        }
        var rng = SeededGenerator(seed: seed)
        return cards.shuffled(using: &rng)
    }

    /// Seed for the n-th shuffle of a game's shoe.
    public static func seed(game: UInt64, shuffle: Int) -> UInt64 {
        game &+ UInt64(shuffle) &* 0x9E37_79B9_7F4A_7C15
    }
}

// MARK: - Hand, seat, phase

public struct BlackjackHand: Codable, Sendable, Equatable {
    public var cards: [Card]
    /// Chips wagered on this hand (includes a double).
    public var bet: Int
    public var isDoubled: Bool
    public var isFromSplit: Bool
    public var isSplitAces: Bool
    public var isSurrendered: Bool
    /// No more decisions on this hand.
    public var isFinished: Bool
    public var outcome: BlackjackOutcome?
    /// Chips RETURNED to the player at settlement (stake included).
    /// Net result = `payout - bet`.
    public var payout: Int

    public init(cards: [Card] = [], bet: Int, isFromSplit: Bool = false) {
        self.cards = cards
        self.bet = bet
        self.isDoubled = false
        self.isFromSplit = isFromSplit
        self.isSplitAces = false
        self.isSurrendered = false
        self.isFinished = false
        self.outcome = nil
        self.payout = 0
    }

    public var value: BlackjackValue { BlackjackRules.value(of: cards) }
    public var isBust: Bool { value.isBust }
    /// A natural blackjack: two cards, 21, not made by splitting.
    public var isNatural: Bool { !isFromSplit && BlackjackRules.isTwoCard21(cards) }
}

public struct BlackjackSeatState: Codable, Sendable, Equatable {
    public var seat: Int
    /// Bankroll NOT currently on the table (wagers are deducted when placed).
    public var chips: Int
    /// Empty until a bet is placed this round.
    public var hands: [BlackjackHand]
    public var sittingOut: Bool
    /// Can no longer afford the minimum bet. Permanent for the session.
    public var isOut: Bool
    public var insuranceBet: Int
    public var insuranceDecided: Bool
    /// Net chips this seat won (+) or lost (-) in the last settled round.
    public var lastRoundNet: Int

    public init(seat: Int, chips: Int) {
        self.seat = seat
        self.chips = chips
        self.hands = []
        self.sittingOut = false
        self.isOut = false
        self.insuranceBet = 0
        self.insuranceDecided = false
        self.lastRoundNet = 0
    }

    public var hasBet: Bool { !hands.isEmpty }
}

public enum BlackjackPhase: String, Codable, Sendable, Equatable {
    /// Waiting on `placeBet` / `sitOut` from every seat still in.
    case betting
    /// Dealer shows an ace and insurance is on: waiting on `takeInsurance`.
    case insurance
    /// `activeSeat`/`activeHand` is the hand on turn.
    case playing
    /// Round settled. Waiting on `nextRound`.
    case roundComplete
    /// Every seat is out of chips. Terminal.
    case sessionOver
}

/// Tag-only view of what a seat may do right now (snapshot `legalActions`).
public enum BlackjackActionKind: String, Codable, Sendable, Equatable {
    case placeBet, sitOut, takeInsurance, hit, stand, doubleDown, split, surrender, nextRound
}

public enum BlackjackAction: Codable, Sendable, Equatable {
    /// Wager `amount` chips this round (betting phase).
    case placeBet(Int)
    /// Skip this round (betting phase).
    case sitOut
    /// Answer the insurance offer (insurance phase). Costs half the bet.
    case takeInsurance(Bool)
    case hit
    case stand
    case doubleDown
    case split
    case surrender
    /// Start the next round (round-complete phase). Any seat may send it.
    case nextRound
}

// MARK: - Events

public enum BlackjackEvent: Codable, Sendable, Equatable {
    case roundStarted(round: Int)
    case shoeReshuffled(decks: Int)
    case betPlaced(seat: Int, amount: Int)
    case satOut(seat: Int)
    case cardDealt(seat: Int, handIndex: Int, card: Card)
    case dealerUpCard(Card)
    /// Hole card dealt face down: the identity is NOT in the event.
    case dealerHoleDealt
    case playerBlackjack(seat: Int)
    case insuranceOffered
    case insuranceTaken(seat: Int, amount: Int)
    case insuranceDeclined(seat: Int)
    case dealerPeek(hasBlackjack: Bool)
    case turnStarted(seat: Int, handIndex: Int)
    case hit(seat: Int, handIndex: Int, card: Card)
    /// `auto` = engine stood the hand for the player (21, or split aces).
    case stand(seat: Int, handIndex: Int, auto: Bool)
    case doubled(seat: Int, handIndex: Int, card: Card, newBet: Int)
    case split(seat: Int)
    case surrendered(seat: Int, handIndex: Int)
    case bust(seat: Int, handIndex: Int, total: Int)
    case dealerRevealed(card: Card, total: Int)
    case dealerDrew(card: Card, total: Int)
    case dealerStands(total: Int)
    case dealerBust(total: Int)
    case dealerBlackjack
    case insuranceSettled(seat: Int, payout: Int, net: Int)
    case handSettled(seat: Int, handIndex: Int, outcome: BlackjackOutcome, bet: Int, payout: Int, net: Int)
    /// `nets[seat]` = that seat's net chips for the round (hands + insurance).
    case roundComplete(round: Int, nets: [Int])
    case seatBroke(seat: Int)
    case sessionOver
    case illegalAttempt(seat: Int, reason: String)
}

// MARK: - State

public struct BlackjackState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var config: BlackjackConfig
    public var phase: BlackjackPhase
    public var roundNumber: Int
    public var seats: [BlackjackSeatState]
    /// Hole card is `dealerCards[1]`; hidden from snapshots until
    /// `holeRevealed`.
    public var dealerCards: [Card]
    public var holeRevealed: Bool
    public var activeSeat: Int?
    public var activeHand: Int
    /// Shuffles done so far (0 = the opening shuffle). Drives `shoeSeed`.
    public var shuffleCount: Int
    public var shoeSeed: UInt64
    /// Cards dealt out of the current shoe.
    public var shoeIndex: Int
    public var shoeSize: Int
    /// Index of the cut card: when `shoeIndex >= cutIndex` the shoe is
    /// reshuffled before the next round.
    public var cutIndex: Int

    public init(seed: UInt64, config: BlackjackConfig, seatCount: Int) {
        self.seed = seed
        self.config = config
        self.phase = .betting
        self.roundNumber = 1
        self.seats = (0..<seatCount).map { BlackjackSeatState(seat: $0, chips: config.startingChips) }
        self.dealerCards = []
        self.holeRevealed = false
        self.activeSeat = nil
        self.activeHand = 0
        self.shuffleCount = 0
        self.shoeSeed = BlackjackShoe.seed(game: seed, shuffle: 0)
        self.shoeIndex = 0
        self.shoeSize = config.deckCount * 52
        self.cutIndex = Int(Double(config.deckCount * 52) * config.cutCardPenetration)
    }

    public var cutCardReached: Bool { shoeIndex >= cutIndex }
    public var shoeRemaining: Int { max(0, shoeSize - shoeIndex) }
    public var dealerHasNatural: Bool { BlackjackRules.isTwoCard21(dealerCards) }
}

// MARK: - Legality helpers (shared by engine, snapshot, bot)

public extension BlackjackState {
    private func activeHandIfOnTurn(_ seat: Int) -> BlackjackHand? {
        guard phase == .playing, activeSeat == seat,
              seat >= 0, seat < seats.count,
              activeHand < seats[seat].hands.count else { return nil }
        let h = seats[seat].hands[activeHand]
        return h.isFinished ? nil : h
    }

    func canHit(seat: Int) -> Bool { activeHandIfOnTurn(seat) != nil }

    func canDouble(seat: Int) -> Bool {
        guard let h = activeHandIfOnTurn(seat) else { return false }
        return h.cards.count == 2 && !h.isSplitAces
            && (!h.isFromSplit || config.doubleAfterSplit)
            && seats[seat].chips >= h.bet
    }

    func canSplit(seat: Int) -> Bool {
        guard let h = activeHandIfOnTurn(seat) else { return false }
        return !h.isFromSplit && BlackjackRules.isPair(h.cards) && seats[seat].chips >= h.bet
    }

    func canSurrender(seat: Int) -> Bool {
        guard config.surrenderEnabled, let h = activeHandIfOnTurn(seat) else { return false }
        return h.cards.count == 2 && !h.isFromSplit
    }

    func legalActions(for seat: Int) -> [BlackjackActionKind] {
        guard seat >= 0, seat < seats.count else { return [] }
        let s = seats[seat]
        switch phase {
        case .betting:
            return (!s.isOut && !s.sittingOut && s.hands.isEmpty) ? [.placeBet, .sitOut] : []
        case .insurance:
            return (s.hasBet && !s.insuranceDecided) ? [.takeInsurance] : []
        case .playing:
            guard canHit(seat: seat) else { return [] }
            var out: [BlackjackActionKind] = [.hit, .stand]
            if canDouble(seat: seat) { out.append(.doubleDown) }
            if canSplit(seat: seat) { out.append(.split) }
            if canSurrender(seat: seat) { out.append(.surrender) }
            return out
        case .roundComplete:
            return [.nextRound]
        case .sessionOver:
            return []
        }
    }
}

// MARK: - Snapshot

/// Everything in blackjack is public except the dealer's hole card before
/// the reveal, so one snapshot shape serves phones and the table; only
/// `mySeat` and `legalActions` are personalized (`mySeat == -1` = the
/// table's public view).
public struct BlackjackSnapshot: Codable, Sendable, Equatable {
    public let mySeat: Int
    public let config: BlackjackConfig
    public let phase: BlackjackPhase
    public let roundNumber: Int
    public let seats: [BlackjackSeatState]
    /// Up card only until the reveal, then every dealer card.
    public let dealerCards: [Card]
    /// true while a face-down hole card sits on the table.
    public let dealerHoleHidden: Bool
    /// Total of the visible dealer cards.
    public let dealerVisibleTotal: Int
    public let activeSeat: Int?
    public let activeHand: Int
    public let shoeRemaining: Int
    public let cutCardReached: Bool
    public let legalActions: [BlackjackActionKind]
}

public extension BlackjackState {
    func snapshot(for seat: Int) -> BlackjackSnapshot {
        let hidden = !holeRevealed && dealerCards.count >= 2
        let visible = hidden ? Array(dealerCards.prefix(1)) : dealerCards
        return BlackjackSnapshot(
            mySeat: seat, config: config, phase: phase, roundNumber: roundNumber,
            seats: seats, dealerCards: visible, dealerHoleHidden: hidden,
            dealerVisibleTotal: BlackjackRules.value(of: visible).total,
            activeSeat: activeSeat, activeHand: activeHand,
            shoeRemaining: shoeRemaining, cutCardReached: cutCardReached,
            legalActions: legalActions(for: seat)
        )
    }

    /// The table's public view (no personalized legal actions).
    func tableSnapshot() -> BlackjackSnapshot { snapshot(for: -1) }
}
