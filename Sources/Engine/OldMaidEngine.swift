import Foundation

/// Authoritative Old Maid reducer (same shape as `CribbageEngine`).
///
/// ```
/// let engine = OldMaidEngine(seed: 3, playerCount: 4)
/// let snap = engine.snapshot(for: engine.state.turnSeat)
/// // snap.drawTarget is the neighbor; snap.handCounts[target] cards fanned
/// _ = engine.apply(.draw(index: 2), from: snap.seat)
/// ```
public final class OldMaidEngine {
    public static let kind = "oldMaid"
    public static let minPlayers = 2
    public static let maxPlayers = 4
    /// The queen removed from the deck; its three siblings remain.
    public static let removedCardID = "c12"

    public private(set) var state: OldMaidState
    /// Events from the opening pair discard (read once after `init`).
    public private(set) var pendingOpeningEvents: [OldMaidEvent] = []

    public init(seed: UInt64, playerCount: Int) {
        let n = min(max(playerCount, Self.minPlayers), Self.maxPlayers)
        let deck = DeckBuilder.shuffled(DeckBuilder.standard52().filter { $0.id != Self.removedCardID }, seed: seed)
        var hands: [Int: [Card]] = [:]
        for seat in 0..<n { hands[seat] = [] }
        for (i, card) in deck.enumerated() { hands[i % n, default: []].append(card) }
        state = OldMaidState(seed: seed, playerCount: n, hands: hands)
        var events: [OldMaidEvent] = [.dealt(handCounts: handCounts())]
        for seat in 0..<n {
            let pairs = discardPairs(seat)
            if !pairs.isEmpty { events.append(.pairsDiscarded(seat: seat, pairs: pairs, onDeal: true)) }
        }
        for seat in 0..<n where (state.hands[seat] ?? []).isEmpty {
            state.outSeats.append(seat)
            events.append(.playerOut(seat: seat))
        }
        if let first = nextActive(after: -1) { state.turnSeat = first }
        events += checkGameOver()
        pendingOpeningEvents = events
    }

    public init(restoring state: OldMaidState) {
        self.state = state
    }

    public func apply(_ action: OldMaidAction, from seat: Int) -> [OldMaidEvent] {
        guard state.phase == .playing else { return reject(seat, "The game is over") }
        guard seat >= 0, seat < state.playerCount else { return reject(seat, "Not a seat in this game") }
        switch action {
        case .draw(let index):
            return handleDraw(index: index, from: seat)
        case .shuffleMyHand:
            guard !(state.hands[seat] ?? []).isEmpty else { return reject(seat, "You have no cards") }
            state.shuffleCounter += 1
            var rng = SeededGenerator(seed: state.seed &+ UInt64(state.shuffleCounter) &* 0x9E37_79B9_7F4A_7C15)
            state.hands[seat]?.shuffle(using: &rng)
            return [.handShuffled(seat: seat)]
        }
    }

    // MARK: - Drawing

    private func handleDraw(index: Int, from seat: Int) -> [OldMaidEvent] {
        guard seat == state.turnSeat else { return reject(seat, "It's not your turn") }
        guard let target = drawTarget(for: seat) else { return reject(seat, "Nobody to draw from") }
        let fan = state.hands[target] ?? []
        guard index >= 0, index < fan.count else { return reject(seat, "Pick one of their cards") }

        var events: [OldMaidEvent] = [.drew(seat: seat, from: target, index: index)]
        let card = state.hands[target]!.remove(at: index)
        var matched = false
        if let rank = card.rank,
           let mateIdx = state.hands[seat]?.firstIndex(where: { $0.rank == rank }) {
            let mate = state.hands[seat]!.remove(at: mateIdx)
            let pair = [mate, card]
            state.laid[seat, default: []].append(pair)
            events.append(.pairsDiscarded(seat: seat, pairs: [pair], onDeal: false))
            matched = true
            state.lastDrawnCardID = nil
        } else {
            state.hands[seat, default: []].append(card)
            state.lastDrawnCardID = card.id
        }
        state.lastDraw = OldMaidDrawRecord(drawer: seat, from: target, index: index, matched: matched)

        for s in [seat, target] where (state.hands[s] ?? []).isEmpty && !state.outSeats.contains(s) {
            state.outSeats.append(s)
            events.append(.playerOut(seat: s))
        }
        events += checkGameOver()
        if state.phase == .playing, let next = nextActive(after: seat) {
            state.turnSeat = next
            events.append(.turnChanged(seat: next))
        }
        return events
    }

    // MARK: - Helpers

    /// The seat `seat` would draw from: the next seat with cards.
    public func drawTarget(for seat: Int) -> Int? {
        guard let t = nextActive(after: seat), t != seat else { return nil }
        return t
    }

    /// Next seat after `seat` (wrapping) that still holds cards; `after: -1` = from seat 0.
    private func nextActive(after seat: Int) -> Int? {
        let n = state.playerCount
        for i in 1...n {
            let s = ((seat + i) % n + n) % n
            if !(state.hands[s] ?? []).isEmpty { return s }
        }
        return nil
    }

    private func checkGameOver() -> [OldMaidEvent] {
        guard state.phase == .playing else { return [] }
        let active = (0..<state.playerCount).filter { !(state.hands[$0] ?? []).isEmpty }
        guard active.count <= 1 else { return [] }
        state.phase = .gameOver
        state.loser = active.first
        if let loser = active.first { return [.gameOver(loser: loser)] }
        return []
    }

    /// Pairs off every same-rank couple in the hand (any suits). A rank held
    /// three times keeps one; four makes two pairs. Returns the pairs laid.
    private func discardPairs(_ seat: Int) -> [[Card]] {
        var byRank: [Int: [Card]] = [:]
        for card in state.hands[seat] ?? [] { if let r = card.rank { byRank[r, default: []].append(card) } }
        var pairs: [[Card]] = []
        var removed = Set<String>()
        for rank in byRank.keys.sorted() {
            var cards = byRank[rank] ?? []
            while cards.count >= 2 {
                let a = cards.removeFirst(), b = cards.removeFirst()
                pairs.append([a, b])
                removed.insert(a.id); removed.insert(b.id)
            }
        }
        state.hands[seat] = (state.hands[seat] ?? []).filter { !removed.contains($0.id) }
        if !pairs.isEmpty { state.laid[seat, default: []].append(contentsOf: pairs) }
        return pairs
    }

    public func handCounts() -> [Int: Int] {
        var out: [Int: Int] = [:]
        for seat in 0..<state.playerCount { out[seat] = state.hands[seat]?.count ?? 0 }
        return out
    }

    public func snapshot(for seat: Int) -> OldMaidSnapshot {
        let target = state.phase == .playing ? drawTarget(for: state.turnSeat) : nil
        let showDrawn = state.lastDraw?.drawer == seat ? state.lastDrawnCardID : nil
        return OldMaidSnapshot(
            seat: seat, playerCount: state.playerCount, hand: state.hands[seat] ?? [],
            handCounts: handCounts(), laidPairs: state.laid, turnSeat: state.turnSeat,
            drawTarget: target, outSeats: state.outSeats, phase: state.phase, loser: state.loser,
            lastDraw: state.lastDraw, lastDrawnCardID: showDrawn
        )
    }

    private func reject(_ seat: Int, _ reason: String) -> [OldMaidEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
