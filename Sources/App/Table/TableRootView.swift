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
            if let game = diceLauncher.game {
                switch game {
                case .lcr(let c):
                    DiceTableView(controller: c, onClose: { diceLauncher.end() })
                case .yahtzee(let c):
                    YahtzeeTableView(controller: c, onClose: { diceLauncher.end() })
                case .zilch(let c):
                    ZilchTableView(controller: c, onClose: { diceLauncher.end() })
                case .shutBox(let c):
                    ShutBoxTableView(controller: c, onClose: { diceLauncher.end() })
                }
            } else if let sideGame = host.sideGame {
                // Generic side games (Battleship, Gin Rummy, ...): the
                // registry picks the table view by kind. Checked before
                // the menu like cribbage — `host.state` stays nil.
                SideGameRegistry.tableView(kind: sideGame.kind, host: host,
                                           onClose: { host.closeTable() })
            } else if host.cribbageEngine != nil {
                // Cribbage lives outside the card engine, same coexistence
                // rule as dice above: `host.state` stays nil the whole
                // time, so this branch has to come before the menu check.
                CribbageTableView(host: host, onClose: { host.closeTable() })
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
            // Sim-verify hook, cribbage wave: an all-bot cribbage game that
            // plays itself, reachable without MenuView (which doesn't have
            // a cribbage launch button yet — see BotRoster for the two
            // names). Mirrors MenuView's own `-autoStartLcr`/`-autoStartUno`
            // hooks; lives here instead since MenuView isn't this wave's
            // file to edit.
            // Side-game harnesses (overnight 2): all-bot tables that play
            // themselves, reachable without MenuView. Each guards on an
            // idle table exactly like -autoStartCribbage below.
            if host.state == nil, host.sideGame == nil, host.cribbageEngine == nil {
                _ = KidsPackIntegration.autoStartIfRequested(host)
            }
            if CommandLine.arguments.contains("-autoStartLiarsDice"),
               host.state == nil, host.sideGame == nil, host.cribbageEngine == nil {
                LiarsDiceHost.launchAllBotDemo(on: host)
            }
            if CommandLine.arguments.contains("-autoStartBlackjack"),
               host.state == nil, host.sideGame == nil, host.cribbageEngine == nil {
                BlackjackLaunch.start(on: host,
                                      allBots: CommandLine.arguments.contains("-blackjackAllBots"))
            }
            if host.state == nil, host.sideGame == nil, host.cribbageEngine == nil {
                GinRummyLaunch.autoStartIfRequested(host: host) // -autoStartGinRummy
            }
            if CommandLine.arguments.contains("-autoStartBattleship"),
               host.state == nil, host.sideGame == nil, host.cribbageEngine == nil {
                let seats = BotRoster.random(count: 2).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                host.startSideGame(seats: seats, seed: UInt64.random(in: UInt64.min...UInt64.max)) {
                    BattleshipHost(seats: $0, seed: $1)
                }
            }
            if CommandLine.arguments.contains("-autoStartCribbage"),
               host.state == nil, host.cribbageEngine == nil {
                let bots = BotRoster.random(count: 2)
                let seats = bots.enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                host.startCribbage(seats: seats, seed: UInt64.random(in: UInt64.min...UInt64.max))
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
