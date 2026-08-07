import Foundation
import Observation

/// Solitaire-style Yahtzee, table-side. Owns all rules state (the 5-die
/// persistent pool's held/rolled values, each seat's scorecard, whose turn
/// it is), requests physical rolls from the table's 3D dice scene exactly
/// like `DiceGameController` does, drives bot turns with the same
/// humanlike pacing, and pushes each phone its personalized
/// `DiceClientState` after every mutation.
///
/// Shape deliberately mirrors `DiceGameController` (same seat-building,
/// same watchdog-on-stall, same manual-cup gating, same
/// `stateVersion`/broadcast idiom) since that controller is this
/// platform-wave's reference implementation — see its own doc comment.
/// Two structural differences fall straight out of Yahtzee's own rules
/// rather than being invented here:
/// - There's no chips/pot economy, so there's no `ChipTransfer`/
///   `PendingTransfer` pair — a turn's only "payout" is one scorecard entry,
///   applied instantly (bots and humans alike; nothing to drag by hand).
/// - A turn is 1-3 ROLLS, not one roll — `rollsUsed`/`heldIndices` track
///   where a turn is mid-flight, and category picking happens ON THE TABLE
///   (the scoresheet), never on the phone. See `DiceClientState.isMyTurn`'s
///   generalized meaning (set in `state(for:)` below): it only stays true
///   while there's actually a roll left to shake; once `rollsUsed == 3` the
///   phone drops back to its standings screen with `statusLine` pointing
///   the player at the table.
///
/// ROLL-REQUEST TYPE NOTE for future dice-game workers: `DiceTableSceneView`/
/// `DiceTableSceneCoordinator` (Sources/App/Dice/Dice3D/DiceTableSceneView.swift)
/// hardcode `DiceGameController.Roll` as their roll-request parameter type —
/// there's no shared/generic "roll request" struct to build against yet.
/// Rather than invent a second incompatible one, this controller reuses
/// that exact nested type via the `Roll` typealias below (its fields —
/// id/seat/count/intensity — were never actually LCR-specific). A future
/// pass that wants a clean shared type will need to touch
/// `DiceTableSceneView.swift` to hoist it out; that file was out of this
/// wave's edit scope for every dice-game worker, so it's still the
/// as-shipped seam today.
@Observable
final class YahtzeeController {
    typealias Roll = DiceGameController.Roll

    struct YahtzeeSeat: Identifiable {
        let id: Int
        let name: String
        let isBot: Bool
        let deviceID: String?
        let colorIndex: Int
    }

    /// One turn's just-recorded result, kept a beat so the table can react
    /// (a gold flourish for a fresh upper-section bonus, the full trophy
    /// beat for a Yahtzee) before the next roller's plate lights up.
    struct ScoreEvent: Equatable {
        let id: Int
        let seat: Int
        let category: YahtzeeCategory
        let value: Int
        let yahtzeeBonus: Bool
        let upperBonusJustEarned: Bool
    }

    static let diceCount = 5

    let kind: DiceGameKind = .yahtzee
    private(set) var seats: [YahtzeeSeat] = []
    private(set) var turnSeat = 0
    private(set) var gameOver = false
    /// More than one entry only on an exact tie at game end.
    private(set) var winnerSeats: [Int] = []
    private(set) var currentRoll: Roll?
    private(set) var rollInFlight = false
    /// Rolls taken THIS turn, 0...3. `roll()` refuses a 4th; the roller
    /// must score a category instead.
    private(set) var rollsUsed = 0
    /// Table pool indices (0..<diceCount) the current roller has locked in
    /// for the rest of this turn — excluded from the next `roll()`'s count
    /// and from `DiceTableSceneCoordinator`'s launch pool via `setHeld`.
    private(set) var heldIndices: Set<Int> = []
    /// Manual cup loading progress this roll, same contract as
    /// `DiceGameController.loadedDiceCount` — reset to 0 every time a roll
    /// resolves or a new turn starts.
    private(set) var loadedDiceCount = 0
    /// Last known pip value per pool index (0..<diceCount) — a held die
    /// keeps its old value untouched across rerolls; an unheld one is
    /// overwritten the moment its next roll resolves. `nil` for a die that
    /// hasn't been read yet this game (only possible before the very first
    /// roll of the very first turn).
    private(set) var dieValues: [Int?]
    private(set) var scorecards: [YahtzeeScorecard] = []
    private(set) var lastScoreEvent: ScoreEvent?
    private(set) var stateVersion = 0

    private let host: GameHostController
    private var rng: SplitMix64
    private var rollCounter = 0
    private var scoreEventCounter = 0

    init(host: GameHostController, seats specs: [SeatSpec]) {
        self.host = host
        rng = SplitMix64(seed: UInt64.random(in: .min ... .max))
        dieValues = Array(repeating: nil, count: Self.diceCount)

        // Humans map onto connected lobby players in lobby order; bots get
        // their roster color for life — identical to DiceGameController's
        // own seat-building (and GameHostController.startGame's).
        var built: [YahtzeeSeat] = []
        var deviceMap: [String: Int] = [:]
        var humanIndex = 0
        for (seatID, spec) in specs.enumerated() {
            if spec.isBot {
                let color = BotRoster.identity(named: spec.name)?.colorIndex ?? seatID
                built.append(YahtzeeSeat(id: seatID, name: spec.name, isBot: true,
                                         deviceID: nil, colorIndex: color))
            } else if humanIndex < host.lobbyPlayers.count {
                let player = host.lobbyPlayers[humanIndex]
                humanIndex += 1
                let name = spec.name.isEmpty ? player.name : spec.name
                deviceMap[player.deviceID] = seatID
                built.append(YahtzeeSeat(id: seatID, name: name, isBot: false,
                                         deviceID: player.deviceID, colorIndex: seatID))
            } else {
                built.append(YahtzeeSeat(id: seatID, name: spec.name, isBot: false,
                                         deviceID: nil, colorIndex: seatID))
            }
        }
        seats = built
        scorecards = Array(repeating: YahtzeeScorecard(), count: built.count)

        host.diceSeatByDevice = deviceMap
        host.onDicePour = { [weak self] seat, intensity in
            self?.roll(from: seat, intensity: intensity)
        }
        host.onDiceHello = { [weak self] deviceID in
            self?.resendState(toDevice: deviceID)
        }

        Announcer.shared.announceGameStart(playerNames: built.map(\.name))
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Rolling

    /// Single entry for every roll: phone pours, plate taps, and bots all
    /// land here. Rolls only the currently UNHELD dice — the table's pool
    /// coordinator already excludes `.held` indices from its own launch
    /// selection (see `DiceTableSceneCoordinator.launch`'s `.held` guard),
    /// so requesting `count = diceCount - heldIndices.count` is enough to
    /// guarantee held dice never move.
    func roll(from seat: Int, intensity rawIntensity: Double) {
        guard !gameOver, !rollInFlight, seat == turnSeat, rollsUsed < 3,
              seats.indices.contains(seat) else {
            NSLog("Yahtzee: roll(from: %d) REFUSED — gameOver=%d inFlight=%d rollsUsed=%d turnSeat=%d",
                  seat, gameOver ? 1 : 0, rollInFlight ? 1 : 0, rollsUsed, turnSeat)
            return
        }
        guard canRoll(seat: seat) else {
            NSLog("Yahtzee: roll(from: %d) REFUSED — cup not loaded (%d/%d)",
                  seat, loadedDiceCount, requiredRollCount(seat: seat))
            return
        }
        let count = requiredRollCount(seat: seat)
        guard count > 0 else { return } // everything's held — nothing to roll

        let intensity = min(1.5, max(0.3, rawIntensity))
        rollCounter += 1
        let roll = Roll(id: rollCounter, seat: seat, count: count, intensity: intensity)
        rollInFlight = true
        currentRoll = roll
        stateVersion += 1
        TableSFX.shared.play(.dicePour)

        // Same watchdog shape as DiceGameController: if the scene never
        // reports back, fall back to seeded RNG faces so the game can't hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.rollInFlight, self.currentRoll?.id == roll.id else { return }
            let faces = (0..<count).map { _ in self.drawPip() }
            self.resolve(rollID: roll.id, faces: faces)
        }
    }

    /// The physics layer's report for a pip pool: settled 1-6 values, in
    /// the same order the coordinator actually launched them
    /// (`activeIndices.sorted()`, ascending pool index — see `resolve`'s
    /// own doc for how this controller reconstructs which pool index each
    /// value belongs to without the callback naming them directly).
    func completeRoll(id: Int, results: [DieResult]) {
        guard rollInFlight, currentRoll?.id == id else { return }
        let faces = results.compactMap { result -> Int? in
            if case .pip(let value) = result { return value }
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.resolve(rollID: id, faces: faces)
        }
    }

    /// Whether `seat` may currently roll: never once `rollsUsed == 3`
    /// (a category must be picked instead); always true for a bot or when
    /// auto-cup is on; for a manual-mode human, true only once every
    /// currently-unheld die is loaded. Mirrors
    /// `DiceGameController.canRoll` exactly, generalized past a flat "3".
    func canRoll(seat: Int) -> Bool {
        guard seats.indices.contains(seat), rollsUsed < 3 else { return false }
        if seats[seat].isBot || UserDefaults.standard.bool(forKey: "gn.autoCup") { return true }
        return loadedDiceCount >= requiredRollCount(seat: seat)
    }

    /// TableCupView calls this once per die dragged into the cup mouth —
    /// same contract as `DiceGameController.loadDie`.
    func loadDie(forSeat seat: Int) {
        guard !gameOver, !rollInFlight, seat == turnSeat, seats.indices.contains(seat),
              !seats[seat].isBot, loadedDiceCount < requiredRollCount(seat: seat) else { return }
        loadedDiceCount += 1
        TableSFX.shared.playDiceContact(.die, strength: 0.35)
        stateVersion += 1
        broadcast()
    }

    /// How many of the pool's `diceCount` dice are still unheld — the
    /// number the next roll actually throws.
    private func requiredRollCount(seat: Int) -> Int {
        Self.diceCount - heldIndices.count
    }

    /// Watchdog fallback only — a fair 1-6 pip, live results come from
    /// DieFaceReader via `completeRoll`.
    private func drawPip() -> Int {
        Int.random(in: 1...6, using: &rng)
    }

    private func resolve(rollID: Int, faces: [Int]) {
        guard let roll = currentRoll, roll.id == rollID, rollInFlight else { return }
        rollInFlight = false
        currentRoll = nil

        // `DiceTableSceneCoordinator.launch` always throws the pool's
        // resting/loaded dice in ASCENDING pool-index order (its `chosen`
        // array is explicitly `.sorted()` before firing) — since Yahtzee's
        // whole 5-die pool is either `.held` (excluded) or resting/loaded
        // (thrown), "every unheld index, ascending" reconstructs exactly
        // which pool index each face in `faces` belongs to without the
        // scene needing to say so directly.
        let rollingIndices = (0..<Self.diceCount).filter { !heldIndices.contains($0) }.sorted()
        for (index, value) in zip(rollingIndices, faces) {
            dieValues[index] = value
        }
        rollsUsed += 1
        loadedDiceCount = 0
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Holding

    /// The table-side half of the hold primitive — a resting/held die
    /// tapped (not dragged). Human rollers only; bots hold via
    /// `advanceBotTurn`'s direct `heldIndices` write. Only meaningful
    /// between rolls (at least one roll taken, more still available) —
    /// tapping before ever rolling or after the third roll is a no-op.
    func toggleHold(poolIndex: Int) {
        guard !gameOver, !rollInFlight, rollsUsed >= 1, rollsUsed < 3,
              seats.indices.contains(turnSeat), !seats[turnSeat].isBot,
              (0..<Self.diceCount).contains(poolIndex) else { return }
        if heldIndices.contains(poolIndex) {
            heldIndices.remove(poolIndex)
        } else {
            heldIndices.insert(poolIndex)
        }
        Haptics.tick()
        stateVersion += 1
        broadcast()
    }

    // MARK: - Scoring

    /// The full 5-value multiset for the CURRENT roller, only once every
    /// pool index actually has a known value (always true once
    /// `rollsUsed >= 1`, since the very first roll fills every index).
    var currentDice: [Int]? {
        let values = (0..<Self.diceCount).compactMap { dieValues[$0] }
        return values.count == Self.diceCount ? values : nil
    }

    /// What tapping `category` right now would score for `seat` — used by
    /// the scoresheet's live preview on open cells while it's that seat's
    /// turn to pick. `nil` when there's nothing to preview (category
    /// already filled, or the dice haven't all been read yet).
    func previewScore(_ category: YahtzeeCategory, forSeat seat: Int) -> Int? {
        guard let dice = currentDice, scorecards.indices.contains(seat),
              scorecards[seat].entries[category] == nil else { return nil }
        return YahtzeeScoring.score(dice: dice, category: category, isJoker: isJokerRoll(dice, seat: seat, category: category))
    }

    private func isJokerRoll(_ dice: [Int], seat: Int, category: YahtzeeCategory) -> Bool {
        category != .yahtzee && YahtzeeScoring.isYahtzee(dice) && (scorecards[seat].entries[.yahtzee] ?? 0) > 0
    }

    /// The scoresheet tap: the human roller (or a bot's own decision)
    /// commits `category` for `seat` using the CURRENT dice, ending the
    /// turn immediately regardless of `rollsUsed` (an early stop is just
    /// "tap a category before using all 3 rolls" — there's no separate
    /// "stop rolling" action to take first). Refuses anything that isn't
    /// actually legal right now: not this seat's turn, no roll yet this
    /// turn, a roll in flight, or the category's already filled.
    func scoreCategory(_ category: YahtzeeCategory, forSeat seat: Int) {
        guard !gameOver, !rollInFlight, seat == turnSeat, rollsUsed >= 1,
              scorecards.indices.contains(seat), scorecards[seat].entries[category] == nil,
              let dice = currentDice else {
            NSLog("Yahtzee: scoreCategory(%@, forSeat: %d) REFUSED", category.rawValue, seat)
            return
        }
        let bonus = isJokerRoll(dice, seat: seat, category: category)
        let value = YahtzeeScoring.score(dice: dice, category: category, isJoker: bonus)
        let beforeUpperBonus = scorecards[seat].upperBonus
        scorecards[seat].record(category: category, value: value, bonus: bonus)
        let upperBonusJustEarned = beforeUpperBonus == 0 && scorecards[seat].upperBonus > 0

        scoreEventCounter += 1
        lastScoreEvent = ScoreEvent(id: scoreEventCounter, seat: seat, category: category,
                                    value: value, yahtzeeBonus: bonus,
                                    upperBonusJustEarned: upperBonusJustEarned)

        if category == .yahtzee, value > 0 {
            // The trophy beat: fanfare + `YahtzeeTableView`'s own "YAHTZEE!"
            // callout. Deliberately NOT `Announcer.shared.announceGameWon` —
            // that clip says "<name>... winner!", which would misannounce
            // a mid-game roll as the actual end of the game.
            TableSFX.shared.play(.fanfareWin)
        } else if bonus {
            TableSFX.shared.play(.chipPlace)
        } else if upperBonusJustEarned {
            TableSFX.shared.play(.chipPlace)
        } else {
            TableSFX.shared.play(.cardFlip)
        }

        finishTurn()
    }

    private func finishTurn() {
        checkGameOver()
        if !gameOver {
            turnSeat = (turnSeat + 1) % max(1, seats.count)
        }
        heldIndices = []
        rollsUsed = 0
        loadedDiceCount = 0
        dieValues = Array(repeating: nil, count: Self.diceCount)
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Every seat has filled all 13 categories — since turns are strict
    /// round-robin with no skipping, this is true for every seat at once.
    /// Ties (identical top score) all get named winners rather than
    /// arbitrarily picking one.
    private func checkGameOver() {
        guard scorecards.allSatisfy(\.isComplete) else { return }
        gameOver = true
        let topScore = scorecards.map(\.total).max() ?? 0
        winnerSeats = scorecards.indices.filter { scorecards[$0].total == topScore }
        TableSFX.shared.play(.fanfareWin)
        if let first = winnerSeats.first, seats.indices.contains(first) {
            Announcer.shared.announceGameWon(winnerName: seats[first].name, margin: 0)
        }
    }

    // MARK: - Bots

    /// Humanlike pacing beat before a bot acts — same random 1.2-2.0s
    /// window as `DiceGameController.scheduleBotIfNeeded`, re-validated
    /// against `stateVersion` on fire so a stale timer from an abandoned
    /// turn can never act late.
    private func scheduleBotIfNeeded() {
        guard !gameOver, !rollInFlight, seats.indices.contains(turnSeat),
              seats[turnSeat].isBot else { return }
        let expectedTurn = turnSeat
        let expectedVersion = stateVersion
        let delay = Double.random(in: 1.2...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.gameOver, !self.rollInFlight,
                  self.turnSeat == expectedTurn, self.stateVersion == expectedVersion else { return }
            self.advanceBotTurn()
        }
    }

    /// One bot beat: the opening roll needs no decision; after that, hold
    /// the dice `YahtzeeBot.chooseHolds` recommends and either reroll
    /// (rolls remain and something's still unheld) or — out of rolls, or
    /// holding everything already — score the best open category.
    private func advanceBotTurn() {
        let seat = turnSeat
        guard seats.indices.contains(seat), seats[seat].isBot else { return }

        if rollsUsed == 0 {
            roll(from: seat, intensity: .random(in: 0.5...1.1))
            return
        }
        guard let dice = currentDice else {
            roll(from: seat, intensity: .random(in: 0.5...1.1)) // defensive: shouldn't happen
            return
        }

        let holds = YahtzeeBot.chooseHolds(values: currentDieValueMap(), scorecard: scorecards[seat])
        if rollsUsed < 3, holds.count < Self.diceCount {
            heldIndices = holds
            stateVersion += 1
            broadcast()
            let expectedVersion = stateVersion
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.9...1.5)) { [weak self] in
                guard let self, !self.gameOver, self.turnSeat == seat,
                      self.stateVersion == expectedVersion else { return }
                self.roll(from: seat, intensity: .random(in: 0.5...1.1))
            }
        } else {
            let category = YahtzeeBot.chooseCategory(dice: dice, scorecard: scorecards[seat])
            scoreCategory(category, forSeat: seat)
        }
    }

    private func currentDieValueMap() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for index in 0..<Self.diceCount {
            if let value = dieValues[index] { map[index] = value }
        }
        return map
    }

    // MARK: - Restart / end

    /// Fresh game, same table: every scorecard clears, the previous
    /// winner rolls first (first winner on a tie), dice pool state resets.
    func restart() {
        guard gameOver else { return }
        scorecards = Array(repeating: YahtzeeScorecard(), count: seats.count)
        gameOver = false
        turnSeat = winnerSeats.first ?? 0
        winnerSeats = []
        currentRoll = nil
        rollInFlight = false
        rollsUsed = 0
        heldIndices = []
        loadedDiceCount = 0
        dieValues = Array(repeating: nil, count: Self.diceCount)
        lastScoreEvent = nil
        stateVersion += 1
        TableSFX.shared.play(.shuffle)
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Outbound

    private func broadcast() {
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(state(for: seat.id), toDevice: deviceID)
        }
    }

    /// One seat's personalized view of the game right now. `chips` is
    /// repurposed per the doc on `DiceClientState.chips` — only the
    /// current roller's entry (how many unheld dice are left to throw) is
    /// ever read by the phone, so every other seat just carries the
    /// game's full dice count.
    private func state(for seatID: Int) -> DiceClientState {
        let mine = seatID == turnSeat
        return DiceClientState(
            kind: kind, mySeat: seatID, seatNames: seats.map(\.name),
            chips: seats.indices.map { $0 == turnSeat ? requiredRollCount(seat: turnSeat) : Self.diceCount },
            centerPot: 0, turnSeat: turnSeat,
            // Only ever true while there's actually a roll left to shake —
            // once rollsUsed hits 3 the phone drops to standings/statusLine
            // pointing the player at the table's scoresheet.
            isMyTurn: !gameOver && !rollInFlight && mine && rollsUsed < 3,
            gameOver: gameOver,
            winnerSeat: winnerSeats.count == 1 ? winnerSeats.first : nil,
            cupReady: canRoll(seat: seatID),
            loadedDice: seatID == turnSeat ? loadedDiceCount : 0,
            statusLine: statusLine(for: seatID),
            rollsLeft: 3 - rollsUsed,
            standingsLines: seats.map { "\($0.name): \(scorecards[safe: $0.id]?.total ?? 0)" })
    }

    private func statusLine(for seatID: Int) -> String {
        guard seats.indices.contains(seatID) else { return "" }
        if gameOver { return "" }
        if seatID != turnSeat {
            return "\(seats[turnSeat].name) is playing…"
        }
        if rollsUsed >= 3 {
            return "Pick a category on the table"
        }
        if rollsUsed == 0 {
            return "Shake to roll — roll 1 of 3"
        }
        return "Tap dice on the table to keep, then shake for roll \(rollsUsed + 1) of 3"
    }

    private func resendState(toDevice deviceID: String) {
        guard let seat = seats.first(where: { $0.deviceID == deviceID }) else { return }
        host.sendDiceState(state(for: seat.id), toDevice: deviceID)
    }

    /// Tear-down: every phone gets the "dice closed" sentinel, and the
    /// host's dice routing is unhooked — identical contract to
    /// `DiceGameController.end`.
    func end() {
        let sentinel = DiceClientState(
            kind: kind, mySeat: -1, seatNames: [], chips: [], centerPot: 0,
            turnSeat: -1, isMyTurn: false, gameOver: true, winnerSeat: nil)
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(sentinel, toDevice: deviceID)
        }
        host.diceSeatByDevice = [:]
        host.onDicePour = nil
        host.onDiceHello = nil
    }
}

// `Array.subscript(safe:)` used above (`scorecards[safe:]`) is the shared
// module-wide bounds-safe subscript already declared in
// DotsAndBoxesPaperView.swift — deliberately not redeclared here.

/// Small seeded RNG (SplitMix64), watchdog-fallback only — identical
/// implementation to `DiceGameController`'s private one (that one isn't
/// reachable from here, so this is a deliberate small duplication rather
/// than reaching into a forbidden-to-edit file to share it).
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
