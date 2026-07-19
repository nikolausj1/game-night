import Foundation

/// Wire envelope. `v` is the protocol version (current: 1); `seq` is a
/// per-sender monotonically increasing sequence number for ordering/dedupe.
public struct NetEnvelope: Codable, Sendable, Equatable {
    public let v: Int
    public let seq: UInt64
    public let msg: NetMessage

    public static let currentVersion = 1

    public init(v: Int = NetEnvelope.currentVersion, seq: UInt64, msg: NetMessage) {
        self.v = v
        self.seq = seq
        self.msg = msg
    }
}

public enum NetMessage: Codable, Sendable, Equatable {
    case hello(name: String, deviceID: String)
    case welcome(seat: Int)
    case seatClaim(seat: Int, name: String)
    case snapshot(ClientSnapshot)
    case action(PlayerAction)
    case events([GameEvent])
    case heartbeat
    case rejected(reason: String)
    /// Presentation-only kinematics sent just before a playCard action:
    /// the flick velocity in points/sec on the thrower's screen. The table
    /// uses it to give the card a matching slide; the engine never sees it.
    case throwInfo(cardID: String, vx: Double, vy: Double)
}

public enum NetCodec {
    public static func encode(_ envelope: NetEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> NetEnvelope {
        try JSONDecoder().decode(NetEnvelope.self, from: data)
    }
}
