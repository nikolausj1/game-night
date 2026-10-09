import Foundation

/// What the host drains to every phone (and keeps for the table): one
/// mutation's events plus a serial. The serial exists because
/// `SideGamePayload` is `Equatable` — two identical consecutive event lists
/// (say, the same rejection twice) would otherwise look like "no change" to
/// SwiftUI's `onChange` and never retrigger. Events carry no secret
/// coordinates (`BattleshipEvent` is public-by-construction), so everyone
/// gets the same batch.
struct BattleshipEventBatch: Codable, Equatable {
    var serial: Int
    var events: [BattleshipEvent]
}

/// Hosts one Battleship game on the table through the generic side-game
/// seam. Owns the pure `BattleshipEngine`, speaks `SideGamePayload`
/// (`BattleshipAction` in, per-seat `BattleshipSnapshot` out), and plays the
/// bot seats with humanlike pacing. `GameHostController` owns seats and
/// peers; this class never learns about them beyond the `SeatSpec`s it was
/// built from.
///
/// Registry line (add to `SideGameRegistry.entries`, NOT done here):
///
///     "battleship": Entry(table: { AnyView(BattleshipTableView(host: $0, onClose: $1)) },
///                         hand:  { AnyView(BattleshipHandView(client: $0)) }),
///
/// Launch (menu / harness):
///
///     host.startSideGame(seats: seats, seed: UInt64.random(in: .min ... .max)) { specs, seed in
///         BattleshipHost(seats: specs, seed: seed)          // classic; salvo: true for the variant
///     }
final class BattleshipHost: SideGameHost {
    let kind = BattleshipEngine.kind
    var onChanged: (() -> Void)?

    private(set) var engine: BattleshipEngine
    let botSeats: Set<Int>
    /// Seat -> name from the `SeatSpec`s (the host controller's own
    /// `sideGameSeatNames` fills human names from their phones; the table
    /// view prefers that and falls back to these).
    let seatNames: [Int: String]
    let seed: UInt64

    /// Recent event batches, oldest first, for the table's choreography.
    /// The table remembers the last serial it saw and replays only newer
    /// ones, so a burst of mutations between redraws is never dropped.
    private(set) var eventLog: [BattleshipEventBatch] = []

    private var serial = 0
    private var pending: [BattleshipEvent] = []
    private var botRNG: SeededGenerator
    private var botWork: DispatchWorkItem?
    private var ended = false
    private var lastShotWasSunk = false

    init(seats: [SeatSpec], seed: UInt64, salvo: Bool = false) {
        var bots: Set<Int> = []
        var names: [Int: String] = [:]
        for spec in seats where spec.id == 0 || spec.id == 1 {
            names[spec.id] = spec.name
            if spec.isBot { bots.insert(spec.id) }
        }
        // A missing seat (lobby had one phone, no bot drafted) is filled by
        // a bot so the game can always start.
        for seat in [0, 1] where names[seat] == nil {
            names[seat] = "Fleet Admiral"
            bots.insert(seat)
        }
        self.botSeats = bots
        self.seatNames = names
        self.seed = seed
        self.engine = BattleshipEngine(seed: seed, salvo: salvo)
        self.botRNG = SeededGenerator(seed: seed ^ 0xB477_1E55_1B00_0001)
        // `onChanged` isn't wired yet; kick the bots on the next runloop tick.
        DispatchQueue.main.async { [weak self] in self?.advanceBots() }
    }

    // MARK: SideGameHost

    func handle(action payload: SideGamePayload, from seat: Int) {
        guard !ended, payload.kind == kind, seat == 0 || seat == 1,
              let action = payload.decode(BattleshipAction.self) else { return }
        apply(action, from: seat)
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat == 0 || seat == 1 else { return nil }
        return try? SideGamePayload(kind: kind, value: engine.snapshot(for: seat))
    }

    func drainEvents() -> SideGamePayload? {
        guard !pending.isEmpty else { return nil }
        let batch = BattleshipEventBatch(serial: serial, events: pending)
        pending = []
        return try? SideGamePayload(kind: kind, value: batch)
    }

    func end() {
        ended = true
        botWork?.cancel()
        botWork = nil
    }

    // MARK: table conveniences

    func tableSnapshot() -> BattleshipTableSnapshot { engine.tableSnapshot() }

    // MARK: mutation

    private func apply(_ action: BattleshipAction, from seat: Int) {
        let events = engine.apply(action, from: seat)
        if case .fire = action {
            lastShotWasSunk = events.contains {
                if case .shotFired(_, _, .sunk, _) = $0 { return true }
                return false
            }
        }
        record(events)
    }

    /// Every mutation funnels here: log for the table, queue for the
    /// phones, schedule the bots, and tell the host controller.
    private func record(_ events: [BattleshipEvent]) {
        guard !events.isEmpty else { return }
        serial += 1
        pending.append(contentsOf: events)
        eventLog.append(BattleshipEventBatch(serial: serial, events: events))
        if eventLog.count > 60 { eventLog.removeFirst(eventLog.count - 60) }
        advanceBots()
        onChanged?()
    }

    // MARK: bots

    private enum BotStep {
        case deploy(seat: Int)
        case confirm(seat: Int)
        case fire(seat: Int)
    }

    private func nextBotStep() -> BotStep? {
        let state = engine.state
        switch state.phase {
        case .placement:
            for seat in botSeats.sorted() where !state.ready.contains(seat) {
                if (state.ships[seat] ?? []).count < BattleshipRules.fleet.count { return .deploy(seat: seat) }
            }
            for seat in botSeats.sorted() where !state.ready.contains(seat) { return .confirm(seat: seat) }
            return nil
        case .battle:
            if let turn = state.turnSeat, botSeats.contains(turn) { return .fire(seat: turn) }
            return nil
        case .gameOver:
            return nil
        }
    }

    /// Schedules at most one pending bot step. Called after every mutation
    /// (and once at start), so it is safe to call redundantly.
    private func advanceBots() {
        guard !ended, botWork == nil, let step = nextBotStep() else { return }
        let delay: Double
        switch step {
        case .deploy: delay = Double.random(in: 0.7...1.3, using: &botRNG)
        case .confirm: delay = Double.random(in: 1.2...2.2, using: &botRNG)
        case .fire:
            // Long enough for the table's peg drop + hit/sink flourish to
            // land before the next one, longer still after a sinking.
            delay = Double.random(in: 1.5...2.3, using: &botRNG) + (lastShotWasSunk ? 1.4 : 0)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            self.botWork = nil
            self.run(step)
            self.advanceBots() // safety net; `record` normally already did
        }
        botWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func run(_ step: BotStep) {
        switch step {
        case .deploy(let seat):
            // Place via the bot's own placement (the same legal-fleet
            // generator the engine's randomize uses), one `placeShip` per
            // vessel so the event stream looks like a human's.
            let fleet = BattleshipBot.placement(seed: seed &+ 0x9E37 &* UInt64(seat + 1))
            var events: [BattleshipEvent] = []
            for ship in fleet {
                events += engine.apply(
                    .placeShip(kind: ship.kind, row: ship.row, col: ship.col, orientation: ship.orientation),
                    from: seat)
            }
            record(events)
        case .confirm(let seat):
            record(engine.apply(.confirmPlacement, from: seat))
        case .fire(let seat):
            guard let cell = BattleshipBot.chooseShot(snapshot: engine.snapshot(for: seat), rng: &botRNG) else { return }
            apply(.fire(row: cell.row, col: cell.col), from: seat)
        }
    }
}
