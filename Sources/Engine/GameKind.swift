import Foundation

/// The games Game Night can host. `fiveHundred` will join later; adding a
/// case only requires a config row below plus a `GameRules` implementation.
public enum GameKind: String, Codable, CaseIterable, Sendable {
    case wizard, ohHell, crazyEights, uno, freePlay
    /// Classic trick-takers (open-ended: played to a score, not a round
    /// schedule). Added after the original five; raw values are new so
    /// saved games are unaffected.
    case hearts, spades

    public var displayName: String {
        switch self {
        case .wizard: return "Wizard"
        case .ohHell: return "Oh Hell"
        case .crazyEights: return "Crazy Eights"
        case .uno: return "UNO"
        case .freePlay: return "Free Play"
        case .hearts: return "Hearts"
        case .spades: return "Spades"
        }
    }

    public var minPlayers: Int {
        switch self {
        case .wizard: return 3
        case .ohHell: return 3
        case .crazyEights: return 2
        case .uno: return 2
        // 1 on purpose: solo free play is the "deal myself a hand and
        // fiddle" test mode (and solitaire night is legitimate).
        case .freePlay: return 1
        case .hearts: return 3
        // Spades is a 4-player partnership game; 2 and 3 players play the
        // individual "cutthroat" variant (see `RulesConfig.spadesCutthroat`).
        case .spades: return 2
        }
    }

    public var maxPlayers: Int {
        switch self {
        case .wizard: return 6
        case .ohHell: return 7
        case .crazyEights: return 6
        case .uno: return 8
        case .freePlay: return 8
        case .hearts: return 5
        case .spades: return 4
        }
    }

    public var usesWizardDeck: Bool { self == .wizard }

    public var isTrickTaking: Bool {
        switch self {
        case .wizard, .ohHell, .hearts, .spades: return true
        case .crazyEights, .uno, .freePlay: return false
        }
    }

    /// Hearts is scored like golf: the LOWEST total wins. Everything else
    /// (including spades) is highest-wins.
    public var lowestScoreWins: Bool { self == .hearts }

    /// Played to a target score over an open-ended number of rounds rather
    /// than a fixed schedule (`roundsSchedule` is empty for these).
    public var isScoreLimitGame: Bool { self == .hearts || self == .spades }

    /// Cards dealt per round, in round order.
    /// Wizard: 1...(60 ÷ players). Oh Hell: 1 up to (52 ÷ players), then back
    /// down to 1. Crazy Eights / UNO / Free Play have no round schedule.
    public func roundsSchedule(playerCount: Int) -> [Int] {
        guard playerCount >= minPlayers, playerCount <= maxPlayers else { return [] }
        switch self {
        case .wizard:
            let rounds = 60 / playerCount
            guard rounds >= 1 else { return [] }
            return Array(1...rounds)
        case .ohHell:
            let maxCards = 52 / playerCount
            guard maxCards >= 1 else { return [] }
            return Array(1...maxCards) + Array((1..<maxCards).reversed())
        case .crazyEights, .uno, .freePlay, .hearts, .spades:
            return []
        }
    }
}
