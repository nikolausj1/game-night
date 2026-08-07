import Foundation
import MultipeerConnectivity
import Observation

/// One chair at the table as the menu configures it: a human (mapped to a
/// connected lobby player, in lobby order) or a bot (no device, driven by
/// BotDirector). `id` is the seat index — pass them in seat order.
struct SeatSpec: Identifiable {
    let id: Int
    var name: String
    var isBot: Bool
}

/// The iPad's brain: owns the authoritative engine and the host session,
/// routes player actions in and snapshots/events out. The table UI observes
/// this; the phones only ever see their own redacted snapshots.
@Observable
final class GameHostController {
    private(set) var engine: HostEngine?
    let session: HostSession

    /// deviceID → seat. THE reclaim table: survives disconnects because it
    /// keys off persistent device identity, not transient peers.
    private(set) var seatByDevice: [String: Int] = [:]
    private var deviceByPeer: [MCPeerID: String] = [:]

    /// Lobby roster before a game starts: deviceID → chosen name.
    private(set) var lobbyPlayers: [(deviceID: String, name: String)] = []

    /// Seats occupied by computer players this game. BotDirector reads this;
    /// `botAction` refuses anything outside it so a bot can never move for a
    /// human.
    private(set) var botSeats: Set<Int> = []

    /// Table UI + announcer director subscribe here.
    var onEvents: (([GameEvent]) -> Void)?

    /// Free play: which seat played each card, so the table can animate the
    /// landing from the right edge. Table-side memory only, never synced.
    private(set) var seatByPlayedCard: [String: Int] = [:]

    /// Flick kinematics from the thrower's phone (points/sec), keyed by
    /// card. Consumed once by the physics when the card lands.
    var throwVelocityByCard: [String: CGSize] = [:]

    /// Dev tool, free play only: cards whose flick should land with the
    /// airborne pile-drop animation instead of the trick-game friction
    /// slide. Presentation-only, set by `.throwStyle` just before the
    /// matching throwInfo/playCard pair arrives.
    var pileDropCards: Set<String> = []

    /// Dice mode (dice games live OUTSIDE the card engine — see
    /// App/Dice/DiceGameController): deviceID → dice seat, set by the dice
    /// controller when a dice game starts and cleared when it ends. Plays
    /// `seatByDevice`'s role for routing `.dicePour`, kept separate so dice
    /// never disturb the card-game reclaim table.
    var diceSeatByDevice: [String: Int] = [:]
    /// A phone poured its dice cup: (dice seat, intensity 0.3…1.5).
    var onDicePour: ((Int, Double) -> Void)?
    /// A device said hello while a dice game is running. The dice
    /// controller re-sends that device its current DiceClientState so a
    /// reconnecting (or freshly re-identified) phone lands straight back
    /// in the cup instead of a stale lobby screen.
    var onDiceHello: ((String) -> Void)?

    /// Dice mode outbound: the per-seat dice state to whichever peer
    /// currently holds `deviceID` (same deviceID-keyed routing as
    /// snapshots — survives reconnects with fresh peer identities).
    func sendDiceState(_ state: DiceClientState, toDevice deviceID: String) {
        for (peer, device) in deviceByPeer where device == deviceID {
            session.send(.diceState(state), to: [peer])
        }
    }

    // MARK: - Free play dice (sandbox: any connected remote may pour)

    /// Free play's dice toy has no rules or turns — unlike LCR, EVERY
    /// connected remote may become a cup and pour AT ANY TIME (it's a
    /// sandbox, not a game). This mirrors the LCR wiring just above
    /// (`diceSeatByDevice`/`onDicePour`/`onDiceHello`/`sendDiceState`) but
    /// keyed off a single on/off latch instead of a running
    /// `DiceGameController`, since free play's dice have no controller of
    /// their own — TableGameView owns the roll trigger locally.
    ///
    /// ONE exception to "pour any time": lobby index 0 is the HOST seat —
    /// the iPad's own "your name" plate, seated at anchor (0.5, 0.94) the
    /// same as every seat count's seat 0 — and if that seat's phone is
    /// connected it mirrors the SAME manual-cup ceremony the table itself
    /// shows (`FreePlayDiceLayer`, `Sources/App/Dice/`): loading gated by
    /// `freePlayCanRoll`, `freePlayLoadedDice` ticking up live. Every OTHER
    /// connected remote keeps the sandbox's original no-gate freedom.
    ///
    /// Integration: TableGameView's Dice toggle calls
    /// `setFreePlayDiceEnabled(_:)` when `freePlayDiceOn` changes, and sets
    /// `onFreePlayDicePour` to fire the same table roll the Roll button
    /// does. Free play keeps `engine` non-nil (it's a real card-engine
    /// game, just with no rules enforced), so a reconnecting device's
    /// `.hello` takes the EXISTING card-reclaim branch below, not the
    /// `engine == nil` branch `onDiceHello` normally answers — that reclaim
    /// branch calls `sendFreePlayDiceState` directly so a phone that drops
    /// and returns mid-free-play still gets its dice state back.
    private(set) var freePlayDiceEnabled = false
    var onFreePlayDicePour: ((Double) -> Void)?

    /// The table's own on-screen cup ceremony (mirrors
    /// `DiceGameController.loadedDiceCount`): how many of the sandbox's 3
    /// dice `FreePlayDiceLayer` has loaded so far. Table-owned state lives
    /// there as `@State`; this is purely the outbound mirror for a
    /// connected host-seat phone.
    private(set) var freePlayLoadedDice = 0

    /// Mirrors `DiceGameController.canRoll` for free play's host seat:
    /// `gn.autoCup` waives the requirement exactly like LCR; otherwise all
    /// 3 dice must be loaded.
    var freePlayCanRoll: Bool {
        UserDefaults.standard.bool(forKey: "gn.autoCup") || freePlayLoadedDice >= 3
    }

    /// `FreePlayDiceLayer` calls this on every die loaded (and to reset to
    /// 0 when a fresh roll launches) — re-broadcasts so a connected host-
    /// seat phone's mirrored cup fills in step with the table's, the same
    /// beat `DiceGameController.loadDie` runs for LCR.
    func setFreePlayLoadedDice(_ count: Int) {
        freePlayLoadedDice = count
        guard freePlayDiceEnabled else { return }
        for player in lobbyPlayers { sendFreePlayDiceState(toDevice: player.deviceID) }
    }

    func setFreePlayDiceEnabled(_ enabled: Bool) {
        guard freePlayDiceEnabled != enabled else { return }
        freePlayDiceEnabled = enabled
        if enabled {
            // Every lobby player becomes a "seat" purely so an incoming
            // .dicePour has something to route through diceSeatByDevice —
            // free play has no real seats/turns, the index is unused by
            // anything (there are no rules to key off it) except the
            // host-seat (0) cup gate above.
            freePlayLoadedDice = 0
            var map: [String: Int] = [:]
            for (index, player) in lobbyPlayers.enumerated() { map[player.deviceID] = index }
            diceSeatByDevice = map
            onDiceHello = { [weak self] deviceID in self?.sendFreePlayDiceState(toDevice: deviceID) }
            onDicePour = { [weak self] _, intensity in self?.onFreePlayDicePour?(intensity) }
            for player in lobbyPlayers { sendFreePlayDiceState(toDevice: player.deviceID) }
        } else {
            diceSeatByDevice = [:]
            onDiceHello = nil
            onDicePour = nil
            let sentinel = DiceClientState(kind: .leftRightCenter, mySeat: -1, seatNames: [],
                                           chips: [], centerPot: 0, turnSeat: -1,
                                           isMyTurn: false, gameOver: true, winnerSeat: nil)
            for player in lobbyPlayers { sendDiceState(sentinel, toDevice: player.deviceID) }
        }
    }

    /// Re-push (reconnect, or the initial enable broadcast). No-ops once
    /// the toy's been switched back off — a straggling hello shouldn't
    /// resurrect dice mode for one phone after the table turned it off.
    private func sendFreePlayDiceState(toDevice deviceID: String) {
        guard freePlayDiceEnabled else { return }
        let names = lobbyPlayers.map(\.name)
        let mySeat = lobbyPlayers.firstIndex(where: { $0.deviceID == deviceID }) ?? 0
        // isMyTurn always true: any remote may pour, any time — the
        // sandbox has no turn order for DiceCupView to gate against. The
        // ONE exception is the host seat's manual cup (see the doc above
        // `freePlayLoadedDice`): seat 0 mirrors the table's real loading
        // state; every other seat stays permanently "ready".
        let isHostSeat = mySeat == 0
        let state = DiceClientState(kind: .leftRightCenter, mySeat: mySeat, seatNames: names,
                                    chips: Array(repeating: 0, count: names.count), centerPot: 0,
                                    turnSeat: mySeat, isMyTurn: true, gameOver: false,
                                    winnerSeat: nil,
                                    cupReady: !isHostSeat || freePlayCanRoll,
                                    loadedDice: isHostSeat ? freePlayLoadedDice : 0)
        sendDiceState(state, toDevice: deviceID)
    }

    /// Free play, table-local physics: where the humans have slid each
    /// card (normalized coords) and which they've flipped face-down.
    var freePlayLayout: [String: CGPoint] = [:]
    var faceDownCards: Set<String> = []

    // MARK: - Cribbage (lives outside the card engine, same coexistence
    // rule as dice — see `startCribbage`)

    private(set) var cribbageEngine: CribbageEngine?
    /// Seats (always 0/1) driven by CribbageBot instead of a phone.
    private(set) var cribbageBotSeats: Set<Int> = []
    /// deviceID → seat, the cribbage-mode twin of `seatByDevice`. Kept
    /// separate so a cribbage table never shares routing with a card game
    /// (mirrors `diceSeatByDevice`'s separation from `seatByDevice`).
    private(set) var cribbageSeatByDevice: [String: Int] = [:]
    /// Display names by seat — `CribbageState` itself carries no names
    /// (it's a bare 2-seat reducer, unlike `Seat.playerName`), so the table
    /// UI reads them here instead.
    private(set) var cribbageSeatNames: [Int: String] = [:]
    /// The events the last `cribbageEmit` produced — the table UI's hook
    /// for one-shot reactions (starter flip, GO/31 callouts, the show
    /// walkthrough), mirroring `GameClientController.recentEvents`.
    private(set) var cribbageRecentEvents: [CribbageEvent] = []
    private var cribbageBotTimer: Timer?
    private var cribbageBotRNG = SeededGenerator(seed: 0)
    /// Remembered for "Play again" after a cribbage game ends — same seats,
    /// fresh seed.
    private var lastCribbageSeats: [SeatSpec] = []

    /// Monotonic bump on EVERY engine mutation. The engine itself is not
    /// @Observable, so this is what guarantees the table redraws the
    /// instant a card lands — views read it, Observation tracks it.
    private(set) var stateVersion = 0

    var state: GameState? { engine?.state }

    init(tableName: String = "Game Night Table") {
        session = HostSession(tableName: tableName)
        session.onMessage = { [weak self] msg, peer in self?.handle(msg, from: peer) }
        session.onPeerChange = { [weak self] peer, connected in self?.peerChanged(peer, connected: connected) }
        session.start()
    }

    /// Screenshot-verification hook: adopt a scripted engine wholesale.
    func adoptDemoEngine(_ demo: HostEngine) {
        engine = demo
    }

    /// Resume hook: adopt an engine restored from a saved game, mirroring
    /// `adoptDemoEngine`. `seats` rebuilds `botSeats` the same way
    /// `startGame(kind:rules:seats:)` does, so BotDirector keeps auto-playing
    /// bot turns after a resume. It can't rebuild `seatByDevice` too, though
    /// — that reclaim table keys off deviceID, which `SeatSpec` doesn't
    /// carry — so, same as any full app relaunch mid-game, a resumed game
    /// doesn't yet auto-reclaim seats by returning phones. That's a
    /// pre-existing limitation of the reclaim design, not something new here.
    func adoptRestoredGame(_ engine: HostEngine, seats: [SeatSpec],
                           deviceMap: [String: Int] = [:]) {
        self.engine = engine
        botSeats = Set(seats.filter(\.isBot).map(\.id))
        // Restore the deviceID→seat reclaim table so phones that were at
        // the table when it was saved walk right back into their seats.
        seatByDevice = deviceMap
        emit([])
    }

    /// Hold-to-close: park the game (autosave has it) and return to the
    /// menu. Connected phones stay in the lobby for the next deal.
    func closeTable() {
        session.broadcast(.tableReset)
        engine = nil
        botSeats = []
        seatByDevice = [:]
        seatByPlayedCard = [:]
        throwVelocityByCard = [:]
        freePlayLayout = [:]
        faceDownCards = []
        // Cribbage and the card engine are mutually exclusive (like dice) —
        // clearing both here, unconditionally, is the defensive half of
        // that rule: whichever one was actually running, this always
        // leaves neither running.
        cribbageEngine = nil
        cribbageBotSeats = []
        cribbageSeatByDevice = [:]
        cribbageSeatNames = [:]
        cribbageRecentEvents = []
        cribbageBotTimer?.invalidate()
        cribbageBotTimer = nil
        stateVersion += 1
    }

    // MARK: cribbage lifecycle (driven by the table UI)

    /// Cribbage hosting entry point: fixed 2 seats, humans mapped onto
    /// connected lobby players in lobby order exactly like
    /// `startGame(kind:rules:seats:)`, bots driven by `CribbageBot` on a
    /// humanlike pacing timer (see `scheduleCribbageBotIfNeeded`).
    /// Coexistence with `HostEngine` mode is enforced the same way dice
    /// mode is: `TableRootView` checks `cribbageEngine` before `host.state`,
    /// so nothing ever routes to both a card table and a cribbage table at
    /// once — this entry point doesn't need to tear a card game down first.
    func startCribbage(seats specs: [SeatSpec], seed: UInt64) {
        guard specs.count == 2 else { return } // CribbageEngine is fixed 2-player
        lastCribbageSeats = specs

        var deviceMap: [String: Int] = [:]
        var names: [Int: String] = [:]
        var bots: Set<Int> = []
        var humanIndex = 0
        for spec in specs {
            if spec.isBot {
                names[spec.id] = spec.name
                bots.insert(spec.id)
            } else if humanIndex < lobbyPlayers.count {
                let player = lobbyPlayers[humanIndex]
                humanIndex += 1
                let name = spec.name.isEmpty ? player.name : spec.name
                names[spec.id] = name
                deviceMap[player.deviceID] = spec.id
            } else {
                // Seat without a phone: mirrors startGame's own fallback —
                // the seat exists but nothing can currently claim it.
                names[spec.id] = spec.name
            }
        }

        cribbageSeatByDevice = deviceMap
        cribbageSeatNames = names
        cribbageBotSeats = bots
        cribbageBotRNG = SeededGenerator(seed: seed ^ 0x5EED_5EED_5EED_5EED)

        // Every remote sheds whatever it was showing before it's reseated —
        // same "shed before reseat" rule startGame follows.
        session.broadcast(.tableReset)
        let engine = CribbageEngine(seed: seed)
        cribbageEngine = engine
        for (deviceID, seat) in deviceMap {
            for (peer, device) in deviceByPeer where device == deviceID {
                session.send(.welcome(seat: seat), to: [peer])
            }
        }
        stateVersion += 1
        pushCribbageSnapshots()
        scheduleCribbageBotIfNeeded()
    }

    /// Fresh cribbage game, same two seats, new seed — the "Play again"
    /// button on the game-over overlay.
    func restartCribbage() {
        guard !lastCribbageSeats.isEmpty else { return }
        startCribbage(seats: lastCribbageSeats, seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    /// The table itself drives `.advance` (deal the next hand) once the
    /// show has finished walking the breakdown — same "table taps onward"
    /// shape as `tableAction(.nextRound)` for card games.
    /// `CribbageEngine.handleAdvance` never inspects the seat argument
    /// (only the phase), so `from: 0` is a formality, not a claim.
    func cribbageAdvance() {
        guard let cribbageEngine else { return }
        cribbageEmit(cribbageEngine.apply(.advance, from: 0))
    }

    // MARK: game lifecycle (driven by table UI)

    /// All-human convenience: every connected lobby player gets a seat in
    /// lobby order. Delegates to the SeatSpec entry point below.
    func startGame(kind: GameKind, rules: RulesConfig) {
        let specs = lobbyPlayers.enumerated().map { index, player in
            SeatSpec(id: index, name: player.name, isBot: false)
        }
        startGame(kind: kind, rules: rules, seats: specs)
    }

    /// Mixed-table entry point: humans map onto connected lobby players in
    /// lobby order (deviceID → seat reclaim keeps working); bot seats have no
    /// device and are driven by BotDirector. Seat ids are assigned by array
    /// position — the engine requires contiguous 0-based seats.
    func startGame(kind: GameKind, rules: RulesConfig, seats specs: [SeatSpec]) {
        var seats: [Seat] = []
        var deviceMap: [String: Int] = [:]
        var bots: Set<Int> = []
        var humanIndex = 0

        for (seatID, spec) in specs.enumerated() {
            if spec.isBot {
                let color = BotRoster.identity(named: spec.name)?.colorIndex ?? seatID
                seats.append(Seat(id: seatID, playerName: spec.name, colorIndex: color,
                                  isConnected: true, isHost: false))
                bots.insert(seatID)
            } else if humanIndex < lobbyPlayers.count {
                let player = lobbyPlayers[humanIndex]
                humanIndex += 1
                let name = spec.name.isEmpty ? player.name : spec.name
                deviceMap[player.deviceID] = seatID
                seats.append(Seat(id: seatID, playerName: name, colorIndex: seatID,
                                  isConnected: true, isHost: false))
            } else {
                // More human seats than connected players: seat exists but
                // starts unclaimed. A late `hello` can't reclaim it (no
                // deviceID yet), so the menu should avoid this — but the
                // engine stays consistent either way.
                seats.append(Seat(id: seatID, playerName: spec.name, colorIndex: seatID,
                                  isConnected: false, isHost: false))
            }
        }

        seatByDevice = deviceMap
        botSeats = bots
        // Every remote sheds the previous game FIRST (a phone not seated
        // in this game must not keep flicking dead cards), then seated
        // remotes get their fresh seat number — welcome is what updates
        // mySeat, and a stale mySeat mislabels rejection events, which is
        // exactly how the silent-bounce deadend happened.
        session.broadcast(.tableReset)
        let engine = HostEngine(seats: seats, gameKind: kind, rules: rules,
                                seed: UInt64.random(in: UInt64.min...UInt64.max))
        self.engine = engine
        for (deviceID, seat) in deviceMap {
            for (peer, device) in deviceByPeer where device == deviceID {
                session.send(.welcome(seat: seat), to: [peer])
            }
        }
        emit(engine.apply(.startGame(kind, rules, seed: engine.state.seed)))
    }

    /// BotDirector's single entry: a bot's PlayerAction takes exactly the
    /// same road as a phone's (engine apply → emit → events + snapshots).
    /// Human seats and table actions are refused by construction.
    func botAction(_ action: PlayerAction, from seat: Int) {
        guard let engine, botSeats.contains(seat) else { return }
        emit(engine.apply(action, from: seat))
    }

    func tableAction(_ action: TableAction) {
        guard let engine else { return }
        emit(engine.apply(action))
    }

    /// The table itself deals: drag from the deck to a nameplate.
    func drawCard(for seat: Int) {
        guard let engine else { return }
        emit(engine.apply(.drawCard, from: seat))
    }

    /// Free play: a table card dragged onto the deck (back to the pile) or
    /// onto a nameplate (into that player's hand).
    func moveTableCard(_ cardID: String, to zone: FreePlayZone, seat: Int) {
        guard let engine else { return }
        freePlayLayout.removeValue(forKey: cardID)
        faceDownCards.remove(cardID)
        emit(engine.apply(.freeMoveCard(cardID: cardID, to: zone, x: 0, y: 0, rotation: 0),
                          from: seat))
    }

    /// Free play reset: everything back into one shuffled deck.
    func gatherAndShuffle() {
        freePlayLayout = [:]
        faceDownCards = []
        seatByPlayedCard = [:]
        tableAction(.newDeal)
    }

    // MARK: inbound

    private func handle(_ msg: NetMessage, from peer: MCPeerID) {
        switch msg {
        case .hello(let name, let deviceID):
            // Ghost hygiene: this device may be returning with a brand-new
            // peer identity (that's the reconnect design). Forget any old
            // peer that claimed the same deviceID so nothing double-routes.
            for (oldPeer, oldDevice) in deviceByPeer where oldDevice == deviceID && oldPeer != peer {
                deviceByPeer.removeValue(forKey: oldPeer)
            }
            deviceByPeer[peer] = deviceID
            if let seat = seatByDevice[deviceID], let engine {
                // Reclaim: same device returns mid-game → same seat, exact hand.
                engine.setConnected(seat: seat, connected: true)
                session.send(.welcome(seat: seat), to: [peer])
                session.send(.snapshot(engine.state.snapshot(for: seat)), to: [peer])
                emit([])
                // Free play keeps `engine` non-nil, so THIS is the reclaim
                // path a returning phone takes — `onDiceHello` (below)
                // never fires here. No-ops unless free-play dice is on.
                sendFreePlayDiceState(toDevice: deviceID)
            } else if let seat = cribbageSeatByDevice[deviceID], let cribbageEngine {
                // Cribbage reclaim: same device returns mid-hand → same
                // seat, exact hand — mirrors the card-engine branch above.
                session.send(.welcome(seat: seat), to: [peer])
                session.send(.cribbageSnapshot(cribbageEngine.state.snapshot(for: seat)), to: [peer])
            } else if engine == nil {
                if !lobbyPlayers.contains(where: { $0.deviceID == deviceID }) {
                    lobbyPlayers.append((deviceID, name))
                }
                session.send(.welcome(seat: lobbyPlayers.count - 1), to: [peer])
                // Dice mode runs with engine == nil: hand a returning (or
                // re-identified) phone its dice seat state immediately.
                onDiceHello?(deviceID)
            } else {
                session.send(.rejected(reason: "Game in progress — no open seat for this device."), to: [peer])
            }

        case .action(let action):
            guard let engine,
                  let deviceID = deviceByPeer[peer],
                  let seat = seatByDevice[deviceID] else {
                // A remote we can't seat is playing a game it isn't in —
                // tell it so instead of ignoring it into a deadend.
                session.send(.tableReset, to: [peer])
                return
            }
            let events = engine.apply(action, from: seat)
            emit(events)
            // Self-healing: a "card isn't in your hand" rejection means the
            // remote's picture of the world is stale — refresh it on the
            // spot so no desync can ever strand a player.
            if events.contains(where: {
                if case .illegalAttempt(let s, let reason) = $0 {
                    return s == seat && reason.contains("isn't in your hand")
                }
                return false
            }) {
                session.send(.snapshot(engine.state.snapshot(for: seat)), to: [peer])
            }

        case .throwInfo(let cardID, let vx, let vy):
            throwVelocityByCard[cardID] = CGSize(width: vx, height: vy)
            if throwVelocityByCard.count > 64 { throwVelocityByCard.removeAll() } // stale-flick hygiene

        case .throwStyle(let cardID, let pileDrop):
            if pileDrop {
                pileDropCards.insert(cardID)
            } else {
                pileDropCards.remove(cardID)
            }
            if pileDropCards.count > 64 { pileDropCards.removeAll() } // stale-flick hygiene

        case .dicePour(let intensity):
            // Same deviceID-keyed routing as .action, against the dice
            // seat table (the card-game seatByDevice is empty in dice mode).
            guard let deviceID = deviceByPeer[peer],
                  let seat = diceSeatByDevice[deviceID] else {
                // A pour we can't route means a phone's session identity
                // desynced from the dice seat table — loud log, because
                // this exact silence was once a shipped bug (the stray-
                // session ghost purge; see GameClientController.obtain).
                NSLog("Host: dicePour DROPPED — device=%@ diceSeats=%@",
                      deviceByPeer[peer] ?? "<unknown peer>",
                      diceSeatByDevice.description)
                return
            }
            // Free play's host seat (0) is gated by the table's own
            // on-screen cup, same as LCR's roller — a swipe/shake-pour
            // fired early (before the drag gesture's own cupReady-hidden
            // affordance would normally stop it) is just dropped rather
            // than launching a roll the cup hasn't actually loaded for.
            // Every other free-play seat keeps the sandbox's pour-any-time
            // freedom; LCR itself is already gated inside
            // DiceGameController.roll, so this only ever fires for free play.
            if freePlayDiceEnabled, seat == 0, !freePlayCanRoll { return }
            onDicePour?(seat, intensity)

        case .cribbageAction(let action):
            guard let cribbageEngine,
                  let deviceID = deviceByPeer[peer],
                  let seat = cribbageSeatByDevice[deviceID] else {
                // Same "can't route it, say so" hygiene as `.action` above.
                session.send(.tableReset, to: [peer])
                return
            }
            cribbageEmit(cribbageEngine.apply(action, from: seat))

        case .cribbageEvents, .cribbageSnapshot:
            break // host-outbound only

        case .seatClaim, .heartbeat:
            break // lobby order is claim order in v1; heartbeats unused (MCSession states suffice)

        case .welcome, .snapshot, .events, .rejected, .diceState, .tableReset:
            break // host-outbound only
        }
    }

    private func peerChanged(_ peer: MCPeerID, connected: Bool) {
        guard !connected else { return }
        guard let deviceID = deviceByPeer[peer] else { return }
        // A disconnected peer never comes back (reconnects always carry a
        // fresh identity) — drop its routing entry so dead peers can't
        // shadow the device's live one.
        deviceByPeer.removeValue(forKey: peer)
        if let engine, let seat = seatByDevice[deviceID] {
            engine.setConnected(seat: seat, connected: false)
            emit([])
        } else if engine == nil {
            lobbyPlayers.removeAll { $0.deviceID == deviceID }
        }
    }

    // MARK: outbound

    /// After every mutation: events to everyone (and the table), then each
    /// seat its own private view of the world.
    private func emit(_ events: [GameEvent]) {
        stateVersion += 1
        for event in events {
            if case .cardPlayed(let seat, let card, _) = event {
                seatByPlayedCard[card.id] = seat
            }
        }
        if !events.isEmpty {
            onEvents?(events)
            session.broadcast(.events(events))
        }
        pushSnapshots()
    }

    private func pushSnapshots() {
        guard let engine else { return }
        for (peer, deviceID) in deviceByPeer {
            guard let seat = seatByDevice[deviceID] else { continue }
            session.send(.snapshot(engine.state.snapshot(for: seat)), to: [peer])
        }
    }

    // MARK: - Cribbage outbound + bot pacing

    /// After every cribbage mutation: events to everyone, then each seat
    /// its own redacted snapshot, then re-check whether a bot is now on
    /// the hook. Mirrors `emit`/`pushSnapshots` above.
    private func cribbageEmit(_ events: [CribbageEvent]) {
        guard cribbageEngine != nil else { return }
        stateVersion += 1
        if !events.isEmpty {
            cribbageRecentEvents = events
            session.broadcast(.cribbageEvents(events))
        }
        pushCribbageSnapshots()
        scheduleCribbageBotIfNeeded()
    }

    private func pushCribbageSnapshots() {
        guard let cribbageEngine else { return }
        for (peer, deviceID) in deviceByPeer {
            guard let seat = cribbageSeatByDevice[deviceID] else { continue }
            session.send(.cribbageSnapshot(cribbageEngine.state.snapshot(for: seat)), to: [peer])
        }
    }

    /// Which bot seat (if any) currently owes a decision — a discard not
    /// yet submitted, or its turn to peg. `nil` covers handComplete/
    /// gameOver (table-driven, see `cribbageAdvance`) and the case where
    /// it's a human's move.
    private func cribbageBotPendingSeat() -> Int? {
        guard let cribbageEngine else { return nil }
        let state = cribbageEngine.state
        switch state.phase {
        case .discarding:
            return cribbageBotSeats.first { !state.discardsSubmitted.contains($0) }
        case .pegging:
            guard let turn = state.pegging?.turnSeat, cribbageBotSeats.contains(turn) else { return nil }
            return turn
        case .handComplete, .gameOver:
            return nil
        }
    }

    /// Humanlike pause before a bot's discard or peg play, same rhythm as
    /// `BotDirector`/`DiceGameController`. Re-checked at fire time so a
    /// stale schedule (the human moved first, a new hand was dealt)
    /// fizzles instead of firing into a world that's moved on.
    private func scheduleCribbageBotIfNeeded() {
        cribbageBotTimer?.invalidate()
        cribbageBotTimer = nil
        guard let seat = cribbageBotPendingSeat() else { return }
        let timer = Timer(timeInterval: .random(in: 0.9...2.0), repeats: false) { [weak self] _ in
            self?.fireCribbageBot(expectedSeat: seat)
        }
        RunLoop.main.add(timer, forMode: .common)
        cribbageBotTimer = timer
    }

    private func fireCribbageBot(expectedSeat: Int) {
        guard let cribbageEngine, cribbageBotPendingSeat() == expectedSeat else {
            scheduleCribbageBotIfNeeded() // the world moved on; maybe a different bot is up now
            return
        }
        let state = cribbageEngine.state
        switch state.phase {
        case .discarding:
            guard let hand = state.hands[expectedSeat] else { return }
            let discard = CribbageBot.discard(hand: hand, isDealer: expectedSeat == state.dealerSeat,
                                              rng: &cribbageBotRNG)
            cribbageEmit(cribbageEngine.apply(.discardToCrib(cards: discard.map(\.id)), from: expectedSeat))
        case .pegging:
            guard let hand = state.hands[expectedSeat], let pegging = state.pegging,
                  let card = CribbageBot.pegPlay(hand: hand, sequence: pegging.sequence.map(\.card),
                                                 count: pegging.count, rng: &cribbageBotRNG)
            else { return }
            cribbageEmit(cribbageEngine.apply(.playCard(cardID: card.id), from: expectedSeat))
        case .handComplete, .gameOver:
            break
        }
    }
}
