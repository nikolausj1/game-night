import SwiftUI

/// The iPad. Menu until the host taps Deal, then the felt stage.
struct TableRootView: View {
    @State private var host = GameHostController()
    @State private var announcer = AnnouncerDirectorHolder()
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
                TableGameView(host: host, onClose: {
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
