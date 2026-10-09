import Foundation

/// The authoritative Battleship reducer — same shape as `CribbageEngine`
/// (`apply(action, from: seat) -> [events]`, seeded, Codable `state`,
/// per-seat redacted snapshots), standalone and fixed 2-player.
///
/// ## Flow
/// `.placement` (each seat places 5 ships via `placeShip` / `randomizeFleet`,
/// then `confirmPlacement`) -> `.battle` (alternating `fire`) -> `.gameOver`.
/// `firstSeat` (who fires first) is `seed % 2`.
///
/// ## Rules
/// - Classic: one shot per turn, hit or miss. Ships may touch; no wrap.
/// - Salvo variant (`salvo: true`, default off): a turn is one shot per ship
///   still afloat on the shooter's side (`shotsRemaining`). Shots are fired
///   and resolved one at a time (the shooter sees each result immediately).
/// - Sinking: the shot that completes a ship returns `.sunk(kind)` and the
///   event carries the whole ship so the table can draw its silhouette.
/// - Win: the moment the opponent's fifth ship sinks.
///
/// ## Wire
/// Every state/snapshot/action/event is `Codable`; `kind` is the side-game
/// seam key.
public final class BattleshipEngine {
    public static let kind = "battleship"

    public private(set) var state: BattleshipState

    public init(seed: UInt64, salvo: Bool = false) {
        state = BattleshipState(
            seed: seed, salvo: salvo, phase: .placement, ships: [0: [], 1: []], ready: [],
            shots: [0: [], 1: []], turnSeat: nil, shotsRemaining: 0, firstSeat: Int(seed % 2),
            shotCounter: 0, winnerSeat: nil
        )
    }

    public init(restoring state: BattleshipState) {
        self.state = state
    }

    /// A complete legal fleet from `seed` (see `BattleshipRules.randomPlacement`).
    public static func randomPlacement(seed: UInt64) -> [BattleshipShip] {
        BattleshipRules.randomPlacement(seed: seed)
    }

    public func snapshot(for seat: Int) -> BattleshipSnapshot { state.snapshot(for: seat) }
    public func tableSnapshot() -> BattleshipTableSnapshot { state.tableSnapshot() }

    public func apply(_ action: BattleshipAction, from seat: Int) -> [BattleshipEvent] {
        guard seat == 0 || seat == 1 else { return reject(seat, "Battleship only has two seats") }
        guard state.phase != .gameOver else { return reject(seat, "The game is over") }
        switch action {
        case .placeShip(let kind, let row, let col, let orientation):
            return handlePlace(BattleshipShip(kind: kind, row: row, col: col, orientation: orientation), from: seat)
        case .removeShip(let kind):
            return handleRemove(kind, from: seat)
        case .randomizeFleet(let seed):
            return handleRandomize(seed, from: seat)
        case .confirmPlacement:
            return handleConfirm(from: seat)
        case .fire(let row, let col):
            return handleFire(row, col, from: seat)
        }
    }

    // MARK: - Placement

    private func guardPlacement(_ seat: Int) -> String? {
        if state.phase != .placement { return "Placement is over" }
        if state.ready.contains(seat) { return "You've already locked in your fleet" }
        return nil
    }

    private func handlePlace(_ ship: BattleshipShip, from seat: Int) -> [BattleshipEvent] {
        if let why = guardPlacement(seat) { return reject(seat, why) }
        let existing = state.ships[seat] ?? []
        if let why = BattleshipRules.validatePlacement(ship, existing: existing) { return reject(seat, why) }
        var fleet = existing.filter { $0.kind != ship.kind }
        fleet.append(ship)
        state.ships[seat] = orderedFleet(fleet)
        return [.shipPlaced(seat: seat, kind: ship.kind)]
    }

    private func handleRemove(_ kind: BattleshipShipKind, from seat: Int) -> [BattleshipEvent] {
        if let why = guardPlacement(seat) { return reject(seat, why) }
        var fleet = state.ships[seat] ?? []
        guard fleet.contains(where: { $0.kind == kind }) else { return reject(seat, "That ship isn't placed") }
        fleet.removeAll { $0.kind == kind }
        state.ships[seat] = fleet
        return [.shipRemoved(seat: seat, kind: kind)]
    }

    private func handleRandomize(_ seed: UInt64, from seat: Int) -> [BattleshipEvent] {
        if let why = guardPlacement(seat) { return reject(seat, why) }
        state.ships[seat] = orderedFleet(BattleshipRules.randomPlacement(seed: seed))
        return [.fleetRandomized(seat: seat)]
    }

    private func handleConfirm(from seat: Int) -> [BattleshipEvent] {
        if let why = guardPlacement(seat) { return reject(seat, why) }
        let placed = Set((state.ships[seat] ?? []).map(\.kind))
        guard placed.count == BattleshipRules.fleet.count else { return reject(seat, "Place all five ships first") }
        state.ready.insert(seat)
        var events: [BattleshipEvent] = [.placementConfirmed(seat: seat)]
        if state.ready.count == 2 {
            state.phase = .battle
            state.turnSeat = state.firstSeat
            state.shotsRemaining = shotsFor(state.firstSeat)
            events.append(.battleBegan(firstSeat: state.firstSeat, salvo: state.salvo))
        }
        return events
    }

    private func orderedFleet(_ fleet: [BattleshipShip]) -> [BattleshipShip] {
        BattleshipRules.fleet.compactMap { kind in fleet.first { $0.kind == kind } }
    }

    // MARK: - Battle

    private func shotsFor(_ seat: Int) -> Int {
        state.salvo ? max(1, state.afloatShips(of: seat).count) : 1
    }

    private func handleFire(_ row: Int, _ col: Int, from seat: Int) -> [BattleshipEvent] {
        guard state.phase == .battle else { return reject(seat, "The battle hasn't started") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        guard BattleshipRules.inBounds(row, col) else { return reject(seat, "That's off the board") }
        let mine = state.shots[seat] ?? []
        guard !mine.contains(where: { $0.row == row && $0.col == col }) else {
            return reject(seat, "You already fired there")
        }
        let opp = 1 - seat
        let target = BattleshipCell(row: row, col: col)
        let struck = (state.ships[opp] ?? []).first { $0.cells.contains(target) }
        var result: BattleshipShotResult = .miss
        var sunkShip: BattleshipShip?
        if let ship = struck {
            let priorHits = Set(mine.filter { $0.result.isHit }.map(\.cell))
            if ship.cells.allSatisfy({ $0 == target || priorHits.contains($0) }) {
                result = .sunk(ship.kind)
                sunkShip = ship
            } else {
                result = .hit
            }
        }
        state.shots[seat, default: []].append(BattleshipShot(row: row, col: col, result: result, turn: state.shotCounter))
        state.shotCounter += 1
        var events: [BattleshipEvent] = [.shotFired(seat: seat, cell: target, result: result, sunkShip: sunkShip)]

        if state.afloatShips(of: opp).isEmpty {
            state.phase = .gameOver
            state.winnerSeat = seat
            state.turnSeat = nil
            state.shotsRemaining = 0
            events.append(.gameWon(seat: seat))
            return events
        }
        state.shotsRemaining -= 1
        if state.shotsRemaining <= 0 {
            state.turnSeat = opp
            state.shotsRemaining = shotsFor(opp)
            events.append(.turnChanged(seat: opp, shots: state.shotsRemaining))
        }
        return events
    }

    private func reject(_ seat: Int, _ reason: String) -> [BattleshipEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
