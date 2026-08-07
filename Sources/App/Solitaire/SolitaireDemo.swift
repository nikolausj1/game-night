import Foundation

/// Sim-verify hook for Solitaire, mirroring `DemoData`'s `-demoTable`/
/// `-demoHand` convention (`Sources/App/DemoData.swift`) but living here
/// instead: this worker's file allowlist doesn't cover `DemoData.swift`,
/// `RoleRouter.swift`, or `TableRootView.swift`, so the actual routing has
/// to be wired by whoever integrates `SolitaireView` into the app. This
/// type is that integration point — fully self-contained and ready to call.
///
/// Integration, for the menu/lead worker wiring `SolitaireView` in:
/// - Wherever `-demoTable`/`-demoHand` are checked today (see
///   `RoleRouter.role`'s initial-value closure), add a branch ahead of the
///   normal role switch:
///   ```
///   if SolitaireDemo.wantsDemo {
///       SolitaireView(onClose: { /* pop back to the menu */ })
///   }
///   ```
/// - That's the entire integration. `SolitaireView` reads
///   `SolitaireDemo.wantsDemo` itself too and seeds its own board from
///   `SolitaireDemo.makeDemoEngine()` when true — the router only has to
///   ROUTE to the view, it never needs to know anything about solitaire's
///   internal state to do it, same contract `-demoTable`/`-demoHand`
///   already follow for their own views.
enum SolitaireDemo {
    static var wantsDemo: Bool { CommandLine.arguments.contains("-demoSolitaire") }

    /// A real seeded mid-game, entirely engine-driven — no faked state.
    /// Seed 20260806, a stock draw and a small handful of opportunistic
    /// legal moves already played, so the screenshot shows piles of
    /// differing depth, at least one foundation started, and cards resting
    /// in the waste rather than a freshly-dealt board.
    static func makeDemoEngine() -> SolitaireEngine {
        let engine = SolitaireEngine(seed: 20260806, drawMode: .drawOne)
        for _ in 0..<3 { _ = engine.draw() }
        playAnyLegalFoundationMove(engine)
        playAnyLegalTableauMove(engine)
        _ = engine.draw()
        playAnyLegalFoundationMove(engine)
        return engine
    }

    /// Sends the first tableau-top or waste-top card that can walk home to
    /// its foundation. A no-op if nothing's currently playable — this seed
    /// only needs to look "mid-game," not hit an exact scripted line.
    private static func playAnyLegalFoundationMove(_ engine: SolitaireEngine) {
        for column in engine.state.tableau.indices {
            guard let top = engine.state.tableau[column].last, top.faceUp,
                  let suit = engine.autoFoundationSuit(for: .tableau(column: column, cardID: top.id))
            else { continue }
            _ = engine.attemptMove(from: .tableau(column: column, cardID: top.id), to: .foundation(suit))
            return
        }
        if let suit = engine.autoFoundationSuit(for: .waste) {
            _ = engine.attemptMove(from: .waste, to: .foundation(suit))
        }
    }

    /// The first legal tableau-to-tableau placement found, if any.
    private static func playAnyLegalTableauMove(_ engine: SolitaireEngine) {
        for sourceColumn in engine.state.tableau.indices {
            guard let top = engine.state.tableau[sourceColumn].last, top.faceUp else { continue }
            for destColumn in engine.state.tableau.indices where destColumn != sourceColumn {
                if engine.attemptMove(from: .tableau(column: sourceColumn, cardID: top.id),
                                      to: .tableau(column: destColumn)) {
                    return
                }
            }
        }
    }
}
