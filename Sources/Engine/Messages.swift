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
}

public enum NetCodec {
    public static func encode(_ envelope: NetEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> NetEnvelope {
        try JSONDecoder().decode(NetEnvelope.self, from: data)
    }
}
