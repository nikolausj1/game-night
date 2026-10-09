import SwiftUI
import Observation

// MARK: - Wire types (phone <-> host)

/// Phone -> host beacon that is NOT an engine action: "I shook my cup and
/// it has settled." The host rolls every seat's dice itself at round start
/// (see `LiarsDiceHost.beginRound`), so this is purely ceremonial — it
/// lets the table show "rolling…" on a plate and lets bots wait for the
/// humans to finish their shake before the first bid lands.
///
/// `LiarsDiceAction` (bid / challenge / spotOn) travels on the same
/// `sideGameAction` wire raw; the host tries that type first, then this.
enum LiarsDiceCeremonyAction: Codable, Equatable {
    case shook
}

/// What one phone is told, after every mutation. `snapshot` is the engine's
/// own per-seat redaction (own dice only until a call reveals them).
struct LiarsDicePhoneState: Codable, Equatable {
    /// Distinguishes "Play again" (round numbers restart at 1) from the
    /// previous game on the phone's local ceremony state.
    var gameID: Int
    var snapshot: LiarsDiceSnapshot
    /// Display names by seat.
    var names: [String]
    var botSeats: [Int]
    /// This seat has shaken + settled its cup for the current round.
    var shaken: Bool
    var shakenSeats: [Int]
}

// MARK: - Timing

/// One clock shared by the host (how long to hold a reveal before the next
/// round) and the table view (when each beat of the reveal lands), so the
/// choreography is never cut off by the host moving on.
enum LiarsDiceTiming {
    static func slamEnd(_ reduced: Bool) -> Double { reduced ? 0.35 : 1.05 }
    static func liftEnd(_ reduced: Bool) -> Double { slamEnd(reduced) + (reduced ? 0.25 : 0.75) }
    static func countStep(_ reduced: Bool) -> Double { reduced ? 0.06 : 0.15 }
    static func countEnd(matching: Int, _ reduced: Bool) -> Double {
        liftEnd(reduced) + 0.2 + Double(max(1, matching)) * countStep(reduced)
    }
    static func verdictEnd(matching: Int, _ reduced: Bool) -> Double {
        countEnd(matching: matching, reduced) + (reduced ? 1.2 : 1.7)
    }
    /// How long the host waits after a call before sending `nextRound`.
    static func hold(matching: Int, _ reduced: Bool) -> Double {
        verdictEnd(matching: matching, reduced) + (reduced ? 0.4 : 0.8)
    }
}

// MARK: - Words

enum LiarsDiceWords {
    private static let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                                "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]

    static func number(_ n: Int) -> String {
        if n >= 0, n < small.count { return small[n] }
        if n < 30 { return "twenty-" + small[n - 20] }
        if n == 30 { return "thirty" }
        return "\(n)"
    }

    /// "four 3s", "one 5", "six 1s".
    static func bid(_ quantity: Int, _ face: Int) -> String {
        "\(number(quantity)) \(face)\(quantity == 1 ? "" : "s")"
    }

    static func faces(_ face: Int, count: Int) -> String {
        "\(face)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Host

/// Liar's Dice as a hosted side game: owns the engine, the bots, and the
/// pacing. See `Sources/Engine/LiarsDiceTypes.swift` for the rules.
///
/// ROLLING (this wave): the HOST rolls every seat at the top of each round
/// with `engine.rollAll(seed:)`. A phone then PERFORMS the roll as a
/// ceremony (shake -> cup settles -> lift-to-peek) over dice the engine
/// already holds. Upgrade path (physical cup roll): swap `beginRound` to
/// `rollAll(seed:, seats: botSeats)` and have the phone send
/// `LiarsDiceAction.setDice(seat:dice:)` with the dice read off its
/// SceneKit cup (`DieFaceReader`); the engine already validates them. The
/// table/phone UIs do not change.
@Observable
final class LiarsDiceHost: SideGameHost {
    let kind = LiarsDiceEngine.kind
    @ObservationIgnored var onChanged: (() -> Void)?

    /// Display names by seat (engine seat order).
    let names: [String]
    let botSeats: Set<Int>
    /// Stable id for this game (derived from the seed). Changes on
    /// "Play again", which builds a fresh host.
    let gameID: Int

    private(set) var engine: LiarsDiceEngine
    /// Human seats that finished the shake-and-settle this round.
    private(set) var shakenSeats: Set<Int> = []
    /// Bumped on every mutation; table views read it so `@Observable`
    /// redraws them (the engine itself is a plain class).
    private(set) var tick = 0

    @ObservationIgnored private var pending: [LiarsDiceEvent] = []
    @ObservationIgnored private var rng: SeededGenerator
    @ObservationIgnored private let gameSeed: UInt64
    @ObservationIgnored private let autoplay: Bool
    @ObservationIgnored private let personalities: [Int: LiarsDicePersonality]
    @ObservationIgnored private var botWork: DispatchWorkItem?
    @ObservationIgnored private var advanceWork: DispatchWorkItem?
    @ObservationIgnored private var roundStartedAt = Date()
    @ObservationIgnored private var ended = false

    // MARK: init

    private init(engine: LiarsDiceEngine, names: [String], botSeats: Set<Int>,
                 gameSeed: UInt64, autoplay: Bool) {
        self.engine = engine
        self.names = names
        self.botSeats = botSeats
        self.gameSeed = gameSeed
        self.gameID = Int(gameSeed % 1_000_000)
        self.autoplay = autoplay
        self.rng = SeededGenerator(seed: gameSeed ^ 0xA5A5_5A5A_1234_4321)
        var p: [Int: LiarsDicePersonality] = [:]
        for seat in botSeats where seat < names.count {
            p[seat] = Self.personality(forName: names[seat])
        }
        self.personalities = p
    }

    /// The factory the lead passes to `GameHostController.startSideGame`.
    /// Seats are clamped to the engine's 2...6; if fewer than two specs are
    /// given the empty chairs are filled with `BotRoster` regulars.
    convenience init(seats specs: [SeatSpec], seed: UInt64,
                     config: LiarsDiceConfig = LiarsDiceConfig(), autoplay: Bool = true) {
        let engine = LiarsDiceEngine(seed: seed, seatCount: specs.count, config: config)
        let n = engine.state.seatCount
        var names: [String] = []
        var bots: Set<Int> = []
        var spare = BotRoster.all.map(\.name).filter { name in
            !specs.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        for i in 0..<n {
            if i < specs.count {
                let spec = specs[i]
                names.append(spec.name.isEmpty ? "Seat \(i + 1)" : spec.name)
                if spec.isBot { bots.insert(i) }
            } else {
                names.append(spare.isEmpty ? "Seat \(i + 1)" : spare.removeFirst())
                bots.insert(i)
            }
        }
        self.init(engine: engine, names: names, botSeats: bots, gameSeed: seed, autoplay: autoplay)
        beginRound()
        schedule()
    }

    /// Preview/test seam: wrap an engine that is already mid-game. Nothing
    /// auto-plays unless `autoplay` is true, so a frozen demo stays frozen.
    convenience init(restoring engine: LiarsDiceEngine, names: [String], botSeats: Set<Int>,
                     shaken: Set<Int> = [], gameSeed: UInt64 = 1, autoplay: Bool = false) {
        self.init(engine: engine, names: names, botSeats: botSeats, gameSeed: gameSeed, autoplay: autoplay)
        shakenSeats = shaken
        if autoplay { schedule() }
    }

    /// Cautious / balanced / reckless, by name. The six `BotRoster` regulars
    /// are pinned so "Ruthie" always plays the same way; any other name gets
    /// a stable djb2-hash pick (never Swift's per-launch randomized hash).
    static func personality(forName name: String) -> LiarsDicePersonality {
        switch name.lowercased() {
        case "hank": return .cautious
        case "ruthie": return .reckless
        case "marco": return .balanced
        case "mae": return .cautious
        case "tucker": return .reckless
        case "julie": return .balanced
        default:
            var hash: UInt64 = 5381
            for byte in name.lowercased().utf8 { hash = hash &* 33 &+ UInt64(byte) }
            return LiarsDicePersonality.allCases[Int(hash % UInt64(LiarsDicePersonality.allCases.count))]
        }
    }

    // MARK: SideGameHost

    func handle(action payload: SideGamePayload, from seat: Int) {
        guard !ended else { return }
        if let action = payload.decode(LiarsDiceAction.self) {
            switch action {
            case .setDice:
                return // the host rolls this wave; see the type doc
            case .nextRound:
                // Only the table may skip the reveal beat (phones can't).
                guard seat == -1, engine.state.phase == .reveal else { return }
                perform(.nextRound, from: engine.state.starterSeat)
            case .bid, .challenge, .spotOn:
                guard seat >= 0, seat < names.count, !botSeats.contains(seat) else { return }
                perform(action, from: seat)
            }
        } else if let ceremony = payload.decode(LiarsDiceCeremonyAction.self) {
            guard case .shook = ceremony, seat >= 0, seat < names.count,
                  !botSeats.contains(seat), !shakenSeats.contains(seat),
                  engine.state.liveSeats.contains(seat) else { return }
            shakenSeats.insert(seat)
            afterMutation()
        }
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat >= 0, seat < names.count else { return nil }
        let phone = LiarsDicePhoneState(
            gameID: gameID,
            snapshot: engine.state.snapshot(for: seat),
            names: names,
            botSeats: botSeats.sorted(),
            shaken: shakenSeats.contains(seat),
            shakenSeats: shakenSeats.sorted())
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
        botWork?.cancel(); botWork = nil
        advanceWork?.cancel(); advanceWork = nil
        onChanged = nil
    }

    // MARK: table-facing helpers

    func name(of seat: Int) -> String {
        names.indices.contains(seat) ? names[seat] : "Seat \(seat + 1)"
    }

    var humanSeats: [Int] { names.indices.filter { !botSeats.contains($0) } }

    /// Live human seats that have not finished their shake yet.
    var seatsStillRolling: [Int] {
        engine.state.liveSeats.filter { !botSeats.contains($0) && !shakenSeats.contains($0) }
    }

    // MARK: rounds

    /// Roll every live seat from the engine's deterministic generator.
    private func beginRound() {
        shakenSeats = []
        roundStartedAt = Date()
        let seed = gameSeed &+ UInt64(engine.state.roundNumber) &* 0x9E37_79B9_7F4A_7C15
        pending += engine.rollAll(seed: seed)
    }

    private func perform(_ action: LiarsDiceAction, from seat: Int) {
        if case .nextRound = action {
            advanceWork?.cancel()
            advanceWork = nil
        }
        let events = engine.apply(action, from: seat)
        pending += events
        let startedRound = events.contains { if case .roundStarted = $0 { return true } else { return false } }
        if startedRound { beginRound() }
        afterMutation()
    }

    private func afterMutation() {
        tick += 1
        onChanged?()
        schedule()
    }

    // MARK: pacing

    private func schedule() {
        guard autoplay, !ended else { return }
        switch engine.state.phase {
        case .bidding: scheduleBotIfNeeded()
        case .reveal: scheduleAdvance()
        case .awaitingDice, .gameOver: break
        }
    }

    private func scheduleAdvance() {
        guard advanceWork == nil, let resolution = engine.state.lastResolution else { return }
        let hold = LiarsDiceTiming.hold(matching: resolution.actualCount,
                                        UIAccessibility.isReduceMotionEnabled)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            self.advanceWork = nil
            guard self.engine.state.phase == .reveal else { return }
            self.perform(.nextRound, from: self.engine.state.starterSeat)
        }
        advanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    private func scheduleBotIfNeeded() {
        guard botWork == nil else { return }
        let state = engine.state
        guard state.phase == .bidding, botSeats.contains(state.turnSeat) else { return }
        let seat = state.turnSeat
        // Humanlike thinking time: a touch quicker on an opening bid, and
        // never instant, so the table gets to read each bid before the next.
        let delay = state.bids.isEmpty
            ? Double.random(in: 1.0...1.8, using: &rng)
            : Double.random(in: 1.5...2.9, using: &rng)
        queueBot(seat: seat, after: delay)
    }

    private func queueBot(seat: Int, after delay: Double) {
        let work = DispatchWorkItem { [weak self] in self?.runBot(seat: seat) }
        botWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runBot(seat: Int) {
        botWork = nil
        guard !ended else { return }
        let state = engine.state
        guard state.phase == .bidding, state.turnSeat == seat else { schedule(); return }
        // Bots wait for the humans to finish shaking (they cannot know it
        // is the host that rolled for them). A 20s cap so a phone that
        // never shakes (or never connected) cannot stall the table.
        if !seatsStillRolling.isEmpty, Date().timeIntervalSince(roundStartedAt) < 20 {
            queueBot(seat: seat, after: 0.5)
            return
        }
        let action = LiarsDiceBot.nextAction(
            state: state, seat: seat,
            personality: personalities[seat] ?? .balanced, rng: &rng)
            ?? (state.currentBid != nil ? .challenge : .bid(quantity: 1, face: 2))
        perform(action, from: seat)
    }
}

// MARK: - Launch helpers (for the lead's menu + harness)

extension LiarsDiceHost {
    /// One-call launch: `LiarsDiceHost.launch(on: host, seats: specs)`.
    static func launch(on host: GameHostController, seats: [SeatSpec],
                       seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        host.startSideGame(seats: seats, seed: seed) { specs, seed in
            LiarsDiceHost(seats: specs, seed: seed)
        }
    }

    /// Sim-verify hook body: an all-bot table that plays itself.
    /// `-liarsDiceSeats N` (2...6, default 4) picks the player count.
    static func launchAllBotDemo(on host: GameHostController) {
        var count = 4
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-liarsDiceSeats"), args.indices.contains(i + 1),
           let n = Int(args[i + 1]) {
            count = min(max(n, 2), 6)
        }
        let seats = BotRoster.random(count: count).enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
        }
        launch(on: host, seats: seats)
    }
}
