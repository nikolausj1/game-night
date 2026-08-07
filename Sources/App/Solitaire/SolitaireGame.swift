import Foundation
import Observation

/// The thin SwiftUI-observable shell around `SolitaireEngine` — same split
/// as `GameHostController` wrapping `HostEngine` (App layer owns
/// `@Observable`/UI concerns; the Engine layer stays pure Foundation with
/// no SwiftUI dependency at all). Every mutation goes through here so the
/// board redraws automatically; `SolitaireView` never touches `engine`
/// directly.
@Observable
final class SolitaireGame {
    private(set) var engine: SolitaireEngine

    var state: SolitaireState { engine.state }

    init(engine: SolitaireEngine) {
        self.engine = engine
    }

    convenience init(seed: UInt64, drawMode: SolitaireDrawMode = .drawOne) {
        self.init(engine: SolitaireEngine(seed: seed, drawMode: drawMode))
    }

    @discardableResult
    func attemptMove(from source: SolitaireMoveSource, to destination: SolitaireMoveDestination) -> Bool {
        engine.attemptMove(from: source, to: destination)
    }

    func legalMove(from source: SolitaireMoveSource, to destination: SolitaireMoveDestination) -> Bool {
        engine.legalMove(from: source, to: destination)
    }

    func autoFoundationSuit(for source: SolitaireMoveSource) -> Suit? {
        engine.autoFoundationSuit(for: source)
    }

    @discardableResult
    func draw() -> Bool {
        engine.draw()
    }

    var canUndo: Bool { engine.canUndo }

    @discardableResult
    func undo() -> Bool {
        engine.undo()
    }

    func newDeal(seed: UInt64, drawMode: SolitaireDrawMode? = nil) {
        engine.newDeal(seed: seed, drawMode: drawMode)
    }

    func setDrawMode(_ mode: SolitaireDrawMode) {
        engine.setDrawMode(mode)
    }

    @discardableResult
    func autoCompleteStep() -> (source: SolitaireMoveSource, suit: Suit, card: Card)? {
        engine.autoCompleteStep()
    }

    var isWon: Bool { state.isWon }
    var isAutoCompletable: Bool { state.isAutoCompletable }
}
