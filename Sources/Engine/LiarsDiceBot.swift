import Foundation

public enum LiarsDicePersonality: String, Codable, Sendable, Equatable, CaseIterable {
    case cautious, balanced, reckless

    /// Challenge when the standing bid's probability of being true is below this.
    public var challengeThreshold: Double {
        switch self {
        case .cautious: return 0.40
        case .balanced: return 0.30
        case .reckless: return 0.20
        }
    }

    /// Minimum probability a raise should have to be considered "safe".
    public var raiseTarget: Double {
        switch self {
        case .cautious: return 0.60
        case .balanced: return 0.50
        case .reckless: return 0.38
        }
    }

    /// Chance of bluffing: bidding a face the bot does not hold.
    public var bluffChance: Double {
        switch self {
        case .cautious: return 0.05
        case .balanced: return 0.15
        case .reckless: return 0.30
        }
    }

    /// Call spot on when P(exactly right) exceeds this.
    public var spotOnThreshold: Double {
        switch self {
        case .cautious: return 0.45
        case .balanced: return 0.38
        case .reckless: return 0.30
        }
    }
}

/// Probability-based bot. Deterministic given the caller's `rng`.
public enum LiarsDiceBot {

    /// P(X == k) for X ~ Binomial(n, p).
    public static func binomialPMF(n: Int, k: Int, p: Double) -> Double {
        guard k >= 0, k <= n else { return 0 }
        var c = 1.0
        if k > 0 { for i in 1...k { c = c * Double(n - k + i) / Double(i) } }
        return c * pow(p, Double(k)) * pow(1 - p, Double(n - k))
    }

    /// P(X >= k).
    public static func binomialAtLeast(n: Int, k: Int, p: Double) -> Double {
        if k <= 0 { return 1 }
        if k > n { return 0 }
        var sum = 0.0
        for i in k...n { sum += binomialPMF(n: n, k: i, p: p) }
        return min(1, sum)
    }

    /// Per-die match chance for `face` among unseen dice.
    private static func matchChance(face: Int, wildOnes: Bool) -> Double {
        (wildOnes && face != 1) ? 1.0 / 3.0 : 1.0 / 6.0
    }

    /// Probability that a bid is true, from `myDice`'s point of view, over
    /// `totalDice - myDice.count` unseen dice.
    public static func probabilityTrue(quantity: Int, face: Int, myDice: [Int],
                                       totalDice: Int, wildOnes: Bool) -> Double {
        let mine = LiarsDiceRules.count(face: face, in: myDice, wildOnes: wildOnes)
        let unseen = max(0, totalDice - myDice.count)
        return binomialAtLeast(n: unseen, k: quantity - mine, p: matchChance(face: face, wildOnes: wildOnes))
    }

    /// Probability that the count is EXACTLY the bid quantity.
    public static func probabilityExact(quantity: Int, face: Int, myDice: [Int],
                                        totalDice: Int, wildOnes: Bool) -> Double {
        let mine = LiarsDiceRules.count(face: face, in: myDice, wildOnes: wildOnes)
        let unseen = max(0, totalDice - myDice.count)
        return binomialPMF(n: unseen, k: quantity - mine, p: matchChance(face: face, wildOnes: wildOnes))
    }

    /// The next action this seat should send, or nil if it has nothing to do.
    /// In `.awaitingDice` it returns nil: use `LiarsDiceEngine.rollAll`.
    public static func nextAction(state: LiarsDiceState, seat: Int,
                                  personality: LiarsDicePersonality = .balanced,
                                  rng: inout SeededGenerator) -> LiarsDiceAction? {
        guard state.phase == .bidding, seat == state.turnSeat,
              seat >= 0, seat < state.seatCount, let mine = state.dice[seat] else { return nil }
        let total = state.totalDice
        let wild = state.config.wildOnes

        if let bid = state.currentBid {
            let pTrue = probabilityTrue(quantity: bid.quantity, face: bid.face, myDice: mine,
                                        totalDice: total, wildOnes: wild)
            if state.config.spotOnEnabled {
                let pExact = probabilityExact(quantity: bid.quantity, face: bid.face, myDice: mine,
                                              totalDice: total, wildOnes: wild)
                if pExact >= personality.spotOnThreshold { return .spotOn }
            }
            if pTrue < personality.challengeThreshold { return .challenge }
        }

        let legal = LiarsDiceRules.legalBids(over: state.currentBid, totalDice: total)
        if legal.isEmpty { return .challenge }
        let scored = legal.map { b -> (q: Int, f: Int, p: Double) in
            (b.quantity, b.face, probabilityTrue(quantity: b.quantity, face: b.face, myDice: mine,
                                                  totalDice: total, wildOnes: wild))
        }
        let safe = scored.filter { $0.p >= personality.raiseTarget }
        guard !safe.isEmpty else {
            // Nothing safe to raise to: challenge if possible, else the least-bad bid.
            if state.currentBid != nil { return .challenge }
            let best = scored.max { a, b in a.p != b.p ? a.p < b.p : (a.q, a.f) > (b.q, b.f) }!
            return .bid(quantity: best.q, face: best.f)
        }
        let heldCount: (Int) -> Int = { f in LiarsDiceRules.count(face: f, in: mine, wildOnes: wild) }
        let roll = Double(Int.random(in: 0..<1000, using: &rng)) / 1000.0
        if roll < personality.bluffChance {
            // Bluff: a safe-ish bid on a face we hold few of.
            let pool = safe.filter { heldCount($0.f) == 0 }
            if !pool.isEmpty {
                let low = pool.min { ($0.q, $0.f) < ($1.q, $1.f) }!
                return .bid(quantity: low.q, face: low.f)
            }
        }
        // Honest raise: the smallest raise, preferring the face we hold most.
        let pick = safe.min { a, b in
            let ha = heldCount(a.f), hb = heldCount(b.f)
            let qa = a.q, qb = b.q
            if qa != qb { return qa < qb }
            if ha != hb { return ha > hb }
            return a.f < b.f
        }!
        return .bid(quantity: pick.q, face: pick.f)
    }
}
