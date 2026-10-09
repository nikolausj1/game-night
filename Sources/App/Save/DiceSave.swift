import Foundation

/// Resume for the table-side dice games. Each controller autosaves itself
/// (see the `persist()` in every dice controller — they own their own
/// debouncer so a save never outlives its game); this is the way back in:
/// read the slot, rebuild the controller with its `restoring:` initializer
/// (which also re-registers the host's dice routing), and hand it to
/// `DiceLauncher`, which `TableRootView` already switches on.
enum DiceSave {
    @discardableResult
    static func resume(kind: DiceKind, host: GameHostController) -> Bool {
        let launcher = DiceLauncher.shared
        guard launcher.game == nil else { return false }
        switch kind {
        case .lcr:
            guard let (_, saved) = SaveSlots.read(kind: .dice(.lcr), as: LcrSaveState.self),
                  let controller = DiceGameController(host: host, restoring: saved) else { return false }
            launcher.adopt(.lcr(controller))
        case .yahtzee:
            guard let (_, saved) = SaveSlots.read(kind: .dice(.yahtzee), as: YahtzeeSaveState.self),
                  let controller = YahtzeeController(host: host, restoring: saved) else { return false }
            launcher.adopt(.yahtzee(controller))
        case .zilch:
            guard let (_, saved) = SaveSlots.read(kind: .dice(.zilch), as: ZilchSaveState.self),
                  let controller = ZilchController(host: host, restoring: saved) else { return false }
            launcher.adopt(.zilch(controller))
        case .shutTheBox:
            guard let (_, saved) = SaveSlots.read(kind: .dice(.shutTheBox), as: ShutBoxSaveState.self),
                  let controller = ShutBoxController(host: host, restoring: saved) else { return false }
            launcher.adopt(.shutBox(controller))
        }
        return true
    }

    /// The envelope seats for a dice game, from the controller's own seat
    /// list (which already remembers each phone's durable deviceID).
    static func envelopeSeats(_ seats: [DiceSavedSeat]) -> [SeatSpecCodable] {
        seats.map { SeatSpecCodable(id: $0.id, name: $0.name, isBot: $0.isBot, deviceID: $0.deviceID) }
    }

    /// "Round 3 · Mae leads 42-31" from a name/score list (higher wins).
    static func leaderSubtitle(prefix: String, standings: [(name: String, score: Int)]) -> String {
        let ranked = standings.sorted { $0.score > $1.score }
        guard ranked.count >= 2 else { return prefix }
        if ranked[0].score == ranked[1].score { return "\(prefix) · tied at \(ranked[0].score)" }
        return "\(prefix) · \(ranked[0].name) leads \(ranked[0].score)-\(ranked[1].score)"
    }
}
