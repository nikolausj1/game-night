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

public enum UnoColor: String, Codable, CaseIterable, Sendable {
    case red, yellow, green, blue
}

public enum UnoSymbol: Codable, Hashable, Sendable {
    case number(Int)
    case skip
    case reverse
    case drawTwo
    case wild
    case wildDrawFour
}

/// Fixed UNO color ↔ Suit mapping so wild color declaration can reuse the
/// existing `declareSuit` / `round.trumpSuit` machinery:
/// red↔hearts, yellow↔diamonds, green↔clubs, blue↔spades.
public extension Suit {
    var unoColor: UnoColor {
        switch self {
        case .hearts: return .red
        case .diamonds: return .yellow
        case .clubs: return .green
        case .spades: return .blue
        }
    }
}

public extension UnoColor {
    var suit: Suit {
        switch self {
        case .red: return .hearts
        case .yellow: return .diamonds
        case .green: return .clubs
        case .blue: return .spades
        }
    }
}

public enum CardKind: Codable, Hashable, Sendable {
    /// rank 2...14, where 14 = Ace (high) and 11/12/13 = Jack/Queen/King.
    case standard(suit: Suit, rank: Int)
    case wizard
    case jester
    /// UNO card. `color` is nil ONLY for wild / wildDrawFour.
    case uno(color: UnoColor?, symbol: UnoSymbol)
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

    /// Printed color for UNO cards; nil for wild/wildDrawFour and non-UNO cards.
    var unoColor: UnoColor? {
        if case .uno(let color, _) = kind { return color }
        return nil
    }

    /// Symbol for UNO cards; nil for non-UNO cards.
    var unoSymbol: UnoSymbol? {
        if case .uno(_, let symbol) = kind { return symbol }
        return nil
    }
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

    /// 108 UNO cards: per color one 0, two each of 1–9, two skips, two
    /// reverses, two draw-twos (25 × 4 = 100), plus 4 wilds and 4 wild-draw-fours.
    ///
    /// ID scheme (stable, unique, deck-assigned):
    /// - Numbers: "u_" + color initial + digit, e.g. "u_r0" (the single zero),
    ///   "u_r5a"/"u_r5b" (the two copies of red 5). Color initials: r/y/g/b.
    /// - Actions: "u_" + color initial + S/R/D + copy, e.g. "u_gSa" (green
    ///   skip a), "u_bRb" (blue reverse b), "u_yDa" (yellow draw-two a).
    /// - Wilds: "u_wild0"..."u_wild3". Wild draw fours: "u_wd40"..."u_wd43".
    public static func uno108() -> [Card] {
        var cards: [Card] = []
        for color in UnoColor.allCases {
            let c = String(color.rawValue.first!)
            cards.append(Card(id: "u_\(c)0", kind: .uno(color: color, symbol: .number(0))))
            for n in 1...9 {
                for copy in ["a", "b"] {
                    cards.append(Card(id: "u_\(c)\(n)\(copy)", kind: .uno(color: color, symbol: .number(n))))
                }
            }
            for copy in ["a", "b"] {
                cards.append(Card(id: "u_\(c)S\(copy)", kind: .uno(color: color, symbol: .skip)))
                cards.append(Card(id: "u_\(c)R\(copy)", kind: .uno(color: color, symbol: .reverse)))
                cards.append(Card(id: "u_\(c)D\(copy)", kind: .uno(color: color, symbol: .drawTwo)))
            }
        }
        for i in 0..<4 { cards.append(Card(id: "u_wild\(i)", kind: .uno(color: nil, symbol: .wild))) }
        for i in 0..<4 { cards.append(Card(id: "u_wd4\(i)", kind: .uno(color: nil, symbol: .wildDrawFour))) }
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
