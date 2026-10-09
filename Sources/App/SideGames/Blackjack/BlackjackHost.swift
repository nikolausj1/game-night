import SwiftUI

/// Blackjack as a `SideGameHost`: owns the `BlackjackEngine`, drives the bot
/// seats with humanlike pacing, and sends `nextRound` itself after a settle
/// beat. `GameHostController` owns seats, peers, and routing; this class
/// only speaks `SideGamePayload`.
///
/// Seats: engine seat index == position in the seat list (sorted by
/// `SeatSpec.id`, which the lobby assigns 0..<n). 1...5 seats.
///
/// Pacing: the engine resolves a whole step instantly, so every mutation's
/// events are timed with `BlackjackTimeline` and the host holds the next
/// bot move (and the next round) until the felt would have caught up.
/// `@Observable` so a table view that reads `version` redraws on every
/// mutation even when mounted without a `GameHostController` (previews).
@Observable
final class BlackjackHost: SideGameHost {
    @ObservationIgnored let kind = BlackjackEngine.kind
    @ObservationIgnored var onChanged: (() -> Void)?

    /// Bumps on every mutation; table views read it to subscribe.
    private(set) var version = 0

    @ObservationIgnored let engine: BlackjackEngine
    @ObservationIgnored let names: [String]
    @ObservationIgnored private(set) var botSeats: Set<Int>
    @ObservationIgnored private var personalities: [Int: BlackjackBetPersonality] = [:]
    @ObservationIgnored private var rng: SeededGenerator

    /// Every batch the table may still need to replay (bounded).
    @ObservationIgnored private var batches: [BlackjackEventBatch] = []
    /// Events produced since the last `drainEvents` (for the phones).
    @ObservationIgnored private var undrained: [BlackjackEvent] = []
    @ObservationIgnored private var seq = 0

    /// When the table's animation of everything so far should be done.
    @ObservationIgnored private var busyUntil = Date()
    /// Invalidates scheduled steps whenever the situation changes.
    @ObservationIgnored private var generation = 0
    /// false = no timers at all (previews, scripted demos, tests).
    @ObservationIgnored let paced: Bool

    var config: BlackjackConfig { engine.state.config }
    var seatCount: Int { engine.state.seats.count }
    func isBot(_ seat: Int) -> Bool { botSeats.contains(seat) }
    func name(of seat: Int) -> String { names.indices.contains(seat) ? names[seat] : "Seat \(seat + 1)" }
    var latestSeq: Int { seq }

    init(seats specs: [SeatSpec], seed: UInt64,
         config: BlackjackConfig = BlackjackConfig(), paced: Bool = true) {
        let sorted = specs.sorted { $0.id < $1.id }
        let n = min(max(sorted.count, 1), 5)
        let used = Array(sorted.prefix(n))
        engine = BlackjackEngine(seed: seed, seatCount: n, config: config)
        names = used.enumerated().map { i, s in s.name.isEmpty ? "Seat \(i + 1)" : s.name }
        botSeats = Set(used.enumerated().filter { $0.element.isBot }.map(\.offset))
        self.paced = paced
        var gen = SeededGenerator(seed: seed ^ 0xB1AC_4A3C)
        for s in botSeats.sorted() {
            personalities[s] = BlackjackBetPersonality.allCases.randomElement(using: &gen) ?? .steady
        }
        rng = gen
        schedulePump()
    }

    // MARK: SideGameHost

    func handle(action payload: SideGamePayload, from seat: Int) {
        guard payload.kind == kind else { return }
        if seat < 0 {
            // The table itself, acting for a seat that has no phone.
            guard let tap = payload.decode(BlackjackTableTap.self),
                  !botSeats.contains(tap.seat) else { return }
            submit(tap.action, from: tap.seat)
        } else {
            guard let action = payload.decode(BlackjackAction.self),
                  !botSeats.contains(seat) else { return }
            submit(action, from: seat)
        }
    }

    func state(for seat: Int) -> SideGamePayload? {
        let phone = BlackjackPhoneState(snapshot: engine.state.snapshot(for: seat), names: names)
        return try? SideGamePayload(kind: kind, value: phone)
    }

    func drainEvents() -> SideGamePayload? {
        guard !undrained.isEmpty else { return nil }
        let batch = BlackjackEventBatch(seq: seq, events: undrained)
        undrained = []
        return try? SideGamePayload(kind: kind, value: batch)
    }

    func end() {
        generation += 1
        onChanged = nil
    }

    // MARK: Table replay

    /// Batches newer than `seq`, oldest first.
    func batches(after seq: Int) -> [BlackjackEventBatch] {
        batches.filter { $0.seq > seq }
    }

    // MARK: Mutation

    /// Scripted play for previews and demos: routes through the same commit
    /// path as a real action (batches, versions) but skips the human-only guards.
    func scripted(_ action: BlackjackAction, from seat: Int) {
        commit(engine.apply(action, from: seat))
    }

    private func submit(_ action: BlackjackAction, from seat: Int) {
        // The host owns the beat between rounds (the table has to finish
        // its settlement theater first); a phone's nextRound is ignored.
        if case .nextRound = action { return }
        commit(engine.apply(action, from: seat))
    }

    private func commit(_ events: [BlackjackEvent]) {
        guard !events.isEmpty else { return }
        seq += 1
        batches.append(BlackjackEventBatch(seq: seq, events: events))
        if batches.count > 80 { batches.removeFirst(batches.count - 80) }
        undrained += events
        if BlackjackTimeline.isVisible(events) {
            let sched = BlackjackTimeline.schedule(events)
            busyUntil = max(Date(), busyUntil).addingTimeInterval(sched.advance + 0.15)
                .addingTimeInterval(max(0, sched.total - sched.advance) * 0.5)
        }
        version += 1
        onChanged?()
        schedulePump()
    }

    // MARK: Automatic play (bots + the round clock)

    private enum Step {
        case bot(seat: Int, action: BlackjackAction)
        case nextRound
    }

    private func schedulePump() {
        generation += 1
        guard paced, let (step, think) = nextStep() else { return }
        let gen = generation
        let wait = max(0, busyUntil.timeIntervalSinceNow) + think
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.generation == gen else { return }
            switch step {
            case .bot(let seat, let action): self.commit(self.engine.apply(action, from: seat))
            case .nextRound: self.commit(self.engine.apply(.nextRound, from: 0))
            }
        }
    }

    /// The next automatic step and the humanlike pause BEFORE it (on top of
    /// waiting for the felt). nil = waiting on a person, or over.
    private func nextStep() -> (Step, Double)? {
        let s = engine.state
        switch s.phase {
        case .betting:
            for seat in botSeats.sorted() where s.legalActions(for: seat).contains(.placeBet) {
                if let a = botAction(seat) { return (.bot(seat: seat, action: a), Double.random(in: 0.55...1.5)) }
            }
            return nil
        case .insurance:
            for seat in botSeats.sorted() where s.legalActions(for: seat).contains(.takeInsurance) {
                if let a = botAction(seat) { return (.bot(seat: seat, action: a), 0.7) }
            }
            return nil
        case .playing:
            guard let seat = s.activeSeat, botSeats.contains(seat),
                  let a = botAction(seat) else { return nil }
            // A bot "thinks": longer on the genuinely close calls.
            let close: Bool = { if case .doubleDown = a { return true }; if case .split = a { return true }; return false }()
            return (.bot(seat: seat, action: a), Double.random(in: 1.0...1.7) + (close ? 0.5 : 0))
        case .roundComplete:
            return (.nextRound, 2.4)
        case .sessionOver:
            return nil
        }
    }

    private func botAction(_ seat: Int) -> BlackjackAction? {
        BlackjackBot.nextAction(state: engine.state, seat: seat,
                                personality: personalities[seat] ?? .steady, rng: &rng)
    }
}
