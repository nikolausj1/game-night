import Foundation

/// Battleship — 2 players, 10x10, standard fleet (5,4,3,3,2). Seats are
/// always exactly 0 and 1. Like `CribbageEngine`, `BattleshipEngine` is a
/// standalone pure reducer (not a `GameKind`/`HostEngine` game): phones hold
/// the secret grids, the table shows only the public shot history.
///
/// Coordinates: `row` 0...9 top to bottom, `col` 0...9 left to right.

public enum BattleshipRules {
    public static let boardSize = 10
    /// Standard fleet, in placement-list order.
    public static let fleet: [BattleshipShipKind] = [.carrier, .battleship, .cruiser, .submarine, .destroyer]
    public static let totalShipCells = 17

    public static func inBounds(_ row: Int, _ col: Int) -> Bool {
        row >= 0 && row < boardSize && col >= 0 && col < boardSize
    }

    /// `nil` when `ship` can legally join `existing` (other ships already
    /// placed; a ship of the same kind in `existing` is ignored so callers
    /// can validate a *move* without removing the old copy first). Otherwise
    /// a human-readable reason (bounds / overlap).
    public static func validatePlacement(_ ship: BattleshipShip, existing: [BattleshipShip]) -> String? {
        for cell in ship.cells where !inBounds(cell.row, cell.col) {
            return "That ship hangs off the board"
        }
        let occupied = Set(existing.filter { $0.kind != ship.kind }.flatMap(\.cells))
        for cell in ship.cells where occupied.contains(cell) {
            return "Ships can't overlap"
        }
        return nil
    }

    /// A complete, legal fleet placed deterministically from `seed`. Always
    /// succeeds (restarts on the vanishingly rare dead end). Ships may touch.
    public static func randomPlacement(seed: UInt64) -> [BattleshipShip] {
        var rng = SeededGenerator(seed: seed)
        while true {
            var placed: [BattleshipShip] = []
            var failed = false
            for kind in fleet {
                var done = false
                for _ in 0..<500 {
                    let orientation: BattleshipOrientation = Bool.random(using: &rng) ? .horizontal : .vertical
                    let maxRow = orientation == .vertical ? boardSize - kind.length : boardSize - 1
                    let maxCol = orientation == .horizontal ? boardSize - kind.length : boardSize - 1
                    let ship = BattleshipShip(
                        kind: kind, row: Int.random(in: 0...maxRow, using: &rng),
                        col: Int.random(in: 0...maxCol, using: &rng), orientation: orientation
                    )
                    if validatePlacement(ship, existing: placed) == nil {
                        placed.append(ship)
                        done = true
                        break
                    }
                }
                if !done { failed = true; break }
            }
            if !failed { return placed }
        }
    }
}

public enum BattleshipShipKind: String, Codable, CaseIterable, Sendable, Equatable {
    case carrier, battleship, cruiser, submarine, destroyer

    public var length: Int {
        switch self {
        case .carrier: return 5
        case .battleship: return 4
        case .cruiser, .submarine: return 3
        case .destroyer: return 2
        }
    }

    public var displayName: String {
        switch self {
        case .carrier: return "Carrier"
        case .battleship: return "Battleship"
        case .cruiser: return "Cruiser"
        case .submarine: return "Submarine"
        case .destroyer: return "Destroyer"
        }
    }
}

public enum BattleshipOrientation: String, Codable, Sendable, Equatable {
    /// Extends toward increasing `col`.
    case horizontal
    /// Extends toward increasing `row`.
    case vertical
}

public struct BattleshipCell: Codable, Hashable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

/// A ship on a grid: `row`/`col` is its top-left cell (bow); it extends
/// right (`.horizontal`) or down (`.vertical`) for `kind.length` cells.
public struct BattleshipShip: Codable, Hashable, Sendable {
    public let kind: BattleshipShipKind
    public let row: Int
    public let col: Int
    public let orientation: BattleshipOrientation

    public init(kind: BattleshipShipKind, row: Int, col: Int, orientation: BattleshipOrientation) {
        self.kind = kind
        self.row = row
        self.col = col
        self.orientation = orientation
    }

    public var cells: [BattleshipCell] {
        (0..<kind.length).map { i in
            orientation == .horizontal
                ? BattleshipCell(row: row, col: col + i)
                : BattleshipCell(row: row + i, col: col)
        }
    }
}

public enum BattleshipShotResult: Codable, Hashable, Sendable {
    case miss
    case hit
    /// The shot that finished off a ship; the kind identifies which.
    case sunk(BattleshipShipKind)

    public var isHit: Bool {
        if case .miss = self { return false }
        return true
    }
}

/// One fired shot. `turn` is the 0-based global shot index (both seats).
public struct BattleshipShot: Codable, Hashable, Sendable {
    public let row: Int
    public let col: Int
    public let result: BattleshipShotResult
    public let turn: Int

    public init(row: Int, col: Int, result: BattleshipShotResult, turn: Int) {
        self.row = row
        self.col = col
        self.result = result
        self.turn = turn
    }

    public var cell: BattleshipCell { BattleshipCell(row: row, col: col) }
}

public enum BattleshipPhase: String, Codable, Sendable, Equatable {
    /// Both seats arranging (and confirming) their fleets.
    case placement
    /// Alternating shots.
    case battle
    /// All of one fleet sunk. Terminal.
    case gameOver
}

public enum BattleshipAction: Codable, Sendable, Equatable {
    /// Place (or move) one ship. Replaces this seat's earlier placement of
    /// the same kind. Legal during `.placement`, before `confirmPlacement`.
    case placeShip(kind: BattleshipShipKind, row: Int, col: Int, orientation: BattleshipOrientation)
    /// Pick a placed ship back up.
    case removeShip(kind: BattleshipShipKind)
    /// Replace the caller's whole fleet with `BattleshipRules.randomPlacement(seed:)`.
    case randomizeFleet(seed: UInt64)
    /// Lock in a complete fleet. When both seats have confirmed, battle begins.
    case confirmPlacement
    /// Fire at one cell of the opponent's grid. In salvo mode a turn is
    /// `shotsRemaining` of these, resolved one at a time.
    case fire(row: Int, col: Int)
}

public enum BattleshipEvent: Codable, Sendable, Equatable {
    /// Public: a ship was placed/moved. Deliberately carries NO coordinates.
    case shipPlaced(seat: Int, kind: BattleshipShipKind)
    case shipRemoved(seat: Int, kind: BattleshipShipKind)
    case fleetRandomized(seat: Int)
    case placementConfirmed(seat: Int)
    case battleBegan(firstSeat: Int, salvo: Bool)
    /// `sunkShip` is non-nil exactly when `result == .sunk(_)`: the full
    /// ship (identity + position), revealed on sink so the table can draw
    /// the silhouette.
    case shotFired(seat: Int, cell: BattleshipCell, result: BattleshipShotResult, sunkShip: BattleshipShip?)
    /// The turn passed to `seat`, who has `shots` shots this turn.
    case turnChanged(seat: Int, shots: Int)
    case gameWon(seat: Int)
    /// A rejected action changed nothing.
    case illegalAttempt(seat: Int, reason: String)
}

/// Authoritative Battleship state (host-side; holds both fleets — only ever
/// ship per-seat `BattleshipSnapshot`s / the public `BattleshipTableSnapshot`).
public struct BattleshipState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var salvo: Bool
    public var phase: BattleshipPhase
    /// Each seat's own ships (partial during placement).
    public var ships: [Int: [BattleshipShip]]
    public var ready: Set<Int>
    /// `shots[s]` = shots FIRED BY seat `s` (at the other seat), in order.
    public var shots: [Int: [BattleshipShot]]
    /// Whose turn to fire; nil outside `.battle`.
    public var turnSeat: Int?
    public var shotsRemaining: Int
    public var firstSeat: Int
    public var shotCounter: Int
    public var winnerSeat: Int?

    public init(
        seed: UInt64, salvo: Bool, phase: BattleshipPhase, ships: [Int: [BattleshipShip]], ready: Set<Int>,
        shots: [Int: [BattleshipShot]], turnSeat: Int?, shotsRemaining: Int, firstSeat: Int,
        shotCounter: Int, winnerSeat: Int?
    ) {
        self.seed = seed
        self.salvo = salvo
        self.phase = phase
        self.ships = ships
        self.ready = ready
        self.shots = shots
        self.turnSeat = turnSeat
        self.shotsRemaining = shotsRemaining
        self.firstSeat = firstSeat
        self.shotCounter = shotCounter
        self.winnerSeat = winnerSeat
    }

    /// Ships of `seat` that have been completely sunk by the opponent's shots.
    public func sunkShips(of seat: Int) -> [BattleshipShip] {
        let hitCells = Set((shots[1 - seat] ?? []).filter { $0.result.isHit }.map(\.cell))
        return (ships[seat] ?? []).filter { ship in ship.cells.allSatisfy { hitCells.contains($0) } }
    }

    /// Ships of `seat` still afloat.
    public func afloatShips(of seat: Int) -> [BattleshipShip] {
        let sunk = Set(sunkShips(of: seat).map(\.kind))
        return (ships[seat] ?? []).filter { !sunk.contains($0.kind) }
    }
}

/// What the table shows: the shot history of both grids and sunk silhouettes.
/// Never contains an unsunk ship's position. (At `.gameOver` the loser's
/// remaining fleet is revealed in `revealedShips`.)
public struct BattleshipTableSnapshot: Codable, Sendable, Equatable {
    public let phase: BattleshipPhase
    public let salvo: Bool
    public let turnSeat: Int?
    public let shotsRemaining: Int
    /// `shotsBy[s]` = shots fired BY seat `s`, in order; each lands on grid `1 - s`.
    public let shotsBy: [Int: [BattleshipShot]]
    /// `sunk[s]` = seat `s`'s ships that have been sunk (kind + full position).
    public let sunk: [Int: [BattleshipShip]]
    public let shipsAfloat: [Int: Int]
    public let ready: Set<Int>
    public let winnerSeat: Int?
    /// Empty until `.gameOver`; then each seat's surviving ships.
    public let revealedShips: [Int: [BattleshipShip]]

    public init(
        phase: BattleshipPhase, salvo: Bool, turnSeat: Int?, shotsRemaining: Int, shotsBy: [Int: [BattleshipShot]],
        sunk: [Int: [BattleshipShip]], shipsAfloat: [Int: Int], ready: Set<Int>, winnerSeat: Int?,
        revealedShips: [Int: [BattleshipShip]]
    ) {
        self.phase = phase
        self.salvo = salvo
        self.turnSeat = turnSeat
        self.shotsRemaining = shotsRemaining
        self.shotsBy = shotsBy
        self.sunk = sunk
        self.shipsAfloat = shipsAfloat
        self.ready = ready
        self.winnerSeat = winnerSeat
        self.revealedShips = revealedShips
    }
}

public enum BattleshipOwnCell: Sendable, Equatable {
    case water
    case miss
    case ship(BattleshipShipKind)
    case hitShip(BattleshipShipKind)
}

public enum BattleshipTargetCell: Sendable, Equatable {
    case unknown
    case miss
    case hit
    case sunk(BattleshipShipKind)
}

/// One seat's redacted view: own grid in full, the opponent's grid as shots only.
public struct BattleshipSnapshot: Codable, Sendable, Equatable {
    public let mySeat: Int
    public let phase: BattleshipPhase
    public let salvo: Bool
    public let turnSeat: Int?
    public let isMyTurn: Bool
    public let shotsRemaining: Int
    /// My fleet (positions). Partial during placement.
    public let myShips: [BattleshipShip]
    /// Shots the opponent has fired at me (results included), in order.
    public let shotsAtMe: [BattleshipShot]
    /// Shots I have fired at the opponent (results included), in order.
    public let myShots: [BattleshipShot]
    /// The opponent's ships I have sunk (identity + position).
    public let opponentSunk: [BattleshipShip]
    /// My ships the opponent has sunk.
    public let mySunk: [BattleshipShip]
    public let opponentShipsAfloat: Int
    public let myShipsAfloat: Int
    public let iAmReady: Bool
    public let opponentReady: Bool
    public let winnerSeat: Int?
    /// Opponent ships revealed — only at `.gameOver`, else empty.
    public let revealedOpponentShips: [BattleshipShip]

    public init(
        mySeat: Int, phase: BattleshipPhase, salvo: Bool, turnSeat: Int?, isMyTurn: Bool, shotsRemaining: Int,
        myShips: [BattleshipShip], shotsAtMe: [BattleshipShot], myShots: [BattleshipShot],
        opponentSunk: [BattleshipShip], mySunk: [BattleshipShip], opponentShipsAfloat: Int, myShipsAfloat: Int,
        iAmReady: Bool, opponentReady: Bool, winnerSeat: Int?, revealedOpponentShips: [BattleshipShip]
    ) {
        self.mySeat = mySeat
        self.phase = phase
        self.salvo = salvo
        self.turnSeat = turnSeat
        self.isMyTurn = isMyTurn
        self.shotsRemaining = shotsRemaining
        self.myShips = myShips
        self.shotsAtMe = shotsAtMe
        self.myShots = myShots
        self.opponentSunk = opponentSunk
        self.mySunk = mySunk
        self.opponentShipsAfloat = opponentShipsAfloat
        self.myShipsAfloat = myShipsAfloat
        self.iAmReady = iAmReady
        self.opponentReady = opponentReady
        self.winnerSeat = winnerSeat
        self.revealedOpponentShips = revealedOpponentShips
    }

    /// Row-major 100-cell view of MY grid (index = row * 10 + col).
    public func ownGridCells() -> [BattleshipOwnCell] {
        var grid = [BattleshipOwnCell](repeating: .water, count: 100)
        for ship in myShips {
            for c in ship.cells where BattleshipRules.inBounds(c.row, c.col) { grid[c.row * 10 + c.col] = .ship(ship.kind) }
        }
        for shot in shotsAtMe {
            let idx = shot.row * 10 + shot.col
            if case .ship(let kind) = grid[idx] { grid[idx] = .hitShip(kind) } else { grid[idx] = .miss }
        }
        return grid
    }

    /// Row-major 100-cell view of the OPPONENT's grid as I know it.
    public func targetGridCells() -> [BattleshipTargetCell] {
        var grid = [BattleshipTargetCell](repeating: .unknown, count: 100)
        for shot in myShots { grid[shot.row * 10 + shot.col] = shot.result.isHit ? .hit : .miss }
        for ship in opponentSunk {
            for c in ship.cells { grid[c.row * 10 + c.col] = .sunk(ship.kind) }
        }
        return grid
    }
}

public extension BattleshipState {
    /// Redacted view for one seat — never leaks the opponent's unsunk positions.
    func snapshot(for seat: Int) -> BattleshipSnapshot {
        let opp = 1 - seat
        let over = phase == .gameOver
        return BattleshipSnapshot(
            mySeat: seat, phase: phase, salvo: salvo, turnSeat: turnSeat, isMyTurn: turnSeat == seat && phase == .battle,
            shotsRemaining: shotsRemaining, myShips: ships[seat] ?? [], shotsAtMe: shots[opp] ?? [],
            myShots: shots[seat] ?? [], opponentSunk: sunkShips(of: opp), mySunk: sunkShips(of: seat),
            opponentShipsAfloat: phase == .placement ? 0 : afloatShips(of: opp).count,
            myShipsAfloat: phase == .placement ? 0 : afloatShips(of: seat).count,
            iAmReady: ready.contains(seat), opponentReady: ready.contains(opp), winnerSeat: winnerSeat,
            revealedOpponentShips: over ? (ships[opp] ?? []) : []
        )
    }

    /// Public view for the shared table.
    func tableSnapshot() -> BattleshipTableSnapshot {
        let over = phase == .gameOver
        return BattleshipTableSnapshot(
            phase: phase, salvo: salvo, turnSeat: turnSeat, shotsRemaining: shotsRemaining,
            shotsBy: [0: shots[0] ?? [], 1: shots[1] ?? []],
            sunk: [0: sunkShips(of: 0), 1: sunkShips(of: 1)],
            shipsAfloat: phase == .placement ? [0: 0, 1: 0] : [0: afloatShips(of: 0).count, 1: afloatShips(of: 1).count],
            ready: ready, winnerSeat: winnerSeat,
            revealedShips: over ? [0: afloatShips(of: 0), 1: afloatShips(of: 1)] : [:]
        )
    }
}
