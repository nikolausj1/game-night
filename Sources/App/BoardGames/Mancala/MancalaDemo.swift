import Foundation

/// Launch-argument demo hooks, for sim screenshot verification.
///
///   `-demoMancala`       drops straight into a scripted mid-game table
///                        (human vs human, near seat to move), skipping setup.
///   `-demoMancalaBots`   same table but BOTH seats are bots, so the sowing /
///                        capture / extra-turn / sweep choreography plays
///                        continuously and can be screenshotted mid-flight.
///   `-demoMancalaSow`    human vs bot mid-game, and the near seat's pit 3 is
///                        sown automatically 1.2 s after appearing, so a
///                        single launch captures a sowing without any tap.
///
/// NOT wired into `RoleRouter` / `MenuView` / `TableRootView` (outside this
/// worker's scope): the lead only needs to mount `MancalaView(onClose:)`
/// somewhere reachable. `MancalaView` itself reads these flags on appear.
enum MancalaDemo {
    static var wantsDemo: Bool {
        let args = CommandLine.arguments
        return args.contains("-demoMancala") || args.contains("-demoMancalaBots") || args.contains("-demoMancalaSow")
    }

    /// Non-nil only when a demo flag is present.
    static func controllerIfRequested() -> MancalaController? {
        let args = CommandLine.arguments
        if args.contains("-demoMancalaBots") { return makeMidGameController(bots: [true, true]) }
        if args.contains("-demoMancalaSow") {
            let controller = makeMidGameController(bots: [false, true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { controller.sow(localPit: 3) }
            return controller
        }
        if args.contains("-demoMancala") { return makeMidGameController(bots: [false, false]) }
        return nil
    }

    /// A short legal script through the REAL engine (never hand-faked board
    /// state), adopted without replaying sound or animation.
    static func makeMidGameController(bots: [Bool] = [false, false]) -> MancalaController {
        let players = [MancalaPlayer(name: "Justin", isBot: bots[0]), MancalaPlayer(name: "Sarah", isBot: bots[1])]
        let engine = MancalaEngine(players: players, firstPlayer: 0)
        // Each entry is a LOCAL pit for whoever is to move (extra turns keep
        // the same seat, so the sequence is walked, not assumed).
        for pit in [2, 1, 3, 0, 4, 2, 5, 1, 3] {
            guard engine.state.phase == .playing else { break }
            let legal = engine.state.legalPits
            let choice = legal.contains(pit) ? pit : (legal.first ?? 0)
            _ = engine.apply(.sow(pit: choice), from: engine.state.currentPlayer)
        }
        return MancalaController(restoring: engine.state)
    }
}
