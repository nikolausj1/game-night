import Foundation

/// Card primitives for Game Night.
///
/// Card ID scheme (deck-assigned, stable across shuffles/encodes):
/// - Standard cards: suit initial + rank, e.g. "c2" = 2♣, "h12" = Q♥, "s14" = A♠.
///   Suit initials: c = clubs, d = diamonds, h = hearts, s = spades.
///   Ranks run 2...14 (11 = Jack, 12 = Queen, 13 = King, 14 = Ace high).
/// - Wizards: "W0"..."W3". Jesters: "J0"..."J3".
public enum Suit: String, Codable, CaseIterable, Sendable, Equatable {
    case clubs, diamonds, hearts, spades

    public var symbol: String {
        switch self {
        case .clubs: return "♣"
        case .diamonds: return "♦"
        case .hearts: return "♥"
        case .spades: return "♠"
        }
    }

    public var isRed: Bool { self == .diamonds || self == .hearts }
}

public enum CardKind: Codable, Hashable, Sendable {
    /// rank 2...14, where 14 = Ace (high) and 11/12/13 = Jack/Queen/King.
    case standard(suit: Suit, rank: Int)
    case wizard
    case jester
}

public struct Card: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: CardKind

    public init(id: String, kind: CardKind) {
        self.id = id
        self.kind = kind
    }
}

public extension Card {
    /// Suit for standard cards; nil for wizards/jesters.
    var suit: Suit? {
        if case .standard(let suit, _) = kind { return suit }
        return nil
    }

    /// Rank for standard cards; nil for wizards/jesters.
    var rank: Int? {
        if case .standard(_, let rank) = kind { return rank }
        return nil
    }

    var isWizard: Bool { kind == .wizard }
    var isJester: Bool { kind == .jester }
}

/// SplitMix64 — deterministic, seed-replayable shuffles for the host.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum DeckBuilder {
    /// 52 cards, ranks 2...14 in each of the four suits.
    public static func standard52() -> [Card] {
        var cards: [Card] = []
        for suit in Suit.allCases {
            for rank in 2...14 {
                cards.append(Card(id: "\(suitPrefix(suit))\(rank)", kind: .standard(suit: suit, rank: rank)))
            }
        }
        return cards
    }

    /// 60 cards: standard 52 + 4 wizards ("W0"..."W3") + 4 jesters ("J0"..."J3").
    public static func wizard60() -> [Card] {
        var cards = standard52()
        for i in 0..<4 { cards.append(Card(id: "W\(i)", kind: .wizard)) }
        for i in 0..<4 { cards.append(Card(id: "J\(i)", kind: .jester)) }
        return cards
    }

    /// Deterministic shuffle: the same deck + seed always yields the same order.
    public static func shuffled(_ deck: [Card], seed: UInt64) -> [Card] {
        var generator = SeededGenerator(seed: seed)
        return deck.shuffled(using: &generator)
    }

    private static func suitPrefix(_ suit: Suit) -> String {
        String(suit.rawValue.first!)
    }
}
