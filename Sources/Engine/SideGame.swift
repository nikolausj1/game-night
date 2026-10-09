import Foundation

/// The generic wire shape for every "side game" — a game hosted by the
/// table OUTSIDE the card engine (the way cribbage and the dice games are),
/// whose per-seat state, actions, and events are its own Codable types.
///
/// Why generic: each new side game used to need its own `NetMessage`
/// cases plus routing edits in four shared files (host, client, the two
/// root routers). With eight such games landing in one night, that is a
/// merge-conflict factory. Instead, a side game ships its payloads as
/// opaque JSON keyed by `kind`; the host/client route by kind and never
/// learn the concrete types. A peer that doesn't know a kind simply has no
/// view registered for it and ignores the payload — forward-compatible.
public struct SideGamePayload: Codable, Equatable, Sendable {
    public let kind: String
    public let data: Data

    public init(kind: String, data: Data) {
        self.kind = kind
        self.data = data
    }

    public init<T: Encodable>(kind: String, value: T) throws {
        self.kind = kind
        self.data = try JSONEncoder().encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
