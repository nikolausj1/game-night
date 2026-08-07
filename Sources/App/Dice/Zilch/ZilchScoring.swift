import Foundation

/// Every tunable number in Zilch's PARTY ruleset (the owner's pick: "no
/// opening minimum, looser banking, faster games — tuned for kids") lives
/// HERE, in one struct, so a future house-rule toggle (a different straight
/// bonus, a lower/higher target) is a one-line change instead of a hunt
/// through `ZilchScorer`/`ZilchController`.
enum ZilchPartyRules {
    /// A single 1 not gathered into a 3+ group.
    static let singleOne = 100
    /// A single 5 not gathered into a 3+ group.
    static let singleFive = 50
    /// Straight 1-6 (all six dice, one of each face) — flat bonus,
    /// independent of the per-face grouping below.
    static let straightBonus = 1500
    /// Three pairs (all six dice, three distinct faces each appearing
    /// twice) — flat bonus, independent of the per-face grouping below.
    static let threePairsBonus = 1000
    /// No opening minimum: ANY positive turn total may bank, any time
    /// after a scoring roll. Named (rather than a bare `0` at the call
    /// site) so a future "you need N to open" house rule is a one-line
    /// change right here.
    static let openingMinimum = 0
    /// First seat to reach this total (on a BANK) triggers the final
    /// chase: everyone else gets exactly one more turn, then the highest
    /// total wins.
    static let targetScore = 5000

    /// Three-of-a-kind's base value for `face` (1...6): face×100, except
    /// three 1s, which are the classic Farkle exception at 1000 rather
    /// than 100.
    static func tripleValue(face: Int) -> Int {
        face == 1 ? 1000 : face * 100
    }

    /// The multiplier applied to `tripleValue` for a group of `count`
    /// matching dice: 3-of-a-kind ×1 (the base value itself), 4-of-a-kind
    /// double, 5-of-a-kind quadruple, 6-of-a-kind 8×. `0` for any count
    /// under 3 — those dice never form an n-of-a-kind group at all (see
    /// `ZilchScorer`, which only ever calls this for count >= 3).
    static func multiplier(count: Int) -> Int {
        switch count {
        case 3: return 1
        case 4: return 2
        case 5: return 4
        case 6: return 8
        default: return 0
        }
    }
}

/// One scoring group found in a roll: which POSITIONS (indices into the
/// value array `ZilchScorer.groups(in:)` was called with — never a pool
/// index; the caller translates) belong together, what the whole group is
/// worth, and a short label for HUD/felt-chip text. Groups from one
/// `groups(in:)` call are always disjoint — every rolled die belongs to at
/// most one group, and a die that scores nothing (a lone 2/3/4/6 short of
/// three of a kind) belongs to none.
struct ZilchScoringGroup: Identifiable, Equatable {
    let id = UUID()
    let positions: [Int]
    let points: Int
    let label: String

    static func == (lhs: ZilchScoringGroup, rhs: ZilchScoringGroup) -> Bool { lhs.id == rhs.id }
}

/// Pure scoring logic — no dice, no UI, no controller state. Given the face
/// values of a roll (1...6 each, in whatever order the physical dice
/// settled), decides every scoring group present.
enum ZilchScorer {
    /// Every scoring group findable in `values`. Whole-roll patterns
    /// (straight, three pairs) only ever apply to a FRESH six-die roll —
    /// they're checked first and, when they match, are the ONLY group
    /// returned (they claim every position at once, so there's nothing
    /// left to group individually). Otherwise dice are grouped by face:
    /// any face appearing 3+ times becomes ONE group worth the whole
    /// n-of-a-kind total (never split into "triple + leftover singles" —
    /// four 5s is worth double a triple-5, not a triple-5 plus a bonus
    /// single 5); a 1 or 5 short of three of a kind scores on its own,
    /// one group per die; every other leftover die (a lone/paired
    /// 2, 3, 4, or 6) scores nothing and is excluded from every group —
    /// those are exactly the "junk" dice a bust roll is stuck holding.
    static func groups(in values: [Int]) -> [ZilchScoringGroup] {
        if values.count == 6 {
            if Set(values) == Set(1...6) {
                return [ZilchScoringGroup(positions: Array(values.indices),
                                          points: ZilchPartyRules.straightBonus,
                                          label: "Straight")]
            }
            let byFace = Dictionary(grouping: values.indices, by: { values[$0] })
            if byFace.count == 3, byFace.values.allSatisfy({ $0.count == 2 }) {
                return [ZilchScoringGroup(positions: Array(values.indices),
                                          points: ZilchPartyRules.threePairsBonus,
                                          label: "Three pairs")]
            }
        }
        return groupsByFace(values)
    }

    /// Whether `values` contains ANY scoring die at all — an empty result
    /// here is a ZILCH (bust): nothing in the roll scores anything.
    static func hasAnyScore(_ values: [Int]) -> Bool { !groups(in: values).isEmpty }

    private static func groupsByFace(_ values: [Int]) -> [ZilchScoringGroup] {
        var result: [ZilchScoringGroup] = []
        let byFace = Dictionary(grouping: values.indices, by: { values[$0] })
        for (face, positions) in byFace.sorted(by: { $0.key < $1.key }) {
            if positions.count >= 3 {
                let count = positions.count
                let points = ZilchPartyRules.tripleValue(face: face)
                    * ZilchPartyRules.multiplier(count: count)
                result.append(ZilchScoringGroup(
                    positions: positions, points: points,
                    label: "\(spelled(count)) \(face)s"))
            } else if face == 1 {
                for position in positions {
                    result.append(ZilchScoringGroup(
                        positions: [position], points: ZilchPartyRules.singleOne,
                        label: "Single 1"))
                }
            } else if face == 5 {
                for position in positions {
                    result.append(ZilchScoringGroup(
                        positions: [position], points: ZilchPartyRules.singleFive,
                        label: "Single 5"))
                }
            }
            // Faces 2/3/4/6 under a 3-count: no group — junk dice.
        }
        return result
    }

    private static func spelled(_ count: Int) -> String {
        switch count {
        case 4: return "Four"
        case 5: return "Five"
        case 6: return "Six"
        default: return "Three"
        }
    }
}
