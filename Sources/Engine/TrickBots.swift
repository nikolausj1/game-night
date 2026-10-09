import Foundation

/// Deterministic bots for the score-limit trick-takers (Hearts, Spades).
/// Pure functions of `GameState` + seat: no randomness, no stored memory
/// (anything a bot "remembers" is re-derived from `round.completedTricks`),
/// so the same state always yields the same action.
///
/// The App's bot director asks `TrickBots.action(for:seat:)` whenever a bot
/// seat owes a decision; it returns nil when it's not that seat's move.
public enum TrickBots {
    /// The one action `seat` should take right now, or nil if the engine is
    /// not waiting on that seat (or the game isn't hearts / spades).
    public static func action(for state: GameState, seat: Int) -> PlayerAction? {
        switch state.gameKind {
        case .hearts:
            switch state.phase {
            case .passing:
                guard let round = state.round, round.passSelections[seat] == nil,
                      let hand = state.hands[seat], hand.count >= HeartsRules.passCount else { return nil }
                return .passCards(HeartsBot.passChoice(hand: hand))
            case .playing:
                return HeartsBot.play(state: state, seat: seat)
            default:
                return nil
            }
        case .spades:
            switch state.phase {
            case .bidding:
                guard let round = state.round, round.turnSeat == seat else { return nil }
                return .placeBid(SpadesBot.bid(state: state, seat: seat))
            case .playing:
                return SpadesBot.play(state: state, seat: seat)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Shared helpers

    fileprivate static func legalCards(state: GameState, seat: Int) -> [Card] {
        guard let round = state.round, round.turnSeat == seat else { return [] }
        let hand = state.hands[seat] ?? []
        let rules = state.gameKind.ruleset
        return hand.filter {
            rules.legality(of: $0, hand: hand, trick: round.currentTrick, trump: round.trumpSuit, state: state).isLegal
        }
    }

    /// Strict, deterministic ordering: rank, then suit, then id.
    fileprivate static func lowerThan(_ a: Card, _ b: Card) -> Bool {
        let ra = a.rank ?? 0, rb = b.rank ?? 0
        if ra != rb { return ra < rb }
        if a.suit?.rawValue != b.suit?.rawValue { return (a.suit?.rawValue ?? "") < (b.suit?.rawValue ?? "") }
        return a.id < b.id
    }

    fileprivate static func lowest(_ cards: [Card]) -> Card? { cards.min(by: lowerThan) }
    fileprivate static func highest(_ cards: [Card]) -> Card? { cards.max(by: lowerThan) }

    /// Cards that top their suit run from the ace down (A; A,K; A,K,Q ...):
    /// a cheap "sure winners" count.
    fileprivate static func sureTricks(_ hand: [Card]) -> Int {
        var total = 0
        for suit in Suit.allCases {
            let ranks = hand.filter { $0.suit == suit }.compactMap(\.rank).sorted(by: >)
            var expected = 14
            for rank in ranks {
                if rank == expected { total += 1; expected -= 1 } else { break }
            }
        }
        return total
    }

    fileprivate static func min<T>(_ items: [T], by key: (T) -> (Int, Int, String)) -> T? {
        items.min { key($0) < key($1) }
    }
}

// MARK: - Hearts

public enum HeartsBot {
    /// Three cards to pass. Dumps the queen of spades, high spades that would
    /// have to catch it, and high hearts; keeps a short suit a priority. When
    /// the hand is overwhelming (see `wantsMoon`) it instead passes its three
    /// lowest non-heart cards and keeps the power.
    public static func passChoice(hand: [Card]) -> [String] {
        let pool = hand.sorted(by: TrickBots.lowerThan)
        if wantsMoon(hand) {
            let junk = pool.filter { $0.suit != .hearts && $0.id != HeartsRules.queenOfSpadesID }.prefix(HeartsRules.passCount)
            var picks = Array(junk)
            if picks.count < HeartsRules.passCount {
                picks += pool.filter { c in !picks.contains(c) }.prefix(HeartsRules.passCount - picks.count)
            }
            return picks.map(\.id)
        }
        let spadeCount = hand.filter { $0.suit == .spades }.count
        let hasQueen = hand.contains { $0.id == HeartsRules.queenOfSpadesID }
        func danger(_ card: Card) -> Int {
            let rank = card.rank ?? 0
            if card.id == HeartsRules.queenOfSpadesID { return 1000 }
            if card.suit == .spades, rank >= 13 {
                return (!hasQueen && spadeCount < 6) ? 500 + rank : rank
            }
            if card.suit == .hearts { return rank >= 10 ? 300 + rank : 40 + rank }
            let suitCount = hand.filter { $0.suit == card.suit }.count
            return rank + (suitCount <= 2 ? 60 : 0)
        }
        let ranked = hand.sorted { a, b in
            let da = danger(a), db = danger(b)
            return da != db ? da > db : a.id < b.id
        }
        return ranked.prefix(HeartsRules.passCount).map(\.id)
    }

    /// Overwhelming: most of the hand is top-of-suit winners, with heart
    /// length and the ace to run them.
    static func wantsMoon(_ hand: [Card]) -> Bool {
        guard hand.count >= 10 else { return false }
        let hearts = hand.filter { $0.suit == .hearts }
        guard hearts.count >= 5, hearts.contains(where: { $0.rank == 14 }) else { return false }
        return TrickBots.sureTricks(hand) * 100 >= hand.count * 65
    }

    static func play(state: GameState, seat: Int) -> PlayerAction? {
        guard let round = state.round else { return nil }
        let legal = TrickBots.legalCards(state: state, seat: seat)
        guard !legal.isEmpty else { return nil }
        let hand = state.hands[seat] ?? []
        let trick = round.currentTrick
        let n = state.seats.count
        let rules = state.gameKind.ruleset

        let seen = round.completedTricks.flatMap { $0 } + trick
        let queenUnplayed = !seen.contains { $0.card.id == HeartsRules.queenOfSpadesID }
            && !hand.contains { $0.id == HeartsRules.queenOfSpadesID }
        let holdsQueen = hand.contains { $0.id == HeartsRules.queenOfSpadesID }

        func result(_ card: Card?) -> PlayerAction? {
            (card ?? TrickBots.lowest(legal)).map { .playCard(cardID: $0.id, force: false) }
        }

        // Moon run: nobody else has points, and the hand is still a sure thing.
        let points = HeartsRules.pointsTaken(in: round.completedTricks)
        let others = points.filter { $0.key != seat }.values.reduce(0, +)
        let mine = points[seat] ?? 0
        let shooting: Bool = {
            guard others == 0 else { return false }
            if round.completedTricks.isEmpty { return wantsMoon(hand) }
            return mine > 0 && TrickBots.sureTricks(hand) >= hand.count - 1
        }()

        if trick.isEmpty {
            if shooting { return result(TrickBots.highest(legal)) }
            func leadRisk(_ c: Card) -> Int {
                let rank = c.rank ?? 0
                if c.id == HeartsRules.queenOfSpadesID { return 1000 }
                if c.suit == .hearts { return 100 + rank }
                if c.suit == .spades, !holdsQueen, queenUnplayed, rank >= 13 { return 200 + rank }
                return rank
            }
            return result(legal.min { a, b in
                let ra = leadRisk(a), rb = leadRisk(b)
                return ra != rb ? ra < rb : a.id < b.id
            })
        }

        guard let led = TrickMath.ledSuit(in: trick) else { return result(TrickBots.lowest(legal)) }
        let following = legal.filter { $0.suit == led }
        let winnerRank = trick.filter { $0.card.suit == led }.compactMap { $0.card.rank }.max() ?? 0
        let isLast = trick.count == n - 1

        if !following.isEmpty {
            if shooting {
                func wins(_ card: Card) -> Bool {
                    rules.trickWinner(trick + [TrickPlay(seat: seat, card: card, wasForced: false)], trump: nil) == seat
                }
                if let top = TrickBots.highest(following), wins(top) { return result(top) }
                return result(TrickBots.lowest(following))
            }
            let duck = following.filter { ($0.rank ?? 0) < winnerRank }
            if !duck.isEmpty {
                if let queen = duck.first(where: { $0.id == HeartsRules.queenOfSpadesID }) { return result(queen) }
                return result(TrickBots.highest(duck))
            }
            // Forced to take the trick. Never feed ourselves the queen if
            // there's any alternative.
            let safe = following.filter { $0.id != HeartsRules.queenOfSpadesID }
            let pool = safe.isEmpty ? following : safe
            if isLast { return result(TrickBots.highest(pool)) }
            return result(TrickBots.lowest(pool)) // hope someone covers us
        }

        // Void: shed the most dangerous card.
        if shooting {
            let nonPoint = legal.filter { HeartsRules.pointValue(of: $0) == 0 }
            return result(TrickBots.lowest(nonPoint.isEmpty ? legal : nonPoint))
        }
        func dumpValue(_ c: Card) -> Int {
            let rank = c.rank ?? 0
            if c.id == HeartsRules.queenOfSpadesID { return 1000 }
            if c.suit == .hearts { return 100 + rank }
            if c.suit == .spades, !holdsQueen, queenUnplayed, rank >= 13 { return 90 + rank }
            let suitCount = hand.filter { $0.suit == c.suit }.count
            return rank + (suitCount <= 2 ? 20 : 0)
        }
        return result(legal.max { a, b in
            let da = dumpValue(a), db = dumpValue(b)
            return da != db ? da < db : a.id > b.id
        })
    }
}

// MARK: - Spades

public enum SpadesBot {
    /// Counts sure tricks (spade honors and length, side aces and guarded
    /// kings, ruffing voids), floors it, and bids nil on a hand that can't
    /// win anything. Leans toward rounding up when the team is carrying bags.
    public static func bid(state: GameState, seat: Int) -> Int {
        guard let round = state.round else { return 1 }
        let hand = state.hands[seat] ?? []
        if shouldNil(hand: hand, state: state, seat: seat) { return 0 }

        let spades = hand.filter { $0.suit == .spades }
        let spadeCount = spades.count
        var expected = 0.0
        for card in spades {
            switch card.rank ?? 0 {
            case 14: expected += 1.0
            case 13: expected += spadeCount >= 2 ? 0.9 : 0.5
            case 12: expected += spadeCount >= 3 ? 0.8 : 0.3
            case 11: expected += spadeCount >= 4 ? 0.5 : 0.1
            default: break
            }
        }
        if spadeCount > 3 { expected += Double(spadeCount - 3) * 0.7 }
        for suit in [Suit.clubs, .diamonds, .hearts] {
            let cards = hand.filter { $0.suit == suit }
            let hasAce = cards.contains { $0.rank == 14 }
            let hasKing = cards.contains { $0.rank == 13 }
            if hasAce { expected += 0.9 }
            if hasKing { expected += cards.count >= 2 ? (hasAce ? 0.8 : 0.5) : 0.2 }
            if cards.isEmpty, spadeCount >= 3 { expected += 0.8 }
            else if cards.count == 1, spadeCount >= 4 { expected += 0.4 }
        }
        // Fewer opponents = more tricks for everyone: a 2- or 3-player hand
        // wins roughly 4/n times what the 4-player count suggests.
        let seatCount = state.seats.count
        if seatCount < 4 { expected *= 4.0 / Double(seatCount) }
        let bags = SpadesRules.currentBags(history: state.roundHistory)[seat] ?? 0
        let raw = bags >= 6 ? Int(expected.rounded(.up)) : Int((expected + 0.3).rounded(.down))
        return Swift.max(1, Swift.min(raw, round.cardsPerPlayer))
    }

    /// A hand with nothing to win with: no spade above a 9 (and few spades),
    /// no queen/king/ace anywhere, at most two tens-or-better, and a low
    /// card to duck with in every suit it holds. Never nil on top of a
    /// partner's nil.
    static func shouldNil(hand: [Card], state: GameState, seat: Int) -> Bool {
        if let partner = SpadesRules.partner(of: seat, in: state),
           state.round?.bids[partner] == 0 { return false }
        let spades = hand.filter { $0.suit == .spades }
        guard spades.count <= 3, (spades.compactMap(\.rank).max() ?? 0) <= 9 else { return false }
        guard !hand.contains(where: { ($0.rank ?? 0) >= 12 }) else { return false }
        guard hand.filter({ ($0.rank ?? 0) >= 10 }).count <= 2 else { return false }
        for suit in Suit.allCases {
            let ranks = hand.filter { $0.suit == suit }.compactMap(\.rank)
            if let low = ranks.min(), low > 7 { return false }
        }
        return true
    }

    /// Spades-aware ordering for "cheap" cards: side-suit cards before any
    /// spade, then by rank.
    private static func cheapKey(_ c: Card) -> (Int, Int, String) {
        (c.suit == .spades ? 1 : 0, c.rank ?? 0, c.id)
    }

    static func play(state: GameState, seat: Int) -> PlayerAction? {
        guard let round = state.round else { return nil }
        let legal = TrickBots.legalCards(state: state, seat: seat)
        guard !legal.isEmpty else { return nil }
        let trick = round.currentTrick
        let n = state.seats.count
        let rules = state.gameKind.ruleset
        let teams = SpadesRules.teams(for: state)
        let members = teams.first(where: { $0.contains(seat) }) ?? [seat]
        let partner = members.first(where: { $0 != seat })

        func nilAlive(_ s: Int) -> Bool { (round.bids[s] ?? 1) == 0 && (round.tricksWon[s] ?? 0) == 0 }
        let iAmNil = nilAlive(seat)
        let partnerNil = partner.map(nilAlive) ?? false
        let contract = members.reduce(0) { $0 + (round.bids[$1] ?? 0) }
        let teamTricks = members.reduce(0) { $0 + (round.tricksWon[$1] ?? 0) }
        let needTricks = teamTricks < contract

        func pick(_ card: Card?) -> PlayerAction? {
            (card ?? TrickBots.min(legal, by: cheapKey)).map { .playCard(cardID: $0.id, force: false) }
        }
        func currentlyWins(_ card: Card) -> Bool {
            rules.trickWinner(trick + [TrickPlay(seat: seat, card: card, wasForced: false)], trump: .spades) == seat
        }
        let currentWinner: Int? = trick.isEmpty ? nil : rules.trickWinner(trick, trump: .spades)
        let cheapest = { (cards: [Card]) in TrickBots.min(cards, by: cheapKey) }

        // Own nil: never take a trick, shed the biggest danger.
        if iAmNil {
            if trick.isEmpty { return pick(cheapest(legal)) }
            let safe = legal.filter { !currentlyWins($0) }
            if !safe.isEmpty {
                // Highest non-winner; side suits before spades.
                return pick(safe.max { cheapKey($0) < cheapKey($1) })
            }
            return pick(TrickBots.lowest(legal))
        }

        // Partner's nil: take the tricks they'd otherwise have to duck.
        if partnerNil, let partner {
            if trick.isEmpty {
                return pick(legal.max { cheapKey($0) < cheapKey($1) })
            }
            let partnerPlayed = trick.contains { $0.seat == partner }
            let winners = legal.filter(currentlyWins)
            if currentWinner == partner || !partnerPlayed {
                return pick(cheapest(winners) ?? cheapest(legal))
            }
            return pick(cheapest(legal))
        }

        // Ordinary contract play.
        if trick.isEmpty {
            if needTricks {
                let side = legal.filter { $0.suit != .spades }
                return pick((side.isEmpty ? legal : side).max { cheapKey($0) < cheapKey($1) })
            }
            return pick(cheapest(legal)) // contract made: lose cheaply, avoid bags
        }

        let isLast = trick.count == n - 1
        let winners = legal.filter(currentlyWins)
        if let partner, currentWinner == partner {
            let partnerCard = trick.first { $0.seat == partner }?.card
            let weak = partnerCard.map { $0.suit != .spades && ($0.rank ?? 0) < 10 } ?? false
            if needTricks, !isLast, weak, let secure = cheapest(winners) { return pick(secure) }
            return pick(cheapest(legal)) // never overtake a partner who is winning
        }
        if needTricks, let cheap = cheapest(winners) { return pick(cheap) }
        if !needTricks {
            let losers = legal.filter { !currentlyWins($0) }
            return pick(cheapest(losers.isEmpty ? legal : losers))
        }
        return pick(cheapest(legal))
    }
}
