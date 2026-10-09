import SwiftUI

/// Everything one phone is allowed to see in Go Fish, plus the table-level
/// facts a phone cannot derive: seat names (the snapshot carries none) and
/// whether an ask is already in flight.
struct GoFishWireState: Codable, Equatable {
    var snapshot: GoFishSnapshot
    var names: [Int: String]
    /// True between "Chase asks Vinny for sevens" and the answer. The phone
    /// shows a waiting line and does not let a second ask through.
    var askInFlight: Bool
}

/// Shared pacing for Go Fish. The host uses it to space out bot moves and
/// the table uses the same numbers to time its narration beats, so the two
/// stay in step.
enum GoFishTiming {
    static let ask = 1.9
    static let gave = 1.6
    static let goFish = 1.3
    static let draw = 0.8
    static let reveal = 1.5
    static let book = 1.5
    static let again = 0.9
    static let refill = 1.2
    static let poolEmpty = 1.1
    static let dealStagger = 0.05
    static let dealFlight = 0.5

    /// Roughly how long the table will take to narrate these events.
    static func dwell(_ events: [GoFishEvent]) -> TimeInterval {
        var total = 0.0
        for event in events {
            switch event {
            case .dealt(let counts, _):
                total += 0.9 + Double(counts.values.reduce(0, +)) * dealStagger + dealFlight + 0.4
            case .asked: total += ask
            case .gave: total += gave
            case .goFish: total += goFish
            case .fished(_, let matched, _): total += matched ? draw + reveal + draw : draw
            case .poolEmpty: total += poolEmpty
            case .goesAgain: total += again
            case .bookLaid: total += book
            case .refilled: total += refill
            case .turnChanged, .gameOver, .illegalAttempt: break
            }
        }
        return total
    }
}

/// Go Fish as a `SideGameHost`: 2-4 seats, bots via `GoFishBot`.
///
/// An ask is staged in two beats so the narration IS the game: the moment
/// a seat asks, the host publishes only `.asked` ("Chase asks Vinny for
/// sevens") and holds the real move for `GoFishTiming.ask` seconds; then it
/// applies the action and publishes everything that happened (cards handed
/// over, "Go fish!", the drawn card, books, go-again). The engine state
/// therefore never runs ahead of what the table is saying.
@Observable
final class GoFishHost: SideGameHost {
    let kind = GoFishEngine.kind
    @ObservationIgnored var onChanged: (() -> Void)?

    private(set) var engine: GoFishEngine
    private(set) var seatNames: [Int: String]
    let botSeats: Set<Int>
    /// Bumped on every mutation; the table observes it.
    private(set) var revision = 0
    /// The most recent numbered batch of events (the table narrates these).
    private(set) var lastBatch: KidsEventBatch<GoFishEvent>?
    private(set) var askInFlight: PendingAsk?

    struct PendingAsk: Equatable {
        let seat: Int
        let target: Int
        let rank: Int
    }

    @ObservationIgnored private var batchSeq = 0
    @ObservationIgnored private var pendingWire: SideGamePayload?
    @ObservationIgnored private var botRNG: SeededGenerator
    @ObservationIgnored private var busyUntil = Date()
    @ObservationIgnored private var botScheduled = false
    @ObservationIgnored private var ended = false

    init(seats: [SeatSpec], seed: UInt64) {
        let trimmed = Array(seats.prefix(GoFishEngine.maxPlayers))
        let count = min(max(trimmed.count, GoFishEngine.minPlayers), GoFishEngine.maxPlayers)
        engine = GoFishEngine(seed: seed, playerCount: count)
        var names: [Int: String] = [:]
        var bots = Set<Int>()
        for (index, spec) in trimmed.enumerated() {
            let id = index
            names[id] = spec.name.isEmpty ? "Player \(id + 1)" : spec.name
            if spec.isBot { bots.insert(id) }
        }
        for id in 0..<count where names[id] == nil { names[id] = "Player \(id + 1)" }
        seatNames = names
        botSeats = bots
        botRNG = SeededGenerator(seed: seed ^ 0x60F1_5400_60F1_5400)
        // Opening deal (and any refill) is the first batch; the controller's
        // first `drainEvents()` hands it to the phones.
        let opening = [engine.dealtEvent] + engine.pendingOpeningEvents
        publish(opening, notify: false)
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * GoFishTiming.dwell(opening))
        scheduleBotIfNeeded()
    }

    // MARK: SideGameHost

    func handle(action: SideGamePayload, from seat: Int) {
        guard !ended, action.kind == kind, seat >= 0, askInFlight == nil,
              engine.state.phase == .playing,
              let decoded = action.decode(GoFishAction.self) else { return }
        switch decoded {
        case .ask(let target, let rank):
            submitAsk(seat: seat, target: target, rank: rank)
        }
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat >= 0, seat < engine.state.playerCount else { return nil }
        let wire = GoFishWireState(snapshot: engine.snapshot(for: seat), names: seatNames,
                                   askInFlight: askInFlight != nil)
        return KidsWire.payload(kind, wire)
    }

    func drainEvents() -> SideGamePayload? {
        defer { pendingWire = nil }
        return pendingWire
    }

    func end() {
        ended = true
        botScheduled = false
        askInFlight = nil
    }

    /// The table pushes the controller's seat names (which include lobby
    /// names for humans) in here; phones get them on the next state push.
    func updateNames(_ names: [Int: String]) {
        var merged = seatNames
        for (seat, name) in names where seat < engine.state.playerCount && !name.isEmpty {
            merged[seat] = name
        }
        guard merged != seatNames else { return }
        seatNames = merged
        revision += 1
        onChanged?()
    }

    func name(_ seat: Int) -> String { seatNames[seat] ?? "Player \(seat + 1)" }

    // MARK: asking

    private func submitAsk(seat: Int, target: Int, rank: Int) {
        guard seat == engine.state.turnSeat,
              engine.askableRanks(for: seat).contains(rank),
              engine.askableTargets(for: seat).contains(target) else { return }
        let ask = PendingAsk(seat: seat, target: target, rank: rank)
        askInFlight = ask
        revision += 1
        onChanged?() // phones learn an ask is in flight
        after(max(0, busyUntil.timeIntervalSinceNow)) { [weak self] in self?.announce(ask) }
    }

    private func announce(_ ask: PendingAsk) {
        guard !ended, askInFlight == ask else { return }
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * GoFishTiming.ask)
        publish([.asked(asker: ask.seat, target: ask.target, rank: ask.rank)])
        after(GoFishTiming.ask) { [weak self] in self?.resolve(ask) }
    }

    private func resolve(_ ask: PendingAsk) {
        guard !ended, askInFlight == ask else { return }
        var events = engine.apply(.ask(target: ask.target, rank: ask.rank), from: ask.seat)
        askInFlight = nil
        // The announce beat already said "asked"; do not repeat it.
        if case .asked? = events.first { events.removeFirst() }
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * GoFishTiming.dwell(events))
        publish(events)
        scheduleBotIfNeeded()
    }

    // MARK: bots

    private func scheduleBotIfNeeded() {
        guard !ended, !botScheduled, askInFlight == nil,
              engine.state.phase == .playing,
              botSeats.contains(engine.state.turnSeat) else { return }
        botScheduled = true
        let think = Double.random(in: 1.0...2.2)
        after(max(0, busyUntil.timeIntervalSinceNow) + think) { [weak self] in
            guard let self else { return }
            self.botScheduled = false
            self.botMove()
        }
    }

    private func botMove() {
        guard !ended, askInFlight == nil, engine.state.phase == .playing else { return }
        let seat = engine.state.turnSeat
        guard botSeats.contains(seat) else { return }
        let snapshot = engine.snapshot(for: seat)
        guard let action = GoFishBot.chooseAction(snapshot: snapshot, rng: &botRNG),
              case .ask(let target, let rank) = action else {
            scheduleBotIfNeeded()
            return
        }
        submitAsk(seat: seat, target: target, rank: rank)
    }

    // MARK: plumbing

    private func publish(_ events: [GoFishEvent], notify: Bool = true) {
        guard !events.isEmpty else {
            if notify { revision += 1; onChanged?() }
            return
        }
        batchSeq += 1
        let batch = KidsEventBatch(seq: batchSeq, events: events)
        lastBatch = batch
        pendingWire = KidsWire.payload(kind, batch)
        revision += 1
        if notify { onChanged?() }
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * KidsMotion.hostScale, execute: block)
    }
}
