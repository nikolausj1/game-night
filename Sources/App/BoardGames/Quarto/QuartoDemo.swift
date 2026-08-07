import Foundation

/// Launch-arg demo state for screenshot verification: `-demoQuarto` drops
/// straight into a mid-game table instead of the setup overlay. Same
/// philosophy as `DemoData` (App/DemoData.swift) for the card games —
/// everything is driven through the REAL engine, never hand-faked render
/// state — but scripted against `QuartoEngine` directly (not through
/// `QuartoController.perform`) so building the position doesn't fire a
/// table-knock sound effect for every setup step before the view has even
/// appeared.
///
/// NOT wired into `RoleRouter`/`MenuView`/`TableRootView` by this file —
/// those are outside this worker's file scope. `QuartoView` checks
/// `QuartoDemo.wantsQuartoDemo` itself and, if set, skips its own setup
/// overlay and adopts `QuartoDemo.makeMidGameController()` on appear; the
/// menu worker still needs to add a launch route to `QuartoView` itself
/// (e.g. a case in TableRootView alongside `DiceLauncher`) before
/// `-demoQuarto` is reachable from a cold launch.
enum QuartoDemo {
    static var wantsQuartoDemo: Bool { CommandLine.arguments.contains("-demoQuarto") }

    /// A short, legal, hand-scripted sequence — open, place three pieces
    /// (verified not to accidentally complete a line), leave a fourth
    /// piece held so the felt-well ceremony has something to show
    /// immediately.
    static func makeMidGameController() -> QuartoController {
        let players = [QuartoPlayer(name: "Justin", isBot: false), QuartoPlayer(name: "Sarah", isBot: false)]
        let engine = QuartoEngine(players: players, use2x2Variant: false, firstPlayer: 0)

        let script: [QuartoAction] = [
            .selectPiece(0),         // P0 gives piece 0 to P1
            .placePiece(0, at: 5),   // P1 places, then must select
            .selectPiece(15),        // P1 gives piece 15 to P0
            .placePiece(15, at: 10), // P0 places, then must select
            .selectPiece(3),         // P0 gives piece 3 to P1
            .placePiece(3, at: 6),   // P1 places, then must select
            .selectPiece(9),         // P1 gives piece 9 to P0 — left HELD, ready to place
        ]
        for action in script {
            let seat = engine.state.currentPlayer
            _ = engine.apply(action, from: seat)
        }
        return QuartoController(restoring: engine.state)
    }
}
