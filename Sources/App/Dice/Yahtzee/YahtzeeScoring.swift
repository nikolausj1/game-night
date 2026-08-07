import Foundation

/// The 13 categories a Yahtzee scorecard fills — six upper-section face
/// values, then the seven classic lower-section combinations, in the order
/// a real scoresheet prints them (`upperOrder`/`lowerOrder` below drive
/// both `YahtzeeScoresheetView`'s row order and `YahtzeeScorecard.total`'s
/// section math).
enum YahtzeeCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case ones, twos, threes, fours, fives, sixes
    case threeOfKind, fourOfKind, fullHouse, smallStraight, largeStraight, yahtzee, chance

    var id: String { rawValue }

    var isUpper: Bool {
        switch self {
        case .ones, .twos, .threes, .fours, .fives, .sixes: return true
        default: return false
        }
    }

    /// The face value an upper-section category counts — `nil` for every
    /// lower-section category.
    var upperFaceValue: Int? {
        switch self {
        case .ones: return 1
        case .twos: return 2
        case .threes: return 3
        case .fours: return 4
        case .fives: return 5
        case .sixes: return 6
        default: return nil
        }
    }

    /// The printed row label — short enough to fit the scoresheet's narrow
    /// player columns without wrapping.
    var label: String {
        switch self {
        case .ones: return "Ones"
        case .twos: return "Twos"
        case .threes: return "Threes"
        case .fours: return "Fours"
        case .fives: return "Fives"
        case .sixes: return "Sixes"
        case .threeOfKind: return "3 of a Kind"
        case .fourOfKind: return "4 of a Kind"
        case .fullHouse: return "Full House"
        case .smallStraight: return "Sm. Straight"
        case .largeStraight: return "Lg. Straight"
        case .yahtzee: return "YAHTZEE"
        case .chance: return "Chance"
        }
    }

    static let upperOrder: [YahtzeeCategory] = [.ones, .twos, .threes, .fours, .fives, .sixes]
    static let lowerOrder: [YahtzeeCategory] = [
        .threeOfKind, .fourOfKind, .fullHouse, .smallStraight, .largeStraight, .yahtzee, .chance,
    ]
}

/// Pure scoring math — no game state, no rolling, just "given these five
/// dice, what does `category` pay." Kept free of `YahtzeeController` so it
/// can be unit-tested and reasoned about on its own.
enum YahtzeeScoring {
    static let upperBonusThreshold = 63
    static let upperBonusValue = 35
    static let yahtzeeBonusValue = 100

    /// Score `dice` (exactly five 1-6 values) against `category`.
    ///
    /// `isJoker`: the SIMPLIFIED joker rule this pass implements instead of
    /// standard Yahtzee's — real Yahtzee only lets a second-or-later
    /// five-of-a-kind fill a lower-section slot as a "wild" (and only after
    /// the matching upper box is filled, with a forced-zero fallback
    /// elsewhere otherwise). Here, once a player has ALREADY banked their
    /// first Yahtzee (the `.yahtzee` box holds 50) and rolls another one,
    /// `YahtzeeController.scoreCategory` may pass `isJoker: true` for
    /// WHATEVER open category they tap — this function then scores that
    /// category at its best-case value for a five-of-a-kind (a full house,
    /// straight, or N-of-a-kind all trivially qualify when all five dice
    /// match) rather than checking the category's normal pattern. Upper
    /// categories never need the flag: five matching dice already score
    /// correctly under their own per-die math.
    static func score(dice: [Int], category: YahtzeeCategory, isJoker: Bool = false) -> Int {
        let counts = Dictionary(grouping: dice, by: { $0 }).mapValues(\.count)
        switch category {
        case .ones, .twos, .threes, .fours, .fives, .sixes:
            let face = category.upperFaceValue ?? 0
            return dice.filter { $0 == face }.count * face
        case .threeOfKind:
            return (isJoker || counts.values.contains(where: { $0 >= 3 })) ? dice.reduce(0, +) : 0
        case .fourOfKind:
            return (isJoker || counts.values.contains(where: { $0 >= 4 })) ? dice.reduce(0, +) : 0
        case .fullHouse:
            if isJoker { return 25 }
            return counts.values.sorted() == [2, 3] ? 25 : 0
        case .smallStraight:
            if isJoker { return 30 }
            let present = Set(dice)
            let runs: [Set<Int>] = [[1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6]]
            return runs.contains(where: { $0.isSubset(of: present) }) ? 30 : 0
        case .largeStraight:
            if isJoker { return 40 }
            let present = Set(dice)
            return present == Set(1...5) || present == Set(2...6) ? 40 : 0
        case .yahtzee:
            return counts.values.contains(5) ? 50 : 0
        case .chance:
            return dice.reduce(0, +)
        }
    }

    /// Whether all five dice show the same face — the roll that scores 50
    /// in `.yahtzee` and, on any turn AFTER that box already holds 50,
    /// triggers the simplified joker rule above.
    static func isYahtzee(_ dice: [Int]) -> Bool {
        dice.count == 5 && Set(dice).count == 1
    }
}

/// One player's paper: a score per filled category (nil = still open) plus
/// how many post-first Yahtzee bonuses (`YahtzeeScoring.yahtzeeBonusValue`
/// each) they've banked. A category, once scored, never unscores —
/// there's no undo in real Yahtzee and none here either.
struct YahtzeeScorecard: Equatable {
    var entries: [YahtzeeCategory: Int] = [:]
    var yahtzeeBonusCount: Int = 0

    var isComplete: Bool { entries.count == YahtzeeCategory.allCases.count }

    var openCategories: [YahtzeeCategory] {
        YahtzeeCategory.allCases.filter { entries[$0] == nil }
    }

    var upperSubtotal: Int {
        YahtzeeCategory.upperOrder.reduce(0) { $0 + (entries[$1] ?? 0) }
    }

    var upperBonus: Int {
        upperSubtotal >= YahtzeeScoring.upperBonusThreshold ? YahtzeeScoring.upperBonusValue : 0
    }

    var lowerSubtotal: Int {
        YahtzeeCategory.lowerOrder.reduce(0) { $0 + (entries[$1] ?? 0) }
    }

    var total: Int {
        upperSubtotal + upperBonus + lowerSubtotal + yahtzeeBonusCount * YahtzeeScoring.yahtzeeBonusValue
    }

    /// Records one turn's result. Refuses to refill an already-scored
    /// category — the table only ever offers open ones, so this is a
    /// defensive guard, not a real path.
    mutating func record(category: YahtzeeCategory, value: Int, bonus: Bool) {
        guard entries[category] == nil else { return }
        entries[category] = value
        if bonus { yahtzeeBonusCount += 1 }
    }
}

/// Simple, legible bot strategy — not game-theoretic optimal, just "plays
/// like a sensible human": chase a straight when one's close, chase
/// of-a-kind pairs/triples otherwise, keep an eye on the upper-section
/// bonus, and reroll everything when nothing on the table is worth keeping.
enum YahtzeeBot {
    /// Decide which of the current dice (keyed by TABLE POOL INDEX, not
    /// die value — a hold has to name a specific physical die) to hold
    /// before the next reroll.
    static func chooseHolds(values: [Int: Int], scorecard: YahtzeeScorecard) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        let byValue = Dictionary(grouping: values.keys, by: { values[$0]! })

        // 1) Already five of a kind — hold all of it. (Whether that scores
        // the Yahtzee box itself or a joker elsewhere is the category-pick
        // decision, not a holding one.)
        if let five = byValue.first(where: { $0.value.count >= 5 }) {
            return Set(five.value)
        }

        // 2) A straight is close: hold the longest run of distinct
        // consecutive values, as long as at least one straight category is
        // still open and the run is worth chasing (3+ distinct values).
        let straightsOpen = scorecard.entries[.largeStraight] == nil || scorecard.entries[.smallStraight] == nil
        if straightsOpen, let run = longestConsecutiveRun(Set(byValue.keys)), run.count >= 3 {
            let chosen = run.compactMap { byValue[$0]?.first }
            if chosen.count == run.count, chosen.count >= 3 { return Set(chosen) }
        }

        // 3) Of-a-kind chasing: hold the most frequent value's dice. If a
        // second pair exists alongside it and Full House is still open,
        // hold both groups — a free look at 25 without giving up the
        // of-a-kind chase.
        if let best = byValue.max(by: { $0.value.count < $1.value.count }), best.value.count >= 2 {
            if scorecard.entries[.fullHouse] == nil,
               let secondPair = byValue.first(where: { $0.key != best.key && $0.value.count >= 2 }) {
                return Set(best.value + secondPair.value)
            }
            return Set(best.value)
        }

        // 4) Nothing promising on the table: hold the high dice (5s/6s)
        // toward Chance/upper-section totals rather than rerolling blind.
        return Set(values.filter { $0.value >= 5 }.keys)
    }

    /// End-of-turn category pick: the highest-scoring OPEN category wins,
    /// with a small nudge toward upper-section entries while the 63-point
    /// bonus is still in reach (a bot that only ever chases Chance never
    /// banks it). If nothing scores anything, sacrifice the open category
    /// least likely to matter later — burn Chance/upper filler first, keep
    /// Yahtzee/the straights alive as long as possible.
    static func chooseCategory(dice: [Int], scorecard: YahtzeeScorecard) -> YahtzeeCategory {
        let open = scorecard.openCategories
        guard !open.isEmpty else { return .chance }
        let isJoker = YahtzeeScoring.isYahtzee(dice) && (scorecard.entries[.yahtzee] ?? 0) > 0

        var best: (category: YahtzeeCategory, weight: Double)?
        for category in open {
            let joker = isJoker && category != .yahtzee
            let raw = YahtzeeScoring.score(dice: dice, category: category, isJoker: joker)
            var weight = Double(raw)
            if category.isUpper, scorecard.upperSubtotal < YahtzeeScoring.upperBonusThreshold {
                weight *= 1.15
            }
            if best == nil || weight > best!.weight {
                best = (category, weight)
            }
        }
        if let best, best.weight > 0 { return best.category }

        let sacrificeOrder: [YahtzeeCategory] = [
            .chance, .ones, .twos, .threeOfKind, .fourOfKind, .threes, .fours,
            .fullHouse, .fives, .sixes, .smallStraight, .largeStraight, .yahtzee,
        ]
        return sacrificeOrder.first(where: open.contains) ?? open[0]
    }

    private static func longestConsecutiveRun(_ values: Set<Int>) -> [Int]? {
        let sorted = values.sorted()
        var best: [Int] = []
        var current: [Int] = []
        for value in sorted {
            if let last = current.last, value == last + 1 {
                current.append(value)
            } else {
                current = [value]
            }
            if current.count > best.count { best = current }
        }
        return best.isEmpty ? nil : best
    }
}
