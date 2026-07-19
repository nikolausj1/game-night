import Foundation
import MultipeerConnectivity
import Observation

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

    /// Table UI + announcer director subscribe here.
    var onEvents: (([GameEvent]) -> Void)?

    /// Free play: which seat played each card, so the table can animate the
    /// landing from the right edge. Table-side memory only, never synced.
    private(set) var seatByPlayedCard: [String: Int] = [:]

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

    // MARK: game lifecycle (driven by table UI)

    func startGame(kind: GameKind, rules: RulesConfig) {
        let seats = lobbyPlayers.enumerated().map { index, player in
            Seat(id: index, playerName: player.name, colorIndex: index, isConnected: true, isHost: false)
        }
        seatByDevice = Dictionary(uniqueKeysWithValues: lobbyPlayers.enumerated().map { ($1.deviceID, $0) })
        let engine = HostEngine(seats: seats, gameKind: kind, rules: rules,
                                seed: UInt64.random(in: UInt64.min...UInt64.max))
        self.engine = engine
        emit(engine.apply(.startGame(kind, rules, seed: engine.state.seed)))
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

    // MARK: inbound

    private func handle(_ msg: NetMessage, from peer: MCPeerID) {
        switch msg {
        case .hello(let name, let deviceID):
            deviceByPeer[peer] = deviceID
            if let seat = seatByDevice[deviceID], let engine {
                // Reclaim: same device returns mid-game → same seat, exact hand.
                engine.setConnected(seat: seat, connected: true)
                session.send(.welcome(seat: seat), to: [peer])
                session.send(.snapshot(engine.state.snapshot(for: seat)), to: [peer])
                emit([])
            } else if engine == nil {
                if !lobbyPlayers.contains(where: { $0.deviceID == deviceID }) {
                    lobbyPlayers.append((deviceID, name))
                }
                session.send(.welcome(seat: lobbyPlayers.count - 1), to: [peer])
            } else {
                session.send(.rejected(reason: "Game in progress — no open seat for this device."), to: [peer])
            }

        case .action(let action):
            guard let engine,
                  let deviceID = deviceByPeer[peer],
                  let seat = seatByDevice[deviceID] else { return }
            emit(engine.apply(action, from: seat))

        case .seatClaim, .heartbeat:
            break // lobby order is claim order in v1; heartbeats unused (MCSession states suffice)

        case .welcome, .snapshot, .events, .rejected:
            break // host-outbound only
        }
    }

    private func peerChanged(_ peer: MCPeerID, connected: Bool) {
        guard !connected else { return }
        guard let deviceID = deviceByPeer[peer] else { return }
        if let engine, let seat = seatByDevice[deviceID] {
            engine.setConnected(seat: seat, connected: false)
            pushSnapshots()
        } else if engine == nil {
            lobbyPlayers.removeAll { $0.deviceID == deviceID }
        }
    }

    // MARK: outbound

    /// After every mutation: events to everyone (and the table), then each
    /// seat its own private view of the world.
    private func emit(_ events: [GameEvent]) {
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
