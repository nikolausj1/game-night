import Foundation
import Observation

/// One card on the lobby's "Pick Up Where You Left Off" strip, whatever
/// kind of game it is.
struct ResumeEntry: Identifiable, Equatable {
    /// Stable per suspended game: the `SavedGame.id` for engine games, the
    /// `ResumeKind.slotKey` for everything else.
    let id: String
    /// "Yahtzee", "Gin Rummy", "Wizard".
    let title: String
    /// "Round 3 · Mae leads 42-31", "Hand 5 · you're up".
    let subtitle: String
    let savedAt: Date
    let kind: ResumeKind
}

/// Where the menu must send a resumed LOCAL (table-only, no host) game.
/// These games own their own full-screen flow, so the menu just mounts
/// the view with `resumeSaved: true` and the view picks its state back up.
enum LocalResumeRoute: String, Identifiable, Hashable {
    case solitaire, dotsAndBoxes, quarto, mancala, checkers, connectFour
    var id: String { rawValue }
}

/// Every resumable game in the app, in one list, for the lobby.
///
/// MENU CONTRACT (for whoever renders the resume strip):
///
///   1. Read `ResumeCatalog.shared.entries` (observable; call
///      `refresh()` in `onAppear`). Render one card per entry: `title`,
///      `subtitle`, `savedAt` (relative), and a glyph picked by `kind`.
///   2. On tap: `let route = ResumeCatalog.shared.resume(entry, host: host)`.
///      - `nil`   → the game is now live on `host` / `DiceLauncher`
///                  (`TableRootView` already routes by `host.state`,
///                  `host.sideGame`, `host.cribbageEngine`,
///                  `DiceLauncher.shared.game` — nothing else to do), OR
///                  the save was stale and has been discarded (the strip
///                  refreshes itself).
///      - `.some(route)` → a LOCAL game: set the menu's full-screen cover
///                  to that route and build the view with
///                  `resumeSaved: true`, e.g.
///                  `SolitaireView(onClose: …, resumeSaved: true)`,
///                  `MancalaView(onClose: …, resumeSaved: true)`.
///   3. Long-press/ⓧ: `ResumeCatalog.shared.delete(entry)`.
///
/// Engine games keep their original `GameStateStore` files; this catalog
/// merges them with the per-kind `SaveSlots` so the strip is one list.
@Observable
final class ResumeCatalog {
    static let shared = ResumeCatalog()

    private(set) var entries: [ResumeEntry] = []

    private init() {}

    /// Rebuilds `entries` from disk (cheap: a handful of small files).
    func refresh() {
        var merged: [ResumeEntry] = GameStateStore.list().map { saved in
            ResumeEntry(id: saved.id,
                        title: saved.gameKind.displayName,
                        subtitle: Self.hostEngineSubtitle(saved),
                        savedAt: saved.savedAt,
                        kind: .hostEngine(saved.gameKind))
        }
        merged += SaveSlots.all().map { envelope in
            ResumeEntry(id: envelope.kind.slotKey,
                        title: envelope.title,
                        subtitle: envelope.subtitle,
                        savedAt: envelope.savedAt,
                        kind: envelope.kind)
        }
        entries = merged.sorted { $0.savedAt > $1.savedAt }
    }

    /// Stores call this after every write/delete so an open lobby updates.
    func noteChanged() {
        refresh()
    }

    func delete(_ entry: ResumeEntry) {
        switch entry.kind {
        case .hostEngine:
            if let saved = GameStateStore.list().first(where: { $0.id == entry.id }) {
                GameStateStore.delete(saved)
            }
        default:
            SaveSlots.clear(kind: entry.kind)
        }
        refresh()
    }

    /// Resumes a HOSTED game onto `host` (engine, cribbage, side game,
    /// dice) and returns nil; for a LOCAL game, touches nothing and
    /// returns the route the menu must open with `resumeSaved: true`.
    @discardableResult
    func resume(_ entry: ResumeEntry, host: GameHostController) -> LocalResumeRoute? {
        switch entry.kind {
        case .hostEngine:
            if let saved = GameStateStore.list().first(where: { $0.id == entry.id }) {
                saved.resume(into: host)
            }
            refresh()
            return nil
        case .cribbage:
            _ = CribbageSave.resume(into: host)
            refresh()
            return nil
        case .sideGame(let kind):
            _ = SideGameSave.resume(kind: kind, into: host)
            refresh()
            return nil
        case .dice(let kind):
            _ = DiceSave.resume(kind: kind, host: host)
            refresh()
            return nil
        case .board, .solitaire:
            return localRoute(for: entry)
        }
    }

    /// The menu route for a local entry (nil for hosted kinds).
    func localRoute(for entry: ResumeEntry) -> LocalResumeRoute? {
        switch entry.kind {
        case .solitaire: return .solitaire
        case .board(let kind): return LocalResumeRoute(rawValue: kind)
        default: return nil
        }
    }

    /// "Round 3 · Mae leads 42-31" for the scored games, "Round 2 · Hank
    /// is up" otherwise. Derived from `GameState` alone, the same way the
    /// round recap scores it.
    static func hostEngineSubtitle(_ saved: SavedGame) -> String {
        let state = saved.state
        if state.gameKind.isTrickTaking, !state.roundHistory.isEmpty {
            let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind,
                                        missScoresTricks: state.rules.missScoresTricks)
            let ranked = state.seats
                .map { (name: $0.playerName, total: totals[$0.id] ?? 0) }
                .sorted { $0.total > $1.total }
            if ranked.count >= 2 {
                return "Round \(state.roundHistory.count + 1) · \(ranked[0].name) leads \(ranked[0].total)-\(ranked[1].total)"
            }
        }
        if let round = state.round, let seat = state.seats.first(where: { $0.id == round.turnSeat }) {
            return "Round \(round.roundNumber) · \(seat.playerName) is up"
        }
        let count = state.seats.count
        return "\(count) player\(count == 1 ? "" : "s")"
    }
}
