import Foundation

/// Expected-value Yahtzee play, pure and headless-testable (the App layer's
/// `YahtzeeController` adapts its scorecard to `YahtzeeStrategy.Sheet`).
///
/// Category indices follow the app's `YahtzeeCategory.allCases` order:
/// 0...5 = ones...sixes, 6 = three of a kind, 7 = four of a kind,
/// 8 = full house, 9 = small straight, 10 = large straight, 11 = Yahtzee,
/// 12 = chance.
///
/// **Hold decisions** are an exact expectimax over the 252 distinct dice
/// multisets: with `r` rerolls left, every one of the 32 position masks is
/// scored by the exact expected value of the best final category (and of
/// the best follow-up hold when `r == 2`). That makes the whole hold choice
/// a few thousand multiply-adds, with no precomputed table to ship.
///
/// **Final value of a set of dice** is `score - par` for the best open
/// category, where `par` is the category's long-run average under strong
/// play (so a 2-point Chance is a cheap sacrifice but a 2-point Yahtzee box
/// is expensive), plus a smooth estimate of how a placement moves the odds
/// of the 35-point upper bonus. This is the classic "regret vs. par" policy,
/// which averages around 230-245 points solo; full-state DP optimum is ~254.
public enum YahtzeeStrategy {
    public static let categoryCount = 13
    private static let yahtzeeIndex = 11

    /// Long-run average score of each category under strong play.
    /// Opportunity cost of using a category now, as a fraction of its long-run
    /// average. 1.0 over-values leaving made combinations open (it would
    /// re-roll a made small straight); 0.8 measured best over 800 seeded games.
    static let parScale = 0.8
    static let par: [Double] = [2.11, 5.28, 8.57, 12.16, 15.69, 19.19,
                                21.66, 13.10, 22.59, 29.46, 32.71, 16.87, 22.01]

    /// A scorecard: `scores[i] == nil` means category `i` is still open.
    public struct Sheet: Equatable, Sendable {
        public var scores: [Int?]
        public var yahtzeeBonusCount: Int
        public init(scores: [Int?] = Array(repeating: nil, count: 13), yahtzeeBonusCount: Int = 0) {
            self.scores = scores
            self.yahtzeeBonusCount = yahtzeeBonusCount
        }
        public var open: [Int] { (0..<13).filter { scores[$0] == nil } }
        public var upperSubtotal: Int { (0..<6).reduce(0) { $0 + (scores[$1] ?? 0) } }
        public var isComplete: Bool { open.isEmpty }
        public var total: Int {
            let upper = upperSubtotal
            let lower = (6..<13).reduce(0) { $0 + (scores[$1] ?? 0) }
            return upper + (upper >= 63 ? 35 : 0) + lower + yahtzeeBonusCount * 100
        }
        /// A second-or-later five of a kind scores as a joker.
        public func isJoker(_ dice: [Int]) -> Bool {
            isFiveOfAKind(dice) && (scores[11] ?? 0) > 0
        }
        public mutating func record(dice: [Int], category: Int) {
            guard scores[category] == nil else { return }
            let joker = isJoker(dice) && category != 11
            scores[category] = YahtzeeStrategy.score(dice: dice, category: category, isJoker: joker)
            if joker { yahtzeeBonusCount += 1 }
        }
    }

    public static func isFiveOfAKind(_ dice: [Int]) -> Bool {
        dice.count == 5 && Set(dice).count == 1
    }

    /// Mirrors `YahtzeeScoring.score` exactly (simplified joker included).
    public static func score(dice: [Int], category: Int, isJoker: Bool = false) -> Int {
        var counts = [Int](repeating: 0, count: 7)
        var sum = 0
        for d in dice { counts[d] += 1; sum += d }
        let maxCount = counts.max() ?? 0
        switch category {
        case 0...5:
            return counts[category + 1] * (category + 1)
        case 6: return (isJoker || maxCount >= 3) ? sum : 0
        case 7: return (isJoker || maxCount >= 4) ? sum : 0
        case 8:
            if isJoker { return 25 }
            let nonZero = counts.filter { $0 > 0 }.sorted()
            return nonZero == [2, 3] ? 25 : 0
        case 9:
            if isJoker { return 30 }
            let has = { (f: Int) in counts[f] > 0 }
            return ((1...4).allSatisfy(has) || (2...5).allSatisfy(has) || (3...6).allSatisfy(has)) ? 30 : 0
        case 10:
            if isJoker { return 40 }
            let has = { (f: Int) in counts[f] > 0 }
            return ((1...5).allSatisfy(has) || (2...6).allSatisfy(has)) ? 40 : 0
        case 11: return maxCount == 5 ? 50 : 0
        default: return sum
        }
    }

    // MARK: Category choice

    /// Best open category for `dice` right now.
    public static func chooseCategory(dice: [Int], sheet: Sheet,
                                      personality: BotPersonality = .neutral) -> Int {
        let ctx = Context(sheet: sheet, personality: personality)
        var best = -1
        var bestValue = -Double.infinity
        for cat in sheet.open {
            let v = ctx.value(of: cat, dice: dice)
            if v > bestValue + 1e-9 { bestValue = v; best = cat }
        }
        return best >= 0 ? best : 12
    }

    // MARK: Hold choice

    /// Which dice (by position in `dice`) to keep before the next reroll.
    /// `rollsLeft` is the number of rerolls still available (1 or 2). Keeping
    /// all five is a valid answer ("stop and score").
    public static func chooseHolds(dice: [Int], rollsLeft: Int, sheet: Sheet,
                                   personality: BotPersonality = .neutral) -> [Bool] {
        guard dice.count == 5, rollsLeft >= 1 else { return Array(repeating: true, count: dice.count) }
        let ctx = Context(sheet: sheet, personality: personality)
        let tables = ctx.tables(rollsLeft: min(rollsLeft, 2))
        var bestMask = 31
        var bestValue = -Double.infinity
        // Prefer keeping MORE dice on exact ties (stop earlier), then lower masks.
        for mask in stride(from: 31, through: 0, by: -1) {
            let kept = (0..<5).filter { mask & (1 << $0) != 0 }.map { dice[$0] }
            let v = tables.expected(hold: kept)
            if v > bestValue + 1e-9 { bestValue = v; bestMask = mask }
        }
        return (0..<5).map { bestMask & (1 << $0) != 0 }
    }

    // MARK: Internals

    /// Multiset <-> index plumbing: a multiset of dice is a count vector
    /// c[1...6] encoded base 6 (each count 0...5 fits a digit < 6).
    private static func key(_ counts: [Int]) -> Int {
        var k = 0
        for f in 1...6 { k = k * 6 + counts[f] }
        return k
    }

    private static let allFiveDiceMultisets: [[Int]] = {
        var result: [[Int]] = []
        var c = [Int](repeating: 0, count: 7)
        func rec(_ face: Int, _ left: Int) {
            if face == 6 { c[6] = left; result.append(c); return }
            for n in 0...left { c[face] = n; rec(face + 1, left - n) }
            c[face] = 0
        }
        rec(1, 5)
        return result
    }()

    /// Every multiset of exactly `n` dice with its probability.
    private static let rerollOutcomes: [[(counts: [Int], prob: Double)]] = {
        (0...5).map { n in
            var out: [(counts: [Int], prob: Double)] = []
            var c = [Int](repeating: 0, count: 7)
            func fact(_ x: Int) -> Double { x <= 1 ? 1 : Double(x) * fact(x - 1) }
            func rec(_ face: Int, _ left: Int) {
                if face == 6 {
                    c[6] = left
                    var denom = 1.0
                    for f in 1...6 { denom *= fact(c[f]) }
                    out.append((c, fact(n) / denom / pow(6.0, Double(n))))
                    return
                }
                for k in 0...left { c[face] = k; rec(face + 1, left - k) }
                c[face] = 0
            }
            rec(1, n)
            return out
        }
    }()

    private struct Context {
        let sheet: Sheet
        let boldness: Double
        let open: [Int]
        let upperOpenPar: Double // sum of 3*face over OPEN upper categories
        let upperSubtotal: Int

        init(sheet: Sheet, personality: BotPersonality) {
            self.sheet = sheet
            boldness = personality.riskBias
            open = sheet.open
            upperSubtotal = sheet.upperSubtotal
            var p = 0.0
            for f in 0..<6 where sheet.scores[f] == nil { p += Double(3 * (f + 1)) }
            upperOpenPar = p
        }

        private func bonusProbability(projected: Double) -> Double {
            1.0 / (1.0 + exp(-(projected - 63.0) / 4.0))
        }

        /// Regret-vs-par value of putting `dice` in `cat`.
        func value(of cat: Int, dice: [Int]) -> Double {
            let joker = sheet.isJoker(dice) && cat != YahtzeeStrategy.yahtzeeIndex
            let raw = Double(YahtzeeStrategy.score(dice: dice, category: cat, isJoker: joker))
            return value(cat: cat, raw: raw, joker: joker)
        }

        func value(cat: Int, raw: Double, joker: Bool) -> Double {
            var v = raw
            // Personality: bold bots overvalue the big payoffs a little.
            if cat == 7 || cat == 9 || cat == 10 || cat == 11 { v *= 1.0 + 0.06 * boldness }
            v -= YahtzeeStrategy.par[cat] * YahtzeeStrategy.parScale
            if cat < 6, upperSubtotal < 63 {
                let face = Double(cat + 1)
                let before = Double(upperSubtotal) + upperOpenPar
                let after = Double(upperSubtotal) + raw + upperOpenPar - 3 * face
                v += 35.0 * (bonusProbability(projected: after) - bonusProbability(projected: before))
            }
            if joker { v += 100 }
            return v
        }

        /// Best final value of a full 5-dice multiset (all rerolls used).
        func finalValue(counts: [Int]) -> Double {
            var dice: [Int] = []
            for f in 1...6 { dice += Array(repeating: f, count: counts[f]) }
            var best = -Double.infinity
            for cat in open { best = max(best, value(of: cat, dice: dice)) }
            return best
        }

        struct Tables {
            let e1: [Double]   // expected value of a hold with exactly 1 reroll left
            let e2: [Double]?  // ... with 2 rerolls left
            let rollsLeft: Int
            func expected(hold: [Int]) -> Double {
                var counts = [Int](repeating: 0, count: 7)
                for d in hold { counts[d] += 1 }
                let k = YahtzeeStrategy.key(counts)
                if rollsLeft == 2, let e2 { return e2[k] }
                return e1[k]
            }
        }

        func tables(rollsLeft: Int) -> Tables {
            var final = [Double](repeating: 0, count: 46_656)
            for m in YahtzeeStrategy.allFiveDiceMultisets {
                final[YahtzeeStrategy.key(m)] = finalValue(counts: m)
            }
            // e1[H]: hold H (any size 0...5), reroll the rest once, take the best category.
            var e1 = [Double](repeating: 0, count: 46_656)
            var holds: [[Int]] = []
            for n in 0...5 { // n = number of held dice
                var c = [Int](repeating: 0, count: 7)
                func rec(_ face: Int, _ left: Int) {
                    if face == 6 { c[6] = left; holds.append(c); return }
                    for k in 0...left { c[face] = k; rec(face + 1, left - k) }
                    c[face] = 0
                }
                rec(1, n)
            }
            for h in holds {
                let n = 5 - h[1...6].reduce(0, +)
                var ev = 0.0
                for outcome in YahtzeeStrategy.rerollOutcomes[n] {
                    var total = h
                    for f in 1...6 { total[f] += outcome.counts[f] }
                    ev += outcome.prob * final[YahtzeeStrategy.key(total)]
                }
                e1[YahtzeeStrategy.key(h)] = ev
            }
            guard rollsLeft == 2 else { return Tables(e1: e1, e2: nil, rollsLeft: 1) }

            // f2[D]: best you can do on dice D with ONE reroll still available
            // (stop and score, or keep the best sub-multiset).
            var f2 = [Double](repeating: 0, count: 46_656)
            for d in YahtzeeStrategy.allFiveDiceMultisets {
                var best = final[YahtzeeStrategy.key(d)]
                // Enumerate sub-multisets of d.
                var sub = [Int](repeating: 0, count: 7)
                func rec(_ face: Int) {
                    if face == 7 {
                        best = max(best, e1[YahtzeeStrategy.key(sub)])
                        return
                    }
                    for k in 0...d[face] { sub[face] = k; rec(face + 1) }
                    sub[face] = 0
                }
                rec(1)
                f2[YahtzeeStrategy.key(d)] = best
            }
            var e2 = [Double](repeating: 0, count: 46_656)
            for h in holds {
                let n = 5 - h[1...6].reduce(0, +)
                var ev = 0.0
                for outcome in YahtzeeStrategy.rerollOutcomes[n] {
                    var total = h
                    for f in 1...6 { total[f] += outcome.counts[f] }
                    ev += outcome.prob * f2[YahtzeeStrategy.key(total)]
                }
                e2[YahtzeeStrategy.key(h)] = ev
            }
            return Tables(e1: e1, e2: e2, rollsLeft: 2)
        }
    }
}
