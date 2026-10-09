import Foundation

/// Launch-argument demo hooks for sim screenshot verification.
///
///   `-demoConnectFour`       scripted mid-game: a dozen discs through the
///                            real engine, human vs human, near seat to move.
///   `-demoConnectFourBots`   both seats bots: continuous play, so aiming
///                            glides, falls, bounces and the winning pulse all
///                            happen on their own.
///   `-demoConnectFourWin`    a finished game with a winning line, so the
///                            pulse and banner can be screenshotted.
///
/// Not routed from `RoleRouter` / `MenuView` here; the lead mounts
/// `ConnectFourView(onClose:)` and the view reads these on appear.
enum ConnectFourDemo {
    static var wantsDemo: Bool {
        let a = CommandLine.arguments
        return a.contains("-demoConnectFour") || a.contains("-demoConnectFourBots") || a.contains("-demoConnectFourWin")
    }

    static func controllerIfRequested() -> ConnectFourController? {
        let a = CommandLine.arguments
        if a.contains("-demoConnectFourBots") { return makeMidGameController(bots: [true, true]) }
        if a.contains("-demoConnectFourWin") { return makeWonController() }
        if a.contains("-demoConnectFour") { return makeMidGameController(bots: [false, false]) }
        return nil
    }

    static func makeMidGameController(bots: [Bool] = [false, false]) -> ConnectFourController {
        let players = [ConnectFourPlayer(name: "Justin", isBot: bots[0]), ConnectFourPlayer(name: "Sarah", isBot: bots[1])]
        let engine = ConnectFourEngine(players: players, firstPlayer: 0)
        for column in [3, 3, 2, 4, 4, 2, 5, 1, 3, 4, 0, 5] {
            guard engine.state.phase == .playing else { break }
            _ = engine.apply(.drop(column: column), from: engine.state.currentPlayer)
        }
        return ConnectFourController(restoring: engine.state)
    }

    /// Red stacks four across the bottom while yellow plays elsewhere.
    static func makeWonController() -> ConnectFourController {
        let players = [ConnectFourPlayer(name: "Justin", isBot: false), ConnectFourPlayer(name: "Sarah", isBot: false)]
        let engine = ConnectFourEngine(players: players, firstPlayer: 0)
        for column in [0, 0, 1, 1, 2, 2, 3] {
            _ = engine.apply(.drop(column: column), from: engine.state.currentPlayer)
        }
        return ConnectFourController(restoring: engine.state)
    }
}
