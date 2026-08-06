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

    func setFreePlayDiceEnabled(_ enabled: Bool) {
        guard freePlayDiceEnabled != enabled else { return }
        freePlayDiceEnabled = enabled
        if enabled {
            // Every lobby player becomes a "seat" purely so an incoming
            // .dicePour has something to route through diceSeatByDevice —
            // free play has no real seats/turns, the index is unused by
            // anything (there are no rules to key off it).
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
        // sandbox has no turn order for DiceCupView to gate against.
        let state = DiceClientState(kind: .leftRightCenter, mySeat: mySeat, seatNames: names,
                                    chips: Array(repeating: 0, count: names.count), centerPot: 0,
                                    turnSeat: mySeat, isMyTurn: true, gameOver: false,
                                    winnerSeat: nil, cupReady: true) // no manual-cup gating here
        sendDiceState(state, toDevice: deviceID)
    }

    /// Free play, table-local physics: where the humans have slid each
    /// card (normalized coords) and which they've flipped face-down.
    var freePlayLayout: [String: CGPoint] = [:]
    var faceDownCards: Set<String> = []

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
        stateVersion += 1
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
            onDicePour?(seat, intensity)

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
}
