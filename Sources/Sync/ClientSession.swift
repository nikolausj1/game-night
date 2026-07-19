import Foundation
import MultipeerConnectivity
import os

/// A phone's side of the wire. Browses for a nearby table, auto-invites
/// itself, and keeps retrying after drops — the player should never have to
/// think about connectivity.
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
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser
    private var outSeq: UInt64 = 0
    private var tablePeer: MCPeerID?

    private(set) var connectionState: ConnectionState = .disconnected

    /// Called on the main queue for every decoded message from the table.
    var onMessage: ((NetMessage) -> Void)?
    /// Called on the main queue when the connection state changes.
    var onStateChange: ((ConnectionState) -> Void)?

    init(playerName: String) {
        self.peerID = PeerIdentity.peerID(displayName: playerName)
        // Mirrors HostSession: simulator-to-simulator DTLS never completes.
        #if targetEnvironment(simulator)
        let encryption: MCEncryptionPreference = .none
        #else
        let encryption: MCEncryptionPreference = .required
        #endif
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: encryption)
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: HostSession.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    func start() {
        setState(.searching)
        browser.startBrowsingForPeers()
    }

    func stop() {
        browser.stopBrowsingForPeers()
        session.disconnect()
        tablePeer = nil
        setState(.disconnected)
    }

    func send(_ msg: NetMessage) {
        guard let table = tablePeer, session.connectedPeers.contains(table) else {
            log.error("send while not connected: \(String(describing: msg))")
            return
        }
        outSeq += 1
        do {
            let data = try NetCodec.encode(NetEnvelope(v: 1, seq: outSeq, msg: msg))
            try session.send(data, toPeers: [table], with: .reliable)
        } catch {
            log.error("send failed: \(error.localizedDescription)")
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
            setState(.connected(tableName: peerID.displayName))
            // Introduce ourselves immediately; the host replies with a
            // snapshot (and our old seat, if we had one).
            send(.hello(name: self.peerID.displayName, deviceID: PeerIdentity.deviceID))
        case .notConnected:
            tablePeer = nil
            setState(.searching)
            // MCNearbyServiceBrowser keeps running; a rediscovered table
            // triggers a fresh invite — this IS the reconnect loop.
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard peerID == tablePeer, let envelope = try? NetCodec.decode(data), envelope.v == 1 else { return }
        DispatchQueue.main.async { self.onMessage?(envelope.msg) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
