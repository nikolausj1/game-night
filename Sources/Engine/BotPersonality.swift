import Foundation

/// A stable table personality for each computer player, derived purely from
/// the bot's NAME (no stored state, no randomness): the same name always
/// plays with the same tempo and the same appetite for risk, in every game
/// and every session. Games read the numeric knobs below; nothing here
/// changes legality or fairness, only pacing and borderline decisions.
///
/// Roster mapping (the six `BotRoster` regulars):
///
/// | Name   | Speed      | Aggression | Chattiness | In a sentence                         |
/// |--------|------------|------------|------------|---------------------------------------|
/// | Hank   | deliberate | cautious   | quiet      | Slow, careful, banks early            |
/// | Ruthie | snappy     | bold       | chatty     | Quick hands, presses her luck         |
/// | Marco  | steady     | bold       | chatty     | Even tempo, loves a gamble            |
/// | Mae    | deliberate | balanced   | normal     | Thinks it over, plays it straight     |
/// | Tucker | snappy     | balanced   | quiet      | Fast and plain                        |
/// | Julie  | steady     | cautious   | chatty     | Even tempo, avoids needless risk      |
///
/// Any other name (a custom seat) hashes to one of the same values
/// deterministically, so a "Pat" is always the same Pat.
///
/// What each trait modulates:
/// - **speed**: `delayScale` multiplies every humanlike pause (0.7 / 1.0 /
///   1.4), and `quartoNodeBudget` (search depth) shrinks for snappy bots and
///   grows for deliberate ones (1200 / 1600 / 2000 nodes, capped by the
///   engine's own default).
/// - **aggression**: `pressFactor` (0.92 / 1.0 / 1.08) scales Zilch's
///   bank-or-press turn-total thresholds, `riskBias` (-1 / 0 / +1) tilts
///   Yahtzee toward big-payoff categories (straights, Yahtzee, 4-of-a-kind)
///   and UNO toward dumping action cards early vs holding them. (Shut the
///   Box is solved exactly, so aggression does not change its choices; only
///   speed applies there.)
/// - **chattiness**: `chatterChance` (0.1 / 0.3 / 0.6) is the probability the
///   announcer layer may use to decide whether to comment on this bot's move.
public struct BotPersonality: Equatable, Sendable {
    public enum Speed: String, Sendable { case snappy, steady, deliberate }
    public enum Aggression: String, Sendable { case cautious, balanced, bold }
    public enum Chattiness: String, Sendable { case quiet, normal, chatty }

    public let name: String
    public let speed: Speed
    public let aggression: Aggression
    public let chattiness: Chattiness

    public init(name: String, speed: Speed, aggression: Aggression, chattiness: Chattiness) {
        self.name = name
        self.speed = speed
        self.aggression = aggression
        self.chattiness = chattiness
    }

    // MARK: Lookup

    private static let roster: [String: (Speed, Aggression, Chattiness)] = [
        "hank": (.deliberate, .cautious, .quiet),
        "ruthie": (.snappy, .bold, .chatty),
        "marco": (.steady, .bold, .chatty),
        "mae": (.deliberate, .balanced, .normal),
        "tucker": (.snappy, .balanced, .quiet),
        "julie": (.steady, .cautious, .chatty),
    ]

    /// Personality for `name` (case-insensitive). Unknown names derive one
    /// from an FNV-1a hash of the lowercased name: stable across launches
    /// (Swift's own `hashValue` is per-process, so it is not used).
    public static func forName(_ name: String) -> BotPersonality {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let t = roster[key] { return BotPersonality(name: name, speed: t.0, aggression: t.1, chattiness: t.2) }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let speeds: [Speed] = [.snappy, .steady, .deliberate]
        let aggs: [Aggression] = [.cautious, .balanced, .bold]
        let chats: [Chattiness] = [.quiet, .normal, .chatty]
        return BotPersonality(name: name,
                              speed: speeds[Int(h % 3)],
                              aggression: aggs[Int((h >> 8) % 3)],
                              chattiness: chats[Int((h >> 16) % 3)])
    }

    /// The neutral personality used when a caller has no name to look up.
    public static let neutral = BotPersonality(name: "", speed: .steady, aggression: .balanced, chattiness: .normal)

    // MARK: Knobs

    /// Multiplier on every humanlike pause.
    public var delayScale: Double {
        switch speed { case .snappy: return 0.7; case .steady: return 1.0; case .deliberate: return 1.4 }
    }

    /// `range` scaled by `delayScale` (e.g. a 1.2...2.0s beat).
    public func scaledDelay(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        (range.lowerBound * delayScale)...(range.upperBound * delayScale)
    }

    /// A random pause in `range`, scaled. Pacing only; not part of any
    /// seeded game logic.
    public func randomDelay(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: scaledDelay(range))
    }

    /// Multiplier on "bank when turn total reaches X" style thresholds.
    public var pressFactor: Double {
        switch aggression { case .cautious: return 0.92; case .balanced: return 1.0; case .bold: return 1.08 }
    }

    /// -1 (cautious) / 0 / +1 (bold).
    public var riskBias: Double {
        switch aggression { case .cautious: return -1; case .balanced: return 0; case .bold: return 1 }
    }

    /// Quarto search budget in nodes (never above `QuartoBot.defaultNodeBudget`).
    public var quartoNodeBudget: Int {
        let base: Int
        switch speed { case .snappy: base = 1200; case .steady: base = 1600; case .deliberate: base = 2000 }
        return min(base, QuartoBot.defaultNodeBudget)
    }

    /// Probability the announcer layer may use to comment on this bot.
    public var chatterChance: Double {
        switch chattiness { case .quiet: return 0.1; case .normal: return 0.3; case .chatty: return 0.6 }
    }
}
