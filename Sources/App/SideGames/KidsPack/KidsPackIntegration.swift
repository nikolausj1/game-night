import SwiftUI

/// Everything the lead needs to plug the kids' pack in, in one place, so
/// integration is a handful of one-liners and no file in here needs to be
/// edited again.
///
/// 1. Registry (SideGameHost.swift) - merge the three entries:
///    ```swift
///    static let entries: [String: Entry] = [ /* other games */ ]
///        .merging(KidsPackIntegration.registryEntries) { current, _ in current }
///    ```
///    or add the three literal lines (see the bottom of this comment).
///
/// 2. Launching (menu): ONE call per game, any seat count the game allows:
///    ```swift
///    KidsPackIntegration.startGoFish(on: host, seats: specs)    // 2-4 seats
///    KidsPackIntegration.startOldMaid(on: host, seats: specs)   // 2-4 seats
///    KidsPackIntegration.startWar(on: host, seats: specs)       // exactly 2 seats
///    ```
///    which are just `host.startSideGame(seats: specs, seed: seed) { GoFishHost(seats: $0, seed: $1) }`.
///
/// 3. Sim-verify harness (TableRootView.onAppear, next to -autoStartCribbage):
///    ```swift
///    KidsPackIntegration.autoStartIfRequested(host)
///    ```
///    handles `-autoStartGoFish`, `-autoStartOldMaid`, `-autoStartWar`
///    (all-bot tables that play themselves; Go Fish/Old Maid 3 bots, War 2).
///
/// The literal registry lines, if you prefer them:
/// ```swift
/// "goFish":  Entry(table: { AnyView(GoFishTableView(host: $0, onClose: $1)) },
///                  hand:  { AnyView(GoFishHandView(client: $0)) }),
/// "oldMaid": Entry(table: { AnyView(OldMaidTableView(host: $0, onClose: $1)) },
///                  hand:  { AnyView(OldMaidHandView(client: $0)) }),
/// "war":     Entry(table: { AnyView(WarTableView(host: $0, onClose: $1)) },
///                  hand:  { AnyView(WarHandView(client: $0)) }),
/// ```
enum KidsPackIntegration {
    static let registryEntries: [String: SideGameRegistry.Entry] = [
        GoFishEngine.kind: SideGameRegistry.Entry(
            table: { AnyView(GoFishTableView(host: $0, onClose: $1)) },
            hand: { AnyView(GoFishHandView(client: $0)) },
            restore: { GoFishHost(restoring: $0, seats: $1) },
            fresh: { GoFishHost(seats: $0, seed: $1) }),
        OldMaidEngine.kind: SideGameRegistry.Entry(
            table: { AnyView(OldMaidTableView(host: $0, onClose: $1)) },
            hand: { AnyView(OldMaidHandView(client: $0)) },
            restore: { OldMaidHost(restoring: $0, seats: $1) },
            fresh: { OldMaidHost(seats: $0, seed: $1) }),
        WarEngine.kind: SideGameRegistry.Entry(
            table: { AnyView(WarTableView(host: $0, onClose: $1)) },
            hand: { AnyView(WarHandView(client: $0)) },
            restore: { WarHost(restoring: $0, seats: $1) },
            fresh: { WarHost(seats: $0, seed: $1) }),
    ]

    private static func randomSeed() -> UInt64 { UInt64.random(in: UInt64.min...UInt64.max) }

    static func startGoFish(on host: GameHostController, seats: [SeatSpec], seed: UInt64? = nil) {
        host.startSideGame(seats: seats, seed: seed ?? randomSeed()) { GoFishHost(seats: $0, seed: $1) }
    }

    static func startOldMaid(on host: GameHostController, seats: [SeatSpec], seed: UInt64? = nil) {
        host.startSideGame(seats: seats, seed: seed ?? randomSeed()) { OldMaidHost(seats: $0, seed: $1) }
    }

    static func startWar(on host: GameHostController, seats: [SeatSpec], seed: UInt64? = nil) {
        host.startSideGame(seats: seats, seed: seed ?? randomSeed()) { WarHost(seats: $0, seed: $1) }
    }

    /// Sim-verify hook. Returns true when a launch argument started a game.
    @discardableResult
    static func autoStartIfRequested(_ host: GameHostController) -> Bool {
        let args = CommandLine.arguments
        guard host.state == nil, host.sideGame == nil, host.cribbageEngine == nil else { return false }
        func bots(_ n: Int) -> [SeatSpec] {
            BotRoster.random(count: n).enumerated().map { SeatSpec(id: $0.offset, name: $0.element.name, isBot: true) }
        }
        if args.contains("-autoStartGoFish") {
            startGoFish(on: host, seats: bots(3))
            return true
        }
        if args.contains("-autoStartOldMaid") {
            startOldMaid(on: host, seats: bots(3))
            return true
        }
        if args.contains("-autoStartWar") {
            startWar(on: host, seats: bots(2))
            return true
        }
        return false
    }
}
