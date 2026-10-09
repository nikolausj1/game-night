import SwiftUI

/// Scripted Battleship positions for `#Preview`s and sim-verify harnesses:
/// real engine states (never hand-built snapshots), so previews exercise the
/// same redaction the live game does.
enum BattleshipDemo {
    enum Stage {
        /// Seat 0 has placed three of five ships.
        case placementPartial
        /// Seat 0 has locked in; seat 1 is still placing.
        case placementLocked
        /// A dozen-plus shots in, two ships sunk each way, seat 0 to fire.
        case midBattle
        /// Seat 0 won; fleets revealed.
        case gameOver
    }

    static func engine(_ stage: Stage, seed: UInt64 = 8, salvo: Bool = false) -> BattleshipEngine {
        let e = BattleshipEngine(seed: seed, salvo: salvo)
        let mine = BattleshipRules.randomPlacement(seed: seed &+ 1)
        let theirs = BattleshipRules.randomPlacement(seed: seed &+ 2)
        func place(_ ships: [BattleshipShip], seat: Int, count: Int) {
            for s in ships.prefix(count) {
                _ = e.apply(.placeShip(kind: s.kind, row: s.row, col: s.col, orientation: s.orientation), from: seat)
            }
        }
        switch stage {
        case .placementPartial:
            place(mine, seat: 0, count: 3)
        case .placementLocked:
            place(mine, seat: 0, count: 5)
            _ = e.apply(.confirmPlacement, from: 0)
            place(theirs, seat: 1, count: 2)
        case .midBattle, .gameOver:
            place(mine, seat: 0, count: 5)
            place(theirs, seat: 1, count: 5)
            _ = e.apply(.confirmPlacement, from: 0)
            _ = e.apply(.confirmPlacement, from: 1)
            var rng = SeededGenerator(seed: seed ^ 0xD3A0)
            var guardCount = 0
            while e.state.phase == .battle, guardCount < 400 {
                guardCount += 1
                if stage == .midBattle {
                    // Stop on seat 0's turn once both sides have sunk two.
                    let s = e.state
                    if s.shots[0, default: []].count >= 14, s.turnSeat == 0,
                       s.sunkShips(of: 1).count >= 2, s.sunkShips(of: 0).count >= 1 { break }
                    if s.shots[0, default: []].count >= 40 { break }
                }
                guard let seat = e.state.turnSeat,
                      let cell = BattleshipBot.chooseShot(snapshot: e.snapshot(for: seat), rng: &rng) else { break }
                _ = e.apply(.fire(row: cell.row, col: cell.col), from: seat)
            }
        }
        return e
    }

    static func snapshot(_ stage: Stage, seat: Int = 0, salvo: Bool = false) -> BattleshipSnapshot {
        engine(stage, salvo: salvo).snapshot(for: seat)
    }

    static func table(_ stage: Stage, salvo: Bool = false) -> BattleshipTableSnapshot {
        engine(stage, salvo: salvo).tableSnapshot()
    }

    static let names: [Int: String] = [0: "Justin", 1: "Admiral Hopper"]

    // MARK: launch flags (sim-verify)

    static var wantsHandDemo: Bool { CommandLine.arguments.contains("-demoBattleshipHand") }
    static var wantsTableDemo: Bool { CommandLine.arguments.contains("-demoBattleshipTable") }
    static var wantsDemo: Bool { wantsHandDemo || wantsTableDemo }

    private static func stage() -> Stage {
        guard let i = CommandLine.arguments.firstIndex(of: "-demoBattleshipStage"),
              CommandLine.arguments.indices.contains(i + 1) else { return .midBattle }
        switch CommandLine.arguments[i + 1] {
        case "placement": return .placementPartial
        case "locked": return .placementLocked
        case "over": return .gameOver
        default: return .midBattle
        }
    }

    /// A standalone harness (add to `RoleRouter` like `-demoQuarto` if
    /// wanted): `-demoBattleshipHand` / `-demoBattleshipTable`, plus
    /// `-demoBattleshipStage placement|locked|mid|over`, `-demoBattleshipFleet`
    /// (open on the own-fleet chart), `-demoBattleshipAim`.
    @ViewBuilder
    static var harness: some View {
        if wantsTableDemo {
            ZStack {
                TableSurface()
                BattleshipTableContent(snapshot: table(stage()), names: names, botSeats: [1])
            }
        } else {
            BattleshipHandContent(
                snapshot: snapshot(stage()),
                preview: BattleshipHandPreview(
                    page: CommandLine.arguments.contains("-demoBattleshipFleet") ? .fleet : .targeting,
                    aim: CommandLine.arguments.contains("-demoBattleshipAim") ? BattleshipCell(row: 4, col: 6) : nil,
                    freeze: true))
        }
    }
}

// MARK: - Previews

#Preview("Phone - deploying") {
    BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.placementPartial))
}

#Preview("Phone - fleet locked") {
    BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.placementLocked))
}

#Preview("Phone - targeting, aimed") {
    BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.midBattle),
                          preview: .init(aim: BattleshipCell(row: 4, col: 6), freeze: true))
}

#Preview("Phone - my fleet") {
    BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.midBattle), preview: .init(page: .fleet, freeze: true))
}

#Preview("Phone - victory") {
    BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.gameOver))
}

#Preview("Table - battle", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        BattleshipTableContent(snapshot: BattleshipDemo.table(.midBattle), names: BattleshipDemo.names, botSeats: [1])
    }
}

#Preview("Table - deploying", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        BattleshipTableContent(snapshot: BattleshipDemo.table(.placementLocked), names: BattleshipDemo.names, botSeats: [1])
    }
}

#Preview("Table - game over reveal", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        BattleshipTableContent(snapshot: BattleshipDemo.table(.gameOver), names: BattleshipDemo.names, botSeats: [1])
    }
}

#Preview("Table - salvo, portrait", traits: .fixedLayout(width: 834, height: 1194)) {
    ZStack {
        TableSurface()
        BattleshipTableContent(snapshot: BattleshipDemo.table(.midBattle, salvo: true), names: BattleshipDemo.names, botSeats: [1])
    }
}
