import Foundation

/// The authoritative cribbage reducer — same shape as `HostEngine`
/// (`apply(action, from: seat) -> [events]`, seeded deals, Codable `state`,
/// per-seat redacted snapshots) but standalone: cribbage isn't a
/// `GameKind`/`HostEngine` game, it's fixed 2-player, 121, no muggins.
///
/// ## Design: auto-go
/// The spec offered a choice — an explicit `declareGo` action, or the
/// engine resolving stuck positions automatically. This engine implements
/// **auto-go**: after every `playCard`, before returning, the engine walks
/// forward through any position where the seat on turn has no legal play,
/// scoring the go/last-card point to whoever played last and resetting the
/// count, cascading until either someone has a real decision to make or
/// the whole hand is pegged out. `CribbageAction.declareGo` is kept for API
/// completeness but always rejects — a caller can never observe itself
/// stuck with a `declareGo` actually available to send, since the engine
/// already resolved it as a side effect of the play that caused it.
/// `CribbageEvent.pointsScored(reason: .go)` / `.lastCard` are how the UI
/// narrates the auto-resolution.
///
/// ## Design: win ordering
/// A win is checked after every discrete scoring action (a peg play, the
/// starter's heels, each of the three show counts) and short-circuits
/// immediately — the phase flips to `.gameOver` and no further events for
/// that action are produced. This is what makes "win mid-pegging" and
/// "non-dealer pegs out during the show before dealer/crib are counted"
/// come out correctly: `beginShow()` counts non-dealer, checks win, and
/// returns early before ever touching the dealer's hand or the crib.
public final class CribbageEngine {
    public private(set) var state: CribbageState

    /// Bumped every new hand so each deal draws from a fresh, deterministic
    /// shuffle stream derived from the game seed (mirrors `HostEngine`'s
    /// `dealSerial`). Not part of `CribbageState`, matching `HostEngine`.
    private var dealSerial: UInt64 = 0

    /// Deals the first hand immediately — cribbage has no lobby/seating
    /// phase, so there's nothing to wait for. `seed % 2` decides the first
    /// dealer (the spec's "skip the cut-for-deal formality").
    public init(seed: UInt64) {
        let dealer = Int(seed % 2)
        state = CribbageState(
            seed: seed, dealShuffleSeed: seed, scores: [0: 0, 1: 0], dealerSeat: dealer,
            phase: .discarding, hands: [:], postDiscardHands: [:], crib: [], discardsSubmitted: [],
            starter: nil, pegging: nil, handNumber: 0
        )
        _ = dealHand(dealerSeat: dealer)
    }

    /// Resume from a saved `CribbageState` (save/resume flow). `dealSerial`
    /// isn't persisted; re-derive it from `handNumber` so post-restore
    /// reshuffles stay in a fresh part of the stream rather than repeating
    /// one already used (exact parity with the pre-save stream isn't
    /// required — only future determinism is).
    public init(restoring state: CribbageState) {
        self.state = state
        dealSerial = UInt64(state.handNumber)
    }

    public func apply(_ action: CribbageAction, from seat: Int) -> [CribbageEvent] {
        guard seat == 0 || seat == 1 else {
            return reject(seat, "Cribbage only has two seats")
        }
        guard state.phase != .gameOver else {
            return reject(seat, "The game is over")
        }
        switch action {
        case .discardToCrib(let cards):
            return handleDiscard(cards, from: seat)
        case .playCard(let cardID):
            return handlePlayCard(cardID, from: seat)
        case .declareGo:
            return reject(seat, "Go is automatic in this engine — no action needed")
        case .advance:
            return handleAdvance(from: seat)
        }
    }

    // MARK: - Discarding

    private func handleDiscard(_ cardIDs: [String], from seat: Int) -> [CribbageEvent] {
        guard state.phase == .discarding else {
            return reject(seat, "Discarding isn't open right now")
        }
        guard !state.discardsSubmitted.contains(seat) else {
            return reject(seat, "You've already discarded")
        }
        guard cardIDs.count == 2, Set(cardIDs).count == 2 else {
            return reject(seat, "Discard exactly two different cards")
        }
        guard var hand = state.hands[seat] else {
            return reject(seat, "No hand to discard from")
        }
        var picked: [Card] = []
        for id in cardIDs {
            guard let idx = hand.firstIndex(where: { $0.id == id }) else {
                return reject(seat, "That card isn't in your hand")
            }
            picked.append(hand.remove(at: idx))
        }
        state.hands[seat] = hand
        state.crib.append(contentsOf: picked)
        state.discardsSubmitted.insert(seat)

        var events: [CribbageEvent] = [.discarded(seat: seat)]
        if state.discardsSubmitted.count == 2 {
            state.postDiscardHands = state.hands
            events += completeCribAndCut()
        }
        return events
    }

    /// Both discards are in: cut the starter (deterministically — the next
    /// card in the same shuffle that dealt this hand), score dealer's
    /// heels if it's a jack, and open pegging with non-dealer to lead.
    private func completeCribAndCut() -> [CribbageEvent] {
        var events: [CribbageEvent] = [.cribComplete]

        let deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: state.dealShuffleSeed)
        let starter = deck[12] // 0...11 were the two 6-card hands
        state.starter = starter
        events.append(.starterCut(starter))

        if starter.rank == 11 {
            addScore(state.dealerSeat, 2)
            events.append(.pointsScored(seat: state.dealerSeat, reason: .heels, points: 2))
            events += checkWin(state.dealerSeat)
            if state.phase == .gameOver { return events }
        }

        let nonDealer = 1 - state.dealerSeat
        state.pegging = CribbagePeggingState(sequence: [], count: 0, turnSeat: nonDealer, lastPlayerSeat: nil)
        state.phase = .pegging
        events += resolvePegging() // defensive: the leader can always play a first card, so this is normally a no-op
        return events
    }

    // MARK: - Pegging

    private func handlePlayCard(_ cardID: String, from seat: Int) -> [CribbageEvent] {
        guard state.phase == .pegging, var pegging = state.pegging else {
            return reject(seat, "You can't play a card right now")
        }
        guard seat == pegging.turnSeat else {
            return reject(seat, "It's not your turn")
        }
        guard var hand = state.hands[seat], let idx = hand.firstIndex(where: { $0.id == cardID }) else {
            return reject(seat, "That card isn't in your hand")
        }
        let card = hand[idx]
        let value = CribbageScoring.pegValue(card)
        guard pegging.count + value <= 31 else {
            return reject(seat, "That card would put the count over 31")
        }

        hand.remove(at: idx)
        state.hands[seat] = hand
        pegging.sequence.append(CribbagePeggedPlay(seat: seat, card: card))
        pegging.count += value
        pegging.lastPlayerSeat = seat

        var events: [CribbageEvent] = [.cardPlayed(seat: seat, card: card, count: pegging.count)]
        let entries = CribbageScoring.peggingScore(sequence: pegging.sequence.map(\.card), count: pegging.count)
        let total = entries.reduce(0) { $0 + $1.points }
        for entry in entries {
            events.append(.pointsScored(seat: seat, reason: entry.reason, points: entry.points))
        }
        let hitThirtyOne = entries.contains {
            if case .thirtyOne = $0.reason { return true }
            return false
        }

        pegging.turnSeat = 1 - seat
        if hitThirtyOne {
            // The count can't go any higher — the segment ends right here,
            // no separate go point layered on top ("not go+31").
            pegging.count = 0
            pegging.sequence = []
            pegging.lastPlayerSeat = nil
        }
        state.pegging = pegging

        if total > 0 {
            addScore(seat, total)
            events += checkWin(seat)
            if state.phase == .gameOver { return events }
        }

        events += resolvePegging()
        return events
    }

    /// Auto-go cascade: while pegging is active and the seat on turn has no
    /// legal play, skip to whoever can play; if NEITHER can play, the go
    /// (or, if both hands are now empty, last-card) point goes to whoever
    /// played last, the count resets, and the previously-stuck seat leads
    /// the fresh segment. Runs to a fixed point every call — either a real
    /// decision is now available, or pegging is fully over and the show has
    /// begun.
    private func resolvePegging() -> [CribbageEvent] {
        var events: [CribbageEvent] = []
        while state.phase == .pegging {
            guard var pegging = state.pegging else { break }
            let seat = pegging.turnSeat
            let other = 1 - seat

            if canPlay(seat, count: pegging.count) {
                break
            }
            if canPlay(other, count: pegging.count) {
                pegging.turnSeat = other
                state.pegging = pegging
                continue
            }

            // Neither seat can continue at this count.
            let bothHandsEmpty = (state.hands[0]?.isEmpty ?? true) && (state.hands[1]?.isEmpty ?? true)
            guard let scorer = pegging.lastPlayerSeat else {
                // Nobody has played in this segment — only reachable right
                // after a 31 already claimed the point. Nothing more to
                // award; just settle whether pegging is over.
                if bothHandsEmpty {
                    events.append(.pegComplete)
                    events += beginShow()
                }
                return events
            }

            let reason: CribbageScoreReason = bothHandsEmpty ? .lastCard : .go
            addScore(scorer, 1)
            events.append(.pointsScored(seat: scorer, reason: reason, points: 1))
            events += checkWin(scorer)
            if state.phase == .gameOver { return events }

            if bothHandsEmpty {
                events.append(.pegComplete)
                events += beginShow()
                return events
            }

            pegging.count = 0
            pegging.sequence = []
            pegging.turnSeat = 1 - scorer
            pegging.lastPlayerSeat = nil
            state.pegging = pegging
        }
        return events
    }

    private func canPlay(_ seat: Int, count: Int) -> Bool {
        guard let hand = state.hands[seat], !hand.isEmpty else { return false }
        return hand.contains { CribbageScoring.pegValue($0) + count <= 31 }
    }

    // MARK: - The show

    /// Non-dealer counts, then dealer, then the crib (dealer's) — in that
    /// order, checking for a win after each and stopping immediately if
    /// found. This ordering (and the early return) is what makes
    /// "non-dealer pegs out during the show" correctly skip dealer/crib.
    private func beginShow() -> [CribbageEvent] {
        var events: [CribbageEvent] = []
        guard let starter = state.starter else { return events }
        let nonDealer = 1 - state.dealerSeat
        let dealer = state.dealerSeat

        let (nonDealerPts, nonDealerBreakdown) = CribbageScoring.scoreShow(
            cards: state.postDiscardHands[nonDealer] ?? [], starter: starter, isCrib: false
        )
        for entry in nonDealerBreakdown {
            events.append(.pointsScored(seat: nonDealer, reason: entry.reason, points: entry.points))
        }
        addScore(nonDealer, nonDealerPts)
        events.append(.handCounted(seat: nonDealer, source: .hand, points: nonDealerPts, breakdown: nonDealerBreakdown))
        events += checkWin(nonDealer)
        if state.phase == .gameOver { return events }

        let (dealerPts, dealerBreakdown) = CribbageScoring.scoreShow(
            cards: state.postDiscardHands[dealer] ?? [], starter: starter, isCrib: false
        )
        for entry in dealerBreakdown {
            events.append(.pointsScored(seat: dealer, reason: entry.reason, points: entry.points))
        }
        addScore(dealer, dealerPts)
        events.append(.handCounted(seat: dealer, source: .hand, points: dealerPts, breakdown: dealerBreakdown))
        events += checkWin(dealer)
        if state.phase == .gameOver { return events }

        events.append(.cribRevealed(state.crib))
        let (cribPts, cribBreakdown) = CribbageScoring.scoreShow(cards: state.crib, starter: starter, isCrib: true)
        for entry in cribBreakdown {
            events.append(.pointsScored(seat: dealer, reason: entry.reason, points: entry.points))
        }
        addScore(dealer, cribPts)
        events.append(.handCounted(seat: dealer, source: .crib, points: cribPts, breakdown: cribBreakdown))
        events += checkWin(dealer)
        if state.phase == .gameOver { return events }

        state.phase = .handComplete
        return events
    }

    // MARK: - Dealing

    private func handleAdvance(from seat: Int) -> [CribbageEvent] {
        guard state.phase == .handComplete else {
            return reject(seat, "Nothing to advance right now")
        }
        return dealHand(dealerSeat: 1 - state.dealerSeat)
    }

    @discardableResult
    private func dealHand(dealerSeat: Int) -> [CribbageEvent] {
        dealSerial &+= 1
        let shuffleSeed = state.seed &+ dealSerial
        var deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: shuffleSeed)
        state.dealShuffleSeed = shuffleSeed
        state.dealerSeat = dealerSeat

        let nonDealer = 1 - dealerSeat
        state.hands = [:]
        state.hands[nonDealer] = Array(deck.prefix(6))
        deck.removeFirst(6)
        state.hands[dealerSeat] = Array(deck.prefix(6))
        deck.removeFirst(6)

        state.postDiscardHands = [:]
        state.crib = []
        state.discardsSubmitted = []
        state.starter = nil
        state.pegging = nil
        state.handNumber += 1
        state.phase = .discarding
        return [.dealt(dealerSeat: dealerSeat)]
    }

    // MARK: - Helpers

    private func addScore(_ seat: Int, _ points: Int) {
        state.scores[seat, default: 0] += points
    }

    /// Reaching 121 wins immediately, at any scoring moment. Returns the
    /// `gameWon` event and flips the phase when it fires; a no-op
    /// otherwise. Idempotent — a second call after the game is already
    /// over does nothing (callers use `state.phase == .gameOver` as the
    /// short-circuit signal, not this return value, everywhere but here).
    @discardableResult
    private func checkWin(_ seat: Int) -> [CribbageEvent] {
        guard state.phase != .gameOver, state.scores[seat, default: 0] >= 121 else { return [] }
        let skunk = state.scores[1 - seat, default: 0] < 91
        state.phase = .gameOver
        state.winnerSeat = seat
        state.skunk = skunk
        return [.gameWon(seat: seat, skunk: skunk)]
    }

    private func reject(_ seat: Int, _ reason: String) -> [CribbageEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
