import Foundation
import MultipeerConnectivity
import os

/// A phone's side of the wire. Browses for a nearby table, auto-invites
/// itself, and aggressively self-heals: locking the phone kills Multipeer
/// sessions silently, so this class rebuilds the session and re-browses
/// whenever the link drops, wedges, or the app returns to the foreground.
@Observable
final class ClientSession: NSObject {
    enum ConnectionState: Equatable {
        case searching
        case connecting(tableName: String)
        case connected(tableName: String)
        case disconnected
    }

    private let log = Logger(subsystem: "com.levelup.gamenight", category: "ClientSession")
    private let playerName: String
    /// DISPOSABLE: regenerated on every rebuild — see PeerIdentity.
    private var peerID: MCPeerID
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var outSeq: UInt64 = 0
    private var tablePeer: MCPeerID?

    /// Discovered tables, ghost-resistant selection state.
    struct TableCandidate { var ts: Double; var name: String }
    private var candidates: [MCPeerID: TableCandidate] = [:]
    private var blacklist: [MCPeerID: Date] = [:]

    /// Peer displayNames carry a uniquing "·XXXX" suffix — never show it.
    private func cleanName(_ displayName: String) -> String {
        displayName.components(separatedBy: "·").first ?? displayName
    }

    /// Court the most recently launched, non-blacklisted table.
    private func tryBestCandidate() {
        guard tablePeer == nil else { return }
        let now = Date()
        blacklist = blacklist.filter { now.timeIntervalSince($0.value) < 25 }
        guard let best = candidates
            .filter({ blacklist[$0.key] == nil })
            .max(by: { $0.value.ts < $1.value.ts }) else { return }
        tablePeer = best.key
        setState(.connecting(tableName: best.value.name))
        // Short timeout: a ghost that won't answer should cost seconds,
        // not a stare-down. notConnected/timeout blacklists and cycles.
        browser.invitePeer(best.key, to: session, withContext: nil, timeout: 6)
    }

    /// Watchdog: the host broadcasts a heartbeat every few seconds; if the
    /// session claims "connected" but nothing arrives, it's wedged.
    private var lastReceiveAt = Date.distantPast
    private var lastStateChangeAt = Date()
    private var watchdog: Timer?

    private(set) var connectionState: ConnectionState = .disconnected

    /// Called on the main queue for every decoded message from the table.
    var onMessage: ((NetMessage) -> Void)?
    /// Called on the main queue when the connection state changes.
    var onStateChange: ((ConnectionState) -> Void)?

    init(playerName: String) {
        self.playerName = playerName
        self.peerID = PeerIdentity.freshPeerID(displayName: playerName)
        super.init()
        rebuildTransport()
    }

    /// Fresh identity, fresh session, fresh browser — the host sees a
    /// brand-new peer every time, so no ghost can block us.
    private func rebuildTransport() {
        session?.disconnect()
        browser?.stopBrowsingForPeers()
        peerID = PeerIdentity.freshPeerID(displayName: playerName)
        // Mirrors HostSession: simulator-to-simulator DTLS never completes.
        #if targetEnvironment(simulator)
        let encryption: MCEncryptionPreference = .none
        #else
        let encryption: MCEncryptionPreference = .required
        #endif
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: encryption)
        session.delegate = self
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: HostSession.serviceType)
        browser.delegate = self
    }

    func start() {
        setState(.searching)
        browser.startBrowsingForPeers()
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        browser.stopBrowsingForPeers()
        session.disconnect()
        tablePeer = nil
        setState(.disconnected)
    }

    /// Revive a session that was fully STOPPED (leave table). Anything
    /// else — searching, connecting, connected — is already alive and
    /// making progress; touching it here would tear down handshakes
    /// mid-flight every time SwiftUI re-inits the owning view. The
    /// watchdog covers wedges.
    func ensureAlive() {
        guard case .disconnected = connectionState else { return }
        startWatchdog() // re-arms after stop() (refresh alone never does)
        refresh()
    }

    /// Tear down and rediscover with a completely fresh identity. Called
    /// after drops, on foregrounding, and by the watchdog. A fresh browser
    /// re-fires foundPeer for tables the old one had already seen.
    func refresh() {
        if case .connected = connectionState, Date().timeIntervalSince(lastReceiveAt) < 6 {
            return // genuinely healthy; leave it alone
        }
        log.info("refresh: rebuilding transport with fresh peer identity")
        tablePeer = nil
        candidates = [:] // fresh browser re-reports live peers only
        rebuildTransport()
        setState(.searching)
        browser.startBrowsingForPeers()
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        lastReceiveAt = Date()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let stateAge = Date().timeIntervalSince(self.lastStateChangeAt)
            switch self.connectionState {
            case .connected:
                // Keep a trickle of outbound traffic so both watchdogs
                // have something to miss.
                self.send(.heartbeat)
                if Date().timeIntervalSince(self.lastReceiveAt) > 12 {
                    self.log.info("watchdog: connected but silent >12s — wedged, refreshing")
                    self.refresh()
                }
            case .connecting where stateAge > 10:
                // Invitation black hole (host had a ghost, or DTLS died
                // mid-handshake): start over with a new identity.
                self.log.info("watchdog: connecting >10s — restarting with fresh identity")
                self.refresh()
            case .searching where stateAge > 20:
                // Browsing can silently rot after backgrounding.
                self.log.info("watchdog: searching >20s — rebuilding browser")
                self.refresh()
            default:
                break
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Returns false when the message could not be handed to the session —
    /// callers treat that as "the link is lying about being alive".
    @discardableResult
    func send(_ msg: NetMessage) -> Bool {
        guard let table = tablePeer, session.connectedPeers.contains(table) else {
            log.error("send while not connected — dropped")
            return false
        }
        outSeq += 1
        do {
            let data = try NetCodec.encode(NetEnvelope(v: 1, seq: outSeq, msg: msg))
            try session.send(data, toPeers: [table], with: .reliable)
            return true
        } catch {
            log.error("send failed: \(error.localizedDescription)")
            return false
        }
    }

    private func setState(_ new: ConnectionState) {
        DispatchQueue.main.async {
            guard self.connectionState != new else { return }
            self.connectionState = new
            self.lastStateChangeAt = Date()
            self.onStateChange?(new)
        }
    }
}

extension ClientSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "table" else { return }
        // Collect candidates instead of marrying the first one: after a few
        // force-quits the mDNS cache is littered with ghost tables, and the
        // ghost usually surfaces first. Newest launch timestamp wins;
        // failed invites get blacklisted so we cycle instead of spinning.
        let ts = Double(info?["ts"] ?? "") ?? 0
        let name = info?["name"] ?? cleanName(peerID.displayName)
        candidates[peerID] = TableCandidate(ts: ts, name: name)
        tryBestCandidate()
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        candidates.removeValue(forKey: peerID)
        if peerID == tablePeer, case .connecting = connectionState {
            tablePeer = nil
            setState(.searching)
            tryBestCandidate()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log.error("browsing failed: \(error.localizedDescription)")
    }
}

extension ClientSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard peerID == tablePeer else { return }
        switch state {
        case .connected:
            lastReceiveAt = Date()
            let name = candidates[peerID]?.name ?? cleanName(peerID.displayName)
            blacklist = [:]
            setState(.connected(tableName: name))
            // Introduce ourselves immediately; the host replies with a
            // snapshot (and our old seat, if we had one). Send the CLEAN
            // player name — the peer displayName carries a uniquing suffix.
            send(.hello(name: playerName, deviceID: PeerIdentity.deviceID))
        case .notConnected:
            // Invite failed or link died. If we were still courting, this
            // candidate is likely a ghost: blacklist it and try the next
            // table rather than re-courting the same corpse forever.
            DispatchQueue.main.async {
                if case .connecting = self.connectionState {
                    self.blacklist[peerID] = Date()
                    self.tablePeer = nil
                    self.setState(.searching)
                    self.tryBestCandidate()
                } else {
                    // Was fully connected and dropped: full rebuild.
                    self.refresh()
                }
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard peerID == tablePeer else { return }
        lastReceiveAt = Date()
        guard let envelope = try? NetCodec.decode(data), envelope.v == 1 else { return }
        DispatchQueue.main.async { self.onMessage?(envelope.msg) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
