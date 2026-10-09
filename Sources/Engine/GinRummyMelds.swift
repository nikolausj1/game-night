import Foundation

/// Gin Rummy card values and meld mathematics. Aces are LOW only (A-2-3 is a
/// run, Q-K-A is not); faces count 10, aces 1, others pip value.
public enum GinRummyCards {
    /// 1 (ace) ... 13 (king). `Card.rank` is 14 for aces.
    public static func rank(_ card: Card) -> Int {
        let r = card.rank ?? 0
        return r == 14 ? 1 : r
    }

    /// Deadwood value: A=1, 2...10 pip, J/Q/K=10.
    public static func points(_ card: Card) -> Int {
        min(rank(card), 10)
    }

    /// Stable display order: by suit (clubs, diamonds, hearts, spades), then low-ace rank.
    public static func sorted(_ cards: [Card]) -> [Card] {
        cards.sorted {
            let a = suitIndex($0), b = suitIndex($1)
            return a != b ? a < b : rank($0) < rank($1)
        }
    }

    static func suitIndex(_ card: Card) -> Int {
        switch card.suit {
        case .clubs?: return 0
        case .diamonds?: return 1
        case .hearts?: return 2
        case .spades?: return 3
        case nil: return 4
        }
    }

    public static func deadwoodPoints(_ cards: [Card]) -> Int {
        cards.reduce(0) { $0 + points($1) }
    }
}

public enum GinMeldKind: String, Codable, Sendable, Equatable {
    /// 3 or 4 cards of one rank.
    case set
    /// 3+ consecutive cards of one suit (ace low only).
    case run
}

/// A declared meld. `cards` are sorted (sets by suit, runs by rank).
public struct GinMeld: Codable, Hashable, Sendable {
    public let kind: GinMeldKind
    public let cards: [Card]

    public init(kind: GinMeldKind, cards: [Card]) {
        self.kind = kind
        self.cards = cards
    }
}

/// A full partition of a hand: disjoint melds plus the leftover deadwood.
public struct GinArrangement: Codable, Sendable, Equatable {
    public let melds: [GinMeld]
    public let deadwood: [Card]
    public var deadwoodPoints: Int { GinRummyCards.deadwoodPoints(deadwood) }

    public init(melds: [GinMeld], deadwood: [Card]) {
        self.melds = melds
        self.deadwood = deadwood
    }
}

public enum GinMelds {
    // MARK: - Meld validity / extension

    /// The kind of meld these cards form, or nil if they are not a valid meld.
    public static func meldKind(of cards: [Card]) -> GinMeldKind? {
        guard cards.count >= 3, cards.allSatisfy({ $0.suit != nil }) else { return nil }
        if cards.count <= 4, Set(cards.map(GinRummyCards.rank)).count == 1, Set(cards.compactMap(\.suit)).count == cards.count {
            return .set
        }
        if Set(cards.compactMap(\.suit)).count == 1 {
            let ranks = cards.map(GinRummyCards.rank).sorted()
            if Set(ranks).count == ranks.count, ranks.last! - ranks.first! == ranks.count - 1 { return .run }
        }
        return nil
    }

    public static func makeMeld(_ cards: [Card]) -> GinMeld? {
        guard let kind = meldKind(of: cards) else { return nil }
        return GinMeld(kind: kind, cards: GinRummyCards.sorted(cards))
    }

    /// Can `card` be laid off onto `meld`? A set takes its 4th card; a run
    /// takes the next rank of its suit at either end (no ace-high).
    public static func canLayOff(_ card: Card, onto meld: GinMeld) -> Bool {
        guard let suit = card.suit, !meld.cards.contains(card) else { return false }
        switch meld.kind {
        case .set:
            return meld.cards.count == 3 && GinRummyCards.rank(card) == GinRummyCards.rank(meld.cards[0])
                && !meld.cards.contains { $0.suit == suit }
        case .run:
            guard meld.cards.first?.suit == suit else { return false }
            let ranks = meld.cards.map(GinRummyCards.rank)
            let r = GinRummyCards.rank(card)
            return r == ranks.min()! - 1 || r == ranks.max()! + 1
        }
    }

    public static func extend(_ meld: GinMeld, with card: Card) -> GinMeld {
        GinMeld(kind: meld.kind, cards: GinRummyCards.sorted(meld.cards + [card]))
    }

    // MARK: - Partition search

    /// Every legal meld inside `cards`, as bitmasks over indices of `cards`.
    static func candidateMelds(_ cards: [Card]) -> [UInt32] {
        var masks: [UInt32] = []
        var byRank: [Int: [Int]] = [:]
        var bySuit: [Int: [Int: Int]] = [:]
        for (i, c) in cards.enumerated() {
            guard c.suit != nil else { continue }
            byRank[GinRummyCards.rank(c), default: []].append(i)
            bySuit[GinRummyCards.suitIndex(c), default: [:]][GinRummyCards.rank(c)] = i
        }
        for (_, idx) in byRank where idx.count >= 3 {
            for skip in 0..<idx.count where idx.count == 4 {
                masks.append(idx.enumerated().reduce(UInt32(0)) { $1.offset == skip ? $0 : $0 | (1 << UInt32($1.element)) })
            }
            if idx.count == 3 || idx.count == 4 {
                masks.append(idx.reduce(UInt32(0)) { $0 | (1 << UInt32($1)) })
            }
        }
        for (_, ranks) in bySuit {
            for start in 1...11 {
                var mask: UInt32 = 0
                var len = 0
                var r = start
                while let i = ranks[r] {
                    mask |= 1 << UInt32(i)
                    len += 1
                    if len >= 3 { masks.append(mask) }
                    r += 1
                    if r > 13 { break }
                }
            }
        }
        return masks
    }

    private final class Solver {
        let pts: [Int]
        let melds: [UInt32]
        var memo: [Int]

        init(cards: [Card]) {
            pts = cards.map(GinRummyCards.points)
            melds = GinMelds.candidateMelds(cards)
            memo = [Int](repeating: -1, count: 1 << cards.count)
        }

        func best(_ mask: UInt32) -> Int {
            if mask == 0 { return 0 }
            if memo[Int(mask)] >= 0 { return memo[Int(mask)] }
            let i = mask.trailingZeroBitCount
            let bit = UInt32(1) << UInt32(i)
            var result = pts[i] + best(mask & ~bit)
            for m in melds where m & bit != 0 && m & mask == m {
                result = min(result, best(mask & ~m))
            }
            memo[Int(mask)] = result
            return result
        }

        /// Collects every optimal (melds, deadwood-mask) partition, up to `limit`.
        func enumerate(_ mask: UInt32, _ chosen: [UInt32], _ dead: UInt32, _ target: Int, _ out: inout [([UInt32], UInt32)], _ limit: Int) {
            if out.count >= limit { return }
            if mask == 0 { out.append((chosen, dead)); return }
            let i = mask.trailingZeroBitCount
            let bit = UInt32(1) << UInt32(i)
            if pts[i] + best(mask & ~bit) == target {
                enumerate(mask & ~bit, chosen, dead | bit, target - pts[i], &out, limit)
            }
            for m in melds where m & bit != 0 && m & mask == m && best(mask & ~m) == target {
                enumerate(mask & ~m, chosen + [m], dead, target, &out, limit)
            }
        }
    }

    /// Minimum deadwood points over all meld partitions of `cards`.
    public static func minDeadwood(_ cards: [Card]) -> Int {
        guard !cards.isEmpty else { return 0 }
        let solver = Solver(cards: cards)
        return solver.best((UInt32(1) << UInt32(cards.count)) - 1)
    }

    /// Up to `limit` distinct minimum-deadwood arrangements of `cards`.
    public static func optimalArrangements(_ cards: [Card], limit: Int = 64) -> [GinArrangement] {
        guard !cards.isEmpty else { return [GinArrangement(melds: [], deadwood: [])] }
        let solver = Solver(cards: cards)
        let full = (UInt32(1) << UInt32(cards.count)) - 1
        var raw: [([UInt32], UInt32)] = []
        solver.enumerate(full, [], 0, solver.best(full), &raw, limit)
        return raw.map { masks, dead in
            func pick(_ m: UInt32) -> [Card] { cards.indices.filter { m & (1 << UInt32($0)) != 0 }.map { cards[$0] } }
            let melds = masks.compactMap { makeMeld(pick($0)) }
            return GinArrangement(melds: melds, deadwood: GinRummyCards.sorted(pick(dead)))
        }
    }

    /// One minimum-deadwood arrangement (the first found).
    public static func bestArrangement(_ cards: [Card]) -> GinArrangement {
        optimalArrangements(cards, limit: 1).first ?? GinArrangement(melds: [], deadwood: cards)
    }

    // MARK: - Layoff

    /// Places as many of `cards` as possible onto `melds`, to a fixpoint (a
    /// laid-off run card can unlock the next). Prefers runs when a card fits
    /// both a run and a set (a filled set can never unlock anything).
    /// Returns the placements in a valid order plus the grown melds.
    static func placeAll(_ cards: [Card], onto melds: [GinMeld]) -> (placements: [(card: Card, meldIndex: Int)], melds: [GinMeld], left: [Card]) {
        var current = melds
        var left = cards
        var placements: [(Card, Int)] = []
        var progress = true
        while progress {
            progress = false
            for card in left {
                let runIdx = current.indices.first { current[$0].kind == .run && canLayOff(card, onto: current[$0]) }
                let idx = runIdx ?? current.indices.first { canLayOff(card, onto: current[$0]) }
                if let i = idx {
                    current[i] = extend(current[i], with: card)
                    placements.append((card, i))
                    left.removeAll { $0 == card }
                    progress = true
                    break
                }
            }
        }
        return (placements, current, left)
    }

    /// The cards of `hand` that could be laid off onto `melds` at all.
    public static func layoffCandidates(hand: [Card], melds: [GinMeld]) -> [Card] {
        placeAll(hand, onto: melds).placements.map(\.card)
    }

    public struct LayoffPlan: Sendable {
        /// (card, index into the knocker's melds), in a valid placement order.
        public let placements: [(card: Card, meldIndex: Int)]
        /// The defender's remaining deadwood after laying those off and melding the rest optimally.
        public let deadwood: Int
    }

    /// The defender's best joint play: which cards to lay off (maybe fewer
    /// than possible, if that keeps a meld of their own intact) to minimise
    /// final deadwood.
    public static func optimalLayoff(hand: [Card], knockerMelds: [GinMeld]) -> LayoffPlan {
        let pool = layoffCandidates(hand: hand, melds: knockerMelds)
        var bestPlan = LayoffPlan(placements: [], deadwood: minDeadwood(hand))
        guard !pool.isEmpty, pool.count <= 12 else { return bestPlan }
        let n = pool.count
        // Larger subsets first so ties favour shedding more cards.
        let subsets = (1..<(1 << n)).sorted { $0.nonzeroBitCount > $1.nonzeroBitCount }
        for s in subsets {
            let chosen = (0..<n).filter { s & (1 << $0) != 0 }.map { pool[$0] }
            let placed = placeAll(chosen, onto: knockerMelds)
            guard placed.left.isEmpty else { continue }
            let rest = hand.filter { c in !chosen.contains(c) }
            let dw = minDeadwood(rest)
            if dw < bestPlan.deadwood {
                bestPlan = LayoffPlan(placements: placed.placements.map { ($0.card, $0.meldIndex) }, deadwood: dw)
            }
        }
        return bestPlan
    }
}
