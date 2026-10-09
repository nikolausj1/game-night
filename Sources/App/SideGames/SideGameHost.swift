import SwiftUI

/// A table-hosted game that lives outside the card engine and speaks the
/// generic `SideGamePayload` wire. Conformers own their rules, their bots,
/// and their pacing; `GameHostController` owns seats, peers, and routing.
///
/// Contract:
/// - `handle(action:from:)` decodes the game's own action type from the
///   payload and applies it for that seat (ignore unknown/illegal input).
/// - `state(for:)` returns the seat's REDACTED state as a payload (what
///   that phone may see). Called after every mutation for every seated
///   phone, and again on reconnect.
/// - Call `onChanged?()` after every mutation (including bot moves and
///   timers) — that is the ONLY way the host learns to re-broadcast and
///   bump `stateVersion` for the table UI.
/// - `end()` stops timers; the host clears routing.
///
/// Save/resume (`Sources/App/Save`): `snapshot()` returns the game's own
/// Codable state as bytes — nil once the game is over (nothing to resume)
/// or for a kind that doesn't save. The host controller autosaves it 2s
/// after the last `onChanged`, and the registry's `restore` closure is the
/// way back: same bytes, same seats, a live host again. `resumeTitle` /
/// `resumeSubtitle` are the lobby card's two lines.
protocol SideGameHost: AnyObject {
    /// Registry key; matches the engine's `static let kind`.
    var kind: String { get }
    /// Fired by the game after every state mutation. Set by the host.
    var onChanged: (() -> Void)? { get set }
    func handle(action: SideGamePayload, from seat: Int)
    func state(for seat: Int) -> SideGamePayload?
    /// Events from the last mutation, for everyone (nil = none).
    func drainEvents() -> SideGamePayload?
    func end()

    /// The game's resumable state, or nil when there's nothing to resume.
    func snapshot() -> Data?
    /// "Gin Rummy" — the lobby resume card's title.
    var resumeTitle: String { get }
    /// "Hand 3 · Mae leads 120-85" — the lobby resume card's subtitle.
    var resumeSubtitle: String { get }
}

extension SideGameHost {
    func snapshot() -> Data? { nil }
    var resumeTitle: String { ResumeKind.sideGameDisplayName(kind) }
    var resumeSubtitle: String { "" }
}

/// Which SwiftUI views render a given side game on the table and on a
/// phone, plus how it comes back from a save. Each game adds ONE entry
/// here at integration — no other shared file changes. Kind strings must
/// match the engines' `kind`.
enum SideGameRegistry {
    struct Entry {
        let table: (GameHostController, _ onClose: @escaping () -> Void) -> AnyView
        let hand: (GameClientController) -> AnyView
        /// Rebuilds a live host from `snapshot()` bytes for these seats
        /// (nil = this kind never saves, or the bytes are unreadable).
        var restore: ((Data, [SeatSpec]) -> (any SideGameHost)?)? = nil
        /// A brand-new game for a rematch after a resume: same seats, new
        /// seed. (`startSideGame` remembers its own factory for games
        /// started from the menu; a resumed game needs this instead.)
        var fresh: (([SeatSpec], UInt64) -> any SideGameHost)? = nil
    }

    static let entries: [String: Entry] = [
        "battleship": Entry(table: { AnyView(BattleshipTableView(host: $0, onClose: $1)) },
                            hand: { AnyView(BattleshipHandView(client: $0)) },
                            restore: { BattleshipHost(restoring: $0, seats: $1) },
                            fresh: { BattleshipHost(seats: $0, seed: $1) }),
        "ginRummy": Entry(table: { AnyView(GinRummyTableView(host: $0, onClose: $1)) },
                          hand: { AnyView(GinRummyHandView(client: $0)) },
                          restore: { GinRummyHost(restoring: $0, seats: $1) },
                          fresh: { GinRummyHost(seats: $0, seed: $1, names: [:]) }),
        "blackjack": Entry(table: { AnyView(BlackjackTableView(host: $0, onClose: $1)) },
                           hand: { AnyView(BlackjackHandView(client: $0)) },
                           restore: { BlackjackHost(restoring: $0, seats: $1) },
                           fresh: { BlackjackHost(seats: $0, seed: $1) }),
        "liarsDice": Entry(table: { AnyView(LiarsDiceTableView(host: $0, onClose: $1)) },
                           hand: { AnyView(LiarsDiceHandView(client: $0)) },
                           restore: { LiarsDiceHost(restoring: $0, seats: $1) },
                           fresh: { LiarsDiceHost(seats: $0, seed: $1) }),
    ].merging(KidsPackIntegration.registryEntries) { current, _ in current }

    @ViewBuilder
    static func tableView(kind: String, host: GameHostController, onClose: @escaping () -> Void) -> some View {
        if let entry = entries[kind] {
            entry.table(host, onClose)
        } else {
            SideGameMissingView(kind: kind)
        }
    }

    @ViewBuilder
    static func handView(kind: String, client: GameClientController) -> some View {
        if let entry = entries[kind] {
            entry.hand(client)
        } else {
            SideGameMissingView(kind: kind)
        }
    }
}

/// Dev-only fallback so an unregistered kind is loud, not blank.
struct SideGameMissingView: View {
    let kind: String
    var body: some View {
        Text("No view registered for side game “\(kind)”")
            .font(.system(.footnote, design: .serif))
            .foregroundStyle(CardStyle.gold)
            .padding()
    }
}
