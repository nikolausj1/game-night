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
    /// Dice mode: set while the table runs a dice game, nil otherwise —
    /// snapshot-driven card UI takes priority when this is nil.
    /// HandRootView routes to DiceCupView whenever it's non-nil.
    private(set) var diceState: DiceClientState?

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

    func placeBid(_ bid: Int) { sendAction(.placeBid(bid)) }

    func chooseTrump(_ suit: Suit) { sendAction(.chooseTrump(suit)) }

    /// velocity: the flick in points/sec on this screen — presentation
    /// data for the table's physics, never game state.
    /// pileDrop: dev-tool only (free play), presentation-only — nil means
    /// "don't send", so every existing caller keeps its current behavior.
    func playCard(_ cardID: String, velocity: CGSize = .zero, pileDrop: Bool? = nil) {
        pendingIllegal = nil
        lastAttemptedCardID = cardID
        if let pileDrop, case .connected = connectionState {
            session.send(.throwStyle(cardID: cardID, pileDrop: pileDrop))
        }
        if velocity != .zero {
            session.send(.throwInfo(cardID: cardID,
                                    vx: Double(velocity.width),
                                    vy: Double(velocity.height)))
        }
        sendAction(.playCard(cardID: cardID, force: false))
    }

    /// The deliberate second step after an illegal warning.
    func forcePlayPendingCard() {
        guard let pending = pendingIllegal else { return }
        pendingIllegal = nil
        sendAction(.playCard(cardID: pending.cardID, force: true))
    }

    func cancelPendingPlay() { pendingIllegal = nil }

    func declareSuit(_ suit: Suit) { sendAction(.declareSuit(suit)) }

    func drawCard() { sendAction(.drawCard) }

    func requestUndo() { sendAction(.requestUndo) }

    /// Every game action goes through here: a failed hand-off means the
    /// session is wedged, so start rebuilding IMMEDIATELY — the card stays
    /// in the hand (no snapshot confirms it left) and the very next swipe
    /// after the pill clears will land.
    private func sendAction(_ action: PlayerAction) {
        if !session.send(.action(action)) {
            session.refresh()
        }
    }

    // MARK: inbound

    private func handle(_ msg: NetMessage) {
        switch msg {
        case .welcome(let seat):
            mySeat = seat
        case .snapshot(let snap):
            snapshot = snap
            diceState = nil // a card game superseded dice mode
            runAutoPlayIfAsked(snap)
        case .diceState(let state):
            // mySeat < 0 is the "dice game closed" sentinel from the table
            // — clears dice mode and drops the phone back to the lobby.
            diceState = state.mySeat >= 0 ? state : nil
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
        case .hello, .seatClaim, .action, .heartbeat, .throwInfo, .throwStyle, .dicePour:
            break // client-outbound only
        }
    }

    // The last card we tried, so an illegalAttempt event ties back to it.
    private var lastAttemptedCardID: String?

    // Sim-verify hook (-autoPlay): draw once, then play the first card —
    // exercises the full phone→table pipeline with no taps.
    private var autoPlayStage = 0
    private func runAutoPlayIfAsked(_ snap: ClientSnapshot) {
        guard CommandLine.arguments.contains("-autoPlay"),
              snap.gameKind == .freePlay, snap.phase == .playing else { return }
        if autoPlayStage == 0, snap.myHand.isEmpty {
            autoPlayStage = 1
            drawCard()
        } else if autoPlayStage == 1, let first = snap.myHand.first {
            autoPlayStage = 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.playCard(first.id)
            }
        }
    }
}
