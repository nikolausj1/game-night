import SwiftUI
import UIKit

/// Transient, phone-only presentation state for a Battleship game: which
/// chart is showing, where the reticle is, the result toast, impact
/// effects, and the shake on a hit to your own board. None of it is game
/// state (the snapshot is the source of truth); it only reacts to the event
/// stream and to taps. Lives in `BattleshipHandContent` so it survives the
/// placement -> battle view swap.
@Observable
final class BattleshipPhoneModel {
    enum Page: Hashable { case targeting, fleet }

    struct Toast: Identifiable, Equatable {
        enum Tone { case hit, miss, sunk, info, warning }
        let id = UUID()
        var text: String
        var tone: Tone
        var detail: String?
    }

    var page: Page = .targeting
    var aim: BattleshipCell?
    var toast: Toast?
    var targetEffects: [ChartEffect] = []
    var fleetEffects: [ChartEffect] = []
    /// Bumped (inside `withAnimation`) to shake the own-fleet chart.
    var shakeCount: CGFloat = 0
    /// True between sending FIRE and the host's answer, so a double-tap
    /// can't fire twice.
    var awaitingFire = false
    /// Previews / render harness: charts skip entrance animations.
    var freeze = false
    var lastSerial = 0
    /// Invalidates a pending "swing back to targeting" when the turn moves on.
    var turnToken = UUID()

    /// New game on the same phone: drop everything transient.
    func reset() {
        page = .targeting
        aim = nil
        toast = nil
        targetEffects = []
        fleetEffects = []
        awaitingFire = false
    }

    // MARK: toast + effects

    func show(_ toast: Toast, for seconds: Double = 2.4) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { self.toast = toast }
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
        }
    }

    private func addEffect(_ kind: ChartEffectKind, at cell: BattleshipCell, onTarget: Bool) {
        let effect = ChartEffect(cell: cell, kind: kind)
        if onTarget { targetEffects.append(effect) } else { fleetEffects.append(effect) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.targetEffects.removeAll { $0.id == effect.id }
            self?.fleetEffects.removeAll { $0.id == effect.id }
        }
    }

    // MARK: event stream

    /// Folds one event batch into the presentation. `mySeat` decides whose
    /// shot it was; the phone never learns anything the snapshot doesn't
    /// already allow (events are public).
    func ingest(_ batch: BattleshipEventBatch, mySeat: Int, reduceMotion: Bool) {
        // `!=` not `>`: a rematch restarts the host's serial at 1.
        guard batch.serial != lastSerial else { return }
        lastSerial = batch.serial
        for event in batch.events {
            switch event {
            case .shotFired(let seat, let cell, let result, _):
                if seat == mySeat {
                    aim = nil
                    awaitingFire = false
                    addEffect(result.isHit ? .burst : .splash, at: cell, onTarget: true)
                    switch result {
                    case .miss:
                        Haptics.tick()
                        show(Toast(text: "Splash. Miss.", tone: .miss, detail: battleshipCellName(cell)), for: 1.8)
                    case .hit:
                        Haptics.arm()
                        show(Toast(text: "Direct hit!", tone: .hit, detail: battleshipCellName(cell)), for: 1.8)
                    case .sunk(let kind):
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        show(Toast(text: "You sunk their \(kind.displayName)!", tone: .sunk, detail: battleshipCellName(cell)), for: 2.8)
                    }
                } else {
                    // Their shot lands on my board: show it there.
                    page = .fleet
                    addEffect(result.isHit ? .burst : .splash, at: cell, onTarget: false)
                    switch result {
                    case .miss:
                        Haptics.tick()
                        show(Toast(text: "They missed", tone: .miss, detail: battleshipCellName(cell)), for: 2.0)
                    case .hit:
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        shake(reduceMotion: reduceMotion)
                        show(Toast(text: "They hit you!", tone: .hit, detail: battleshipCellName(cell)), for: 2.2)
                    case .sunk(let kind):
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        shake(reduceMotion: reduceMotion)
                        show(Toast(text: "They sunk your \(kind.displayName)!", tone: .sunk, detail: battleshipCellName(cell)), for: 3.0)
                    }
                }
            case .battleBegan:
                show(Toast(text: "Battle stations!", tone: .info), for: 2.0)
            case .illegalAttempt(let seat, let reason):
                guard seat == mySeat else { continue }
                awaitingFire = false
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                show(Toast(text: reason, tone: .warning), for: 2.0)
            case .gameWon(let seat):
                UINotificationFeedbackGenerator().notificationOccurred(seat == mySeat ? .success : .error)
            default:
                break
            }
        }
    }

    private func shake(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.5)) { shakeCount += 1 }
    }
}
