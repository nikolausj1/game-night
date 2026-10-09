import SwiftUI

// Gin Rummy as a table-hosted side game.
//
// INTEGRATION (the lead wires these; nothing here touches shared files):
//
//  1. Registry (Sources/App/SideGames/SideGameHost.swift, inside `entries`):
//       "ginRummy": GinRummyLaunch.registryEntry,
//     or, spelled out:
//       "ginRummy": Entry(table: { AnyView(GinRummyTableView(host: $0, onClose: $1)) },
//                         hand:  { AnyView(GinRummyHandView(client: $0)) }),
//
//  2. Launch factory (menu button / wherever a 2-seat game is started):
//       GinRummyLaunch.start(on: host, seats: [SeatSpec(id: 0, name: "", isBot: false),
//                                              SeatSpec(id: 1, name: "Hank", isBot: true)])
//     which is just
//       host.startSideGame(seats: seats, seed: seed) { specs, seed in
//           GinRummyHost(seats: specs, seed: seed, names: host.sideGameSeatNames)
//       }
//
//  3. Sim-verify harness (TableRootView.onAppear, next to -autoStartCribbage):
//       GinRummyLaunch.autoStartIfRequested(host: host)   // honours -autoStartGinRummy
//
//  4. Optional phone-only harness (any root, e.g. RoleRouter), a local game
//     against a bot that needs no iPad:
//       if CommandLine.arguments.contains("-autoStartGinRummyPhone") { GinRummyPhoneHarness() }

// MARK: - Wire types

/// What a phone is told after every mutation: its redacted snapshot plus the
/// seat names (the engine knows seats, the table knows people).
struct GinRummyPhoneState: Codable, Equatable {
    var snapshot: GinRummySnapshot
    var names: [Int: String]

    func name(_ seat: Int) -> String {
        names[seat].flatMap { $0.isEmpty ? nil : $0 } ?? GinSeat.fallbackName(seat)
    }
}

/// One line of the paper score pad (one finished hand).
struct GinScoreRow: Codable, Equatable, Identifiable {
    var id: Int { handNumber }
    let handNumber: Int
    let winnerSeat: Int?
    let points: Int
    let outcome: GinHandOutcome
}

// MARK: - Bot temperament

enum GinBotMood {
    /// Stable per bot name so "Hank" always plays like Hank: the blunt ones
    /// knock the moment they can, the patient ones wait and chase gin.
    static func personality(name: String, seat: Int) -> GinBotPersonality {
        switch name.lowercased() {
        case "hank", "tucker": return .eager
        case "ruthie", "mae": return .balanced
        case "marco", "julie": return .ginChaser
        default:
            var h = 5381
            for b in name.utf8 { h = (h &* 33) &+ Int(b) }
            switch abs(h &+ seat) % 3 {
            case 0: return .eager
            case 1: return .balanced
            default: return .ginChaser
            }
        }
    }
}

// MARK: - Host

/// Owns the engine, the bots, and the clock. `GameHostController` owns seats,
/// peers and routing; this class never sees a peer.
///
/// Pacing: a bot "thinks" for a humanlike beat before every move (longer for
/// the discard than for the draw), and after a showdown the host waits long
/// enough for the table's reveal choreography to play out before dealing the
/// next hand itself (`advance`). Game over never auto-advances: the table
/// offers Rematch.
final class GinRummyHost: SideGameHost {
    let kind = GinRummyEngine.kind
    var onChanged: (() -> Void)?

    struct Pacing {
        var firstUpcard: ClosedRange<Double> = 1.2...2.0
        var draw: ClosedRange<Double> = 0.9...1.6
        var discard: ClosedRange<Double> = 1.3...2.4
        var layoff: ClosedRange<Double> = 1.6...2.4
        /// Hold after a scored hand before the host deals the next (the table's reveal runs ~6s).
        var showdownBeat: Double = 9.5
        var drawnBeat: Double = 4.5

        static let live = Pacing()
        /// For tests and fast soaks.
        static let instant = Pacing(firstUpcard: 0.02...0.04, draw: 0.02...0.04, discard: 0.02...0.04,
                                    layoff: 0.02...0.04, showdownBeat: 0.1, drawnBeat: 0.1)
    }

    private let engine: GinRummyEngine
    private let botSeats: Set<Int>
    private let pacing: Pacing
    private var personalities: [Int: GinBotPersonality] = [:]
    private var rng: SeededGenerator
    private var timer: Timer?
    private var ended = false
    private var pending: [GinRummyEvent] = []

    /// Seat names, kept current so a late-resolving lobby name still shows.
    var seatNames: [Int: String]

    /// Bumped on every mutation that produced events; the table keys its
    /// animations off this.
    private(set) var eventSeq = 0
    /// The events from the latest mutation (illegal attempts removed).
    private(set) var recentEvents: [GinRummyEvent] = []
    /// One row per finished hand (reset with each new game: a rematch builds a fresh host).
    private(set) var scoreRows: [GinScoreRow] = []

    init(seed: UInt64, botSeats: Set<Int>, names: [Int: String], pacing: Pacing = .live) {
        self.engine = GinRummyEngine(seed: seed)
        self.botSeats = botSeats
        self.seatNames = names
        self.pacing = pacing
        self.rng = SeededGenerator(seed: seed ^ 0x61_6E_52_75_6D_6D_79)
        for seat in botSeats {
            personalities[seat] = GinBotMood.personality(name: names[seat] ?? "", seat: seat)
        }
        // First beat: a bot non-dealer may need to act at once.
        DispatchQueue.main.async { [weak self] in self?.schedule() }
    }

    /// The shape `GameHostController.startSideGame` hands a factory.
    convenience init(seats specs: [SeatSpec], seed: UInt64, names: [Int: String]) {
        var merged = names
        for spec in specs where (merged[spec.id] ?? "").isEmpty && !spec.name.isEmpty {
            merged[spec.id] = spec.name
        }
        self.init(seed: seed, botSeats: Set(specs.filter(\.isBot).map(\.id)), names: merged)
    }

    // MARK: SideGameHost

    func handle(action payload: SideGamePayload, from seat: Int) {
        guard !ended, payload.kind == kind, let action = payload.decode(GinRummyAction.self) else { return }
        if seat == -1 {
            // The table itself may only deal the next hand.
            guard case .advance = action else { return }
            apply(.advance, from: 0)
            return
        }
        guard seat == 0 || seat == 1, !botSeats.contains(seat) else { return }
        apply(action, from: seat)
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat == 0 || seat == 1 else { return nil }
        let phone = GinRummyPhoneState(snapshot: engine.snapshot(for: seat), names: seatNames)
        return try? SideGamePayload(kind: kind, value: phone)
    }

    func drainEvents() -> SideGamePayload? {
        guard !pending.isEmpty else { return nil }
        let events = pending
        pending = []
        return try? SideGamePayload(kind: kind, value: events)
    }

    func end() {
        ended = true
        timer?.invalidate()
        timer = nil
    }

    // MARK: Table-side reads

    var tableSnapshot: GinRummyTableSnapshot { engine.tableSnapshot() }

    func name(_ seat: Int) -> String {
        seatNames[seat].flatMap { $0.isEmpty ? nil : $0 } ?? GinSeat.fallbackName(seat)
    }

    func isBot(_ seat: Int) -> Bool { botSeats.contains(seat) }

    /// The table's "deal the next hand now" tap (also what the host's own beat timer does).
    func tableAdvance() {
        guard let payload = try? SideGamePayload(kind: kind, value: GinRummyAction.advance) else { return }
        handle(action: payload, from: -1)
    }

    // MARK: Mutation

    private func apply(_ action: GinRummyAction, from seat: Int) {
        let events = engine.apply(action, from: seat)
        let real = events.filter { if case .illegalAttempt = $0 { return false }; return true }
        if !real.isEmpty {
            for event in real {
                switch event {
                case .showdown(let result): record(result)
                case .handDrawn: if let result = engine.state.lastResult { record(result) }
                default: break
                }
            }
            pending += real
            recentEvents = real
            eventSeq += 1
        }
        // Always notify, even for a rejected move: the sender's phone re-syncs to the truth.
        onChanged?()
        schedule()
    }

    private func record(_ result: GinHandResult) {
        guard !scoreRows.contains(where: { $0.handNumber == result.handNumber }) else { return }
        scoreRows.append(GinScoreRow(handNumber: result.handNumber, winnerSeat: result.winnerSeat,
                                     points: result.points, outcome: result.outcome))
    }

    // MARK: Bot + beat clock

    private struct Expectation: Equatable {
        let hand: Int
        let phase: GinRummyPhase
        let turn: Int
        let moves: Int
        let layoffs: Int
    }

    private func expectation() -> Expectation {
        let s = engine.state
        return Expectation(hand: s.handNumber, phase: s.phase, turn: s.turnSeat, moves: s.moves.count, layoffs: s.layoffs.count)
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !ended else { return }
        let s = engine.state
        let delay: Double
        switch s.phase {
        case .gameOver:
            return
        case .handComplete:
            delay = s.lastResult?.outcome == .drawn ? pacing.drawnBeat : pacing.showdownBeat
        case .firstUpcard:
            guard botSeats.contains(s.turnSeat) else { return }
            delay = .random(in: pacing.firstUpcard, using: &rng)
        case .draw:
            guard botSeats.contains(s.turnSeat) else { return }
            delay = .random(in: pacing.draw, using: &rng)
        case .discard:
            guard botSeats.contains(s.turnSeat) else { return }
            delay = .random(in: pacing.discard, using: &rng)
        case .layoff:
            guard botSeats.contains(s.turnSeat) else { return }
            delay = .random(in: pacing.layoff, using: &rng)
        }
        let expected = expectation()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.fire(expected)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire(_ expected: Expectation) {
        timer = nil
        guard !ended else { return }
        guard expectation() == expected else { schedule(); return } // the world moved on
        let s = engine.state
        switch s.phase {
        case .handComplete:
            apply(.advance, from: 0)
        case .gameOver:
            return
        default:
            let seat = s.turnSeat
            guard botSeats.contains(seat) else { return }
            let personality = personalities[seat] ?? .balanced
            let action = GinRummyBot.nextAction(snapshot: engine.snapshot(for: seat), personality: personality, rng: &rng)
            guard let action else { schedule(); return }
            apply(action, from: seat)
        }
    }
}

// MARK: - Launch helpers

enum GinRummyLaunch {
    /// The registry value for `SideGameRegistry.entries["ginRummy"]`.
    static var registryEntry: SideGameRegistry.Entry {
        SideGameRegistry.Entry(
            table: { AnyView(GinRummyTableView(host: $0, onClose: $1)) },
            hand: { AnyView(GinRummyHandView(client: $0)) }
        )
    }

    /// Start a 2-seat game on the table. Humans map onto connected lobby
    /// players in lobby order (the generic side-game contract); bots are
    /// driven by `GinRummyHost`.
    static func start(on host: GameHostController, seats: [SeatSpec],
                      seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        guard seats.count == 2 else { return }
        host.startSideGame(seats: seats, seed: seed) { [weak host] specs, seed in
            GinRummyHost(seats: specs, seed: seed, names: host?.sideGameSeatNames ?? [:])
        }
    }

    /// `-autoStartGinRummy`: two bots play a full game on the table, no menu.
    static func autoStartIfRequested(host: GameHostController) {
        guard CommandLine.arguments.contains("-autoStartGinRummy"),
              host.state == nil, host.sideGame == nil else { return }
        let bots = BotRoster.random(count: 2)
        let seats = bots.enumerated().map { SeatSpec(id: $0.offset, name: $0.element.name, isBot: true) }
        start(on: host, seats: seats)
    }
}
