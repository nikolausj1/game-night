import Foundation
import Observation

/// The one root-visible handle for dice mode. Dice games live entirely
/// outside the card engine, so `host.state` stays nil while one runs —
/// TableRootView switches on `DiceLauncher.shared.controller` instead:
///
///     if let dice = DiceLauncher.shared.controller {
///         DiceTableView(controller: dice, onClose: { DiceLauncher.shared.end() })
///     } else if host.state == nil { MenuView(host: host) } else { … }
///
/// MenuView calls `start(host:seats:)` from its deal button; `end()` sends
/// every phone the "dice closed" sentinel and returns the table to the menu.
/// The one live dice game, whichever kind it is. Each case wraps that
/// game's own controller type — they share a shape (`init(host:seats:)`,
/// `end()`, broadcast-on-mutate) by convention, not by protocol, because
/// their public surfaces differ everywhere it matters (scorecards, tiles,
/// turn totals) and TableRootView needs the concrete type per branch
/// anyway.
enum ActiveDiceGame {
    case lcr(DiceGameController)
    case yahtzee(YahtzeeController)
    case zilch(ZilchController)
    case shutBox(ShutBoxController)

    func end() {
        switch self {
        case .lcr(let c): c.end()
        case .yahtzee(let c): c.end()
        case .zilch(let c): c.end()
        case .shutBox(let c): c.end()
        }
    }
}

@Observable
final class DiceLauncher {
    static let shared = DiceLauncher()
    private(set) var game: ActiveDiceGame?

    /// Back-compat accessor for the LCR-era call sites (MenuView's deal
    /// button and harness hooks read this to know "a dice game is live").
    var controller: DiceGameController? {
        if case .lcr(let c) = game { return c }
        return nil
    }

    private init() {}

    /// Routing seam for the dice games landing alongside LCR tonight
    /// (Yahtzee, Zilch, Shut the Box): `kind` picks which
    /// `DiceGameConfig.config(for:)` recipe — and, below, which concrete
    /// controller — a table run uses. Only `.lcr` actually builds a
    /// controller today; the other three fall through to a logged no-op
    /// until their own worker adds a `case` here for their controller,
    /// the exact same one-line shape as `.lcr`'s. `kind` defaults to
    /// `.lcr` so every EXISTING call site — `start(host:seats:)`, still
    /// how MenuView's `-autoStartLcr`/`-autoStartLcrHuman`/
    /// `-autoStartLcrRemote` hooks and its real deal button call this —
    /// keeps compiling and behaving byte-identically without touching
    /// MenuView.swift/TableRootView.swift.
    ///
    /// NOTE for whoever wires in the first non-LCR controller: `controller`
    /// above is typed `DiceGameController?` (LCR's own controller type) —
    /// broadening that (a protocol, an enum of controllers, whatever fits)
    /// is part of THAT integration, not done here, since no second
    /// controller type exists yet to design against.
    func start(kind: DiceKind = .lcr, host: GameHostController, seats: [SeatSpec]) {
        guard game == nil else { return }
        switch kind {
        case .lcr:
            game = .lcr(DiceGameController(host: host, seats: seats))
        case .yahtzee:
            game = .yahtzee(YahtzeeController(host: host, seats: seats))
        case .zilch:
            game = .zilch(ZilchController(host: host, seats: seats))
        case .shutTheBox:
            game = .shutBox(ShutBoxController(host: host, seats: seats))
        }
    }

    func end() {
        game?.end()
        game = nil
    }

    /// Resume (see `DiceSave`): mount a controller rebuilt from its save.
    /// No-op while a dice game is already live.
    func adopt(_ restored: ActiveDiceGame) {
        guard game == nil else { return }
        game = restored
    }
}

/// Left-Right-Center, table-side. Owns all rules state (chips, pot, turn),
/// requests physical rolls from the table's 3D dice scene (the settled
/// faces ARE the result — physics is the RNG), drives bot turns, and
/// pushes each phone its personalized `DiceClientState` after every
/// mutation — the dice-world mirror of GameHostController's engine + emit
/// loop.
///
/// LCR rules as implemented:
/// - Everyone starts with 3 chips.
/// - On your turn you roll `min(chips, 3)` dice. Faces per die: 3 sides
///   dot, 1 left, 1 right, 1 center (p: dot 1/2, L 1/6, R 1/6, C 1/6).
/// - L passes a chip to your left neighbor (next seat clockwise), R to
///   your right neighbor, C into the center pot. Neighbors are immediate
///   seats — a 0-chip neighbor can win chips back this way.
/// - Players at 0 chips stay in the game but roll 0 dice: the turn skips
///   them until a neighbor passes them something.
/// - The game ends when exactly one player holds all the non-pot chips;
///   the winner takes the pot.
@Observable
final class DiceGameController {
    /// One chair in the dice game. Humans carry the deviceID of the phone
    /// that holds the seat (mapped from the lobby, in lobby order, exactly
    /// like `GameHostController.startGame(kind:rules:seats:)`).
    struct DiceSeat: Identifiable {
        let id: Int
        let name: String
        let isBot: Bool
        let deviceID: String?
        let colorIndex: Int
    }

    /// One roll in flight, for the table's 3D physics layer. The controller
    /// no longer pre-rolls faces — it asks the scene to throw `count` real
    /// dice and the PHYSICS decides: when they settle, the scene reads the
    /// up-faces and reports back via `completeRoll(id:faces:)`.
    struct Roll: Equatable {
        let id: Int
        let seat: Int
        let count: Int
        let intensity: Double // 0.3…1.5
    }

    /// A chip movement resolved from the last roll. `to == nil` → the pot.
    /// The table view animates these as chip flights.
    struct ChipTransfer: Identifiable, Equatable {
        let id: Int
        let from: Int
        let to: Int?
    }

    /// A penalty coin a HUMAN roller still has to move by hand. Bots'
    /// transfers apply instantly (they're animated flights); a human's
    /// owed coins float up off their plate and wait to be DRAGGED to the
    /// destination — the game blocks until every one lands. `to == nil`
    /// → the pot.
    struct PendingTransfer: Identifiable, Equatable {
        let id: Int
        let from: Int
        let to: Int?
    }

    let kind: DiceGameKind = .leftRightCenter
    private(set) var seats: [DiceSeat] = []
    private(set) var chips: [Int] = []
    private(set) var centerPot = 0
    private(set) var turnSeat = 0
    private(set) var gameOver = false
    private(set) var winnerSeat: Int?
    private(set) var currentRoll: Roll?
    private(set) var lastTransfers: [ChipTransfer] = []
    /// Coins a human roller still owes by hand. Non-empty blocks the turn.
    private(set) var pendingTransfers: [PendingTransfer] = []
    /// True from a roll until it resolves — the dice are still tumbling.
    private(set) var rollInFlight = false
    /// Manual cup loading (`gn.autoCup` off, the default): how many of the
    /// current roller's required dice have been dragged into their
    /// TableCupView so far this turn. Reset to 0 every time the turn
    /// changes (advanceTurn/restart) so a stale count from the PREVIOUS
    /// roller can never carry over and skip the next one's cup.
    private(set) var loadedDiceCount = 0
    /// Monotonic bump on every mutation (same redraw-guarantee pattern as
    /// GameHostController.stateVersion).
    private(set) var stateVersion = 0

    private let host: GameHostController
    private var rng: SplitMix64
    private var rollCounter = 0
    private var transferCounter = 0
    /// Bumps whenever a pending-transfer phase starts or ends, so a stale
    /// watchdog can tell its phase is over.
    private var pendingGeneration = 0
    private let autosave = SaveDebouncer()

    init(host: GameHostController, seats specs: [SeatSpec]) {
        self.host = host
        rng = SplitMix64(seed: UInt64.random(in: .min ... .max))

        // Humans map onto connected lobby players in lobby order; bots get
        // their roster color for life — both exactly as the card games do.
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
                // Seat without a phone: playable from the table (tap the
                // plate to roll), just never gets a cup.
                built.append(DiceSeat(id: seatID, name: spec.name, isBot: false,
                                      deviceID: nil, colorIndex: seatID))
            }
        }
        seats = built
        chips = Array(repeating: 3, count: built.count)
        SaveSlots.clear(kind: .dice(.lcr)) // an explicit new game supersedes any parked one

        host.diceSeatByDevice = deviceMap
        host.onDicePour = { [weak self] seat, intensity in
            self?.roll(from: seat, intensity: intensity)
        }
        // A phone that reconnects (or re-identifies) mid-game gets its
        // dice state back immediately — without this it sits on a stale
        // lobby screen until the next turn-end broadcast.
        host.onDiceHello = { [weak self] deviceID in
            self?.resendState(toDevice: deviceID)
        }

        Announcer.shared.announceGameStart(playerNames: built.map(\.name))
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Resume (see `DiceSave`): chips, pot and turn exactly as parked; the
    /// host's dice routing is re-registered from the seats' durable
    /// deviceIDs so returning phones land straight back in their cups.
    init?(host: GameHostController, restoring saved: LcrSaveState) {
        guard !saved.seats.isEmpty, saved.chips.count == saved.seats.count,
              saved.seats.indices.contains(saved.turnSeat) else { return nil }
        self.host = host
        rng = SplitMix64(seed: UInt64.random(in: .min ... .max))
        seats = saved.seats.map {
            DiceSeat(id: $0.id, name: $0.name, isBot: $0.isBot, deviceID: $0.deviceID, colorIndex: $0.colorIndex)
        }
        chips = saved.chips.map { max(0, $0) }
        centerPot = max(0, saved.centerPot)
        turnSeat = saved.turnSeat
        var deviceMap: [String: Int] = [:]
        for seat in seats {
            if let deviceID = seat.deviceID { deviceMap[deviceID] = seat.id }
        }
        host.diceSeatByDevice = deviceMap
        host.onDicePour = { [weak self] seat, intensity in
            self?.roll(from: seat, intensity: intensity)
        }
        host.onDiceHello = { [weak self] deviceID in
            self?.resendState(toDevice: deviceID)
        }
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Save (see Sources/App/Save/DiceSave.swift)

    /// Writes the game between rolls, 2s after the last change; a finished
    /// game clears its slot. Skipped while dice are in the air or chips are
    /// still being passed — the slot always holds the last settled moment.
    private func persist() {
        if gameOver {
            SaveSlots.clear(kind: .dice(.lcr))
            return
        }
        guard !rollInFlight, pendingTransfers.isEmpty, seats.indices.contains(turnSeat) else { return }
        let savedSeats = seats.map {
            DiceSavedSeat(id: $0.id, name: $0.name, isBot: $0.isBot, deviceID: $0.deviceID, colorIndex: $0.colorIndex)
        }
        let saved = LcrSaveState(seats: savedSeats, chips: chips, centerPot: centerPot, turnSeat: turnSeat)
        let subtitle = DiceSave.leaderSubtitle(prefix: "\(seats[turnSeat].name) rolling · pot \(centerPot)",
                                               standings: seats.map { ($0.name, chips[$0.id]) })
        SaveSlots.write(kind: .dice(.lcr), title: "L·R·C", subtitle: subtitle,
                        seats: DiceSave.envelopeSeats(savedSeats), payload: saved)
    }

    // MARK: - Rolling

    /// Single entry for every roll: phone pours, plate taps, and bots all
    /// land here. Ignores anything that isn't the current turn. Publishes
    /// a `Roll` request; the table's SceneKit layer throws real dice and
    /// calls `completeRoll(id:faces:)` with what physics settled on.
    func roll(from seat: Int, intensity rawIntensity: Double) {
        guard !gameOver, !rollInFlight, pendingTransfers.isEmpty, seat == turnSeat,
              seats.indices.contains(seat) else {
            NSLog("Dice: roll(from: %d) REFUSED — gameOver=%d inFlight=%d pending=%d turnSeat=%d",
                  seat, gameOver ? 1 : 0, rollInFlight ? 1 : 0,
                  pendingTransfers.count, turnSeat)
            return
        }
        guard canRoll(seat: seat) else {
            // Manual cup mode and this human hasn't loaded every die yet —
            // a phone shake or a plate tap here is just ignored, same as
            // any other out-of-turn request. TableCupView is the only
            // path that unblocks this (loadDie), never a direct override.
            NSLog("Dice: roll(from: %d) REFUSED — cup not loaded (%d/%d)",
                  seat, loadedDiceCount, min(chips[seat], 3))
            return
        }
        let count = min(chips[seat], 3)
        guard count > 0 else { return } // turn skipping should prevent this

        let intensity = min(1.5, max(0.3, rawIntensity))
        rollCounter += 1
        let roll = Roll(id: rollCounter, seat: seat, count: count, intensity: intensity)
        rollInFlight = true
        currentRoll = roll
        stateVersion += 1
        TableSFX.shared.play(.dicePour)

        // Watchdog: if no scene reports back (table view torn down
        // mid-roll, physics wedged), fall back to seeded RNG faces so the
        // game never hangs. In normal play the scene answers in 2–5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.rollInFlight, self.currentRoll?.id == roll.id else { return }
            var faces: [LcrFace] = []
            for _ in 0..<count { faces.append(self.drawFace()) }
            self.resolve(rollID: roll.id, faces: faces)
        }
    }

    /// The physics layer's report: the dice have settled and these are the
    /// faces pointing up (die order). A short beat lets everyone read the
    /// table before the chips move.
    func completeRoll(id: Int, faces: [LcrFace]) {
        guard rollInFlight, currentRoll?.id == id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.resolve(rollID: id, faces: faces)
        }
    }

    /// Whether `seat` may currently roll: always true for a bot (no hands
    /// to load a cup with) and whenever auto-cup is on; for a manual-mode
    /// human, true only once every required die has been dragged into
    /// their TableCupView. Read live off UserDefaults rather than a cached
    /// flag so flipping the setting mid-game takes effect on the very
    /// next roll attempt, no restart needed.
    func canRoll(seat: Int) -> Bool {
        guard seats.indices.contains(seat) else { return false }
        if seats[seat].isBot || UserDefaults.standard.bool(forKey: "gn.autoCup") { return true }
        return loadedDiceCount >= min(chips[seat], 3)
    }

    /// TableCupView calls this once per die dragged into the cup mouth.
    /// Ignored once the roller already has enough dice loaded (extra
    /// drops are a no-op, not an over-fill), or if it isn't actually
    /// their turn (a drag that finishes just as the turn moves on).
    /// Every load bumps `stateVersion` so the table HUD and the phone's
    /// `cupReady` flag (via broadcast) both update immediately.
    func loadDie(forSeat seat: Int) {
        guard !gameOver, !rollInFlight, pendingTransfers.isEmpty, seat == turnSeat,
              seats.indices.contains(seat), !seats[seat].isBot,
              loadedDiceCount < min(chips[seat], 3) else { return }
        loadedDiceCount += 1
        TableSFX.shared.playDiceContact(.die, strength: 0.35)
        stateVersion += 1
        broadcast()
    }

    /// Watchdog fallback only — one die: 3 dot sides, 1 left, 1 right,
    /// 1 center. Live results come from DieFaceReader, not this.
    private func drawFace() -> LcrFace {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0, 1, 2: return .dot
        case 3: return .left
        case 4: return .right
        default: return .center
        }
    }

    private func resolve(rollID: Int, faces: [LcrFace]) {
        guard let roll = currentRoll, roll.id == rollID, rollInFlight else { return }
        rollInFlight = false

        // Work out where each owed coin goes WITHOUT touching chip counts
        // yet — bots apply immediately, humans move theirs by hand.
        let n = seats.count
        var owed: [Int?] = [] // destination seat, nil = pot
        for face in faces {
            guard owed.count < chips[roll.seat] else { break } // can't overdraw
            switch face {
            case .dot: continue
            case .left: owed.append((roll.seat + 1) % n)
            case .right: owed.append((roll.seat - 1 + n) % n)
            case .center: owed.append(nil)
            }
        }

        if seats[roll.seat].isBot || owed.isEmpty {
            // Bot (or a clean roll): instant transfers, animated flights.
            var transfers: [ChipTransfer] = []
            for to in owed {
                transferCounter += 1
                transfers.append(ChipTransfer(id: transferCounter, from: roll.seat, to: to))
                applyTransfer(from: roll.seat, to: to)
            }
            lastTransfers = transfers
            if !transfers.isEmpty {
                TableSFX.shared.play(.chipPass)
                if transfers.contains(where: { $0.to == nil }) {
                    TableSFX.shared.play(.chipPlace)
                }
            }
            finishTurn(roller: roll.seat)
        } else {
            // Human: the owed coins rise off the plate and wait to be
            // dragged. Turn (and broadcast) block until all land.
            pendingTransfers = owed.map { to in
                transferCounter += 1
                return PendingTransfer(id: transferCounter, from: roll.seat, to: to)
            }
            pendingGeneration += 1
            stateVersion += 1
            startPendingWatchdog(roller: roll.seat)
        }
    }

    /// Move one chip now (chips/pot mutation only — no turn advance).
    private func applyTransfer(from seat: Int, to: Int?) {
        guard chips[seat] > 0 else { return }
        chips[seat] -= 1
        if let to { chips[to] += 1 } else { centerPot += 1 }
    }

    /// The human dragged one owed coin home. Applies it; when the last
    /// one lands, the turn finally advances and the table broadcasts.
    func completePendingTransfer(id: Int) {
        guard let index = pendingTransfers.firstIndex(where: { $0.id == id }) else { return }
        let transfer = pendingTransfers.remove(at: index)
        applyTransfer(from: transfer.from, to: transfer.to)
        TableSFX.shared.play(transfer.to == nil ? .chipPlace : .chipPass)
        stateVersion += 1
        if pendingTransfers.isEmpty {
            pendingGeneration += 1
            finishTurn(roller: transfer.from)
        }
    }

    /// Someone walked away: after 25s the table sighs, chimes softly, and
    /// slides the remaining owed coins home itself (animated flights, like
    /// a bot's) so the game never hangs.
    private func startPendingWatchdog(roller: Int) {
        let generation = pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.pendingGeneration == generation,
                  !self.pendingTransfers.isEmpty else { return }
            var transfers: [ChipTransfer] = []
            for pending in self.pendingTransfers {
                self.applyTransfer(from: pending.from, to: pending.to)
                transfers.append(ChipTransfer(id: pending.id, from: pending.from,
                                              to: pending.to))
            }
            self.pendingTransfers = []
            self.pendingGeneration += 1
            self.lastTransfers = transfers
            TableSFX.shared.play(.softChime)
            self.finishTurn(roller: roller)
        }
    }

    /// Shared tail of every resolved roll: end-check, next seat, tell the
    /// phones, wake the next bot.
    private func finishTurn(roller: Int) {
        checkGameOver(roller: roller)
        if !gameOver { advanceTurn() }
        // New roller, empty cup — manual mode starts them from scratch
        // every turn, never carrying over the previous roller's progress.
        loadedDiceCount = 0
        stateVersion += 1
        broadcast()
        scheduleBotIfNeeded()
    }

    /// Exactly one player holding all the non-pot chips ends the game; the
    /// winner takes the pot. (Zero holders is unreachable in normal play —
    /// the game would have ended a roll earlier — but defensively the
    /// roller takes the pot back.)
    private func checkGameOver(roller: Int) {
        let holders = chips.indices.filter { chips[$0] > 0 }
        guard holders.count <= 1 else { return }
        let winner = holders.first ?? roller
        gameOver = true
        winnerSeat = winner
        chips[winner] += centerPot
        centerPot = 0
        TableSFX.shared.play(.fanfareWin)
        Announcer.shared.announceGameWon(winnerName: seats[winner].name, margin: 0)
    }

    /// Next seat clockwise, skipping anyone at 0 chips (they stay in the
    /// game but can't roll until a neighbor feeds them).
    private func advanceTurn() {
        let n = seats.count
        var next = (turnSeat + 1) % n
        var hops = 0
        while chips[next] == 0 && hops < n {
            next = (next + 1) % n
            hops += 1
        }
        turnSeat = next
    }

    /// Bots shake an imaginary cup for a moment, then pour. LCR has no
    /// decisions (the dice are the whole game), so a bot's personality only
    /// shows in its tempo: snappy bots 0.7x, deliberate bots 1.4x the base beat.
    private func scheduleBotIfNeeded() {
        guard !gameOver, !rollInFlight, pendingTransfers.isEmpty,
              seats[turnSeat].isBot else { return }
        let expectedTurn = turnSeat
        let expectedVersion = stateVersion
        let delay = BotPersonality.forName(seats[expectedTurn].name).randomDelay(1.2...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.gameOver, !self.rollInFlight,
                  self.turnSeat == expectedTurn,
                  self.stateVersion == expectedVersion else { return }
            self.roll(from: expectedTurn, intensity: .random(in: 0.5...1.1))
        }
    }

    /// Fresh game, same table: chips back to 3, pot cleared, loser of
    /// nothing — the winner rolls first next game.
    func restart() {
        guard gameOver else { return }
        chips = Array(repeating: 3, count: seats.count)
        centerPot = 0
        gameOver = false
        turnSeat = winnerSeat ?? 0
        winnerSeat = nil
        currentRoll = nil
        lastTransfers = []
        pendingTransfers = []
        pendingGeneration += 1
        loadedDiceCount = 0
        stateVersion += 1
        TableSFX.shared.play(.shuffle)
        broadcast()
        scheduleBotIfNeeded()
    }

    // MARK: - Outbound

    /// Every phone gets its own personalized state after every mutation.
    private func broadcast() {
        for seat in seats {
            guard let deviceID = seat.deviceID else { continue }
            host.sendDiceState(state(for: seat.id), toDevice: deviceID)
        }
        autosave.schedule { [weak self] in self?.persist() }
    }

    /// One seat's personalized view of the game, as of right now.
    private func state(for seatID: Int) -> DiceClientState {
        DiceClientState(
            kind: kind, mySeat: seatID, seatNames: seats.map(\.name),
            chips: chips, centerPot: centerPot, turnSeat: turnSeat,
            isMyTurn: !gameOver && !rollInFlight && pendingTransfers.isEmpty
                && turnSeat == seatID,
            gameOver: gameOver, winnerSeat: winnerSeat,
            cupReady: canRoll(seat: seatID),
            loadedDice: seatID == turnSeat ? loadedDiceCount : 0)
    }

    /// Re-push the current state to one device (reconnect / re-hello).
    private func resendState(toDevice deviceID: String) {
        guard let seat = seats.first(where: { $0.deviceID == deviceID }) else { return }
        host.sendDiceState(state(for: seat.id), toDevice: deviceID)
    }

    /// Tear-down: every phone gets the "dice closed" sentinel (mySeat -1 →
    /// GameClientController clears diceState, phone returns to the lobby),
    /// and the host's dice routing is unhooked.
    func end() {
        // Park it now (the debounced write may not have landed yet).
        autosave.cancel()
        persist()
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

/// Small seeded RNG (SplitMix64) so a dice game's rolls are reproducible
/// from its seed — same philosophy as HostEngine's seeded deals.
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
