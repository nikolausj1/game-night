import SwiftUI

/// What one phone sees in War, plus whether the table is ready for the next
/// flip (the last battle may still be playing out on the felt).
struct WarWireState: Codable, Equatable {
    var snapshot: WarSnapshot
    var names: [Int: String]
    var ready: Bool
}

/// How long the table takes to play a battle out. The host uses this to
/// hold off the next flip (and to pace an all-bot game); the table's stage
/// uses the same constants for its beats, so the two agree.
enum WarTiming {
    static let flipFlight = 0.75
    static let compare = 0.55
    static let warCallout = 1.1
    static let downFlight = 0.45
    static let downStagger = 0.12
    static let downSettle = 0.25
    static let sweep = 0.8
    static let counted = 0.3
    static let forfeit = 1.4
    static let dealStagger = 0.025
    static let dealFlight = 0.45

    static func downSpan(_ cardsPerSeat: Int) -> Double {
        Double(max(0, cardsPerSeat - 1)) * downStagger + downFlight + downSettle
    }

    static func duration(_ events: [WarEvent]) -> TimeInterval {
        var total = 0.0
        var flips = 0
        for event in events {
            switch event {
            case .dealt: total += 0.7 + 52 * dealStagger + dealFlight + 0.4
            case .flipped: flips += 1
            case .warDeclared: total += warCallout
            case .faceDownPlaced(_, let count): total += downSpan(count) / 2 // one event per seat, flown together
            case .captured: total += sweep + counted
            case .forfeited: total += forfeit
            case .gameOver: total += 0.6
            case .illegalAttempt: break
            }
        }
        total += Double(flips / 2) * (flipFlight + compare)
        return total
    }
}

/// War as a `SideGameHost`: two seats. A "flip" resolves a whole battle
/// (wars included) in the engine; the table then plays it out as drama.
///
/// - Both seats bots: the host flips on a timer, paced to the animation.
/// - Any human seated: a phone's big Flip button (seat 0 or 1) or a tap on
///   the table's flip zone (seat -1, via `sideGameTableAction`) starts the
///   next battle. Flips that arrive while the felt is still busy are ignored.
@Observable
final class WarHost: SideGameHost {
    let kind = WarEngine.kind
    @ObservationIgnored var onChanged: (() -> Void)?

    private(set) var engine: WarEngine
    private(set) var seatNames: [Int: String]
    let botSeats: Set<Int>
    private(set) var revision = 0
    private(set) var lastBatch: KidsEventBatch<WarEvent>?

    @ObservationIgnored private var batchSeq = 0
    @ObservationIgnored private var pendingWire: SideGamePayload?
    @ObservationIgnored private var busyUntil = Date()
    @ObservationIgnored private var autoScheduled = false
    @ObservationIgnored private var ended = false

    /// True when nobody needs to tap: the host flips for itself.
    var runsItself: Bool { botSeats.contains(0) && botSeats.contains(1) }

    init(seats: [SeatSpec], seed: UInt64, maxRounds: Int = WarEngine.defaultMaxRounds) {
        engine = WarEngine(seed: seed, maxRounds: maxRounds)
        var names: [Int: String] = [0: "Player 1", 1: "Player 2"]
        var bots = Set<Int>()
        for (index, spec) in seats.prefix(2).enumerated() {
            names[index] = spec.name.isEmpty ? "Player \(index + 1)" : spec.name
            if spec.isBot { bots.insert(index) }
        }
        seatNames = names
        botSeats = bots
        let opening = [engine.dealtEvent]
        publish(opening, notify: false)
        let dealSpan = WarTiming.duration(opening)
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * dealSpan)
        // Phones are told the felt is free once the deal has been dealt.
        after(dealSpan + 0.05) { [weak self] in
            guard let self, !self.ended else { return }
            self.revision += 1
            self.onChanged?()
        }
        scheduleAutoIfNeeded()
    }

    // MARK: SideGameHost

    func handle(action: SideGamePayload, from seat: Int) {
        guard !ended, action.kind == kind, seat == -1 || seat == 0 || seat == 1,
              let decoded = action.decode(WarAction.self) else { return }
        switch decoded {
        case .flip: flip(from: seat)
        }
    }

    func state(for seat: Int) -> SideGamePayload? {
        guard seat == 0 || seat == 1 else { return nil }
        let wire = WarWireState(snapshot: engine.snapshot(for: seat), names: seatNames, ready: isReady)
        return KidsWire.payload(kind, wire)
    }

    func drainEvents() -> SideGamePayload? {
        defer { pendingWire = nil }
        return pendingWire
    }

    func end() {
        ended = true
        autoScheduled = false
    }

    func updateNames(_ names: [Int: String]) {
        var merged = seatNames
        for (seat, name) in names where (seat == 0 || seat == 1) && !name.isEmpty { merged[seat] = name }
        guard merged != seatNames else { return }
        seatNames = merged
        revision += 1
        onChanged?()
    }

    func name(_ seat: Int) -> String { seatNames[seat] ?? "Player \(seat + 1)" }

    var isReady: Bool { !ended && engine.state.phase == .playing && Date() >= busyUntil }

    // MARK: flipping

    private func flip(from seat: Int) {
        guard isReady else { return }
        let events = engine.apply(.flip, from: seat < 0 ? 0 : seat)
        let meaningful = events.filter { if case .illegalAttempt = $0 { return false } else { return true } }
        guard !meaningful.isEmpty else { return }
        let span = WarTiming.duration(meaningful)
        busyUntil = Date().addingTimeInterval(KidsMotion.hostScale * span)
        publish(meaningful)
        // Phones learn the felt is free again the moment the drama ends.
        after(span + 0.05) { [weak self] in
            guard let self, !self.ended else { return }
            self.revision += 1
            self.onChanged?()
        }
        scheduleAutoIfNeeded()
    }

    private func scheduleAutoIfNeeded() {
        guard !ended, runsItself, !autoScheduled, engine.state.phase == .playing else { return }
        autoScheduled = true
        after(max(0, busyUntil.timeIntervalSinceNow) + 0.7) { [weak self] in
            guard let self else { return }
            self.autoScheduled = false
            guard !self.ended, self.engine.state.phase == .playing else { return }
            // Woke a hair early (timer slop)? Try again rather than stall.
            guard self.isReady else { self.scheduleAutoIfNeeded(); return }
            self.flip(from: 0)
        }
    }

    // MARK: plumbing

    private func publish(_ events: [WarEvent], notify: Bool = true) {
        guard !events.isEmpty else { return }
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
