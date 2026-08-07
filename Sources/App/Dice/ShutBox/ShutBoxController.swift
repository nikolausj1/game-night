import Foundation
import Observation

/// Classic pub Shut the Box, table-side. Owns all rules state (the box's 9
/// tiles, whose turn it is, this round's scores), requests physical rolls
/// from the table's 3D dice scene exactly like `DiceGameController` (LCR)
/// does — the settled faces ARE the result, physics is the RNG — drives bot
/// turns, and pushes each phone a state update after every mutation. This
/// is the dice-game sibling of `DiceGameController`, deliberately mirroring
/// its shape (seat-building, roll lifecycle, bot scheduling, broadcast)
/// rather than sharing a base class with it — LCR's controller is owned by
/// another worker and lives outside this file's edit scope (`Sources/App/
/// Dice/ShutBox/**` only), so duplication here is the seam, not a
/// refactor waiting to happen.
///
/// Rules as implemented (classic pub Shut the Box):
/// - The box has 9 tiles, values 1...9, all standing at the start of each
///   player's turn.
/// - On your turn: roll 2 dice (or, once tiles 7/8/9 are ALL down, you may
///   choose to roll just 1 — `oneDieAvailable`/`usingOneDie`). Flip any set
///   of standing tiles whose values sum EXACTLY to the roll, then roll
///   again. Keep going until either every tile is down (SHUT THE BOX — an
///   instant win, score 0) or no legal set exists for the roll (your turn
///   ends; your score is the sum of the tiles still standing).
/// - Turns are SEQUENTIAL and non-concurrent, one full stuck-or-shut turn
///   per player, each starting from a freshly reset box — never everyone
///   rolling into the same shared box at once.
/// - Round winner: lowest score (a shut box's 0 always wins outright and
///   ends the round immediately, skipping anyone who hasn't gone yet).
///   `roundsToWin` (default 1) supports a multi-round match; the default
///   single-round game just ends after that one round with a play-again
///   loop (`restart()`).
@Observable
final class ShutBoxController {
    /// One chair in the game — same shape as `DiceGameController.DiceSeat`.
    struct ShutBoxSeat: Identifiable {
        let id: Int
        let name: String
        let isBot: Bool
        let deviceID: String?
        let colorIndex: Int
    }

    /// The 9 tiles, values 1...9 at indices 0...8. `true` = still standing.
    private(set) var standing: [Bool] = Array(repeating: true, count: 9)
    /// Tiles the CURRENT human roller has tipped as candidates for their
    /// next confirm — cleared on every new roll and on confirm. Bots never
    /// populate this for longer than the preview beat (see
    /// `handleBotDecision`).
    private(set) var selected: Set<Int> = []
    /// The last roll's settled pip values, in die order — empty once
    /// they've been resolved (confirmed or busted). Non-empty is exactly
    /// "there's a live roll on the felt waiting for a set."
    private(set) var lastDice: [Int] = []

    private(set) var seats: [ShutBoxSeat] = []
    private(set) var turnSeat = 0
    private(set) var roundIndex = 0
    let roundsToWin: Int
    private(set) var roundsWon: [Int] = []
    /// This round's score per seat; `nil` = hasn't taken their turn yet.
    private(set) var roundScores: [Int?] = []

    private(set) var currentRoll: DiceGameController.Roll?
    private(set) var rollInFlight = false
    private(set) var loadedDiceCount = 0
    /// This turn's die-count choice — 2 unless the player (or a bot, by
    /// expectation) has switched to 1. Reset to `false` at the start of
    /// every turn.
    private(set) var usingOneDie = false
    /// Unlocked once tiles 7, 8, and 9 are ALL down — the brass toggle only
    /// ever appears once this flips true.
    private(set) var oneDieAvailable = false

    /// Set the instant a turn busts (no legal set for the roll) and cleared
    /// ~1.6s later once the score has inked onto the paper scorecard and
    /// the turn actually advances — the table view keys its scorecard
    /// overlay off this window.
    private(set) var lastBustedSeat: Int?
    private(set) var lastBustedScore: Int?
    /// Set the instant someone shuts the box and held through game-over —
    /// the table view's trophy overlay and the final banner both key off
    /// this. Cleared by `restart()`.
    private(set) var shutTheBoxSeat: Int?

    private(set) var gameOver = false
    /// Usually one seat; more than one on a tied lowest score.
    private(set) var winnerSeats: [Int] = []

    /// Short status line for the felt HUD / (once the wire carries it) the
    /// active roller's phone — "Flip tiles adding to 7", "One die
    /// unlocked!", etc. Table-only today; see `state(for:)`'s doc for the
    /// wire-format note.
    private(set) var statusLine = ""

    /// Monotonic bump on every mutation — same redraw-guarantee pattern as
    /// `DiceGameController.stateVersion`.
    private(set) var stateVersion = 0

    private let host: GameHostController
    private var rng: SplitMix64
    private var rollCounter = 0

    init(host: GameHostController, seats specs: [SeatSpec], roundsToWin: Int = 1) {
        self.host = host
        self.roundsToWin = max(1, roundsToWin)
        rng = SplitMix64(seed: UInt64.random(in: .min ... .max))

        // Humans map onto connected lobby players in lobby order; bots get
        // their roster color for life — identical construction to
        // `DiceGameController.init`.
        var built: [ShutBoxSeat] = []
        var deviceMap: [String: Int] = [:]
        var humanIndex = 0
        for (seatID, spec) in specs.enumerated() {
            if spec.isBot {
                let color = BotRoster.identity(named: spec.name)?.colorIndex ?? seatID
                built.append(ShutBoxSeat(id: seatID, name: spec.name, isBot: true,
                                         deviceID: nil, colorIndex: color))
            } else if humanIndex < host.lobbyPlayers.count {
                let player = host.lobbyPlayers[humanIndex]
                humanIndex += 1
                let name = spec.name.isEmpty ? player.name : spec.name
                deviceMap[player.deviceID] = seatID
                built.append(ShutBoxSeat(id: seatID, name: name, isBot: false,
                                         deviceID: player.deviceID, colorIndex: seatID))
            } else {
                built.append(ShutBoxSeat(id: seatID, name: spec.name, isBot: false,
                                         deviceID: nil, colorIndex: seatID))
            }
        }
        seats = built
        roundScores = Array(repeating: nil, count: built.count)
        roundsWon = Array(repeating: 0, count: built.count)

        host.diceSeatByDevice = deviceMap
        host.onDicePour = { [weak self] seat, intensity in
            self?.roll(from: seat, intensity: intensity)
        }
        host.onDiceHello = { [weak self] deviceID in
            self?.resendState(toDevice: deviceID)
        }

        Announcer.shared.announceGameStart(playerNames: built.map(\.name))
        resetBoxForCurrentPlayer()
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Rolling

    /// Single entry for every roll: phone pours, plate taps, and bots all
    /// land here — identical contract to `DiceGameController.roll`.
    func roll(from seat: Int, intensity rawIntensity: Double) {
        guard !gameOver, !rollInFlight, seat == turnSeat, lastDice.isEmpty,
              seats.indices.contains(seat) else { return }
        guard canRoll(seat: seat) else { return }
        selected.removeAll()

        let dieCount = usingOneDie ? 1 : 2
        let intensity = min(1.5, max(0.3, rawIntensity))
        rollCounter += 1
        let roll = DiceGameController.Roll(id: rollCounter, seat: seat, count: dieCount, intensity: intensity)
        rollInFlight = true
        currentRoll = roll
        stateVersion += 1
        TableSFX.shared.play(.dicePour)

        // Same 10s physics watchdog LCR uses: if the scene never reports
        // back, fall back to seeded RNG pips so the game never hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.rollInFlight, self.currentRoll?.id == roll.id else { return }
            let faces = (0..<dieCount).map { _ in DieResult.pip(self.drawPip()) }
            self.completeRoll(id: roll.id, results: faces)
        }
    }

    /// The physics layer's report: the dice have settled. A short beat lets
    /// everyone read the table before tiles react.
    func completeRoll(id: Int, results: [DieResult]) {
        guard rollInFlight, currentRoll?.id == id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.resolve(rollID: id, results: results)
        }
    }

    /// Whether `seat` may currently roll — same manual-cup contract as LCR,
    /// reading `gn.autoCup` live (not cached) and against however many dice
    /// THIS turn actually needs (1 once one-die is chosen, else 2).
    func canRoll(seat: Int) -> Bool {
        guard seats.indices.contains(seat) else { return false }
        if seats[seat].isBot || UserDefaults.standard.bool(forKey: "gn.autoCup") { return true }
        return loadedDiceCount >= (usingOneDie ? 1 : 2)
    }

    /// TableCupView calls this once per die dragged into the cup mouth —
    /// identical contract to `DiceGameController.loadDie`.
    func loadDie(forSeat seat: Int) {
        guard !gameOver, !rollInFlight, seat == turnSeat, seats.indices.contains(seat),
              !seats[seat].isBot, lastDice.isEmpty,
              loadedDiceCount < (usingOneDie ? 1 : 2) else { return }
        loadedDiceCount += 1
        TableSFX.shared.playDiceContact(.die, strength: 0.35)
        stateVersion += 1
        broadcast()
    }

    private func drawPip() -> Int { Int.random(in: 1...6, using: &rng) }

    private func resolve(rollID: Int, results: [DieResult]) {
        guard let roll = currentRoll, roll.id == rollID, rollInFlight else { return }
        rollInFlight = false
        currentRoll = nil
        lastDice = results.compactMap { result -> Int? in
            if case .pip(let value) = result { return value }
            return nil
        }
        let sum = lastDice.reduce(0, +)

        if seats[roll.seat].isBot {
            handleBotDecision(seat: roll.seat, sum: sum)
        } else {
            let hasLegalSet = !legalSubsets(forSum: sum).isEmpty
            statusLine = hasLegalSet ? "Flip tiles adding to \(sum)" : "No set adds to \(sum)…"
            stateVersion += 1
            broadcast()
            if !hasLegalSet {
                handleBust(seat: roll.seat)
            }
        }
    }

    // MARK: - Tile selection (human)

    /// Tap a standing tile to tip it as a candidate (or un-tip an already
    /// selected one). No-op for a bot's turn, a folded tile, or when
    /// there's no live roll to match against.
    func toggleTileCandidate(_ tileIndex: Int) {
        guard !gameOver, !rollInFlight, standing.indices.contains(tileIndex),
              seats.indices.contains(turnSeat), !seats[turnSeat].isBot,
              standing[tileIndex], !lastDice.isEmpty else { return }
        if selected.contains(tileIndex) {
            selected.remove(tileIndex)
        } else {
            selected.insert(tileIndex)
        }
        Haptics.tick()
        stateVersion += 1
    }

    /// Sum of the currently tipped candidates (tile value = index + 1).
    var selectedSum: Int { selected.reduce(0) { $0 + ($1 + 1) } }

    /// Arms the confirm button — an EXACT match against the live roll, and
    /// at least one tile selected.
    var selectionMatchesRoll: Bool {
        !selected.isEmpty && !lastDice.isEmpty && selectedSum == lastDice.reduce(0, +)
    }

    /// Every standing tile that participates in AT LEAST ONE legal exact-sum
    /// set for the live roll — the table view uses this to keep genuinely
    /// useful tiles full-brightness and dim the rest, without ever handing
    /// over the actual combination.
    var tilesInPlay: Set<Int> {
        guard !lastDice.isEmpty else { return [] }
        let sum = lastDice.reduce(0, +)
        var result: Set<Int> = []
        for subset in legalSubsets(forSum: sum) {
            for value in subset { result.insert(value - 1) }
        }
        return result
    }

    /// Flips the tipped candidates for real, on an exact match.
    func confirmSelection() {
        guard selectionMatchesRoll, !seats[turnSeat].isBot else { return }
        flipTiles(selected, seat: turnSeat)
        selected.removeAll()
        lastDice = []
        checkShutOrContinue(seat: turnSeat)
    }

    /// The brass toggle: only reachable before rolling, once unlocked, for
    /// a human, with nothing mid-flight.
    func toggleOneDie() {
        guard !gameOver, !rollInFlight, oneDieAvailable, lastDice.isEmpty,
              seats.indices.contains(turnSeat), !seats[turnSeat].isBot else { return }
        usingOneDie.toggle()
        Haptics.tick()
        stateVersion += 1
        broadcast()
    }

    private func flipTiles(_ indices: Set<Int>, seat: Int) {
        for index in indices where standing.indices.contains(index) { standing[index] = false }
        // Wooden clack: reusing the dice-contact "rail" bank (a woodier,
        // more resonant knock than felt/die-on-die) — the SFX audit's
        // closest existing match to a tile knocking home; no dedicated
        // "wood knock" sample exists in TableSFX's inventory.
        TableSFX.shared.playDiceContact(.rail, strength: 0.65)
        Haptics.arm()
        updateOneDieAvailability()
        stateVersion += 1
        broadcast()
    }

    private func checkShutOrContinue(seat: Int) {
        if standing.allSatisfy({ !$0 }) {
            shutTheBox(seat: seat)
            return
        }
        statusLine = "\(seats[seat].name), roll again"
        stateVersion += 1
        broadcast()
        // A bot's turn doesn't stop after one successful flip — it keeps
        // rolling until it's shut the box or busts. `scheduleBotIfNeeded`
        // is a no-op for a human seat (nothing here waits on a human; the
        // plate tap / phone shake drives their next roll instead), so this
        // is safe to call unconditionally after every mid-turn flip.
        scheduleBotIfNeeded()
    }

    // MARK: - Bots

    /// A bot's whole turn-in-one-roll decision: pick the best legal set (or
    /// bust), with a short preview beat (tip the tiles, THEN flip) so a bot
    /// turn still reads as a deliberate choice rather than an instant snap.
    private func handleBotDecision(seat: Int, sum: Int) {
        let subsets = legalSubsets(forSum: sum)
        guard !subsets.isEmpty else {
            statusLine = "No set adds to \(sum)…"
            stateVersion += 1
            broadcast()
            handleBust(seat: seat)
            return
        }
        let chosen = Set(Self.botPreferredSubset(subsets).map { $0 - 1 })
        statusLine = "\(seats[seat].name) is thinking…"
        stateVersion += 1
        broadcast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.turnSeat == seat, !self.gameOver else { return }
            self.selected = chosen
            self.stateVersion += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, self.turnSeat == seat, !self.gameOver else { return }
                self.flipTiles(chosen, seat: seat)
                self.selected.removeAll()
                self.lastDice = []
                self.checkShutOrContinue(seat: seat)
            }
        }
    }

    /// Optimal-ish tile choice: fewest tiles first (clearing one big tile
    /// beats clearing three small ones for the same sum), then the larger
    /// max value among ties — real basic strategy, since burning a single
    /// high tile preserves more small, flexible numbers for later rolls
    /// than scattering the same total across several of them.
    private static func botPreferredSubset(_ subsets: [[Int]]) -> [Int] {
        subsets.min { a, b in
            if a.count != b.count { return a.count < b.count }
            return (a.max() ?? 0) > (b.max() ?? 0)
        } ?? subsets[0]
    }

    /// Whether a bot should switch to one die once it's unlocked: compare
    /// the fraction of outcomes that leave AT LEAST ONE legal set with one
    /// die (faces 1...6, 6 equally likely outcomes) vs. two (sums 2...12
    /// over the true 36-combination distribution) against the board as it
    /// stands RIGHT NOW, and take whichever has the lower bust chance —
    /// "one-die when beneficial by expectation."
    private func botDecideOneDie() -> Bool {
        guard oneDieAvailable else { return false }
        var oneDieHits = 0
        for face in 1...6 where !legalSubsets(forSum: face).isEmpty { oneDieHits += 1 }
        var twoDiceHits = 0
        for a in 1...6 { for b in 1...6 where !legalSubsets(forSum: a + b).isEmpty { twoDiceHits += 1 } }
        let pOne = Double(oneDieHits) / 6.0
        let pTwo = Double(twoDiceHits) / 36.0
        return pOne > pTwo
    }

    private func scheduleBotIfNeeded() {
        guard !gameOver, !rollInFlight, lastDice.isEmpty,
              seats.indices.contains(turnSeat), seats[turnSeat].isBot else { return }
        let expectedTurn = turnSeat
        let expectedVersion = stateVersion
        let delay = Double.random(in: 1.0...1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.gameOver, !self.rollInFlight,
                  self.turnSeat == expectedTurn, self.stateVersion == expectedVersion else { return }
            self.usingOneDie = self.botDecideOneDie()
            self.roll(from: expectedTurn, intensity: .random(in: 0.5...1.1))
        }
    }

    // MARK: - Busting / turn advance

    /// No legal set for the live roll: score = sum of what's still
    /// standing. The table shows the resigned rattle + paper scorecard for
    /// a beat before the turn actually moves on.
    private func handleBust(seat: Int) {
        let score = standing.indices.filter { standing[$0] }.reduce(0) { $0 + ($1 + 1) }
        roundScores[seat] = score
        lastBustedSeat = seat
        lastBustedScore = score
        lastDice = []
        TableSFX.shared.play(.softChime)
        stateVersion += 1
        broadcast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.lastBustedSeat == seat else { return }
            self.lastBustedSeat = nil
            self.lastBustedScore = nil
            self.advanceTurnOrEndRound()
        }
    }

    private func advanceTurnOrEndRound() {
        let next = turnSeat + 1
        guard next < seats.count else {
            finishRound()
            return
        }
        turnSeat = next
        resetBoxForCurrentPlayer()
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    private func resetBoxForCurrentPlayer() {
        standing = Array(repeating: true, count: 9)
        selected = []
        lastDice = []
        usingOneDie = false
        oneDieAvailable = false
        loadedDiceCount = 0
        statusLine = seats.indices.contains(turnSeat)
            ? "\(seats[turnSeat].name)'s box — roll to begin" : ""
    }

    private func updateOneDieAvailability() {
        // Indices 6, 7, 8 are tile values 7, 8, 9.
        oneDieAvailable = !standing[6] && !standing[7] && !standing[8]
    }

    private func shutTheBox(seat: Int) {
        shutTheBoxSeat = seat
        roundScores[seat] = 0
        lastDice = []
        TableSFX.shared.play(.fanfareWin)
        Announcer.shared.announceGameWon(winnerName: seats[seat].name, margin: 0)
        finishRound()
    }

    // MARK: - Round / game resolution

    private func finishRound() {
        let played = roundScores.enumerated().compactMap { index, score in score.map { (index, $0) } }
        let minScore = played.map(\.1).min() ?? 0
        let winners = played.filter { $0.1 == minScore }.map(\.0)
        winnerSeats = winners
        for winner in winners { roundsWon[winner] += 1 }

        // Announcer's own grammar reads HIGHER as better ("leader"); Shut
        // the Box is lowest-wins, so it's given inverted points (a
        // perfect-box 0 becomes the max) purely for that one broadcast —
        // never stored, never shown anywhere a player could see the number.
        let standings = played.map { (name: seats[$0.0].name, score: 45 - $0.1) }
        if !standings.isEmpty { Announcer.shared.announceRoundScored(standings: standings) }

        if let solo = winners.count == 1 ? winners.first : nil, roundsWon[solo] >= roundsToWin {
            gameOver = true
            if shutTheBoxSeat != solo {
                TableSFX.shared.play(.fanfareWin)
                Announcer.shared.announceGameWon(winnerName: seats[solo].name, margin: 0)
            }
        } else if roundsToWin <= 1 {
            // Single-round match (the default) always resolves after one
            // round, tie or not — there's no next round to break it.
            gameOver = true
        } else {
            roundIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.beginNextRound()
            }
        }
        stateVersion += 1
        broadcast()
    }

    private func beginNextRound() {
        guard !gameOver else { return }
        roundScores = Array(repeating: nil, count: seats.count)
        turnSeat = 0
        shutTheBoxSeat = nil
        resetBoxForCurrentPlayer()
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Fresh game, same table — play-again loop off the final banner.
    func restart() {
        guard gameOver else { return }
        gameOver = false
        winnerSeats = []
        shutTheBoxSeat = nil
        roundScores = Array(repeating: nil, count: seats.count)
        roundsWon = Array(repeating: 0, count: seats.count)
        roundIndex = 0
        turnSeat = 0
        resetBoxForCurrentPlayer()
        TableSFX.shared.play(.shuffle)
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Legal-set search

    /// Every combination of currently-standing tile VALUES (not indices)
    /// that sums exactly to `sum`. At most 9 standing tiles, so a plain
    /// backtrack is cheap — called every roll (and twice more per bot
    /// one-die decision, 6 + 36 times over) with no need for memoization.
    private func legalSubsets(forSum sum: Int) -> [[Int]] {
        guard sum > 0 else { return [] }
        let values = standing.indices.filter { standing[$0] }.map { $0 + 1 }
        var results: [[Int]] = []
        func backtrack(start: Int, remaining: Int, path: [Int]) {
            if remaining == 0 { results.append(path); return }
            guard start < values.count else { return }
            for i in start..<values.count where values[i] <= remaining {
                backtrack(start: i + 1, remaining: remaining - values[i], path: path + [values[i]])
            }
        }
        backtrack(start: 0, remaining: sum, path: [])
        return results
    }

    // MARK: - Outbound

    /// Every phone gets its own personalized state after every mutation —
    /// same broadcast shape as `DiceGameController`.
    private func broadcast() {
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(state(for: seat.id), toDevice: deviceID)
        }
    }

    /// One seat's personalized view of the game, as of right now.
    ///
    /// `DiceClientState` is LCR-shaped at its core (chips/centerPot) but
    /// was generalized (by the same wave that added `DiceGameKind.
    /// shutTheBox`) with free-text `statusLine`/`standingsLines` fields
    /// exactly for games like this one — see their doc in `Sources/Engine/
    /// DiceTypes.swift`. `chips` is still repurposed as "how many dice does
    /// THIS seat's cup need right now" (1 or 2, read by `DiceCupView.
    /// myDiceCount` off `chips[mySeat]`, capped at `DiceGameConfig.
    /// config(for: .shutTheBox).diceCount` == 2 on that end), and
    /// `centerPot`/`rollsLeft` don't apply to this game (0/nil).
    private func state(for seatID: Int) -> DiceClientState {
        let dieCountNeeded = usingOneDie ? 1 : 2
        return DiceClientState(
            kind: .shutTheBox, mySeat: seatID, seatNames: seats.map(\.name),
            chips: seats.map { $0.id == turnSeat ? dieCountNeeded : 2 },
            centerPot: 0, turnSeat: turnSeat,
            isMyTurn: !gameOver && !rollInFlight && lastDice.isEmpty && turnSeat == seatID,
            gameOver: gameOver, winnerSeat: winnerSeats.count == 1 ? winnerSeats.first : nil,
            cupReady: canRoll(seat: seatID),
            loadedDice: seatID == turnSeat ? loadedDiceCount : 0,
            statusLine: statusLine, standingsLines: standingsLines())
    }

    /// One line per seat, same order as `seatNames` — the phone's "not
    /// your turn" panel shows these verbatim (`DiceCupView.
    /// genericStandingsView`).
    private func standingsLines() -> [String] {
        seats.map { seat in
            if let score = roundScores[seat.id] {
                return score == 0 ? "\(seat.name): shut the box!" : "\(seat.name): \(score)"
            }
            if seat.id == turnSeat && !gameOver { return "\(seat.name): rolling…" }
            return "\(seat.name): waiting"
        }
    }

    private func resendState(toDevice deviceID: String) {
        guard let seat = seats.first(where: { $0.deviceID == deviceID }) else { return }
        host.sendDiceState(state(for: seat.id), toDevice: deviceID)
    }

    /// Tear-down: every phone gets the "dice closed" sentinel, and the
    /// host's dice routing is unhooked — identical contract to
    /// `DiceGameController.end()`.
    func end() {
        let sentinel = DiceClientState(
            kind: .shutTheBox, mySeat: -1, seatNames: [], chips: [], centerPot: 0,
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

/// Small seeded RNG (SplitMix64) — watchdog-fallback only, same algorithm
/// `DiceGameController` uses, duplicated here rather than shared since that
/// file lives outside this pass's edit scope and the type is 12 lines.
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
