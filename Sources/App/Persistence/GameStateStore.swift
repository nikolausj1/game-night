import Foundation

/// A device-linked seat, serializable for the save file. Distinct from the
/// bots worker's `SeatSpec` (just `id`/`name`/`isBot`, used at game-creation
/// time before any phone is bound to a seat) — this one also remembers
/// which deviceID, if any, held the seat, so a future reconnect-after-resume
/// pass has what it needs without re-deriving it.
struct SeatSpecCodable: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var isBot: Bool
    var deviceID: String?
}

/// One suspended game, one file. `id` is stable for the life of a started
/// game — minted on the first autosave and carried forward through resume —
/// so repeated autosaves overwrite the same slot instead of piling up, and
/// the resume strip shows each suspended game exactly once.
struct SavedGame: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var gameKind: GameKind
    var savedAt: Date
    var state: GameState
    var seats: [SeatSpecCodable]
}

/// JSON-file persistence for suspended games, under
/// `Documents/SavedGames/<id>.json`. A namespace rather than an instance —
/// the only long-lived state is the in-memory engine → save-id registry
/// that keeps autosaves landing in the same slot for the life of one
/// `HostEngine` (a fresh one is minted on relaunch or resume, never reused).
enum GameStateStore {
    /// Which save-slot id a given (in-memory) engine writes to. Reset on
    /// every app launch by construction — a new `HostEngine` always mints
    /// or is handed a fresh entry before its first save.
    private static var activeGameIDs: [ObjectIdentifier: String] = [:]

    private static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SavedGames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// The stable save-slot id for this engine instance, minting a fresh
    /// one on first use (a brand-new game) and remembering it thereafter.
    private static func gameID(for engine: HostEngine) -> String {
        let key = ObjectIdentifier(engine)
        if let existing = activeGameIDs[key] { return existing }
        let fresh = UUID().uuidString
        activeGameIDs[key] = fresh
        return fresh
    }

    /// Pins a specific save-slot id to an engine — used on resume so
    /// continued autosaves overwrite the original file instead of forking
    /// a new slot for what is, to the player, the same suspended game.
    static func registerActiveGameID(_ id: String, for engine: HostEngine) {
        activeGameIDs[ObjectIdentifier(engine)] = id
    }

    /// Writes (or overwrites) this host's current game to its save slot.
    /// No-ops if there's no game in progress.
    static func saveCurrent(host: GameHostController) {
        guard let engine = host.engine, let state = host.state else { return }
        let id = gameID(for: engine)
        let deviceBySeat = Dictionary(uniqueKeysWithValues: host.seatByDevice.map { ($1, $0) })
        let seats = state.seats.map { seat in
            SeatSpecCodable(
                id: seat.id,
                name: seat.playerName,
                isBot: deviceBySeat[seat.id] == nil,
                deviceID: deviceBySeat[seat.id]
            )
        }
        let saved = SavedGame(
            id: id,
            label: "\(state.gameKind.displayName) · \(state.seats.count) player\(state.seats.count == 1 ? "" : "s")",
            gameKind: state.gameKind,
            savedAt: Date(),
            state: state,
            seats: seats
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL(for: id), options: .atomic)
    }

    /// Deletes whatever save slot this host's current engine owns (the
    /// `gameWon` moment — a finished game has nothing left to resume) and
    /// forgets the in-memory registry entry.
    static func deleteActiveSave(for host: GameHostController) {
        guard let engine = host.engine else { return }
        let key = ObjectIdentifier(engine)
        guard let id = activeGameIDs[key] else { return }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        activeGameIDs.removeValue(forKey: key)
    }

    /// All suspended games, newest first.
    static func list() -> [SavedGame] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedGame? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedGame.self, from: data)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    static func delete(_ saved: SavedGame) {
        try? FileManager.default.removeItem(at: fileURL(for: saved.id))
    }
}

extension SavedGame {
    /// Resumes this suspended game onto the host: rebuilds a `HostEngine`
    /// from the saved `GameState` and adopts it wholesale, then re-registers
    /// this save's id so further autosaves overwrite the same file instead
    /// of forking a new slot.
    func resume(into host: GameHostController) {
        let engine = HostEngine(restoring: state)
        let restoredSeats = seats.map { SeatSpec(id: $0.id, name: $0.name, isBot: $0.isBot) }
        var deviceMap: [String: Int] = [:]
        for seat in seats {
            if let deviceID = seat.deviceID { deviceMap[deviceID] = seat.id }
        }
        host.adoptRestoredGame(engine, seats: restoredSeats, deviceMap: deviceMap)
        GameStateStore.registerActiveGameID(id, for: engine)
    }
}
