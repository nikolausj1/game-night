import Foundation

/// Screenshot-verification harness for Dots & Boxes, mirroring
/// `Sources/App/DemoData.swift`'s pattern for the other games (`-demoTable`,
/// `-demoHand`, `-demoFreePlay`) — but living here instead of that file,
/// since this game's build task's permitted file set doesn't include
/// `DemoData.swift` itself.
///
/// NOT WIRED YET. The menu/routing worker should hook this up the same way
/// the existing demo flags are hooked up:
///   - `RoleRouter`'s `role` initializer: treat `DotsAndBoxesDemoData.wantsDemo`
///     like `DemoData.wantsTableDemo` (routes straight to `.table`, skipping
///     the role picker).
///   - `TableRootView.body`: mount `DotsAndBoxesView(onClose: ...)` the same
///     place `DiceTableView` is mounted (both are "games that live outside
///     the card engine" — see `DiceLauncher` for the sibling pattern), and
///     in `.onAppear`, when `DotsAndBoxesDemoData.wantsDemo` is set, seed it
///     with `DotsAndBoxesDemoData.makeMidGameController()` instead of
///     showing the setup overlay.
enum DotsAndBoxesDemoData {
    static var wantsDemo: Bool { CommandLine.arguments.contains("-demoDotsAndBoxes") }

    /// A 4-player, 4x4 game a few real moves in — two humans, two bots,
    /// one box already completed and initialed — so a screenshot shows
    /// actual pencil texture and a real handwritten letter, not an empty
    /// sheet. Everything flows through the real engine via `controller`,
    /// same "script inputs, never fake render state" rule `DemoData`
    /// documents for the card games.
    static func makeMidGameController() -> DotsAndBoxesController {
        let players = (0..<4).map { index in
            DotsAndBoxesPlayer(name: DemoData.names[index % DemoData.names.count],
                               colorIndex: index, isBot: index >= 2)
        }
        let controller = DotsAndBoxesController(gridSize: 4, players: players, seed: 20260806)

        // Complete box (0,0), then leave a few more lines down for texture —
        // drawn through the real `claim` path, always by whoever the engine
        // says is actually on turn right now (never a hardcoded seat), so
        // extra-turn bookkeeping stays honest exactly like `DemoData`'s
        // trick-game scripting does. NOTE: because two of the four seats
        // are bots, if this synchronous script happens to leave turnIndex on
        // a bot, that bot's own 0.75s-delayed move will still fire shortly
        // after this returns — take the screenshot promptly, or drive the
        // script further until turnIndex lands back on a human seat.
        let scripted: [DotsAndBoxesEdge] = [
            DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), // top of (0,0)
            DotsAndBoxesEdge(orientation: .horizontal, row: 1, col: 0), // bottom of (0,0)
            DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0),   // left of (0,0)
            DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 1),   // right of (0,0) — completes it, extra turn
            DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 2), // an unrelated open line
            DotsAndBoxesEdge(orientation: .vertical, row: 2, col: 3),   // another open line
        ]
        for edge in scripted {
            controller.claim(edge, by: controller.state.turnIndex)
        }
        return controller
    }
}
