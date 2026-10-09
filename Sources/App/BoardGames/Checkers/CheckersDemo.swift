import Foundation

/// Launch-argument demo hooks for sim screenshot verification.
///
///   `-demoCheckers`       scripted mid-game (human vs human, near seat to
///                         move, a capture available so the glowing jump
///                         squares and the forced-capture rule can be seen).
///   `-demoCheckersBots`   both seats bots: continuous bot play, so hops,
///                         multi-jumps, tumbling captures and crowns happen
///                         on their own.
///
/// Not routed from `RoleRouter` / `MenuView` here; the lead mounts
/// `CheckersView(onClose:)` and `CheckersView` reads these on appear.
enum CheckersDemo {
    static var wantsDemo: Bool {
        CommandLine.arguments.contains("-demoCheckers") || CommandLine.arguments.contains("-demoCheckersBots")
    }

    static func controllerIfRequested() -> CheckersController? {
        if CommandLine.arguments.contains("-demoCheckersBots") { return makeMidGameController(bots: [true, true]) }
        if CommandLine.arguments.contains("-demoCheckers") { return makeMidGameController(bots: [false, false]) }
        return nil
    }

    /// Plays the REAL bot against itself for a handful of plies (depth-capped
    /// for speed) so the position is a genuine one, then stops with the near
    /// seat to move.
    static func makeMidGameController(bots: [Bool] = [false, false]) -> CheckersController {
        let players = [CheckersPlayer(name: "Justin", isBot: bots[0]), CheckersPlayer(name: "Sarah", isBot: bots[1])]
        let engine = CheckersEngine(players: players, firstPlayer: 0)
        var ply = 0
        while ply < 16, engine.state.phase == .playing {
            let action = CheckersBot.decide(state: engine.state, seed: UInt64(ply) &+ 11, maxDepth: 2, nodeBudget: 2_000)
            _ = engine.apply(action, from: engine.state.currentPlayer)
            ply += 1
        }
        // Land on the near seat's turn.
        if engine.state.phase == .playing, engine.state.currentPlayer == 1 {
            let action = CheckersBot.decide(state: engine.state, seed: 99, maxDepth: 2, nodeBudget: 2_000)
            _ = engine.apply(action, from: 1)
        }
        return CheckersController(restoring: engine.state)
    }
}
