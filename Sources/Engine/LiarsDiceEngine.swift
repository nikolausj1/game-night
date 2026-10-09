import Foundation

/// Authoritative Liar's Dice reducer: `apply(action, from: seat) -> [events]`,
/// Codable `state`, per-seat snapshots via `state.snapshot(for:)`.
/// Standalone like `CribbageEngine`. See `LiarsDiceTypes.swift` for the
/// rule decisions.
public final class LiarsDiceEngine {
    public static let kind = "liarsDice"

    public private(set) var state: LiarsDiceState

    /// Seats are clamped to 2...6. The first starter is `seed % seatCount`.
    public init(seed: UInt64, seatCount: Int, config: LiarsDiceConfig = LiarsDiceConfig()) {
        let n = min(max(seatCount, 2), 6)
        state = LiarsDiceState(seed: seed, seatCount: n, config: config, starterSeat: Int(seed % UInt64(n)))
    }

    public init(restoring state: LiarsDiceState) {
        self.state = state
    }

    public func apply(_ action: LiarsDiceAction, from seat: Int) -> [LiarsDiceEvent] {
        guard seat >= 0, seat < state.seatCount else { return reject(seat, "No such seat") }
        guard state.phase != .gameOver else { return reject(seat, "The game is over") }
        switch action {
        case .setDice(let target, let dice): return handleSetDice(target, dice, from: seat)
        case .bid(let q, let f): return handleBid(q, f, from: seat)
        case .challenge: return handleCall(.challenge, from: seat)
        case .spotOn: return handleCall(.spotOn, from: seat)
        case .nextRound: return handleNextRound(from: seat)
        }
    }

    /// Roll dice deterministically for every live seat that has not supplied
    /// a roll yet (or only for `seats`). For bots and tests; a human's
    /// phone-cup result arrives through `.setDice`. Returns the events of
    /// the resulting `setDice` actions.
    @discardableResult
    public func rollAll(seed: UInt64, seats: Set<Int>? = nil) -> [LiarsDiceEvent] {
        guard state.phase == .awaitingDice else { return [] }
        var rng = SeededGenerator(seed: seed)
        var ev: [LiarsDiceEvent] = []
        for s in state.liveSeats {
            let faces = (0..<state.diceCounts[s]).map { _ in Int.random(in: 1...6, using: &rng) }
            guard state.dice[s] == nil, seats?.contains(s) ?? true else { continue }
            ev += apply(.setDice(seat: s, dice: faces), from: s)
        }
        return ev
    }

    // MARK: - Dice

    private func handleSetDice(_ target: Int, _ dice: [Int], from seat: Int) -> [LiarsDiceEvent] {
        guard state.phase == .awaitingDice else { return reject(seat, "Dice aren't being rolled right now") }
        guard target == seat else { return reject(seat, "You can only roll your own dice") }
        guard state.diceCounts[seat] > 0 else { return reject(seat, "You're eliminated") }
        guard state.dice[seat] == nil else { return reject(seat, "Your dice are already set") }
        guard dice.count == state.diceCounts[seat] else {
            return reject(seat, "Roll exactly \(state.diceCounts[seat]) dice")
        }
        guard dice.allSatisfy({ (1...6).contains($0) }) else { return reject(seat, "Dice show 1 to 6") }
        state.dice[seat] = dice
        var ev: [LiarsDiceEvent] = [.diceSet(seat: seat)]
        if state.liveSeats.allSatisfy({ state.dice[$0] != nil }) {
            state.phase = .bidding
            state.turnSeat = state.starterSeat
            ev.append(.allDiceSet(starterSeat: state.starterSeat))
        }
        return ev
    }

    // MARK: - Bidding

    private func handleBid(_ q: Int, _ f: Int, from seat: Int) -> [LiarsDiceEvent] {
        guard state.phase == .bidding else { return reject(seat, "Bidding isn't open") }
        guard seat == state.turnSeat else { return reject(seat, "It isn't your turn") }
        guard LiarsDiceRules.isLegalBid(quantity: q, face: f, over: state.currentBid, totalDice: state.totalDice) else {
            return reject(seat, "That bid doesn't raise the last one")
        }
        state.bids.append(LiarsDiceBid(seat: seat, quantity: q, face: f))
        state.turnSeat = state.nextLiveSeat(after: seat)
        return [.bidMade(seat: seat, quantity: q, face: f)]
    }

    private func handleCall(_ kind: LiarsDiceCallKind, from seat: Int) -> [LiarsDiceEvent] {
        guard state.phase == .bidding else { return reject(seat, "Nothing to call right now") }
        guard seat == state.turnSeat else { return reject(seat, "It isn't your turn") }
        guard let bid = state.currentBid else { return reject(seat, "There's no bid to call yet") }
        if kind == .spotOn && !state.config.spotOnEnabled {
            return reject(seat, "Spot on is turned off")
        }
        var ev: [LiarsDiceEvent] = []
        ev.append(kind == .challenge ? .challenged(seat: seat, against: bid.seat)
                                     : .spotOnCalled(seat: seat, against: bid.seat))
        let revealed = state.dice.filter { state.diceCounts[$0.key] > 0 }
        let all = revealed.values.flatMap { $0 }
        let actual = LiarsDiceRules.count(face: bid.face, in: all, wildOnes: state.config.wildOnes)
        ev.append(.revealed(dice: revealed, face: bid.face, quantity: bid.quantity, actualCount: actual))

        var loser: Int?
        var gainer: Int?
        let succeeded: Bool
        var nextStarter: Int
        switch kind {
        case .challenge:
            if actual >= bid.quantity { loser = seat; succeeded = false }
            else { loser = bid.seat; succeeded = true }
            nextStarter = loser!
        case .spotOn:
            if actual == bid.quantity {
                succeeded = true
                if state.diceCounts[seat] < state.config.diceCount { gainer = seat }
            } else {
                succeeded = false
                loser = seat
            }
            nextStarter = seat
        }

        if let l = loser {
            state.diceCounts[l] -= 1
            ev.append(.dieLost(seat: l, remaining: state.diceCounts[l]))
            if state.diceCounts[l] == 0 {
                state.eliminationOrder.append(l)
                ev.append(.eliminated(seat: l))
            }
        }
        if let g = gainer {
            state.diceCounts[g] += 1
            ev.append(.dieGained(seat: g, remaining: state.diceCounts[g]))
        }
        if state.diceCounts[nextStarter] == 0 {
            nextStarter = state.nextLiveSeat(after: nextStarter)
        }
        state.starterSeat = nextStarter
        state.lastResolution = LiarsDiceResolution(
            kind: kind, caller: seat, bid: bid, actualCount: actual, dice: revealed,
            callSucceeded: succeeded, loserSeat: loser, gainerSeat: gainer)

        if state.liveSeats.count == 1 {
            state.phase = .gameOver
            state.winnerSeat = state.liveSeats[0]
            ev.append(.gameWon(seat: state.liveSeats[0]))
        } else {
            state.phase = .reveal
        }
        return ev
    }

    private func handleNextRound(from seat: Int) -> [LiarsDiceEvent] {
        guard state.phase == .reveal else { return reject(seat, "The round isn't over") }
        state.roundNumber += 1
        state.dice = [:]
        state.bids = []
        state.lastResolution = nil
        state.phase = .awaitingDice
        state.turnSeat = state.starterSeat
        return [.roundStarted(round: state.roundNumber, starterSeat: state.starterSeat, diceCounts: state.diceCounts)]
    }

    private func reject(_ seat: Int, _ reason: String) -> [LiarsDiceEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
