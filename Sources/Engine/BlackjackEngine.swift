import Foundation

/// Authoritative blackjack reducer: `apply(action, from: seat) -> [events]`,
/// seeded shoe, Codable `state`, per-seat snapshots via
/// `state.snapshot(for:)`. Standalone like `CribbageEngine`.
///
/// ## Flow
/// `.betting` (every seat `placeBet` or `sitOut`) -> auto-deal ->
/// [`.insurance` if enabled and the dealer shows an ace] -> dealer peek (US
/// rules, flag) -> `.playing` (seat by seat, hand by hand; the engine
/// stands 21s and split aces automatically) -> dealer reveals and plays ->
/// settlement -> `.roundComplete` -> `nextRound` (reshuffles first if the
/// cut card was reached).
///
/// ## Chip accounting
/// Wagers (bet, double, split, insurance) leave `chips` the moment they are
/// placed; settlement returns `payout` (stake included). Chips are
/// conserved: a seat's net for the round is the sum of `payout - bet`.
public final class BlackjackEngine {
    public static let kind = "blackjack"

    public private(set) var state: BlackjackState
    private var shoe: [Card]

    /// Seats are clamped to 1...5. The opening shuffle is derived from `seed`.
    public init(seed: UInt64, seatCount: Int, config: BlackjackConfig = BlackjackConfig()) {
        let n = min(max(seatCount, 1), 5)
        state = BlackjackState(seed: seed, config: config, seatCount: n)
        shoe = BlackjackShoe.make(deckCount: config.deckCount, seed: state.shoeSeed)
    }

    /// Resume from saved state. The shoe is re-derived from
    /// `shoeSeed`, so dealing continues from `shoeIndex` exactly as before
    /// (a `stackShoe` test shoe is not persisted).
    public init(restoring state: BlackjackState) {
        self.state = state
        shoe = BlackjackShoe.make(deckCount: state.config.deckCount, seed: state.shoeSeed)
    }

    /// TEST / SCRIPTED-DEAL HOOK: replace the shoe with exactly `cards`
    /// (dealt in order from the top) and suppress the cut card until they
    /// run out. Only meaningful in the betting phase.
    public func stackShoe(_ cards: [Card]) {
        shoe = cards
        state.shoeIndex = 0
        state.shoeSize = cards.count
        state.cutIndex = cards.count
    }

    // MARK: - Reducer

    public func apply(_ action: BlackjackAction, from seat: Int) -> [BlackjackEvent] {
        guard seat >= 0, seat < state.seats.count else {
            return reject(seat, "No such seat")
        }
        guard state.phase != .sessionOver else {
            return reject(seat, "The session is over")
        }
        switch action {
        case .placeBet(let amount): return handleBet(amount, from: seat)
        case .sitOut: return handleSitOut(from: seat)
        case .takeInsurance(let take): return handleInsurance(take, from: seat)
        case .hit: return handleHit(from: seat)
        case .stand: return handleStand(from: seat)
        case .doubleDown: return handleDouble(from: seat)
        case .split: return handleSplit(from: seat)
        case .surrender: return handleSurrender(from: seat)
        case .nextRound: return handleNextRound(from: seat)
        }
    }

    // MARK: - Betting

    private func handleBet(_ amount: Int, from seat: Int) -> [BlackjackEvent] {
        guard state.phase == .betting else { return reject(seat, "Betting isn't open right now") }
        let s = state.seats[seat]
        guard !s.isOut else { return reject(seat, "You're out of chips") }
        guard !s.sittingOut, s.hands.isEmpty else { return reject(seat, "You've already acted this round") }
        let c = state.config
        guard amount >= c.minBet, amount <= c.maxBet else {
            return reject(seat, "Bets run \(c.minBet) to \(c.maxBet)")
        }
        guard amount % c.betStep == 0 else { return reject(seat, "Bets go up in \(c.betStep)s") }
        guard amount <= s.chips else { return reject(seat, "You don't have that many chips") }
        state.seats[seat].chips -= amount
        state.seats[seat].hands = [BlackjackHand(bet: amount)]
        return [.betPlaced(seat: seat, amount: amount)] + dealIfBetsComplete()
    }

    private func handleSitOut(from seat: Int) -> [BlackjackEvent] {
        guard state.phase == .betting else { return reject(seat, "Betting isn't open right now") }
        let s = state.seats[seat]
        guard !s.isOut, !s.sittingOut, s.hands.isEmpty else { return reject(seat, "You've already acted this round") }
        state.seats[seat].sittingOut = true
        return [.satOut(seat: seat)] + dealIfBetsComplete()
    }

    private func dealIfBetsComplete() -> [BlackjackEvent] {
        let waiting = state.seats.contains { !$0.isOut && !$0.sittingOut && $0.hands.isEmpty }
        if waiting { return [] }
        if !state.seats.contains(where: { $0.hasBet }) {
            // Everyone sat out: nothing to deal.
            state.phase = .roundComplete
            return [.roundComplete(round: state.roundNumber, nets: Array(repeating: 0, count: state.seats.count))]
        }
        return deal()
    }

    // MARK: - Deal

    private func deal() -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        let bettors = state.seats.indices.filter { state.seats[$0].hasBet }
        for pass in 0..<2 {
            for s in bettors {
                let c = draw(&ev)
                state.seats[s].hands[0].cards.append(c)
                ev.append(.cardDealt(seat: s, handIndex: 0, card: c))
            }
            let c = draw(&ev)
            state.dealerCards.append(c)
            ev.append(pass == 0 ? .dealerUpCard(c) : .dealerHoleDealt)
        }
        for s in bettors where state.seats[s].hands[0].isNatural {
            state.seats[s].hands[0].isFinished = true
            ev.append(.playerBlackjack(seat: s))
        }
        let up = state.dealerCards[0]
        if state.config.insuranceEnabled && BlackjackRules.cardValue(up) == 11 {
            state.phase = .insurance
            ev.append(.insuranceOffered)
            for s in bettors {
                let cost = state.seats[s].hands[0].bet / 2
                if cost < 1 || state.seats[s].chips < cost {
                    state.seats[s].insuranceDecided = true
                    ev.append(.insuranceDeclined(seat: s))
                }
            }
            if insuranceComplete { ev += peekAndPlay() }
            return ev
        }
        ev += peekAndPlay()
        return ev
    }

    /// Pulls the next card. A shoe that runs dry mid-round (cannot happen
    /// with 5 seats and a 75% cut, but never crash) is replaced by a fresh
    /// shuffle.
    private func draw(_ ev: inout [BlackjackEvent]) -> Card {
        if state.shoeIndex >= shoe.count {
            reshuffle(&ev)
        }
        let c = shoe[state.shoeIndex]
        state.shoeIndex += 1
        return c
    }

    private func reshuffle(_ ev: inout [BlackjackEvent]) {
        state.shuffleCount += 1
        state.shoeSeed = BlackjackShoe.seed(game: state.seed, shuffle: state.shuffleCount)
        shoe = BlackjackShoe.make(deckCount: state.config.deckCount, seed: state.shoeSeed)
        state.shoeSize = shoe.count
        state.shoeIndex = 0
        state.cutIndex = Int(Double(shoe.count) * state.config.cutCardPenetration)
        ev.append(.shoeReshuffled(decks: state.config.deckCount))
    }

    // MARK: - Insurance

    private var insuranceComplete: Bool {
        !state.seats.contains { $0.hasBet && !$0.insuranceDecided }
    }

    private func handleInsurance(_ take: Bool, from seat: Int) -> [BlackjackEvent] {
        guard state.phase == .insurance else { return reject(seat, "Insurance isn't being offered") }
        let s = state.seats[seat]
        guard s.hasBet, !s.insuranceDecided else { return reject(seat, "No insurance decision for you") }
        var ev: [BlackjackEvent] = []
        if take {
            let cost = s.hands[0].bet / 2
            guard cost >= 1, s.chips >= cost else { return reject(seat, "You can't cover insurance") }
            state.seats[seat].chips -= cost
            state.seats[seat].insuranceBet = cost
            ev.append(.insuranceTaken(seat: seat, amount: cost))
        } else {
            ev.append(.insuranceDeclined(seat: seat))
        }
        state.seats[seat].insuranceDecided = true
        if insuranceComplete { ev += peekAndPlay() }
        return ev
    }

    // MARK: - Peek and player turns

    private func peekAndPlay() -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        let upValue = BlackjackRules.cardValue(state.dealerCards[0])
        if state.config.dealerPeeks && upValue >= 10 {
            let bj = state.dealerHasNatural
            ev.append(.dealerPeek(hasBlackjack: bj))
            if bj {
                ev += finishRound(dealerMayDraw: false)
                return ev
            }
        }
        state.phase = .playing
        ev += advanceTurn()
        return ev
    }

    /// Moves to the first unfinished hand (seat order, then hand order),
    /// dealing a split hand its second card as it becomes active and
    /// auto-standing 21s. Runs the dealer when nobody is left to act.
    private func advanceTurn() -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        while true {
            guard let (s, h) = nextUnfinished() else {
                state.activeSeat = nil
                state.activeHand = 0
                ev += finishRound(dealerMayDraw: true)
                return ev
            }
            state.activeSeat = s
            state.activeHand = h
            if state.seats[s].hands[h].cards.count == 1 {
                let c = draw(&ev)
                state.seats[s].hands[h].cards.append(c)
                ev.append(.cardDealt(seat: s, handIndex: h, card: c))
            }
            let hand = state.seats[s].hands[h]
            if hand.isSplitAces {
                state.seats[s].hands[h].isFinished = true
                ev.append(.stand(seat: s, handIndex: h, auto: true))
                continue
            }
            if hand.value.total >= 21 {
                state.seats[s].hands[h].isFinished = true
                ev.append(.stand(seat: s, handIndex: h, auto: true))
                continue
            }
            ev.append(.turnStarted(seat: s, handIndex: h))
            return ev
        }
    }

    private func nextUnfinished() -> (Int, Int)? {
        for s in state.seats.indices {
            for h in state.seats[s].hands.indices where !state.seats[s].hands[h].isFinished {
                return (s, h)
            }
        }
        return nil
    }

    private func requireTurn(_ seat: Int) -> String? {
        if state.phase != .playing { return "It isn't time to play hands" }
        if state.activeSeat != seat { return "It isn't your turn" }
        return nil
    }

    /// After a decision: bust / 21 / finished hands move play along.
    private func afterAction(seat: Int, hand: Int) -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        let h = state.seats[seat].hands[hand]
        if !h.isFinished {
            if h.isBust {
                state.seats[seat].hands[hand].isFinished = true
                ev.append(.bust(seat: seat, handIndex: hand, total: h.value.total))
            } else if h.value.total == 21 {
                state.seats[seat].hands[hand].isFinished = true
                ev.append(.stand(seat: seat, handIndex: hand, auto: true))
            }
        } else if h.isBust {
            ev.append(.bust(seat: seat, handIndex: hand, total: h.value.total))
        }
        if state.seats[seat].hands[hand].isFinished {
            ev += advanceTurn()
        }
        return ev
    }

    private func handleHit(from seat: Int) -> [BlackjackEvent] {
        if let why = requireTurn(seat) { return reject(seat, why) }
        guard state.canHit(seat: seat) else { return reject(seat, "This hand can't take a card") }
        let h = state.activeHand
        var ev: [BlackjackEvent] = []
        let c = draw(&ev)
        state.seats[seat].hands[h].cards.append(c)
        ev.append(.hit(seat: seat, handIndex: h, card: c))
        ev += afterAction(seat: seat, hand: h)
        return ev
    }

    private func handleStand(from seat: Int) -> [BlackjackEvent] {
        if let why = requireTurn(seat) { return reject(seat, why) }
        guard state.canHit(seat: seat) else { return reject(seat, "Nothing to stand on") }
        let h = state.activeHand
        state.seats[seat].hands[h].isFinished = true
        return [.stand(seat: seat, handIndex: h, auto: false)] + advanceTurn()
    }

    private func handleDouble(from seat: Int) -> [BlackjackEvent] {
        if let why = requireTurn(seat) { return reject(seat, why) }
        guard state.canDouble(seat: seat) else {
            return reject(seat, "You can't double this hand")
        }
        let h = state.activeHand
        var ev: [BlackjackEvent] = []
        let extra = state.seats[seat].hands[h].bet
        state.seats[seat].chips -= extra
        state.seats[seat].hands[h].bet += extra
        state.seats[seat].hands[h].isDoubled = true
        let c = draw(&ev)
        state.seats[seat].hands[h].cards.append(c)
        state.seats[seat].hands[h].isFinished = true
        ev.append(.doubled(seat: seat, handIndex: h, card: c, newBet: state.seats[seat].hands[h].bet))
        ev += afterAction(seat: seat, hand: h)
        return ev
    }

    private func handleSplit(from seat: Int) -> [BlackjackEvent] {
        if let why = requireTurn(seat) { return reject(seat, why) }
        guard state.canSplit(seat: seat) else { return reject(seat, "You can't split this hand") }
        let h = state.activeHand
        var ev: [BlackjackEvent] = []
        let original = state.seats[seat].hands[h]
        let isAces = BlackjackRules.cardValue(original.cards[0]) == 11
        state.seats[seat].chips -= original.bet
        var first = BlackjackHand(cards: [original.cards[0]], bet: original.bet, isFromSplit: true)
        var second = BlackjackHand(cards: [original.cards[1]], bet: original.bet, isFromSplit: true)
        first.isSplitAces = isAces
        second.isSplitAces = isAces
        state.seats[seat].hands = [first, second]
        ev.append(.split(seat: seat))
        // The first hand gets its second card now; the second hand gets
        // its card when play reaches it (advanceTurn).
        let c = draw(&ev)
        state.seats[seat].hands[0].cards.append(c)
        ev.append(.cardDealt(seat: seat, handIndex: 0, card: c))
        if isAces {
            state.seats[seat].hands[0].isFinished = true
            ev.append(.stand(seat: seat, handIndex: 0, auto: true))
            ev += advanceTurn()
        } else {
            ev += afterAction(seat: seat, hand: 0)
            if state.phase == .playing, state.activeSeat == seat, !state.seats[seat].hands[0].isFinished {
                ev.append(.turnStarted(seat: seat, handIndex: 0))
            }
        }
        return ev
    }

    private func handleSurrender(from seat: Int) -> [BlackjackEvent] {
        if let why = requireTurn(seat) { return reject(seat, why) }
        guard state.canSurrender(seat: seat) else { return reject(seat, "You can't surrender this hand") }
        let h = state.activeHand
        state.seats[seat].hands[h].isSurrendered = true
        state.seats[seat].hands[h].isFinished = true
        return [.surrendered(seat: seat, handIndex: h)] + advanceTurn()
    }

    // MARK: - Dealer and settlement

    private func finishRound(dealerMayDraw: Bool) -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        state.holeRevealed = true
        ev.append(.dealerRevealed(card: state.dealerCards[1], total: BlackjackRules.value(of: state.dealerCards).total))

        let anyLive = state.seats.contains { seat in
            seat.hands.contains { !$0.isBust && !$0.isSurrendered && !$0.isNatural }
        }
        if dealerMayDraw && anyLive {
            while BlackjackRules.dealerShouldHit(state.dealerCards, hitsSoft17: state.config.dealerHitsSoft17) {
                let c = draw(&ev)
                state.dealerCards.append(c)
                ev.append(.dealerDrew(card: c, total: BlackjackRules.value(of: state.dealerCards).total))
            }
        }
        let dv = BlackjackRules.value(of: state.dealerCards)
        if state.dealerHasNatural { ev.append(.dealerBlackjack) }
        else if dv.isBust { ev.append(.dealerBust(total: dv.total)) }
        else { ev.append(.dealerStands(total: dv.total)) }

        ev += settle()
        return ev
    }

    private func settle() -> [BlackjackEvent] {
        var ev: [BlackjackEvent] = []
        let c = state.config
        let dealer = BlackjackRules.value(of: state.dealerCards)
        let dealerNatural = state.dealerHasNatural
        var nets = Array(repeating: 0, count: state.seats.count)

        for s in state.seats.indices {
            guard state.seats[s].hasBet else {
                state.seats[s].lastRoundNet = 0
                continue
            }
            // Insurance first, so event order reads cleanly.
            let ins = state.seats[s].insuranceBet
            if ins > 0 {
                let pay = dealerNatural ? ins * 3 : 0
                state.seats[s].chips += pay
                nets[s] += pay - ins
                ev.append(.insuranceSettled(seat: s, payout: pay, net: pay - ins))
            }
            for h in state.seats[s].hands.indices {
                let hand = state.seats[s].hands[h]
                let outcome: BlackjackOutcome
                var payout: Int
                if hand.isSurrendered {
                    outcome = .surrender
                    payout = hand.bet / 2
                } else if hand.isBust {
                    outcome = .bust
                    payout = 0
                } else if hand.isNatural {
                    if dealerNatural {
                        outcome = .push
                        payout = hand.bet
                    } else {
                        outcome = .blackjack
                        payout = hand.bet + hand.bet * c.blackjackPayoutNumerator / c.blackjackPayoutDenominator
                    }
                } else if dealerNatural {
                    outcome = .lose
                    payout = 0
                } else if dealer.isBust || hand.value.total > dealer.total {
                    outcome = .win
                    payout = hand.bet * 2
                } else if hand.value.total == dealer.total {
                    outcome = .push
                    payout = hand.bet
                } else {
                    outcome = .lose
                    payout = 0
                }
                state.seats[s].hands[h].outcome = outcome
                state.seats[s].hands[h].payout = payout
                state.seats[s].chips += payout
                nets[s] += payout - hand.bet
                ev.append(.handSettled(seat: s, handIndex: h, outcome: outcome, bet: hand.bet,
                                       payout: payout, net: payout - hand.bet))
            }
            state.seats[s].lastRoundNet = nets[s]
        }

        state.phase = .roundComplete
        state.activeSeat = nil
        state.activeHand = 0
        ev.append(.roundComplete(round: state.roundNumber, nets: nets))

        for s in state.seats.indices where !state.seats[s].isOut && state.seats[s].chips < c.minBet {
            state.seats[s].isOut = true
            ev.append(.seatBroke(seat: s))
        }
        if state.seats.allSatisfy({ $0.isOut }) {
            state.phase = .sessionOver
            ev.append(.sessionOver)
        }
        return ev
    }

    // MARK: - Next round

    private func handleNextRound(from seat: Int) -> [BlackjackEvent] {
        guard state.phase == .roundComplete else { return reject(seat, "The round isn't over") }
        var ev: [BlackjackEvent] = []
        state.roundNumber += 1
        if state.cutCardReached {
            reshuffle(&ev)
        }
        state.dealerCards = []
        state.holeRevealed = false
        state.activeSeat = nil
        state.activeHand = 0
        for s in state.seats.indices {
            state.seats[s].hands = []
            state.seats[s].sittingOut = false
            state.seats[s].insuranceBet = 0
            state.seats[s].insuranceDecided = false
            state.seats[s].lastRoundNet = 0
        }
        state.phase = .betting
        ev.insert(.roundStarted(round: state.roundNumber), at: 0)
        return ev
    }

    private func reject(_ seat: Int, _ reason: String) -> [BlackjackEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
