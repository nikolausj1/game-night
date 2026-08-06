import Foundation
import Observation

/// Auto-saves the in-progress game after meaningful beats (a round scored,
/// a trick won, a suit declared), debounced 2s so a burst of events writes
/// once. Deletes the save the instant the game is won — nothing left to
/// resume. Mirrors `AnnouncerDirectorHolder`'s onEvents-chaining pattern so
/// `TableRootView` stays declarative.
@Observable
final class GameStateAutoSaveHolder {
    private var wired = false
    private var pendingSave: DispatchWorkItem?

    func wire(to host: GameHostController) {
        guard !wired else { return }
        wired = true
        let previous = host.onEvents
        host.onEvents = { [weak self, weak host] events in
            previous?(events)
            guard let self, let host else { return }
            for event in events {
                switch event {
                case .gameWon:
                    self.pendingSave?.cancel()
                    GameStateStore.deleteActiveSave(for: host)
                    return
                case .dealt, .cardPlayed, .roundScored, .trickWon, .suitDeclared, .unoCalled, .cardsDrawn,
                     .cardDealt, .topCardFlipped:
                    // The debounce coalesces a burst (e.g. a whole trick's
                    // worth of cardPlayed) into one write, so it's safe to
                    // treat every game-progress event as save-worthy — UNO
                    // and Crazy Eights have no "round" events to key off of.
                    // A drawUntilPlayable pull can move several cards into a
                    // hand with no other event firing, so it's a save
                    // trigger too. topCardFlipped moves a card out of the
                    // draw pile in free play — same felt-state-changed logic.
                    self.scheduleSave(for: host)
                default:
                    break
                }
            }
        }
    }

    private func scheduleSave(for host: GameHostController) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak host] in
            guard let host else { return }
            GameStateStore.saveCurrent(host: host)
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }
}
