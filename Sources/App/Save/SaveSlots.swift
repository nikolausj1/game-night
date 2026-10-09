import Foundation

/// Which family a resumable game belongs to, and (where it matters) which
/// game. This is the one key every save/resume path in the app speaks:
/// `SaveSlots` names its files by it, `ResumeCatalog` lists by it, and the
/// menu routes by it.
///
/// `hostEngine` games (Wizard, UNO, Hearts...) keep their ORIGINAL store
/// (`GameStateStore`, one file per suspended game under
/// `Documents/SavedGames/`); that format is untouched. Every other kind
/// saves one envelope per kind under `Documents/SavedGames/Kinds/` — a
/// family only ever has one suspended game at a time, which is also how
/// the lobby's "pick up where you left off" strip reads best: one card per
/// game, never a pile of half-finished Yahtzees.
enum ResumeKind: Equatable, Hashable {
    case hostEngine(GameKind)
    case cribbage
    /// `SideGameHost.kind` (e.g. "blackjack", "goFish").
    case sideGame(String)
    case dice(DiceKind)
    /// `"mancala"`, `"checkers"`, `"connectFour"`, `"dotsAndBoxes"`, `"quarto"`.
    case board(String)
    case solitaire

    /// Stable on-disk / routing key. Never derived from a type name, so a
    /// refactor can't orphan a save file.
    var slotKey: String {
        switch self {
        case .hostEngine(let kind): return "engine.\(kind.rawValue)"
        case .cribbage: return "cribbage"
        case .sideGame(let kind): return "side.\(kind)"
        case .dice(let kind): return "dice.\(Self.diceKey(kind))"
        case .board(let kind): return "board.\(kind)"
        case .solitaire: return "solitaire"
        }
    }

    init?(slotKey: String) {
        if slotKey == "cribbage" { self = .cribbage; return }
        if slotKey == "solitaire" { self = .solitaire; return }
        let parts = slotKey.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "engine":
            guard let kind = GameKind(rawValue: parts[1]) else { return nil }
            self = .hostEngine(kind)
        case "side": self = .sideGame(parts[1])
        case "dice":
            guard let kind = Self.diceKind(parts[1]) else { return nil }
            self = .dice(kind)
        case "board": self = .board(parts[1])
        default: return nil
        }
    }

    /// The player-facing family name, used for resume cards and recap demos.
    var displayName: String {
        switch self {
        case .hostEngine(let kind): return kind.displayName
        case .cribbage: return "Cribbage"
        case .sideGame(let kind): return Self.sideGameDisplayName(kind)
        case .dice(let kind): return kind.displayName
        case .board(let kind): return Self.boardDisplayName(kind)
        case .solitaire: return "Solitaire"
        }
    }

    private static func diceKey(_ kind: DiceKind) -> String {
        switch kind {
        case .lcr: return "lcr"
        case .yahtzee: return "yahtzee"
        case .zilch: return "zilch"
        case .shutTheBox: return "shutTheBox"
        }
    }

    private static func diceKind(_ key: String) -> DiceKind? {
        switch key {
        case "lcr": return .lcr
        case "yahtzee": return .yahtzee
        case "zilch": return .zilch
        case "shutTheBox": return .shutTheBox
        default: return nil
        }
    }

    static func sideGameDisplayName(_ kind: String) -> String {
        switch kind {
        case "battleship": return "Battleship"
        case "ginRummy": return "Gin Rummy"
        case "blackjack": return "Blackjack"
        case "liarsDice": return "Liar's Dice"
        case "goFish": return "Go Fish"
        case "oldMaid": return "Old Maid"
        case "war": return "War"
        default: return kind
        }
    }

    static func boardDisplayName(_ kind: String) -> String {
        switch kind {
        case "mancala": return "Mancala"
        case "checkers": return "Checkers"
        case "connectFour": return "Connect Four"
        case "dotsAndBoxes": return "Dots & Boxes"
        case "quarto": return "Quarto"
        default: return kind
        }
    }
}

extension ResumeKind: Codable {
    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        guard let kind = ResumeKind(slotKey: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown resume kind \(key)"))
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slotKey)
    }
}

/// One suspended non-engine game on disk. `payload` is the game's own
/// Codable snapshot (an engine state, a controller freeze-frame), opaque
/// to everything but the code that wrote it — the catalog never decodes
/// it, which is what lets the lobby list every kind without linking every
/// kind's types.
struct SavedGameEnvelope: Codable, Equatable {
    /// Bump when the ENVELOPE shape changes. Payload versioning is each
    /// game's own business (their states already decode leniently).
    var schema: Int
    var kind: ResumeKind
    /// e.g. "Yahtzee".
    var title: String
    /// e.g. "Round 3 · Mae leads 42-31".
    var subtitle: String
    var savedAt: Date
    /// Who was at the table, with durable deviceIDs so phones reclaim
    /// their seats on resume (mirrors `SavedGame.seats`).
    var seats: [SeatSpecCodable]
    var payload: Data
}

/// JSON-file persistence for every non-`HostEngine` game, one file per
/// `ResumeKind` under `Documents/SavedGames/Kinds/<slotKey>.json`. A
/// namespace, like `GameStateStore`, and deliberately a sibling of it
/// rather than a replacement: the engine games' files stay exactly where
/// and what they were.
enum SaveSlots {
    static let schema = 1

    private static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SavedGames", isDirectory: true)
            .appendingPathComponent("Kinds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(for kind: ResumeKind) -> URL {
        directory.appendingPathComponent("\(kind.slotKey).json")
    }

    /// Writes (or overwrites) the one slot for `kind`.
    static func write<T: Encodable>(kind: ResumeKind, title: String, subtitle: String,
                                    seats: [SeatSpecCodable], payload: T) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        write(kind: kind, title: title, subtitle: subtitle, seats: seats, payloadData: data)
    }

    /// Same, for a game that already produced its own bytes
    /// (`SideGameHost.snapshot()`).
    static func write(kind: ResumeKind, title: String, subtitle: String,
                      seats: [SeatSpecCodable], payloadData: Data) {
        let envelope = SavedGameEnvelope(schema: schema, kind: kind, title: title, subtitle: subtitle,
                                         savedAt: Date(), seats: seats, payload: payloadData)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL(for: kind), options: .atomic)
        ResumeCatalog.shared.noteChanged()
    }

    static func envelope(for kind: ResumeKind) -> SavedGameEnvelope? {
        guard let data = try? Data(contentsOf: fileURL(for: kind)),
              let envelope = try? JSONDecoder().decode(SavedGameEnvelope.self, from: data),
              envelope.schema <= schema else { return nil }
        return envelope
    }

    /// The envelope plus its payload decoded as `T`. A payload that no
    /// longer decodes (an old save from before a state type grew) is
    /// treated as absent AND deleted, so the lobby never offers a card
    /// that can't actually resume.
    static func read<T: Decodable>(kind: ResumeKind, as type: T.Type) -> (envelope: SavedGameEnvelope, payload: T)? {
        guard let envelope = envelope(for: kind) else { return nil }
        guard let payload = try? JSONDecoder().decode(T.self, from: envelope.payload) else {
            clear(kind: kind)
            return nil
        }
        return (envelope, payload)
    }

    static func clear(kind: ResumeKind) {
        let url = fileURL(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        ResumeCatalog.shared.noteChanged()
    }

    /// Every slot on disk, newest first.
    static func all() -> [SavedGameEnvelope] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedGameEnvelope? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? decoder.decode(SavedGameEnvelope.self, from: data),
                      envelope.schema <= schema else { return nil }
                return envelope
            }
            .sorted { $0.savedAt > $1.savedAt }
    }
}

/// Coalesces a burst of "something changed" calls into one save, two
/// seconds after the last one — the same beat `GameStateAutoSaveHolder`
/// gives the card engine, so every game in the app saves on the same
/// rhythm. Main-thread only (every caller is a UI-driven controller).
final class SaveDebouncer {
    private var pending: DispatchWorkItem?
    let delay: TimeInterval

    init(delay: TimeInterval = 2.0) {
        self.delay = delay
    }

    func schedule(_ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops whatever was queued (a game ended, a new one started).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
