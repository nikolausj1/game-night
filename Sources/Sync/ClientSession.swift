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
    private let peerID: MCPeerID
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var outSeq: UInt64 = 0
    private var tablePeer: MCPeerID?

    /// Watchdog: the host broadcasts a heartbeat every few seconds; if the
    /// session claims "connected" but nothing arrives, it's wedged.
    private var lastReceiveAt = Date.distantPast
    private var watchdog: Timer?

    private(set) var connectionState: ConnectionState = .disconnected

    /// Called on the main queue for every decoded message from the table.
    var onMessage: ((NetMessage) -> Void)?
    /// Called on the main queue when the connection state changes.
    var onStateChange: ((ConnectionState) -> Void)?

    init(playerName: String) {
        self.peerID = PeerIdentity.peerID(displayName: playerName)
        super.init()
        rebuildSession()
        rebuildBrowser()
    }

    private func rebuildSession() {
        session?.disconnect()
        // Mirrors HostSession: simulator-to-simulator DTLS never completes.
        #if targetEnvironment(simulator)
        let encryption: MCEncryptionPreference = .none
        #else
        let encryption: MCEncryptionPreference = .required
        #endif
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: encryption)
        session.delegate = self
    }

    private func rebuildBrowser() {
        browser?.stopBrowsingForPeers()
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

    /// Tear down and rediscover. Called after drops, on foregrounding, and
    /// by the watchdog. A fresh browser re-fires foundPeer for tables the
    /// old one had already seen — without this, a re-found table is
    /// invisible and the phone hangs in "searching" forever.
    func refresh() {
        if case .connected = connectionState, Date().timeIntervalSince(lastReceiveAt) < 6 {
            return // genuinely healthy; leave it alone
        }
        log.info("refresh: rebuilding session + browser")
        tablePeer = nil
        rebuildSession()
        rebuildBrowser()
        setState(.searching)
        browser.startBrowsingForPeers()
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        lastReceiveAt = Date()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Keep a trickle of outbound traffic so the host's watchdog
            // (and ours) has something to miss.
            if case .connected = self.connectionState {
                self.send(.heartbeat)
                if Date().timeIntervalSince(self.lastReceiveAt) > 12 {
                    self.log.info("watchdog: connected but silent >12s — wedged, refreshing")
                    self.refresh()
                }
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
            self.onStateChange?(new)
        }
    }
}

extension ClientSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "table" else { return }
        // First table wins; multiple simultaneous tables in one house is a
        // v2 problem (QR code would disambiguate).
        guard tablePeer == nil || tablePeer == peerID else { return }
        tablePeer = peerID
        setState(.connecting(tableName: peerID.displayName))
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if peerID == tablePeer, case .connecting = connectionState {
            tablePeer = nil
            setState(.searching)
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
            setState(.connected(tableName: peerID.displayName))
            // Introduce ourselves immediately; the host replies with a
            // snapshot (and our old seat, if we had one).
            send(.hello(name: self.peerID.displayName, deviceID: PeerIdentity.deviceID))
        case .notConnected:
            // The old session object is dead — rebuild everything so the
            // next discovery starts clean. (Sessions do not survive locks.)
            DispatchQueue.main.async { self.refresh() }
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
