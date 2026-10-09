import Foundation
import Observation

/// Zilch, table-side — the LCR sibling `DiceLauncher.start(kind:host:seats:)`
/// left a TODO for (`Sources/App/Dice/DiceGameController.swift`). Owns all
/// rules state (banked scores, whose turn, the live turn total), requests
/// physical rolls from the table's 3D dice scene exactly like
/// `DiceGameController` does, and pushes every phone its own
/// `DiceClientState` after every mutation.
///
/// PARTY RULES as implemented (see `ZilchPartyRules`/`ZilchScorer` for the
/// scoring table itself):
/// - No opening minimum — any positive turn total may bank, any time after
///   a scoring roll.
/// - Pour all 6 (or however many aren't already set aside this turn). No
///   scoring die anywhere in the roll → ZILCH: the WHOLE turn total
///   (everything set aside earlier this same turn too, not just this roll)
///   is lost, turn passes.
/// - Otherwise the roller taps scoring dice ON THE TABLE to set them aside
///   (`dieTapped`, wired to `DiceTableSceneView.onDieTapped` → the physical
///   hold-tray primitive, `DiceTableSceneCoordinator.setHeld`). Tapping a
///   die that isn't part of any scoring group is a no-op — only a die
///   belonging to a currently-available `ZilchScoringGroup` sets aside
///   (and takes the WHOLE group with it: tapping one of three 4s sets
///   aside all three, worth the triple, never just the one die). Tapping
///   an already-set-aside die from the SAME roll undoes it (see
///   `dieTapped`'s doc); dice locked in from an EARLIER roll this turn are
///   permanent.
/// - House simplification (documented here since it's a real rules choice,
///   not an oversight): once at least one group is set aside from a roll,
///   the roller may immediately bank OR reroll the rest — any other
///   still-scoring-but-untapped dice from that same roll are fair game to
///   risk on the reroll, same as any other die. Some Farkle variants force
///   you to set aside EVERY scoring die each roll; this app's party rules
///   don't.
/// - All six dice set aside (across however many rolls) → HOT DICE: they
///   all return to the felt for a fresh six-die roll, turn total keeps
///   building.
/// - First seat to bank a total of `ZilchPartyRules.targetScore` (5,000)
///   triggers the final chase: every other seat gets exactly one more full
///   turn (win, lose, or bust), then the game ends and the HIGHEST total
///   wins — not necessarily the seat that crossed the target first.
@Observable
final class ZilchController {
    /// Mirrors `DiceGameController.DiceSeat` exactly (same shape, same
    /// build-from-`SeatSpec` rules) — reused as-is rather than duplicated,
    /// since it's a plain internal type with a memberwise init.
    typealias DiceSeat = DiceGameController.DiceSeat

    let diceCount = DiceGameConfig.config(for: .zilch).diceCount // 6

    private(set) var seats: [DiceSeat] = []
    /// Permanent, banked total per seat — only ever grows, only ever on a
    /// successful `bank()`.
    private(set) var bankedScore: [Int] = []
    private(set) var turnSeat = 0
    /// This turn's accumulated-but-not-yet-banked total: every consumed
    /// `ZilchScoringGroup`'s points, across every roll so far this turn.
    /// Lost entirely on a ZILCH; folded into `bankedScore[turnSeat]` on a
    /// `bank()`; carries across a hot-dice reset.
    private(set) var turnScore = 0
    private(set) var gameOver = false
    private(set) var winnerSeat: Int?
    private(set) var currentRoll: DiceGameController.Roll?
    private(set) var rollInFlight = false

    /// Pool indices currently set aside THIS TURN (any roll) — fed
    /// straight to `DiceTableSceneView.heldIndices`, which is what actually
    /// slides them into the gold-ringed tray. Cleared at the start of every
    /// new turn and on every hot-dice reset.
    private(set) var heldIndices: Set<Int> = []
    /// Groups found in the MOST RECENT roll, not yet tapped — pool-index
    /// space (already translated from `ZilchScorer`'s roll-relative
    /// positions). Empty either because no roll has happened yet this
    /// decision cycle (turn start / just after hot dice) or because every
    /// group from the last roll has been tapped.
    private(set) var pendingGroups: [ZilchScoringGroup] = []
    /// Groups tapped so far from the CURRENT roll only (undoable — see
    /// `dieTapped`). Reset at the start of every roll.
    private(set) var heldGroupsThisRoll: [ZilchScoringGroup] = []
    /// True while every die last rolled came up junk — the dramatic ZILCH
    /// beat (`ZilchTableView` shows the shake + red callout) before the
    /// turn actually passes.
    private(set) var zilchFlash = false
    /// True for a short beat right after all six dice get set aside — the
    /// table shows "HOT DICE!" before the tray empties back onto the felt.
    private(set) var hotDiceFlash = false
    /// Manual cup loading, same meaning as `DiceGameController.
    /// loadedDiceCount`: how many of the CURRENT roller's still-live dice
    /// (`diceCount - heldIndices.count`) are dragged into the cup so far.
    private(set) var loadedDiceCount = 0
    private(set) var stateVersion = 0

    /// The seat that first banked past `ZilchPartyRules.targetScore` — nil
    /// until someone does. Once set, every OTHER seat still owes exactly
    /// one more turn (`finalChaseRemaining`); the trigger seat gets no
    /// extra turn of their own.
    private(set) var finalChaseSeat: Int?
    private var finalChaseRemaining: Set<Int> = []
    /// A bot's choice of which pending groups to set aside from the current roll.
    private var botPlan: Set<UUID>?

    private let host: GameHostController
    private var rollCounter = 0

    init(host: GameHostController, seats specs: [SeatSpec]) {
        self.host = host

        // Same seat-building rules as DiceGameController: humans map onto
        // connected lobby players in lobby order, bots get their roster
        // color for life.
        var built: [DiceSeat] = []
        var deviceMap: [String: Int] = [:]
        var humanIndex = 0
        for (seatID, spec) in specs.enumerated() {
            if spec.isBot {
                let color = BotRoster.identity(named: spec.name)?.colorIndex ?? seatID
                built.append(DiceSeat(id: seatID, name: spec.name, isBot: true,
                                      deviceID: nil, colorIndex: color))
            } else if humanIndex < host.lobbyPlayers.count {
                let player = host.lobbyPlayers[humanIndex]
                humanIndex += 1
                let name = spec.name.isEmpty ? player.name : spec.name
                deviceMap[player.deviceID] = seatID
                built.append(DiceSeat(id: seatID, name: name, isBot: false,
                                      deviceID: player.deviceID, colorIndex: seatID))
            } else {
                built.append(DiceSeat(id: seatID, name: spec.name, isBot: false,
                                      deviceID: nil, colorIndex: seatID))
            }
        }
        seats = built
        bankedScore = Array(repeating: 0, count: built.count)

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

    // MARK: - Turn-progress gate

    /// A roll just resolved with points on the table and nothing tapped
    /// from it yet — the ONE window where neither rolling again nor
    /// banking is allowed. See the type doc's "house simplification" note
    /// for why this is the only such gate.
    private var awaitingTableTap: Bool {
        !pendingGroups.isEmpty && heldGroupsThisRoll.isEmpty
    }

    /// Whether the current roller may act at all right now (roll again or
    /// bank) — false only during `awaitingTableTap`, mid-roll, or one of
    /// the two dramatic-beat flashes.
    var mayAct: Bool {
        !gameOver && !rollInFlight && !zilchFlash && !hotDiceFlash && !awaitingTableTap
    }

    var canBank: Bool { mayAct && turnScore > ZilchPartyRules.openingMinimum }

    /// How many of the CURRENT roller's dice are still live (not yet set
    /// aside) — what the next roll (or the manual cup) will actually throw.
    var liveDiceCount: Int { diceCount - heldIndices.count }

    // MARK: - Rolling

    /// Single entry for every roll — phone pours, plate taps, and bots all
    /// land here, exactly like `DiceGameController.roll`.
    func roll(from seat: Int, intensity rawIntensity: Double) {
        guard mayAct, seat == turnSeat, seats.indices.contains(seat) else { return }
        guard canRoll(seat: seat) else { return } // manual cup not loaded yet
        let count = liveDiceCount
        guard count > 0 else { return } // hot dice always resets this before it could hit 0

        // Clear any leftover, never-tapped groups from a decision the
        // roller chose to abandon by rolling again — those dice are about
        // to be rethrown, so their old scoring opportunity is gone.
        pendingGroups = []
        heldGroupsThisRoll = []

        let intensity = min(1.5, max(0.3, rawIntensity))
        rollCounter += 1
        let roll = DiceGameController.Roll(id: rollCounter, seat: seat, count: count, intensity: intensity)
        rollInFlight = true
        currentRoll = roll
        loadedDiceCount = 0
        stateVersion += 1
        TableSFX.shared.play(.dicePour)
        broadcast()

        // Watchdog: if the scene never reports back (view torn down
        // mid-roll, physics wedged), fall back to plain random faces so
        // the game never hangs — same 10s budget as LCR's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.rollInFlight, self.currentRoll?.id == roll.id else { return }
            self.completeRoll(id: roll.id, faces: (0..<count).map { _ in Int.random(in: 1...6) })
        }
    }

    /// The physics layer's report: settled pip values, in POOL-INDEX
    /// ascending order — always exactly `liveDiceCount` values, since a
    /// Zilch roll always throws every currently-unheld die and
    /// `DiceTableSceneCoordinator.launch()` always sources them (via its
    /// `.loaded(seat:)`/`.resting` fallback chain) from that same set,
    /// sorted. That's what lets `resolve` reconstruct which physical pool
    /// index produced which value without the platform's `onResult`
    /// callback needing to carry indices itself.
    func completeRoll(id: Int, faces: [Int]) {
        guard rollInFlight, currentRoll?.id == id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.resolve(rollID: id, faces: faces)
        }
    }

    private func resolve(rollID: Int, faces: [Int]) {
        guard let roll = currentRoll, roll.id == rollID, rollInFlight else { return }
        rollInFlight = false

        let activePoolIndices = (0..<diceCount).filter { !heldIndices.contains($0) }.sorted()
        guard activePoolIndices.count == faces.count else {
            NSLog("Zilch: resolve() face count (%d) != live pool count (%d) — dropping roll",
                  faces.count, activePoolIndices.count)
            finishTurn(roller: roll.seat) // don't strand the game on a mismatch
            return
        }

        let rawGroups = ZilchScorer.groups(in: faces)
        if rawGroups.isEmpty {
            // ZILCH — the whole turn total is gone, not just this roll.
            zilchFlash = true
            pendingGroups = []
            stateVersion += 1
            TableSFX.shared.play(.tableKnock)
            broadcast()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self else { return }
                self.zilchFlash = false
                self.turnScore = 0
                self.heldIndices = []
                self.pendingGroups = []
                self.finishTurn(roller: roll.seat)
            }
            return
        }

        pendingGroups = rawGroups.map { group in
            ZilchScoringGroup(positions: group.positions.map { activePoolIndices[$0] },
                              points: group.points, label: group.label)
        }
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Whether `seat` may currently roll: always true for a bot (no hands
    /// to load a cup with) and whenever auto-cup is on; for a manual-mode
    /// human, true only once every live die is dragged into the cup.
    func canRoll(seat: Int) -> Bool {
        guard seats.indices.contains(seat) else { return false }
        if seats[seat].isBot || UserDefaults.standard.bool(forKey: "gn.autoCup") { return true }
        return loadedDiceCount >= liveDiceCount
    }

    /// `TableCupView`'s drop target calls this once per die dragged in —
    /// identical contract to `DiceGameController.loadDie`.
    func loadDie(forSeat seat: Int) {
        guard mayAct, seat == turnSeat, seats.indices.contains(seat), !seats[seat].isBot,
              loadedDiceCount < liveDiceCount else { return }
        loadedDiceCount += 1
        TableSFX.shared.playDiceContact(.die, strength: 0.35)
        stateVersion += 1
        broadcast()
    }

    // MARK: - Set-aside (tap) / bank

    /// The table-side half of the hold/set-aside primitive
    /// (`DiceTableSceneView.onDieTapped`). Three outcomes:
    /// 1. `poolIndex` belongs to a currently-PENDING scoring group → the
    ///    whole group sets aside (all its dice, not just this one), its
    ///    points join `turnScore`, and — if that empties the felt (all six
    ///    now held) — HOT DICE fires.
    /// 2. `poolIndex` belongs to a group already held THIS ROLL → undo:
    ///    the whole group returns to the felt, its points come back out of
    ///    `turnScore`. Dice locked in from an EARLIER roll this turn can't
    ///    be undone this way (they're not in `heldGroupsThisRoll` anymore).
    /// 3. Neither — a junk die (never scored) or nothing tappable right
    ///    now — no-op, exactly "only scoring dice/sets accepted."
    func dieTapped(_ poolIndex: Int) {
        guard !gameOver, !rollInFlight, !zilchFlash, !hotDiceFlash else { return }

        if let index = pendingGroups.firstIndex(where: { $0.positions.contains(poolIndex) }) {
            let group = pendingGroups.remove(at: index)
            heldIndices.formUnion(group.positions)
            heldGroupsThisRoll.append(group)
            turnScore += group.points
            Haptics.arm()
            TableSFX.shared.play(.chipPlace)
            stateVersion += 1
            if heldIndices.count >= diceCount {
                triggerHotDice()
            } else {
                broadcast()
            }
            return
        }

        if let index = heldGroupsThisRoll.firstIndex(where: { $0.positions.contains(poolIndex) }) {
            let group = heldGroupsThisRoll.remove(at: index)
            heldIndices.subtract(group.positions)
            turnScore -= group.points
            pendingGroups.append(group)
            Haptics.tick()
            stateVersion += 1
            broadcast()
        }
    }

    /// All six dice scored across this turn's rolls — they all come back
    /// to the felt for a fresh six-die roll; `turnScore` is untouched.
    private func triggerHotDice() {
        hotDiceFlash = true
        pendingGroups = []
        heldGroupsThisRoll = []
        TableSFX.shared.play(.softChime)
        Haptics.play()
        stateVersion += 1
        broadcast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            self.hotDiceFlash = false
            self.heldIndices = []
            self.loadedDiceCount = 0
            self.stateVersion += 1
            self.broadcast()
            self.scheduleBotIfNeeded()
        }
    }

    /// Brass-button bank: folds `turnScore` into `bankedScore[seat]`,
    /// checks whether this crosses the final-chase target, and passes the
    /// turn.
    func bank(seat: Int) {
        guard canBank, seat == turnSeat, seats.indices.contains(seat) else { return }
        bankedScore[seat] += turnScore
        TableSFX.shared.play(.chipPlace)
        Haptics.play()
        checkFinalChaseTrigger(seat: seat)
        turnScore = 0
        heldIndices = []
        pendingGroups = []
        heldGroupsThisRoll = []
        loadedDiceCount = 0
        finishTurn(roller: seat)
    }

    // MARK: - Turn lifecycle

    private func checkFinalChaseTrigger(seat: Int) {
        guard finalChaseSeat == nil, bankedScore[seat] >= ZilchPartyRules.targetScore else { return }
        finalChaseSeat = seat
        finalChaseRemaining = Set(seats.indices).subtracting([seat])
    }

    /// Shared tail of every completed turn (bank OR bust): final-chase
    /// bookkeeping, next seat, tell the phones, wake the next bot.
    private func finishTurn(roller: Int) {
        checkGameOverAfterTurn(roller: roller)
        if !gameOver { advanceTurn() }
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Every seat gets a turn regardless of score — no LCR-style skip.
    private func advanceTurn() {
        turnSeat = (turnSeat + 1) % seats.count
    }

    /// Once the final chase is on, every seat but the trigger owes exactly
    /// one more completed turn; when the last of them finishes, the
    /// HIGHEST banked total wins (not necessarily the trigger seat).
    private func checkGameOverAfterTurn(roller: Int) {
        guard let chaseSeat = finalChaseSeat, roller != chaseSeat else { return }
        finalChaseRemaining.remove(roller)
        guard finalChaseRemaining.isEmpty else { return }
        gameOver = true
        let best = bankedScore.indices.max(by: { bankedScore[$0] < bankedScore[$1] }) ?? chaseSeat
        winnerSeat = best
        TableSFX.shared.play(.fanfareWin)
        Announcer.shared.announceGameWon(winnerName: seats[best].name, margin: 0)
    }

    // MARK: - Bots

    /// Bots play by `ZilchStrategy`'s expected-value risk model: after each
    /// roll they decide WHICH scoring groups to set aside (not always all of
    /// them: leaving a lone 5 live can be worth more than banking its 50),
    /// then press or bank by comparing the table's expected turn gain with
    /// the points at risk, nudged by the bot's personality (cautious banks
    /// earlier, bold rolls on) and by the score gap in the final chase.
    /// Pacing is a short personality-scaled beat before every action, one
    /// action at a time, so the table can actually watch it happen.
    private func scheduleBotIfNeeded() {
        guard !gameOver, !rollInFlight, !zilchFlash, !hotDiceFlash,
              seats.indices.contains(turnSeat), seats[turnSeat].isBot else { return }
        let expectedSeat = turnSeat
        let expectedVersion = stateVersion
        let delay = BotPersonality.forName(seats[expectedSeat].name).randomDelay(1.0...1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.turnSeat == expectedSeat, self.stateVersion == expectedVersion,
                  !self.rollInFlight else { return }
            self.botAct(seat: expectedSeat)
        }
    }

    private func botAct(seat: Int) {
        guard seats.indices.contains(seat), seats[seat].isBot, seat == turnSeat,
              !gameOver, !rollInFlight, !zilchFlash, !hotDiceFlash else { return }
        let personality = BotPersonality.forName(seats[seat].name)
        let ctx = botContext(seat: seat, personality: personality)

        // A decision is pending: decide once which groups to set aside, then
        // tap them one at a time so each die visibly lands in the tray.
        if !pendingGroups.isEmpty {
            if botPlan == nil {
                let groups = pendingGroups.map { ZilchStrategy.Group(dice: $0.positions.count, points: $0.points) }
                let take = ZilchStrategy.chooseGroups(groups, diceRolled: liveDiceCount,
                                                      turnScore: turnScore, ctx: ctx)
                botPlan = Set(take.map { pendingGroups[$0].id })
            }
            if let plan = botPlan,
               let group = pendingGroups.first(where: { plan.contains($0.id) }),
               let poolIndex = group.positions.first {
                dieTapped(poolIndex)
                DispatchQueue.main.asyncAfter(deadline: .now() + personality.randomDelay(0.35...0.55)) { [weak self] in
                    self?.scheduleBotIfNeeded()
                }
                return
            }
            // Plan complete: any leftover scoring groups are deliberately
            // left live to be rerolled.
        }

        guard mayAct else { return } // still settling (e.g. hot-dice beat) — its own completion reschedules
        botPlan = nil

        if turnScore == 0 {
            roll(from: seat, intensity: .random(in: 0.5...1.1))
            return
        }
        if ZilchStrategy.shouldPress(diceLeft: liveDiceCount, turnScore: turnScore, ctx: ctx) {
            roll(from: seat, intensity: .random(in: 0.5...1.1))
        } else {
            bank(seat: seat)
        }
    }

    private func botContext(seat: Int, personality: BotPersonality) -> ZilchStrategy.Context {
        let rivals = bankedScore.indices.filter { $0 != seat }.map { bankedScore[$0] }
        return ZilchStrategy.Context(
            bankedScore: bankedScore[seat],
            bestOpponentScore: rivals.max() ?? 0,
            finalChaseActive: finalChaseSeat != nil,
            chasersAfterMe: finalChaseRemaining.subtracting([seat]).count,
            personality: personality)
    }

    // MARK: - Outbound (phone broadcast)

    private func broadcast() {
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(state(for: seat.id), toDevice: deviceID)
        }
    }

    private func resendState(toDevice deviceID: String) {
        guard let seat = seats.first(where: { $0.deviceID == deviceID }) else { return }
        host.sendDiceState(state(for: seat.id), toDevice: deviceID)
    }

    /// Every seat's running total, one line per seat in seat order — feeds
    /// `DiceClientState.standingsLines`, same "Hank: 145" shape its own doc
    /// comment describes.
    private var standingsLines: [String] {
        seats.map { "\($0.name): \(bankedScore[$0.id])" }
    }

    /// `statusLine` text for `seatID`, matched to whichever phone panel
    /// will actually show it (see `DiceCupView`): the cup stage (under
    /// "Your roll!") while `isMyTurn`, the generic standings panel
    /// otherwise. `nil` falls back to that panel's own default text
    /// (`rollingDiceLabel`'s "Rolling N dice" / "N of M dice loaded").
    private func statusLine(for seatID: Int) -> String? {
        guard seatID == turnSeat else { return nil }
        if zilchFlash { return "ZILCH! Turn lost." }
        if hotDiceFlash { return "Hot dice! All six back — shake for a fresh roll." }
        if awaitingTableTap {
            return "Set aside scoring dice on the table — or shake to press your luck"
        }
        if turnScore > 0 {
            return "Bank \(turnScore) points, or shake to press your luck"
        }
        return nil
    }

    /// `isMyTurn` for the wire: true only while the cup has something
    /// meaningful to actually DO — false during `awaitingTableTap` (there's
    /// nothing to shake until a table tap happens) and during the ZILCH
    /// flash, so those beats show on the standings/`statusLine` panel
    /// instead of a cup with nothing to shake. Same pattern
    /// `DiceCupView`'s own doc describes for Yahtzee's spent-rolls case.
    private func isMyTurnForPhone(_ seatID: Int) -> Bool {
        guard seatID == turnSeat, !gameOver, !zilchFlash else { return false }
        return !awaitingTableTap
    }

    private func state(for seatID: Int) -> DiceClientState {
        var chips = Array(repeating: diceCount, count: seats.count)
        if seats.indices.contains(turnSeat) { chips[turnSeat] = liveDiceCount }
        return DiceClientState(
            kind: .zilch, mySeat: seatID, seatNames: seats.map(\.name),
            chips: chips, centerPot: turnScore, turnSeat: turnSeat,
            isMyTurn: isMyTurnForPhone(seatID),
            gameOver: gameOver, winnerSeat: winnerSeat,
            cupReady: canRoll(seat: seatID),
            loadedDice: seatID == turnSeat ? loadedDiceCount : 0,
            statusLine: statusLine(for: seatID),
            rollsLeft: nil, // no fixed roll count in Zilch — always nil
            standingsLines: standingsLines)
    }

    /// Tear-down: every phone gets the "dice closed" sentinel, same
    /// contract as `DiceGameController.end()`.
    func end() {
        let sentinel = DiceClientState(
            kind: .zilch, mySeat: -1, seatNames: [], chips: [], centerPot: 0,
            turnSeat: -1, isMyTurn: false, gameOver: true, winnerSeat: nil)
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(sentinel, toDevice: deviceID)
        }
        host.diceSeatByDevice = [:]
        host.onDicePour = nil
        host.onDiceHello = nil
    }

    /// Fresh game, same table: scores back to 0, no chase in progress —
    /// the winner rolls first next game (LCR's own `restart()` convention).
    func restart() {
        guard gameOver else { return }
        bankedScore = Array(repeating: 0, count: seats.count)
        turnScore = 0
        turnSeat = winnerSeat ?? 0
        winnerSeat = nil
        gameOver = false
        currentRoll = nil
        heldIndices = []
        pendingGroups = []
        heldGroupsThisRoll = []
        zilchFlash = false
        hotDiceFlash = false
        loadedDiceCount = 0
        finalChaseSeat = nil
        finalChaseRemaining = []
        stateVersion += 1
        TableSFX.shared.play(.shuffle)
        broadcast()
        scheduleBotIfNeeded()
    }
}

// MARK: - Sim-verify harness

extension ZilchController {
    /// `-autoStartZilch`: an all-bot Zilch game that plays itself, same
    /// spirit as `-autoStartLcr`. NOT reachable from anywhere yet — this
    /// worker's edit scope is `Sources/App/Dice/Zilch/**` only, and every
    /// file that would actually ROUTE to a live Zilch table
    /// (`DiceLauncher.start` in `DiceGameController.swift`,
    /// `TableRootView.swift`'s switch, `MenuView.swift`'s `-autoStartLcr`-
    /// style `onAppear` block) sits outside it. The one-line wiring the
    /// lead needs, mirroring the existing `-autoStartLcr` hook exactly:
    ///
    /// 1. `DiceGameController.swift`, `DiceLauncher.start`'s switch — add
    ///    a `.zilch` case (and broaden `controller`'s type, per that
    ///    file's own NOTE — a Zilch game needs a `ZilchController`, not a
    ///    `DiceGameController`):
    ///        case .zilch:
    ///            zilchController = ZilchController(host: host, seats: seats)
    ///
    /// 2. `TableRootView.swift` — route to `ZilchTableView` alongside
    ///    `DiceTableView`, however `DiceLauncher` ends up exposing the two
    ///    controller types (an enum, a protocol — that's the lead's call,
    ///    noted as unmade in `DiceLauncher`'s own doc comment).
    ///
    /// 3. `MenuView.swift`'s `onAppear`, right next to the existing
    ///    `-autoStartLcr` block:
    ///        if CommandLine.arguments.contains("-autoStartZilch"),
    ///           DiceLauncher.shared.controller == nil /* + zilch equivalent */ {
    ///            let bots = BotRoster.random(count: 3).enumerated().map {
    ///                SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
    ///            }
    ///            DiceLauncher.shared.start(kind: .zilch, host: host, seats: bots)
    ///        }
    ///
    /// Until that lands, this factory is reachable only from Swift code
    /// that already has a `GameHostController` in hand (a preview, a unit
    /// test, or the lead's own wiring above) — it does the exact same
    /// "3 random bots" roster `-autoStartLcr` uses.
    static func autoStartIfRequested(host: GameHostController) -> ZilchController? {
        guard CommandLine.arguments.contains("-autoStartZilch") else { return nil }
        let bots = BotRoster.random(count: 3).enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
        }
        return ZilchController(host: host, seats: bots)
    }
}
