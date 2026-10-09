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
}

/// Which SwiftUI views render a given side game on the table and on a
/// phone. Each game adds ONE line to `entries` at integration — no other
/// shared file changes. Kind strings must match the engines' `kind`.
enum SideGameRegistry {
    struct Entry {
        let table: (GameHostController, _ onClose: @escaping () -> Void) -> AnyView
        let hand: (GameClientController) -> AnyView
    }

    /// Populated at integration time, one line per game, e.g.
    ///   "battleship": Entry(table: { AnyView(BattleshipTableView(host: $0, onClose: $1)) },
    ///                       hand:  { AnyView(BattleshipHandView(client: $0)) }),
    static let entries: [String: Entry] = [
        "battleship": Entry(table: { AnyView(BattleshipTableView(host: $0, onClose: $1)) },
                            hand: { AnyView(BattleshipHandView(client: $0)) }),
        "ginRummy": Entry(table: { AnyView(GinRummyTableView(host: $0, onClose: $1)) },
                          hand: { AnyView(GinRummyHandView(client: $0)) }),
        "blackjack": Entry(table: { AnyView(BlackjackTableView(host: $0, onClose: $1)) },
                           hand: { AnyView(BlackjackHandView(client: $0)) }),
        "liarsDice": Entry(table: { AnyView(LiarsDiceTableView(host: $0, onClose: $1)) },
                           hand: { AnyView(LiarsDiceHandView(client: $0)) }),
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
