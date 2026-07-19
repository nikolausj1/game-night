import Foundation
import MultipeerConnectivity

/// Stable identity for this device across launches, so a phone that dies
/// mid-game reclaims its exact seat (and hand) on reconnect.
enum PeerIdentity {
    private static let deviceIDKey = "gn.deviceID"
    private static let peerNameKey = "gn.peerDisplayName"

    /// Persistent random ID — the host keys seat reclaim off this, never off
    /// the MCPeerID (which can be recreated).
    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// MCPeerID must be reused, not recreated each session, or Multipeer
    /// treats every relaunch as a brand-new peer and leaks ghost sessions.
    static func peerID(displayName: String) -> MCPeerID {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: peerNameKey),
           let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           archived.displayName == displayName {
            return archived
        }
        let fresh = MCPeerID(displayName: displayName)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            defaults.set(data, forKey: peerNameKey)
        }
        return fresh
    }
}
