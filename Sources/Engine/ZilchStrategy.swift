import Foundation

/// Risk-model play for Zilch (Farkle), pure and headless-testable. The App's
/// `ZilchController` hands it the scoring groups of a roll and asks two
/// questions: WHICH groups to set aside, and then whether to press or bank.
///
/// **The model.** `V[n][t]` is the exact expected number of points this turn
/// finally banks, when `n` dice are about to be rolled with `t` points already
/// at risk, assuming optimal choices afterwards (which groups to set aside,
/// bank vs. press, hot dice resets to 6). It is computed once (lazily) by
/// enumerating all 923 dice multisets for 1...6 dice against the party rules
/// and sweeping `t` from high to low in steps of 50 (turn totals only grow,
/// so each level depends only on higher ones). Above `tableCap` points the
/// model just banks.
///
/// **Decisions.**
/// - `shouldPress`: press when `V[n][t] * pressFactor > t`, i.e. when the
///   expected gain from rolling beats the points at risk. `pressFactor` is
///   the bot's personality (cautious 0.92, balanced 1.0, bold 1.08).
/// - `chooseGroups`: of the non-empty subsets of the roll's groups, take the
///   one whose follow-up (best of bank / press with the dice that remain)
///   is worth most. This is what makes it set aside a lone 1 and keep five
///   dice live rather than greedily grabbing every 5 too.
/// - **Score gap.** In the final chase a trailing bot whose banking would
///   not pass the leader always presses (banking loses anyway); one whose
///   banking WOULD pass the best rival banks as soon as it is the last chaser.
///
/// The scoring constants mirror `ZilchPartyRules` in the App layer.
public enum ZilchStrategy {
    public static let singleOne = 100
    public static let singleFive = 50
    public static let straightBonus = 1500
    public static let threePairsBonus = 1000
    public static let targetScore = 5000
    public static let tableCap = 3000

    /// One scoring group of a roll: how many dice it consumes and its worth.
    public struct Group: Equatable, Sendable {
        public let dice: Int
        public let points: Int
        public init(dice: Int, points: Int) { self.dice = dice; self.points = points }
    }

    /// What the bot knows about the match when deciding.
    public struct Context: Sendable {
        public var bankedScore: Int
        /// Highest banked total among the OTHER seats.
        public var bestOpponentScore: Int
        public var finalChaseActive: Bool
        /// Other chasers still to take their last turn after this one.
        public var chasersAfterMe: Int
        public var personality: BotPersonality
        public init(bankedScore: Int = 0, bestOpponentScore: Int = 0, finalChaseActive: Bool = false,
                    chasersAfterMe: Int = 0, personality: BotPersonality = .neutral) {
            self.bankedScore = bankedScore
            self.bestOpponentScore = bestOpponentScore
            self.finalChaseActive = finalChaseActive
            self.chasersAfterMe = chasersAfterMe
            self.personality = personality
        }
    }

    // MARK: Scoring (mirror of ZilchScorer.groups(in:))

    public static func groups(in values: [Int]) -> [Group] {
        if values.count == 6 {
            if Set(values) == Set(1...6) { return [Group(dice: 6, points: straightBonus)] }
            let byFace = Dictionary(grouping: values, by: { $0 })
            if byFace.count == 3, byFace.values.allSatisfy({ $0.count == 2 }) {
                return [Group(dice: 6, points: threePairsBonus)]
            }
        }
        var result: [Group] = []
        for face in 1...6 {
            let count = values.filter { $0 == face }.count
            if count >= 3 {
                let base = face == 1 ? 1000 : face * 100
                let mult = [3: 1, 4: 2, 5: 4, 6: 8][count] ?? 0
                result.append(Group(dice: count, points: base * mult))
            } else if face == 1 {
                for _ in 0..<count { result.append(Group(dice: 1, points: singleOne)) }
            } else if face == 5 {
                for _ in 0..<count { result.append(Group(dice: 1, points: singleFive)) }
            }
        }
        return result
    }

    // MARK: The expectation table

    private final class Table {
        /// v[n][level], level = turnScore / 50, for n in 1...6.
        var v: [[Double]]
        let levels: Int

        init() {
            levels = ZilchStrategy.tableCap / 50 + 1
            v = Array(repeating: Array(repeating: 0, count: levels + 1), count: 7)

            // Pareto option lists per dice multiset: (diceUsed, points).
            struct Outcome { let prob: Double; let options: [(used: Int, pts: Int)] }
            var outcomes: [[Outcome]] = Array(repeating: [], count: 7)
            func fact(_ x: Int) -> Double { x <= 1 ? 1 : Double(x) * fact(x - 1) }
            for n in 1...6 {
                var counts = [Int](repeating: 0, count: 7)
                func rec(_ face: Int, _ left: Int) {
                    if face == 6 {
                        counts[6] = left
                        var denom = 1.0
                        for f in 1...6 { denom *= fact(counts[f]) }
                        let prob = fact(n) / denom / pow(6.0, Double(n))
                        var dice: [Int] = []
                        for f in 1...6 { dice += Array(repeating: f, count: counts[f]) }
                        let groups = ZilchStrategy.groups(in: dice)
                        var bestForUsed: [Int: Int] = [:]
                        if !groups.isEmpty {
                            for mask in 1..<(1 << groups.count) {
                                var used = 0, pts = 0
                                for (i, g) in groups.enumerated() where mask & (1 << i) != 0 {
                                    used += g.dice; pts += g.points
                                }
                                if pts > (bestForUsed[used] ?? -1) { bestForUsed[used] = pts }
                            }
                        }
                        outcomes[n].append(Outcome(prob: prob, options: bestForUsed.map { ($0.key, $0.value) }))
                        return
                    }
                    for k in 0...left { counts[face] = k; rec(face + 1, left - k) }
                    counts[face] = 0
                }
                rec(1, n)
            }

            // Sweep turn total from high to low.
            for level in stride(from: levels - 1, through: 0, by: -1) {
                let t = level * 50
                for n in 1...6 {
                    var ev = 0.0
                    for outcome in outcomes[n] {
                        guard !outcome.options.isEmpty else { continue } // bust: lose t, worth 0
                        var best = 0.0
                        for opt in outcome.options {
                            let t2 = t + opt.pts
                            let left = n - opt.used
                            let m = left == 0 ? 6 : left
                            let level2 = t2 / 50
                            let press = level2 < levels ? v[m][level2] : Double(t2)
                            best = max(best, max(Double(t2), press))
                        }
                        ev += outcome.prob * best
                    }
                    v[n][level] = ev
                }
            }
        }

        func value(dice n: Int, turnScore t: Int) -> Double {
            let level = t / 50
            guard level < levels, n >= 1, n <= 6 else { return Double(t) }
            return v[n][level]
        }
    }

    private static let table = Table()

    /// Expected final points of this turn if `dice` dice are rolled now with
    /// `turnScore` at risk (optimal continuation). Exposed for tests/tuning.
    public static func expectedTurnValue(dice: Int, turnScore: Int) -> Double {
        table.value(dice: dice, turnScore: turnScore)
    }

    // MARK: Decisions

    /// Whether banking right now loses outright (final chase, not enough).
    private static func mustPress(turnScore: Int, ctx: Context) -> Bool {
        guard ctx.finalChaseActive else { return false }
        return ctx.bankedScore + turnScore <= ctx.bestOpponentScore
    }

    /// True = roll again with `diceLeft` live dice, false = bank.
    public static func shouldPress(diceLeft: Int, turnScore: Int, ctx: Context) -> Bool {
        guard diceLeft >= 1 else { return false }
        if ctx.finalChaseActive {
            if mustPress(turnScore: turnScore, ctx: ctx) { return true }
            // Ahead of everyone: lock it in when nobody can still answer, and
            // otherwise bank anyway unless the table says rolling is cheap.
            if ctx.chasersAfterMe == 0 { return false }
        }
        if ctx.bankedScore + turnScore >= targetScore && !ctx.finalChaseActive { return false }
        let ev = table.value(dice: diceLeft, turnScore: turnScore) * ctx.personality.pressFactor
        return ev > Double(turnScore)
    }

    /// Indices (into `groups`) to set aside from a roll of `diceRolled` dice,
    /// given the points already at risk this turn. Never empty if `groups`
    /// isn't (a roll with scoring dice must set at least one aside).
    public static func chooseGroups(_ groups: [Group], diceRolled: Int, turnScore: Int, ctx: Context) -> [Int] {
        guard !groups.isEmpty else { return [] }
        var bestMask = (1 << groups.count) - 1
        var bestValue = -Double.infinity
        for mask in 1..<(1 << groups.count) {
            var used = 0, pts = 0
            for (i, g) in groups.enumerated() where mask & (1 << i) != 0 { used += g.dice; pts += g.points }
            let t2 = turnScore + pts
            let left = diceRolled - used
            let m = left <= 0 ? 6 : left
            var value: Double
            if mustPress(turnScore: t2, ctx: ctx) {
                value = table.value(dice: m, turnScore: t2) // banking is worthless; judge by the roll-on value
            } else if ctx.finalChaseActive && ctx.chasersAfterMe == 0 {
                value = 1_000_000 + Double(t2) // banking wins the game
            } else {
                value = max(Double(t2), table.value(dice: m, turnScore: t2) * ctx.personality.pressFactor)
            }
            // Tiny tie-break toward keeping more dice live, then more points.
            value += Double(m) * 0.001 + Double(pts) * 1e-6
            if value > bestValue { bestValue = value; bestMask = mask }
        }
        return (0..<groups.count).filter { bestMask & (1 << $0) != 0 }
    }
}
