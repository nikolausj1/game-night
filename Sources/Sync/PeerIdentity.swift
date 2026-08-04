import Foundation
import MultipeerConnectivity

/// Identity split, learned the hard way:
///
/// - `deviceID` is DURABLE — it names the seat. A phone that dies, locks,
///   or reinstalls reclaims its exact hand with this.
/// - MCPeerID is DISPOSABLE — a fresh one for every connection attempt.
///   Reusing an archived peerID leaves a ghost session on the host that
///   rejects the returning peer (observed: stuck "Reconnecting…" that even
///   force-quit couldn't clear, because relaunch reused the same identity).
enum PeerIdentity {
    private static let deviceIDKey = "gn.deviceID"

    /// Persistent random ID — the host keys seat reclaim off this, never
    /// off the transient Multipeer identity.
    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// Always brand-new. The 4-char suffix keeps displayNames unique so
    /// two attempts from the same phone can never collide on the host.
    static func freshPeerID(displayName: String) -> MCPeerID {
        let suffix = String(UUID().uuidString.prefix(4))
        let base = String(displayName.prefix(58))
        return MCPeerID(displayName: "\(base)·\(suffix)")
    }
}
