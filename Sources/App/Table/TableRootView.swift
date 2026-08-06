import SwiftUI

/// The iPad. Menu until the host taps Deal, then the felt stage.
struct TableRootView: View {
    @State private var host = GameHostController()
    @State private var announcer = AnnouncerDirectorHolder()
    @State private var callouts = TableCalloutWireHolder()
    @State private var autoSave = GameStateAutoSaveHolder()
    @State private var bots = BotDirector()

    /// Dice games live outside the card engine; the launcher is the switch.
    @State private var diceLauncher = DiceLauncher.shared

    var body: some View {
        ZStack {
            TableSurface()
            if let dice = diceLauncher.controller {
                DiceTableView(controller: dice, onClose: { diceLauncher.end() })
            } else if host.state == nil {
                MenuView(host: host)
            } else {
                TableGameView(host: host, calloutCenter: callouts.center, onClose: {
                    // Autosave already has the latest state; just fold the
                    // table. The save shows up as a resume card on the menu.
                    GameStateStore.saveCurrent(host: host)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        host.closeTable()
                    }
                })
                .environment(\.unoDeckStyle, host.state?.gameKind == .uno)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // the table never sleeps
            announcer.wire(to: host)
            callouts.wire(to: host)
            autoSave.wire(to: host)
            bots.wire(to: host)
            SharedHost.controller = host // TV spectator reads through this
            if DemoData.wantsTableDemo, host.state == nil {
                host.adoptDemoEngine(DemoData.makeTableEngine())
            }
            if DemoData.wantsFreePlayDemo, host.state == nil {
                host.adoptDemoEngine(DemoData.makeFreePlayEngine())
                // One card face-down so screenshots exercise the back.
                if let first = host.state?.discardPile.first {
                    host.faceDownCards.insert(first.id)
                }
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Holds the callout wiring (same shape as AnnouncerDirectorHolder):
/// one TableCalloutCenter for the table's lifetime, chained once onto
/// host.onEvents — TableGameView re-inits must never re-chain or the
/// closure list would grow a stale center per game.
@Observable
final class TableCalloutWireHolder {
    let center = TableCalloutCenter()
    private var wired = false
    /// Seat of the last wild (or wild eight) played: `suitDeclared` carries
    /// no seat of its own, and by the time it fires the choosingTrump phase
    /// has already moved on — the declarer is whoever played that wild.
    private var lastWildSeat: Int?

    func wire(to host: GameHostController) {
        guard !wired else { return }
        wired = true
        let previous = host.onEvents
        host.onEvents = { [weak self, center] events in
            previous?(events)
            guard let state = host.state else { return }
            for event in events {
                if case .cardPlayed(let seat, let card, _) = event {
                    switch card.kind {
                    case .uno(color: nil, _): self?.lastWildSeat = seat
                    case .standard(_, 8) where state.gameKind == .crazyEights:
                        self?.lastWildSeat = seat
                    default: break
                    }
                }
                center.post(event: event, seatName: { seat in
                    state.seats.indices.contains(seat)
                        ? state.seats[seat].playerName : ""
                }, declaringSeat: self?.lastWildSeat)
            }
        }
    }
}

/// Holds the announcer wiring so TableRootView stays declarative.
/// AnnouncerDirector maps GameEvents → announcer + SFX calls.
@Observable
final class AnnouncerDirectorHolder {
    private var wired = false

    func wire(to host: GameHostController) {
        guard !wired else { return }
        wired = true
        let previous = host.onEvents
        host.onEvents = { events in
            previous?(events)
            AnnouncerDirector.shared.handle(events: events, state: host.state)
        }
    }
}
