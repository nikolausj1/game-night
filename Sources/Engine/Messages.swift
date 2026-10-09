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

/// Adding a case here is safe for back-compat on its own: an old peer that
/// receives a message using a case it doesn't know about will fail to
/// decode the whole `NetEnvelope`, but both call sites
/// (`ClientSession.handleData`, `HostSession.handleData`) already wrap that
/// decode in `try? NetCodec.decode(data)` and silently drop the message on
/// failure — the existing "unknown case" resilience lives there, not in a
/// custom `Decodable` on this enum. New cases below (added for cribbage)
/// rely on that same mechanism; no envelope/decoder changes were needed.
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
    /// Dev tool, free play only, presentation-only (like throwInfo): which
    /// play animation the table should use for this card's landing —
    /// `pileDrop` true for the airborne arc onto a neat pile, false for the
    /// trick-game friction slide. Sent just before the throwInfo/playCard
    /// pair so the table already knows the style when the card lands.
    case throwStyle(cardID: String, pileDrop: Bool)
    /// Dice mode, phone → table: the pour. `intensity` (0.3…1.5) scales the
    /// table-side launch velocity and tumble time. The dice results are
    /// rolled on the table (seeded RNG), never on the phone.
    case dicePour(intensity: Double)
    /// Dice mode, table → each phone: that seat's personalized view of the
    /// dice game (see DiceClientState).
    case diceState(DiceClientState)
    /// Table → everyone: the game that was running is GONE (closed, or a
    /// new one is starting). Remotes drop all game state immediately —
    /// without this, a remote can keep flicking cards from a dead deck
    /// into a new engine that rightly rejects them (observed in the field
    /// as the silent-bounce deadend).
    case tableReset
    /// Cribbage, phone → table: the seat's action. Mirrors `.action`
    /// (`PlayerAction`) — the sender's seat comes from the connection
    /// (`welcome(seat:)`), never embedded in the message.
    case cribbageAction(CribbageAction)
    /// Cribbage, table → everyone: the events an action just produced.
    /// Mirrors `.events` ([GameEvent]).
    case cribbageEvents([CribbageEvent])
    /// Cribbage, table → each phone: that seat's personalized, redacted
    /// view. Mirrors `.snapshot` (`ClientSnapshot`).
    case cribbageSnapshot(CribbageSnapshot)
    /// Generic side games (Battleship, Gin Rummy, Go Fish, Liar's Dice,
    /// ...): opaque Codable payloads keyed by the game's `kind` string.
    /// See `SideGamePayload`. Phone → table action; table → each phone its
    /// redacted state; table → everyone the events an action produced.
    case sideGameAction(SideGamePayload)
    case sideGameState(SideGamePayload)
    case sideGameEvents(SideGamePayload)
}

public enum NetCodec {
    public static func encode(_ envelope: NetEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> NetEnvelope {
        try JSONDecoder().decode(NetEnvelope.self, from: data)
    }
}
