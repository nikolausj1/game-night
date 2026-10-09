import Foundation

/// Authoritative War reducer. There are no decisions, so the table (or a
/// host timer) just keeps calling `autoStep()` until `state.phase == .gameOver`.
public final class WarEngine {
    public static let kind = "war"
    public static let defaultMaxRounds = 200

    public private(set) var state: WarState

    public init(seed: UInt64, maxRounds: Int = WarEngine.defaultMaxRounds) {
        let deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: seed)
        state = WarState(seed: seed, maxRounds: max(1, maxRounds),
                         hands: [0: Array(deck[0..<26]), 1: Array(deck[26..<52])])
    }

    public init(restoring state: WarState) {
        self.state = state
    }

    /// The `.dealt` event the host broadcasts after init.
    public var dealtEvent: WarEvent { .dealt(handCounts: counts()) }

    public func apply(_ action: WarAction, from seat: Int) -> [WarEvent] {
        guard seat == 0 || seat == 1 else { return [.illegalAttempt(seat: seat, reason: "War only has two seats")] }
        guard state.phase == .playing else { return [.illegalAttempt(seat: seat, reason: "The game is over")] }
        switch action {
        case .flip: return resolveBattle()
        }
    }

    /// Plays one whole battle (flip, wars and capture). No-op returning `[]`
    /// once the game is over.
    @discardableResult
    public func autoStep() -> [WarEvent] {
        guard state.phase == .playing else { return [] }
        return resolveBattle()
    }

    // MARK: - Battle

    private func resolveBattle() -> [WarEvent] {
        let round = state.round + 1
        var events: [WarEvent] = []
        var flips: [WarFlip] = []
        var pot: [Card] = []
        var depth = 0
        var wars = 0
        var winner: Int?
        var split = false

        battle: while true {
            // A player with nothing to flip forfeits.
            let empty0 = state.hands[0, default: []].isEmpty
            let empty1 = state.hands[1, default: []].isEmpty
            if empty0 && empty1 { split = true; break battle }
            if empty0 || empty1 {
                let loser = empty0 ? 0 : 1
                winner = 1 - loser
                events.append(.forfeited(seat: loser, round: round))
                break battle
            }
            let a = state.hands[0]!.removeFirst()
            let b = state.hands[1]!.removeFirst()
            pot.append(a); pot.append(b)
            flips.append(WarFlip(seat: 0, card: a, faceDown: false, depth: depth))
            flips.append(WarFlip(seat: 1, card: b, faceDown: false, depth: depth))
            events.append(.flipped(seat: 0, card: a, round: round, depth: depth))
            events.append(.flipped(seat: 1, card: b, round: round, depth: depth))
            let ra = a.rank ?? 0, rb = b.rank ?? 0
            if ra != rb { winner = ra > rb ? 0 : 1; break battle }

            // Tie: WAR.
            depth += 1
            wars += 1
            events.append(.warDeclared(round: round, depth: depth))
            for seat in 0...1 {
                // Keep one card back to flip; lay down up to 3.
                let down = min(3, max(0, (state.hands[seat]?.count ?? 0) - 1))
                if down > 0 {
                    let laid = Array(state.hands[seat]!.prefix(down))
                    state.hands[seat]!.removeFirst(down)
                    pot.append(contentsOf: laid)
                    for _ in laid { flips.append(WarFlip(seat: seat, card: nil, faceDown: true, depth: depth)) }
                    events.append(.faceDownPlaced(seat: seat, count: down))
                }
            }
        }

        // Award the pot in a seeded shuffled order.
        var rng = SeededGenerator(seed: state.seed &+ UInt64(round) &* 0x9E37_79B9_7F4A_7C15)
        pot.shuffle(using: &rng)
        if let w = winner {
            state.hands[w, default: []].append(contentsOf: pot)
            events.append(.captured(seat: w, count: pot.count, round: round))
        } else if split {
            for (i, card) in pot.enumerated() { state.hands[i % 2, default: []].append(card) }
            events.append(.captured(seat: 0, count: (pot.count + 1) / 2, round: round))
            events.append(.captured(seat: 1, count: pot.count / 2, round: round))
        }
        state.round = round
        state.lastBattle = WarBattle(round: round, flips: flips, wars: wars,
                                     winner: split ? nil : winner, captured: pot.count)

        events += checkEnd()
        return events
    }

    private func checkEnd() -> [WarEvent] {
        let c = counts()
        let c0 = c[0] ?? 0, c1 = c[1] ?? 0
        if c0 == 0 || c1 == 0 {
            state.phase = .gameOver
            state.winner = c0 == 0 ? 1 : 0
            state.endReason = .allCards
        } else if state.round >= state.maxRounds {
            state.phase = .gameOver
            state.endReason = .roundCap
            state.winner = c0 == c1 ? nil : (c0 > c1 ? 0 : 1)
        } else {
            return []
        }
        return [.gameOver(winner: state.winner, reason: state.endReason!, counts: c)]
    }

    public func counts() -> [Int: Int] {
        [0: state.hands[0]?.count ?? 0, 1: state.hands[1]?.count ?? 0]
    }

    public func snapshot(for seat: Int) -> WarSnapshot {
        let c = counts()
        return WarSnapshot(seat: seat, myCount: c[seat] ?? 0, opponentCount: c[1 - seat] ?? 0,
                           round: state.round, maxRounds: state.maxRounds, phase: state.phase,
                           winner: state.winner, endReason: state.endReason, lastBattle: state.lastBattle)
    }
}
