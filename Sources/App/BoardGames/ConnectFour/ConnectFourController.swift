import SwiftUI

/// Owns the pure `ConnectFourEngine`, the in-flight disc, bot aiming/pacing
/// and sound. Like the other table games the engine applies a move at once
/// but the TABLE only believes it when the disc has stopped bouncing.
@Observable
final class ConnectFourController {
    struct Falling: Equatable {
        var seat: Int
        var column: Int
        var row: Int
        var start: Date
    }

    private(set) var engine: ConnectFourEngine
    private(set) var falling: Falling?
    private(set) var dropPlan: ConnectFourDropPlan?
    private(set) var isBusy = false
    private(set) var shownTurn: Int
    /// The column a disc is being held over (humans: under the finger; bots:
    /// where they are "aiming").
    var hoverColumn: Int?
    /// Becomes true a beat after the game ends so the winning line can pulse
    /// on its own before the banner covers it.
    private(set) var resultVisible = false
    private(set) var revision = 0
    var reduceMotion = false

    private var token = 0
    private var botScheduled = false

    init(players: [ConnectFourPlayer], firstPlayer: Int = 0) {
        engine = ConnectFourEngine(players: players, firstPlayer: firstPlayer)
        shownTurn = firstPlayer
    }

    init(restoring state: ConnectFourState) {
        engine = ConnectFourEngine(restoring: state)
        shownTurn = state.currentPlayer
        resultVisible = state.phase == .gameOver
    }

    /// Reads `revision` so views reading `state` re-evaluate when a drop
    /// completes (the engine is a plain class Observation can't see into).
    var state: ConnectFourState { _ = revision; return engine.state }
    var humanTurn: Bool { !isBusy && state.phase == .playing && !state.players[state.currentPlayer].isBot }

    /// Cells as the TABLE sees them: the disc still in the air isn't
    /// resting in its hole yet.
    var visibleCells: [Int?] {
        var cells = engine.state.cells
        if let f = falling { cells[f.row * 7 + f.column] = nil }
        return cells
    }

    func restart(players: [ConnectFourPlayer], firstPlayer: Int) {
        token += 1
        botScheduled = false
        isBusy = false
        falling = nil
        dropPlan = nil
        hoverColumn = nil
        resultVisible = false
        _ = engine.restart(players: players, firstPlayer: firstPlayer)
        shownTurn = firstPlayer
        revision += 1
        scheduleBotIfNeeded()
    }

    // MARK: - Dropping

    func drop(column: Int) {
        guard !isBusy, engine.state.phase == .playing else { return }
        let seat = engine.state.currentPlayer
        let events = engine.apply(.drop(column: column), from: seat)
        var landed: (row: Int, column: Int)?
        for e in events {
            if case .illegalAttempt = e { return }
            if case .discDropped(_, let c, let r, _) = e { landed = (r, c) }
        }
        guard let landed else { return }
        isBusy = true
        token += 1
        let mine = token
        hoverColumn = landed.column

        if reduceMotion {
            Haptics.tick()
            TableSFX.shared.playDiceContact(.die, strength: 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finish(token: mine) }
            return
        }

        let plan = ConnectFourDropPlan(row: landed.row)
        dropPlan = plan
        falling = Falling(seat: seat, column: landed.column, row: landed.row, start: Date())
        // The soft rattle of entering the slot, then a plastic clack on every
        // strike (the landing hard, the bounces fainter).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.token == mine else { return }
            TableSFX.shared.playDiceContact(.rail, strength: 0.15)
        }
        for (i, t) in plan.impacts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.token == mine else { return }
                let strength = [0.80, 0.34, 0.14][i]
                TableSFX.shared.playDiceContact(.die, strength: strength)
                if i == 0 { Haptics.tick() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.duration + 0.05) { [weak self] in
            self?.finish(token: mine)
        }
    }

    private func finish(token mine: Int) {
        guard mine == token else { return }
        falling = nil
        dropPlan = nil
        isBusy = false
        hoverColumn = nil
        shownTurn = engine.state.currentPlayer
        revision += 1
        if engine.state.phase == .gameOver {
            TableSFX.shared.play(engine.state.winner != nil ? .fanfareWin : .softChime)
            let result = token
            DispatchQueue.main.asyncAfter(deadline: .now() + (engine.state.winner != nil ? 1.6 : 0.7)) { [weak self] in
                guard let self, self.token == result else { return }
                withAnimation(.easeInOut(duration: 0.3)) { self.resultVisible = true }
            }
        }
        scheduleBotIfNeeded()
    }

    // MARK: - Bots

    func scheduleBotIfNeeded() {
        guard !botScheduled, !isBusy, engine.state.phase == .playing else { return }
        let seat = engine.state.currentPlayer
        guard engine.state.players[seat].isBot else { return }
        botScheduled = true
        let snapshot = engine.state
        let seed = UInt64(snapshot.moveCount) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(seat)
        let mine = token
        let pause = 0.50 + Double.random(in: 0...0.40)
        let begun = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let action = ConnectFourBot.decide(state: snapshot, seed: seed)
            let wait = max(0, pause - Date().timeIntervalSince(begun))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard let self, self.token == mine else { return }
                self.botScheduled = false
                guard !self.isBusy, self.engine.state.phase == .playing,
                      self.engine.state.moveCount == snapshot.moveCount,
                      case .drop(let column) = action else { return }
                // Aim first: the held disc glides over the chosen column,
                // like a hand lining one up, then lets go.
                self.hoverColumn = column
                let aim = self.reduceMotion ? 0.05 : 0.42
                DispatchQueue.main.asyncAfter(deadline: .now() + aim) { [weak self] in
                    guard let self, self.token == mine, !self.isBusy else { return }
                    self.drop(column: column)
                }
            }
        }
    }
}
