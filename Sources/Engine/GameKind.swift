import Foundation

/// The games Game Night can host. `fiveHundred` will join later; adding a
/// case only requires a config row below plus a `GameRules` implementation.
public enum GameKind: String, Codable, CaseIterable, Sendable {
    case wizard, ohHell, crazyEights, freePlay

    public var displayName: String {
        switch self {
        case .wizard: return "Wizard"
        case .ohHell: return "Oh Hell"
        case .crazyEights: return "Crazy Eights"
        case .freePlay: return "Free Play"
        }
    }

    public var minPlayers: Int {
        switch self {
        case .wizard: return 3
        case .ohHell: return 3
        case .crazyEights: return 2
        case .freePlay: return 2
        }
    }

    public var maxPlayers: Int {
        switch self {
        case .wizard: return 6
        case .ohHell: return 7
        case .crazyEights: return 6
        case .freePlay: return 8
        }
    }

    public var usesWizardDeck: Bool { self == .wizard }

    public var isTrickTaking: Bool {
        switch self {
        case .wizard, .ohHell: return true
        case .crazyEights, .freePlay: return false
        }
    }

    /// Cards dealt per round, in round order.
    /// Wizard: 1...(60 ÷ players). Oh Hell: 1 up to (52 ÷ players), then back
    /// down to 1. Crazy Eights / Free Play have no round schedule.
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
        case .crazyEights, .freePlay:
            return []
        }
    }
}
