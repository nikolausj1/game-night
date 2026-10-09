import SwiftUI

/// What one phone may see in Old Maid, plus the seat names the snapshot lacks.
struct OldMaidWireState: Codable, Equatable {
    var snapshot: OldMaidSnapshot
    var names: [Int: String]
}

/// Pacing shared by the host (bot spacing) and the table (narration beats).
enum OldMaidTiming {
    static let dealStagger = 0.028
    static let dealFlight = 0.45
    static let draw = 1.1
    static let pair = 1.3
    static let openingPair = 1.0
    static let out = 1.3
    static let shuffle = 0.8
    static let finale = 3.2

    static func dwell(_ events: [OldMaidEvent]) -> TimeInterval {
        var total = 0.0
        for event in events {
            switch event {
            case .dealt(let counts):
                total += Double(counts.values.reduce(0, +)) * dealStagger + dealFlight + 1.0
            case .pairsDiscarded(_, _, let onDeal): total += onDeal ? openingPair : pair
            case .drew: total += draw
            case .handShuffled: total += shuffle
            case .playerOut: total += out
            case .gameOver: total += finale
            case .turnChanged, .illegalAttempt: break
            }
        }
        return total
    }
}

/// Old Maid as a `SideGameHost`: 2-4 seats, bots via `OldMaidBot`.
/// The drawer picks an INDEX in the neighbor's fan; the engine applies it
/// at once and the table narrates the result.
@Observable
final class OldMaidHost: SideGameHost {
    let kind = OldMaidEngine.kind
    @ObservationIgnored var onChanged: (() -> Void)?

    private(set) var engine: OldMaidEngine
    private(set) var seatNames: [Int: String]
    let botSeats: Set<Int>
    private(set) var revision = 0
    private(set) var lastBatch: KidsEventBatch<OldMaidEvent>?

    @ObservationIgnored private var batchSeq = 0
    /// Bumped by every published batch; lets a delayed bot shuffle notice
    /// that the world moved on while it waited.
    @ObservationIgnored private var moveCounter = 0
    @ObservationIgnored private var lastBotShuffleCounter = -1
    @ObservationIgnored private var pendingWire: SideGamePayload?
    @ObservationIgnored private var botRNG: SeededGenerator
    @ObservationIgnored private var busyUntil = Date()
    @ObservationIgnored private var botScheduled = false
    @ObservationIgnored private var ended = false

    init(seats: [SeatSpec], seed: UInt64) {
        let trimmed = Array(seats.prefix(OldMaidEngine.maxPlayers))
        let count = min(max(trimmed.count, OldMaidEngine.minPlayers), OldMaidEngine.maxPlayers)
        engine = OldMaidEngine(seed: seed, playerCount: count)
        var names: [Int: String] = [:]
        var bots = Set<Int>()
        for (index, spec) in trimmed.enumerated() {
            names[index] = spec.name.isEmpty ? "Player \(index + 1)" : spec.name
            if spec.isBot { bots.insert(index) }
        }
        for id in 0..<count where names[id] == nil { names[id] = "Player \(id + 1)" }
        seatNames = names
        botSeats = bots
        botRNG = SeededGenerator(seed: seed ^ 0x01D0_4A1D_01D0_4A1D)
        let opening = engine.pendingOpeningEvents
        publish(opening, notify: false)
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * OldMaidTiming.dwell(opening))
        scheduleBotIfNeeded()
    }

    // MARK: SideGameHost

    func handle(action: SideGamePayload, from seat: Int) {
        guard !ended, action.kind == kind, seat >= 0,
              let decoded = action.decode(OldMaidAction.self) else { return }
        let events = engine.apply(decoded, from: seat)
        // A refused move (not your turn, bad index) changes nothing: stay quiet.
        let meaningful = events.filter { if case .illegalAttempt = $0 { return false } else { return true } }
        guard !meaningful.isEmpty else { return }
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * OldMaidTiming.dwell(meaningful))
        publish(meaningful)
        scheduleBotIfNeeded()
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat >= 0, seat < engine.state.playerCount else { return nil }
        return KidsWire.payload(kind, OldMaidWireState(snapshot: engine.snapshot(for: seat), names: seatNames))
    }

    func drainEvents() -> SideGamePayload? {
        defer { pendingWire = nil }
        return pendingWire
    }

    func end() {
        ended = true
        botScheduled = false
    }

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

    // MARK: bots

    private func scheduleBotIfNeeded() {
        guard !ended, !botScheduled, engine.state.phase == .playing else { return }
        let turn = engine.state.turnSeat
        if botSeats.contains(turn) {
            botScheduled = true
            let think = Double.random(in: 1.3...2.6)
            after(max(0, busyUntil.timeIntervalSinceNow) + think) { [weak self] in
                guard let self else { return }
                self.botScheduled = false
                self.botDraw()
            }
        } else if let target = engine.drawTarget(for: turn), botSeats.contains(target),
                  moveCounter != lastBotShuffleCounter,
                  (engine.state.hands[target]?.count ?? 0) > 2, Double.random(in: 0...1) < 0.3 {
            // A bot about to be picked from sometimes shuffles first, like a
            // real player would. The table narrates it.
            botScheduled = true
            let counterAtSchedule = moveCounter
            after(max(0, busyUntil.timeIntervalSinceNow) + Double.random(in: 0.7...1.6)) { [weak self] in
                guard let self else { return }
                self.botScheduled = false
                if !self.ended, self.engine.state.phase == .playing,
                   self.engine.state.turnSeat == turn, self.moveCounter == counterAtSchedule {
                    let events = self.engine.apply(.shuffleMyHand, from: target)
                    self.busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * OldMaidTiming.dwell(events))
                    self.publish(events)
                    self.lastBotShuffleCounter = self.moveCounter
                }
                self.scheduleBotIfNeeded()
            }
        }
    }

    private func botDraw() {
        guard !ended, engine.state.phase == .playing else { return }
        let seat = engine.state.turnSeat
        guard botSeats.contains(seat) else { return }
        let snapshot = engine.snapshot(for: seat)
        guard let index = OldMaidBot.chooseIndex(snapshot: snapshot, rng: &botRNG) else {
            scheduleBotIfNeeded()
            return
        }
        let events = engine.apply(.draw(index: index), from: seat)
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * OldMaidTiming.dwell(events))
        publish(events)
        scheduleBotIfNeeded()
    }

    // MARK: plumbing

    private func publish(_ events: [OldMaidEvent], notify: Bool = true) {
        guard !events.isEmpty else {
            if notify { revision += 1; onChanged?() }
            return
        }
        batchSeq += 1
        moveCounter += 1
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
