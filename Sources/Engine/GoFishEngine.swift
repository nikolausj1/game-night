import Foundation

/// Authoritative Go Fish reducer. Same shape as `CribbageEngine`:
/// `apply(action, from: seat) -> [events]`, seeded deal, Codable `state`,
/// per-seat redacted `snapshot(for:)`.
///
/// ```
/// let engine = GoFishEngine(seed: 7, playerCount: 3)
/// let events = engine.apply(.ask(target: 1, rank: 9), from: engine.state.turnSeat)
/// let mine = engine.snapshot(for: 2)
/// ```
public final class GoFishEngine {
    public static let kind = "goFish"
    public static let minPlayers = 2
    public static let maxPlayers = 4
    public static let totalBooks = 13

    public private(set) var state: GoFishState

    /// Deals immediately. `playerCount` is clamped to 2...4. Seat 0 leads.
    public init(seed: UInt64, playerCount: Int) {
        let n = min(max(playerCount, Self.minPlayers), Self.maxPlayers)
        let handSize = n == 2 ? 7 : 5
        var deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: seed)
        var hands: [Int: [Card]] = [:]
        for seat in 0..<n {
            hands[seat] = Array(deck.prefix(handSize))
            deck.removeFirst(handSize)
        }
        var books: [Int: [Int]] = [:]
        for seat in 0..<n { books[seat] = [] }
        state = GoFishState(seed: seed, playerCount: n, handSize: handSize, hands: hands,
                            pool: deck, books: books, turnSeat: 0)
        for seat in 0..<n { _ = layBooks(seat) } // opening books (rare), silent here
        pendingOpeningEvents = settle()
    }

    /// Resume from a saved state.
    public init(restoring state: GoFishState) {
        self.state = state
    }

    /// Events produced by the opening deal (books laid, a refill if somebody
    /// opened empty-handed). Read once by the host after `init`.
    public private(set) var pendingOpeningEvents: [GoFishEvent] = []

    /// The `.dealt` event the host broadcasts after init.
    public var dealtEvent: GoFishEvent {
        .dealt(handCounts: handCounts(), poolCount: state.pool.count)
    }

    public func apply(_ action: GoFishAction, from seat: Int) -> [GoFishEvent] {
        guard state.phase == .playing else { return reject(seat, "The game is over") }
        guard seat >= 0, seat < state.playerCount else { return reject(seat, "Not a seat in this game") }
        switch action {
        case .ask(let target, let rank):
            return handleAsk(target: target, rank: rank, from: seat)
        }
    }

    // MARK: - Asking

    private func handleAsk(target: Int, rank: Int, from seat: Int) -> [GoFishEvent] {
        guard seat == state.turnSeat else { return reject(seat, "It's not your turn") }
        guard target >= 0, target < state.playerCount, target != seat else {
            return reject(seat, "Pick another player to ask")
        }
        guard (state.hands[seat] ?? []).contains(where: { $0.rank == rank }) else {
            return reject(seat, "You can only ask for a rank you hold")
        }

        var events: [GoFishEvent] = [.asked(asker: seat, target: target, rank: rank)]
        let given = (state.hands[target] ?? []).filter { $0.rank == rank }
        recordAsk(GoFishAskRecord(asker: seat, target: target, rank: rank, gave: given.count))

        if !given.isEmpty {
            state.hands[target] = (state.hands[target] ?? []).filter { $0.rank != rank }
            state.hands[seat, default: []].append(contentsOf: given)
            events.append(.gave(from: target, to: seat, rank: rank, cards: given))
            events += layBooks(seat)
            events.append(.goesAgain(seat: seat))
        } else {
            events.append(.goFish(seat: seat, rank: rank))
            if state.pool.isEmpty {
                events.append(.poolEmpty(seat: seat))
                events += passTurn()
            } else {
                let drawn = state.pool.removeFirst()
                state.hands[seat, default: []].append(drawn)
                let matched = drawn.rank == rank
                events.append(.fished(seat: seat, matched: matched, card: matched ? drawn : nil))
                events += layBooks(seat)
                if matched {
                    events.append(.goesAgain(seat: seat))
                } else {
                    events += passTurn()
                }
            }
        }
        events += settle()
        return events
    }

    // MARK: - Turn flow

    private func passTurn() -> [GoFishEvent] {
        state.turnSeat = (state.turnSeat + 1) % state.playerCount
        return [.turnChanged(seat: state.turnSeat)]
    }

    private var totalBooksMade: Int { state.books.values.reduce(0) { $0 + $1.count } }

    /// Brings the position to a fixed point: ends the game when all books are
    /// made, refills an empty-handed player on turn from the pool, and skips
    /// a player who is empty with nothing left to draw.
    private func settle() -> [GoFishEvent] {
        var events: [GoFishEvent] = []
        var guardCount = 0
        while state.phase == .playing, guardCount < 200 {
            guardCount += 1
            let everyoneEmpty = state.hands.values.allSatisfy(\.isEmpty)
            if totalBooksMade >= Self.totalBooks || (everyoneEmpty && state.pool.isEmpty) {
                events += finish()
                break
            }
            let seat = state.turnSeat
            if !(state.hands[seat] ?? []).isEmpty { break }
            if !state.pool.isEmpty {
                let n = min(state.handSize, state.pool.count)
                state.hands[seat, default: []].append(contentsOf: state.pool.prefix(n))
                state.pool.removeFirst(n)
                events.append(.refilled(seat: seat, count: n))
                events += layBooks(seat)
                continue
            }
            events += passTurn()
        }
        return events
    }

    private func finish() -> [GoFishEvent] {
        state.phase = .gameOver
        let counts = (0..<state.playerCount).map { ($0, state.books[$0]?.count ?? 0) }
        let best = counts.map(\.1).max() ?? 0
        state.winners = counts.filter { $0.1 == best }.map(\.0)
        return [.gameOver(winners: state.winners, books: Dictionary(uniqueKeysWithValues: counts))]
    }

    // MARK: - Books

    /// Lays down every rank the seat holds all four of, in ascending rank order.
    @discardableResult
    private func layBooks(_ seat: Int) -> [GoFishEvent] {
        var events: [GoFishEvent] = []
        let hand = state.hands[seat] ?? []
        var byRank: [Int: [Card]] = [:]
        for card in hand { if let r = card.rank { byRank[r, default: []].append(card) } }
        for rank in byRank.keys.sorted() {
            guard let cards = byRank[rank], cards.count == 4 else { continue }
            state.hands[seat] = (state.hands[seat] ?? []).filter { $0.rank != rank }
            state.books[seat, default: []].append(rank)
            events.append(.bookLaid(seat: seat, rank: rank, cards: cards))
        }
        return events
    }

    private func recordAsk(_ record: GoFishAskRecord) {
        state.askLog.append(record)
        if state.askLog.count > 80 { state.askLog.removeFirst(state.askLog.count - 80) }
    }

    // MARK: - Snapshots

    public func handCounts() -> [Int: Int] {
        var out: [Int: Int] = [:]
        for seat in 0..<state.playerCount { out[seat] = state.hands[seat]?.count ?? 0 }
        return out
    }

    /// Ranks `seat` could ask for right now (empty off-turn / game over).
    public func askableRanks(for seat: Int) -> [Int] {
        guard state.phase == .playing, seat == state.turnSeat else { return [] }
        return Set((state.hands[seat] ?? []).compactMap(\.rank)).sorted()
    }

    /// Seats `seat` could ask right now (empty off-turn / game over).
    public func askableTargets(for seat: Int) -> [Int] {
        guard state.phase == .playing, seat == state.turnSeat else { return [] }
        return (0..<state.playerCount).filter { $0 != seat }
    }

    public func snapshot(for seat: Int) -> GoFishSnapshot {
        GoFishSnapshot(
            seat: seat, playerCount: state.playerCount, hand: state.hands[seat] ?? [],
            handCounts: handCounts(), books: state.books, poolCount: state.pool.count,
            turnSeat: state.turnSeat, phase: state.phase, winners: state.winners,
            askLog: state.askLog, askableRanks: askableRanks(for: seat),
            askableTargets: askableTargets(for: seat)
        )
    }

    private func reject(_ seat: Int, _ reason: String) -> [GoFishEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
