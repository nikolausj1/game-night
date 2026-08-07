import Foundation

/// Klondike solitaire — a deterministic, seeded, single-player engine.
///
/// Unlike the rest of `Sources/Engine/*.swift`, solitaire never leaves the
/// iPad: there's no host/client split, no `PlayerAction`/`GameEvent`/
/// `HostEngine` wiring, nothing to redact into a `ClientSnapshot`. So this
/// file stays entirely self-contained — pure Foundation, no dependency on
/// `HostEngine` or the multiplayer machinery — while still borrowing the
/// shared `Card`/`Suit`/`DeckBuilder`/`SeededGenerator` primitives from
/// `Card.swift` so the SwiftUI layer's `CardView`/`CardFaceView` work on
/// solitaire cards exactly as they do everywhere else on the table.

// MARK: - Klondike rank

public extension Card {
    /// Klondike is Ace-low, King-high (A,2,3...10,J,Q,K) — the OPPOSITE of
    /// the shared `Card.rank` scale (2...14, Ace = 14, so it sits HIGH in
    /// Wizard/Oh Hell's trick-taking ranking). This remaps the shared rank
    /// onto Klondike's own 1...13 scale without touching `Card` itself:
    /// only rank 14 (Ace) moves, landing at 1; 2...13 (through King) are
    /// already numerically identical on both scales.
    var solitaireRank: Int { rank == 14 ? 1 : (rank ?? 0) }
}

// MARK: - Draw mode

/// Draw-1 (classic, default) turns one stock card at a time; draw-3 turns
/// three, of which only the topmost is playable. Both redeal the same way
/// — see `SolitaireEngine.draw()` — unlimited redeals regardless of mode,
/// the friendly casual-table rule rather than the stingier casino one.
public enum SolitaireDrawMode: String, Codable, Sendable, CaseIterable {
    case drawOne, drawThree

    public var cardsPerDraw: Int { self == .drawOne ? 1 : 3 }

    public var displayName: String {
        self == .drawOne ? "Draw 1" : "Draw 3"
    }
}

// MARK: - Card with face state

/// A tableau/stock/waste card paired with its face-up state. The shared
/// `Card` type doesn't track this itself (it's meaningless for Wizard/UNO,
/// where the engine tracks face-down-ness structurally via hand vs. draw
/// pile membership); solitaire cards flip face up/down freely within a
/// single pile, so this wrapper carries that bit explicitly.
public struct SolitaireCard: Codable, Hashable, Sendable, Identifiable {
    public let card: Card
    public var faceUp: Bool

    public var id: String { card.id }

    public init(card: Card, faceUp: Bool) {
        self.card = card
        self.faceUp = faceUp
    }
}

// MARK: - Piles

/// Where a card (or the bottom card of a run) is being moved FROM.
public enum SolitaireMoveSource: Hashable, Sendable {
    /// `cardID` names the bottom card of the run being lifted — everything
    /// from that card to the top of the column travels together.
    case tableau(column: Int, cardID: String)
    case waste
    /// Moving a card back off a foundation onto the tableau — a legal
    /// rescue play in real Klondike, so the engine allows it for free: it
    /// falls straight out of the same generic legality check every other
    /// move goes through, no special-casing required.
    case foundation(Suit)
}

/// Where a card (or run) is being moved TO. Only two kinds of pile ever
/// accept a card in Klondike — the stock/waste are draw-only, never a drop
/// target.
public enum SolitaireMoveDestination: Hashable, Sendable {
    case tableau(column: Int)
    case foundation(Suit)
}

// MARK: - State

/// The full, authoritative Klondike table. One Codable value type — cheap
/// to snapshot wholesale for undo, and directly save-and-resumable (encode
/// it, decode it later, hand the result to `SolitaireEngine(state:)`).
public struct SolitaireState: Codable, Sendable, Equatable {
    /// 7 columns. Index 0 within a column is the BOTTOM (dealt first,
    /// usually face-down and buried); the last index is the TOP — the one
    /// card actually exposed, drawn from, and dropped onto.
    public var tableau: [[SolitaireCard]]
    /// One ascending Ace...King run per suit. Empty array = no cards home
    /// yet for that suit.
    public var foundations: [Suit: [Card]]
    /// Face-down. Cards are drawn from the END (the "top" of the stock).
    public var stock: [Card]
    /// Face-up. The end (`.last`) is the exposed, playable card.
    public var waste: [Card]
    public var drawMode: SolitaireDrawMode
    public var seed: UInt64
    /// Every successful move (draw, tableau/foundation placement, undo does
    /// NOT decrement it — it's a lifetime counter, not "moves from here").
    public var moveCount: Int

    public init(tableau: [[SolitaireCard]], foundations: [Suit: [Card]],
                stock: [Card], waste: [Card], drawMode: SolitaireDrawMode,
                seed: UInt64, moveCount: Int = 0) {
        self.tableau = tableau
        self.foundations = foundations
        self.stock = stock
        self.waste = waste
        self.drawMode = drawMode
        self.seed = seed
        self.moveCount = moveCount
    }
}

public extension SolitaireState {
    /// All 52 cards accounted for and home — the win condition. Each
    /// foundation tops out at King (13 cards); summing beats checking all
    /// four individually against a magic number.
    var isWon: Bool { foundations.values.reduce(0) { $0 + $1.count } == 52 }

    /// Safe-to-autoplay: every tableau card is face-up and nothing is still
    /// hidden in the stock or waste. From here, every remaining card can
    /// legally walk itself home to a foundation without the player
    /// choosing anything — see `SolitaireEngine.autoCompleteStep()`, which
    /// the table view drives on a timer for the cascading win animation.
    var isAutoCompletable: Bool {
        guard stock.isEmpty, waste.isEmpty else { return false }
        return tableau.allSatisfy { pile in pile.allSatisfy(\.faceUp) }
    }
}

// MARK: - Engine

/// The mutable game in progress. Deterministic (seeded shuffle), bounded
/// undo (snapshot the whole state before every mutating move — Klondike
/// states are small, a few hundred bytes, so 50 of them is nothing), and
/// Codable through `SolitaireState` for save-and-resume.
public final class SolitaireEngine {
    public private(set) var state: SolitaireState

    /// Prior states, oldest first, most recent last — `undo()` pops the
    /// tail. Capped so a very long game's memory footprint stays flat.
    private var undoStack: [SolitaireState] = []
    private static let undoLimit = 50

    /// A fresh, freshly-shuffled deal.
    public init(seed: UInt64, drawMode: SolitaireDrawMode = .drawOne) {
        state = Self.deal(seed: seed, drawMode: drawMode)
    }

    /// Resume (or hand-construct, for tests) an existing table state.
    public init(state: SolitaireState) {
        self.state = state
    }

    /// Resume from a previously-encoded save. Fails (returns nil) only if
    /// `data` isn't a valid encoded `SolitaireState` — the caller falls
    /// back to a fresh deal in that case.
    public convenience init?(encodedState data: Data) {
        guard let decoded = try? JSONDecoder().decode(SolitaireState.self, from: data) else { return nil }
        self.init(state: decoded)
    }

    /// The current state, encoded for save-and-resume-later. `nil` only if
    /// `SolitaireState` somehow fails to encode, which never happens in
    /// practice (every field is a plain Codable value).
    public var encodedState: Data? { try? JSONEncoder().encode(state) }

    // MARK: - Deal

    /// A standard Klondike deal: 7 tableau columns of 1...7 cards each (the
    /// last card in every column face-up, the rest face-down beneath it),
    /// the remaining 24 cards face-down in the stock, foundations and
    /// waste empty. `DeckBuilder.shuffled(_:seed:)` is the same
    /// SplitMix64-backed deterministic shuffle every other game in the app
    /// uses — same seed, same deal, always.
    public static func deal(seed: UInt64, drawMode: SolitaireDrawMode) -> SolitaireState {
        let shuffled = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: seed)
        var cursor = 0
        var tableau: [[SolitaireCard]] = []
        for column in 0..<7 {
            var pile: [SolitaireCard] = []
            for row in 0...column {
                pile.append(SolitaireCard(card: shuffled[cursor], faceUp: row == column))
                cursor += 1
            }
            tableau.append(pile)
        }
        let stock = Array(shuffled[cursor...])
        var foundations: [Suit: [Card]] = [:]
        for suit in Suit.allCases { foundations[suit] = [] }
        return SolitaireState(tableau: tableau, foundations: foundations,
                              stock: stock, waste: [], drawMode: drawMode, seed: seed)
    }

    /// Shuffle a brand-new table in place (the "New Deal" control). Wipes
    /// undo history — there's nothing sensible to undo back INTO a
    /// different deal.
    public func newDeal(seed: UInt64, drawMode: SolitaireDrawMode? = nil) {
        state = Self.deal(seed: seed, drawMode: drawMode ?? state.drawMode)
        undoStack.removeAll()
    }

    /// Mid-game rules change (the draw-1/draw-3 toggle). Only changes how
    /// many cards `draw()` turns going forward; doesn't reshuffle or touch
    /// what's already down.
    public func setDrawMode(_ mode: SolitaireDrawMode) {
        state.drawMode = mode
    }

    // MARK: - Legality

    /// Pure query, no mutation: could `source`'s card (or run) legally land
    /// on `destination` right now?
    public func legalMove(from source: SolitaireMoveSource, to destination: SolitaireMoveDestination) -> Bool {
        guard let moving = movingCards(for: source) else { return false }
        switch destination {
        case .tableau(let column):
            guard state.tableau.indices.contains(column) else { return false }
            if case .tableau(let sourceColumn, _) = source, sourceColumn == column { return false }
            return canPlace(moving[0].card, onTableauTop: state.tableau[column].last)
        case .foundation(let suit):
            guard moving.count == 1, moving[0].card.suit == suit else { return false }
            return canPlace(moving[0].card, onFoundationTop: state.foundations[suit]?.last)
        }
    }

    /// If `source`'s (single) top card can walk straight home to its own
    /// suit's foundation right now, the suit to send it to — nil
    /// otherwise. Backs the "double-tap to auto-place" gesture: the view
    /// checks this on a double-tap and, if non-nil, fires
    /// `attemptMove(from:to: .foundation(suit))` to actually send it.
    public func autoFoundationSuit(for source: SolitaireMoveSource) -> Suit? {
        guard let moving = movingCards(for: source), moving.count == 1,
              let suit = moving[0].card.suit,
              legalMove(from: source, to: .foundation(suit)) else { return nil }
        return suit
    }

    /// A face-up run starting at `index`: every card from there to the top
    /// must be face-up AND form a valid descending-alternating-color
    /// sequence. Under normal legal play the face-up portion of a column
    /// is always exactly one such run (that's the only way it could have
    /// been built), but this still validates it directly rather than
    /// assuming — the defensive check that keeps hand-constructed/loaded
    /// states from producing a move nobody actually made legal.
    private func isMovableRun(_ pile: [SolitaireCard], from index: Int) -> Bool {
        guard pile.indices.contains(index), pile[index...].allSatisfy(\.faceUp) else { return false }
        var previous = pile[index].card
        for entry in pile[(index + 1)...] {
            let card = entry.card
            guard let prevSuit = previous.suit, let suit = card.suit,
                  prevSuit.isRed != suit.isRed,
                  previous.solitaireRank == card.solitaireRank + 1 else { return false }
            previous = card
        }
        return true
    }

    /// King on empty, otherwise opposite color and exactly one rank below.
    private func canPlace(_ moving: Card, onTableauTop top: SolitaireCard?) -> Bool {
        guard let top else { return moving.solitaireRank == 13 }
        guard let topSuit = top.card.suit, let movingSuit = moving.suit else { return false }
        return topSuit.isRed != movingSuit.isRed && top.card.solitaireRank == moving.solitaireRank + 1
    }

    /// Ace on empty, otherwise same suit and exactly one rank above.
    private func canPlace(_ moving: Card, onFoundationTop top: Card?) -> Bool {
        guard let suit = moving.suit else { return false }
        if let top {
            guard top.suit == suit else { return false }
            return top.solitaireRank + 1 == moving.solitaireRank
        }
        return moving.solitaireRank == 1
    }

    /// The cards `source` would carry if moved right now, without
    /// mutating anything — nil if the source is empty, or (tableau case)
    /// names a card that either doesn't exist or isn't the base of a
    /// legal movable run.
    private func movingCards(for source: SolitaireMoveSource) -> [SolitaireCard]? {
        switch source {
        case .tableau(let column, let cardID):
            guard state.tableau.indices.contains(column) else { return nil }
            let pile = state.tableau[column]
            guard let index = pile.firstIndex(where: { $0.id == cardID }),
                  isMovableRun(pile, from: index) else { return nil }
            return Array(pile[index...])
        case .waste:
            guard let top = state.waste.last else { return nil }
            return [SolitaireCard(card: top, faceUp: true)]
        case .foundation(let suit):
            guard let top = state.foundations[suit]?.last else { return nil }
            return [SolitaireCard(card: top, faceUp: true)]
        }
    }

    // MARK: - Moves

    /// Attempt to move `source` onto `destination`. Returns whether it
    /// happened. On success: snapshots undo, relocates the whole run,
    /// auto-flips any tableau card newly exposed on top of its column, and
    /// bumps `moveCount`. On failure the state is untouched — nothing to
    /// undo, nothing to animate.
    @discardableResult
    public func attemptMove(from source: SolitaireMoveSource, to destination: SolitaireMoveDestination) -> Bool {
        guard legalMove(from: source, to: destination), let moving = movingCards(for: source) else { return false }
        pushUndoSnapshot()
        removeMovingCards(source: source, count: moving.count)
        appendCards(moving, to: destination)
        autoFlipExposedTableauTops()
        state.moveCount += 1
        return true
    }

    private func removeMovingCards(source: SolitaireMoveSource, count: Int) {
        switch source {
        case .tableau(let column, _):
            state.tableau[column].removeLast(count)
        case .waste:
            state.waste.removeLast()
        case .foundation(let suit):
            state.foundations[suit]?.removeLast()
        }
    }

    private func appendCards(_ cards: [SolitaireCard], to destination: SolitaireMoveDestination) {
        switch destination {
        case .tableau(let column):
            state.tableau[column].append(contentsOf: cards)
        case .foundation(let suit):
            // Foundation destinations only ever carry a single card —
            // `legalMove` already enforced `moving.count == 1`.
            state.foundations[suit, default: []].append(cards[0].card)
        }
    }

    /// A pile that just lost its top card exposes a face-down card
    /// beneath it — real Klondike flips that card automatically the
    /// instant it's exposed, no separate player action. Sweeps every
    /// column rather than just the source column: cheap (7 piles), and
    /// correct even for moves that touch more than one column in one call
    /// in the future.
    private func autoFlipExposedTableauTops() {
        for column in state.tableau.indices {
            guard let lastIndex = state.tableau[column].indices.last,
                  !state.tableau[column][lastIndex].faceUp else { continue }
            state.tableau[column][lastIndex].faceUp = true
        }
    }

    // MARK: - Stock / waste

    /// Turn the next `drawMode.cardsPerDraw` stock cards face-up into the
    /// waste (fewer, right at the tail of the stock). When the stock is
    /// already empty, this instead REDEALS: the waste flips back into the
    /// stock face-down, in reverse order (so the card that's been waiting
    /// longest comes up first again), ready to draw from anew — unlimited
    /// redeals, the relaxed casual-table rule. Returns false only when
    /// there's truly nothing left to do (stock AND waste both empty).
    @discardableResult
    public func draw() -> Bool {
        guard !(state.stock.isEmpty && state.waste.isEmpty) else { return false }
        pushUndoSnapshot()
        if state.stock.isEmpty {
            state.stock = state.waste.reversed()
            state.waste = []
        } else {
            let n = min(state.drawMode.cardsPerDraw, state.stock.count)
            state.waste.append(contentsOf: state.stock.suffix(n))
            state.stock.removeLast(n)
        }
        state.moveCount += 1
        return true
    }

    // MARK: - Undo

    public var canUndo: Bool { !undoStack.isEmpty }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        state = previous
        return true
    }

    private func pushUndoSnapshot() {
        undoStack.append(state)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    // MARK: - Autocomplete

    /// One step of the trophy-moment cascade: finds a single card — a
    /// tableau top (columns checked in order) or, failing that, the waste
    /// top — that can walk straight home to its foundation right now,
    /// performs exactly that one move, and reports what it did. Returns
    /// nil once nothing more can move; when `isAutoCompletable` was true
    /// at the start, that only happens once the game is won (every card
    /// is home). Deliberately one card per call — the table view drives
    /// the cadence (staggered timers, accelerating arcs), so the engine
    /// never has to know anything about animation pacing, and each step
    /// stays independently undo-able like any other move.
    @discardableResult
    public func autoCompleteStep() -> (source: SolitaireMoveSource, suit: Suit, card: Card)? {
        for column in state.tableau.indices {
            guard let top = state.tableau[column].last, top.faceUp, let suit = top.card.suit else { continue }
            let source = SolitaireMoveSource.tableau(column: column, cardID: top.id)
            if legalMove(from: source, to: .foundation(suit)) {
                attemptMove(from: source, to: .foundation(suit))
                return (source, suit, top.card)
            }
        }
        if let top = state.waste.last, let suit = top.suit, legalMove(from: .waste, to: .foundation(suit)) {
            attemptMove(from: .waste, to: .foundation(suit))
            return (.waste, suit, top)
        }
        return nil
    }
}
