import Foundation

/// Save/resume for every `SideGameHost` (Battleship, Gin Rummy, Blackjack,
/// Liar's Dice, Go Fish, Old Maid, War). The host controller calls
/// `noteChanged` from its one side-game emit path, so a game that
/// implements `snapshot()` is saved with no further wiring; the registry's
/// `restore` closure is the matching way back in.
enum SideGameSave {
    private static let debouncer = SaveDebouncer()

    static func noteChanged(host: GameHostController) {
        guard let game = host.sideGame else { return }
        debouncer.schedule { [weak host, weak game] in
            guard let host, let game, let live = host.sideGame, live === game else { return }
            persist(host: host, game: game)
        }
    }

    /// Synchronous write before the table folds (`closeTable`).
    static func flush(host: GameHostController) {
        debouncer.cancel()
        guard let game = host.sideGame else { return }
        persist(host: host, game: game)
    }

    static func clear(kind: String) {
        debouncer.cancel()
        SaveSlots.clear(kind: .sideGame(kind))
    }

    private static func persist(host: GameHostController, game: any SideGameHost) {
        guard let data = game.snapshot() else {
            // nil = over (or this kind doesn't save). Either way: no card.
            SaveSlots.clear(kind: .sideGame(game.kind))
            return
        }
        SaveSlots.write(kind: .sideGame(game.kind), title: game.resumeTitle, subtitle: game.resumeSubtitle,
                        seats: host.sideGameSavedSeats, payloadData: data)
    }

    @discardableResult
    static func resume(kind: String, into host: GameHostController) -> Bool {
        guard let envelope = SaveSlots.envelope(for: .sideGame(kind)),
              let entry = SideGameRegistry.entries[kind],
              let restore = entry.restore else { return false }
        let specs = envelope.seats.map { SeatSpec(id: $0.id, name: $0.name, isBot: $0.isBot) }
        guard let game = restore(envelope.payload, specs) else {
            // Unreadable (a save from before the state type changed): drop it.
            SaveSlots.clear(kind: .sideGame(kind))
            return false
        }
        host.adoptRestoredSideGame(game, seats: envelope.seats, fresh: entry.fresh)
        return true
    }
}
