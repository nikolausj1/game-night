import Foundation
import Observation

/// A phone's brain: mirrors the table's redacted snapshot and sends actions.
/// Never computes rules locally beyond what the snapshot already carries —
/// the host is the single source of truth.
@Observable
final class GameClientController {
    let session: ClientSession
    let playerName: String

    private(set) var mySeat: Int?
    private(set) var snapshot: ClientSnapshot?
    private(set) var lastRejection: String?
    /// Set when the host refuses a play softly; UI shows the confirm sheet.
    private(set) var pendingIllegal: (cardID: String, reason: String)?
    /// Recent events, for hand-side animation triggers.
    private(set) var recentEvents: [GameEvent] = []

    var connectionState: ClientSession.ConnectionState { session.connectionState }

    init(playerName: String) {
        self.playerName = playerName
        session = ClientSession(playerName: playerName)
        session.onMessage = { [weak self] msg in self?.handle(msg) }
        session.start()
    }

    /// Screenshot-verification hook: adopt a snapshot without a session.
    func adoptDemoSnapshot(_ snap: ClientSnapshot) {
        snapshot = snap
        mySeat = snap.mySeat
    }

    // MARK: actions from the hand UI

    func placeBid(_ bid: Int) { session.send(.action(.placeBid(bid))) }

    func chooseTrump(_ suit: Suit) { session.send(.action(.chooseTrump(suit))) }

    func playCard(_ cardID: String) {
        pendingIllegal = nil
        lastAttemptedCardID = cardID
        session.send(.action(.playCard(cardID: cardID, force: false)))
    }

    /// The deliberate second step after an illegal warning.
    func forcePlayPendingCard() {
        guard let pending = pendingIllegal else { return }
        pendingIllegal = nil
        session.send(.action(.playCard(cardID: pending.cardID, force: true)))
    }

    func cancelPendingPlay() { pendingIllegal = nil }

    func declareSuit(_ suit: Suit) { session.send(.action(.declareSuit(suit))) }

    func drawCard() { session.send(.action(.drawCard)) }

    func requestUndo() { session.send(.action(.requestUndo)) }

    // MARK: inbound

    private func handle(_ msg: NetMessage) {
        switch msg {
        case .welcome(let seat):
            mySeat = seat
        case .snapshot(let snap):
            snapshot = snap
        case .events(let events):
            recentEvents = events
            for event in events {
                if case .illegalAttempt(let seat, let reason) = event, seat == mySeat {
                    // Reconstruct which card: the host rejected our last try.
                    if let cardID = lastAttemptedCardID {
                        pendingIllegal = (cardID, reason)
                    }
                }
            }
        case .rejected(let reason):
            lastRejection = reason
        case .hello, .seatClaim, .action, .heartbeat:
            break // client-outbound only
        }
    }

    // The last card we tried, so an illegalAttempt event ties back to it.
    private var lastAttemptedCardID: String?
}
