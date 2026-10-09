import Foundation

/// Cribbage save/resume. The engine's `CribbageState` is already a complete
/// Codable snapshot (seed, scores, hands, pegging, the lot), so the payload
/// is the state itself; the envelope carries the two seats with their
/// durable deviceIDs so phones reclaim their chairs.
enum CribbageSave {
    private static let debouncer = SaveDebouncer()

    /// Called on every cribbage mutation (the table view hooks
    /// `host.stateVersion`); writes 2s after the last one. A finished game
    /// deletes its slot instead — nothing left to resume.
    static func noteChanged(host: GameHostController) {
        guard host.cribbageEngine != nil else { return }
        debouncer.schedule { [weak host] in
            guard let host else { return }
            persist(host: host)
        }
    }

    /// Synchronous write (the table is closing; don't lose the last 2s).
    static func flush(host: GameHostController) {
        debouncer.cancel()
        persist(host: host)
    }

    static func clear() {
        debouncer.cancel()
        SaveSlots.clear(kind: .cribbage)
    }

    private static func persist(host: GameHostController) {
        guard let engine = host.cribbageEngine else { return }
        let state = engine.state
        guard state.phase != .gameOver else {
            SaveSlots.clear(kind: .cribbage)
            return
        }
        SaveSlots.write(kind: .cribbage, title: "Cribbage",
                        subtitle: subtitle(state: state, names: host.cribbageSeatNames),
                        seats: host.cribbageSavedSeats, payload: state)
    }

    /// "Hand 5 · Mae leads 61-48".
    static func subtitle(state: CribbageState, names: [Int: String]) -> String {
        let a = state.scores[0] ?? 0, b = state.scores[1] ?? 0
        let name0 = names[0] ?? "Seat 1", name1 = names[1] ?? "Seat 2"
        let hand = max(1, state.handNumber)
        if a == b { return "Hand \(hand) · tied at \(a)" }
        return a > b ? "Hand \(hand) · \(name0) leads \(a)-\(b)" : "Hand \(hand) · \(name1) leads \(b)-\(a)"
    }

    /// Rebuilds the cribbage table from disk. False if there was nothing
    /// (or something unreadable, which is then discarded).
    @discardableResult
    static func resume(into host: GameHostController) -> Bool {
        guard let (envelope, state) = SaveSlots.read(kind: .cribbage, as: CribbageState.self) else { return false }
        guard state.phase != .gameOver else {
            SaveSlots.clear(kind: .cribbage)
            return false
        }
        host.adoptRestoredCribbage(state: state, seats: envelope.seats)
        return true
    }
}
