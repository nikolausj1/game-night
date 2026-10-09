import Foundation

/// Save/resume for the LOCAL games (no host, no phones): the five board
/// games and Solitaire. Each view calls the matching `note…` on every
/// state change; the write lands 2s after the last one, a finished game
/// clears its slot, and `load…` hands the state back when the view is
/// mounted with `resumeSaved: true`.
enum LocalGameSave {
    private static var debouncers: [String: SaveDebouncer] = [:]

    private static func debouncer(_ kind: ResumeKind) -> SaveDebouncer {
        if let existing = debouncers[kind.slotKey] { return existing }
        let fresh = SaveDebouncer()
        debouncers[kind.slotKey] = fresh
        return fresh
    }

    static func clear(_ kind: ResumeKind) {
        debouncer(kind).cancel()
        SaveSlots.clear(kind: kind)
    }

    private static func schedule<T: Encodable>(_ kind: ResumeKind, over: Bool, subtitle: @escaping () -> String,
                                               seats: [SeatSpecCodable], state: @escaping () -> T) {
        if over {
            clear(kind)
            return
        }
        debouncer(kind).schedule {
            SaveSlots.write(kind: kind, title: kind.displayName, subtitle: subtitle(), seats: seats, payload: state())
        }
    }

    private static func seats(_ names: [String], bots: [Bool]) -> [SeatSpecCodable] {
        names.indices.map { SeatSpecCodable(id: $0, name: names[$0], isBot: bots[$0], deviceID: nil) }
    }

    private static func twoPlayerSubtitle(move: Int, names: [String], scores: [Int]?, turn: Int) -> String {
        if let scores, scores.count == 2, scores[0] != scores[1] {
            let lead = scores[0] > scores[1] ? 0 : 1
            return "Move \(move) · \(names[lead]) leads \(scores[lead])-\(scores[1 - lead])"
        }
        return "Move \(move) · \(names[min(max(turn, 0), names.count - 1)]) to play"
    }

    // MARK: Mancala

    static func noteMancala(_ state: MancalaState) {
        let names = state.players.map(\.name)
        schedule(.board("mancala"), over: state.phase == .gameOver,
                 subtitle: { twoPlayerSubtitle(move: state.moveCount + 1, names: names,
                                               scores: [state.scores[0], state.scores[1]], turn: state.currentPlayer) },
                 seats: seats(names, bots: state.players.map(\.isBot)), state: { state })
    }

    static func loadMancala() -> MancalaState? {
        SaveSlots.read(kind: .board("mancala"), as: MancalaState.self)?.payload
    }

    // MARK: Checkers

    static func noteCheckers(_ state: CheckersState) {
        let names = state.players.map(\.name)
        schedule(.board("checkers"), over: state.phase == .gameOver,
                 subtitle: { twoPlayerSubtitle(move: state.moveCount / 2 + 1, names: names, scores: nil,
                                               turn: state.currentPlayer) },
                 seats: seats(names, bots: state.players.map(\.isBot)), state: { state })
    }

    static func loadCheckers() -> CheckersState? {
        SaveSlots.read(kind: .board("checkers"), as: CheckersState.self)?.payload
    }

    // MARK: Connect Four

    static func noteConnectFour(_ state: ConnectFourState) {
        let names = state.players.map(\.name)
        schedule(.board("connectFour"), over: state.phase == .gameOver,
                 subtitle: { twoPlayerSubtitle(move: state.moveCount + 1, names: names, scores: nil,
                                               turn: state.currentPlayer) },
                 seats: seats(names, bots: state.players.map(\.isBot)), state: { state })
    }

    static func loadConnectFour() -> ConnectFourState? {
        SaveSlots.read(kind: .board("connectFour"), as: ConnectFourState.self)?.payload
    }

    // MARK: Quarto

    static func noteQuarto(_ state: QuartoState) {
        let names = state.players.map(\.name)
        schedule(.board("quarto"), over: state.phase == .gameOver,
                 subtitle: { twoPlayerSubtitle(move: state.moveCount + 1, names: names, scores: nil,
                                               turn: state.currentPlayer) },
                 seats: seats(names, bots: state.players.map(\.isBot)), state: { state })
    }

    static func loadQuarto() -> QuartoState? {
        SaveSlots.read(kind: .board("quarto"), as: QuartoState.self)?.payload
    }

    // MARK: Dots & Boxes

    static func noteDotsAndBoxes(_ state: DotsAndBoxesState) {
        let names = state.players.map(\.name)
        schedule(.board("dotsAndBoxes"), over: state.isGameOver,
                 subtitle: {
                     let claimed = state.claimedBy.count
                     let ranked = state.players.sorted { $0.score > $1.score }
                     if ranked.count >= 2, ranked[0].score != ranked[1].score {
                         return "\(claimed) lines · \(ranked[0].name) leads \(ranked[0].score)-\(ranked[1].score)"
                     }
                     let turn = state.players.indices.contains(state.turnIndex) ? state.players[state.turnIndex].name : "Someone"
                     return "\(claimed) lines · \(turn) to draw"
                 },
                 seats: seats(names, bots: state.players.map(\.isBot)), state: { state })
    }

    static func loadDotsAndBoxes() -> DotsAndBoxesState? {
        SaveSlots.read(kind: .board("dotsAndBoxes"), as: DotsAndBoxesState.self)?.payload
    }

    // MARK: Solitaire

    static func noteSolitaire(_ state: SolitaireState) {
        schedule(.solitaire, over: state.isWon,
                 subtitle: {
                     let home = state.foundations.values.reduce(0) { $0 + $1.count }
                     let mode = state.drawMode == .drawThree ? "draw three" : "draw one"
                     return "\(home) of 52 home · \(state.moveCount) moves · \(mode)"
                 },
                 seats: [], state: { state })
    }

    static func loadSolitaire() -> SolitaireState? {
        SaveSlots.read(kind: .solitaire, as: SolitaireState.self)?.payload
    }
}
