import Foundation
import MultipeerConnectivity
import os

/// The iPad table's side of the wire. Advertises the table, accepts every
/// invitation, and moves NetEnvelopes. Knows nothing about game rules —
/// GameHostController wires messages to the engine.
@Observable
final class HostSession: NSObject {
    static let serviceType = "gamenight"

    private let log = Logger(subsystem: "com.levelup.gamenight", category: "HostSession")
    private let peerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var outSeq: UInt64 = 0

    /// Connected phones by their MC peer. deviceIDs arrive via hello and are
    /// tracked by the controller, not here.
    private(set) var connectedPeers: [MCPeerID] = []

    /// Called on the main queue for every decoded message.
    var onMessage: ((NetMessage, MCPeerID) -> Void)?
    /// Called on the main queue when a peer connects/disconnects.
    var onPeerChange: ((MCPeerID, Bool) -> Void)?

    init(tableName: String) {
        self.peerID = PeerIdentity.peerID(displayName: tableName)
        // DTLS between two simulators is broken (endless -9803 handshakes);
        // devices keep encryption on.
        #if targetEnvironment(simulator)
        let encryption: MCEncryptionPreference = .none
        #else
        let encryption: MCEncryptionPreference = .required
        #endif
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: encryption)
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["role": "table"],
            serviceType: Self.serviceType
        )
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    func start() { advertiser.startAdvertisingPeer() }

    func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        connectedPeers = []
    }

    func send(_ msg: NetMessage, to peers: [MCPeerID]) {
        let targets = peers.filter { session.connectedPeers.contains($0) }
        guard !targets.isEmpty else { return }
        outSeq += 1
        do {
            let data = try NetCodec.encode(NetEnvelope(v: 1, seq: outSeq, msg: msg))
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            log.error("send failed: \(error.localizedDescription)")
        }
    }

    func broadcast(_ msg: NetMessage) { send(msg, to: session.connectedPeers) }
}

extension HostSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) { self.connectedPeers.append(peerID) }
                self.onPeerChange?(peerID, true)
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                self.onPeerChange?(peerID, false)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let envelope = try? NetCodec.decode(data), envelope.v == 1 else {
            log.error("undecodable envelope from \(peerID.displayName)")
            return
        }
        DispatchQueue.main.async { self.onMessage?(envelope.msg, peerID) }
    }

    // Unused stream/resource channels.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension HostSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Household trust model: every nearby Game Night phone may join the
        // lobby; seat claiming is the actual gate.
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log.error("advertising failed: \(error.localizedDescription)")
    }
}
