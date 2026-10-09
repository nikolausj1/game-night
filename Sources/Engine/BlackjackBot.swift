import Foundation

/// A basic-strategy move (the decision, before it becomes a `BlackjackAction`).
public enum BlackjackMove: String, Codable, Sendable, Equatable {
    case hit, stand, double, split, surrender
}

/// How a bot sizes its bets. Flat betting only: the bet never reacts to the
/// previous result (no martingale / chasing). A personality picks a base
/// fraction of the bankroll and a weighted "tier" multiplier per hand.
public enum BlackjackBetPersonality: String, Codable, Sendable, Equatable, CaseIterable {
    case timid, steady, bold

    /// Base bet as a fraction of the current bankroll.
    public var bankrollFraction: Double {
        switch self {
        case .timid: return 0.02
        case .steady: return 0.05
        case .bold: return 0.10
        }
    }

    /// Weights for tiers x1, x2, x3 of the base bet (sum 100).
    public var tierWeights: [Int] {
        switch self {
        case .timid: return [80, 15, 5]
        case .steady: return [60, 30, 10]
        case .bold: return [30, 40, 30]
        }
    }
}

/// Exact multi-deck basic strategy (6 decks, double after split, one split,
/// no re-split, split aces take one card), with the S17 and H17 variants.
/// Pure functions; deterministic given the caller's `rng` (betting only).
public enum BlackjackBot {

    /// The basic-strategy decision for a hand. `canDouble`/`canSplit`/
    /// `canSurrender` come from the engine's legality (a double that is
    /// unavailable falls back to hit, or stand for the "Ds" cells).
    public static func move(hand: [Card], dealerUp: Card,
                            canDouble: Bool, canSplit: Bool, canSurrender: Bool = false,
                            dealerHitsSoft17: Bool = false) -> BlackjackMove {
        let up = BlackjackRules.cardValue(dealerUp)   // 2...11 (11 = ace)
        let v = BlackjackRules.value(of: hand)
        let h17 = dealerHitsSoft17

        // Surrender first (only ever offered on the opening two cards).
        if canSurrender && hand.count == 2 && !v.isSoft {
            switch v.total {
            case 16 where up == 9 || up == 10 || up == 11:
                // 8-8 splits instead (except H17 vs ace, where it surrenders).
                if BlackjackRules.isPair(hand) && canSplit {
                    if h17 && up == 11 { return .surrender }
                } else {
                    return .surrender
                }
            case 15 where up == 10 || (h17 && up == 11):
                return .surrender
            case 17 where h17 && up == 11:
                return .surrender
            default: break
            }
        }

        // Pairs.
        if canSplit && BlackjackRules.isPair(hand) {
            let pv = BlackjackRules.cardValue(hand[0])
            switch pv {
            case 11: return .split
            case 10: break
            case 9:
                if (2...6).contains(up) || up == 8 || up == 9 { return .split }
            case 8: return .split
            case 7:
                if (2...7).contains(up) { return .split }
            case 6:
                if (2...6).contains(up) { return .split }
            case 5: break                      // played as hard 10
            case 4:
                if up == 5 || up == 6 { return .split }
            case 2, 3:
                if (2...7).contains(up) { return .split }
            default: break
            }
        }

        let dbl: (BlackjackMove) -> BlackjackMove = { fallback in canDouble ? .double : fallback }

        if v.isSoft {
            switch v.total {
            case 13, 14:                       // A-2, A-3
                return (up == 5 || up == 6) ? dbl(.hit) : .hit
            case 15, 16:                       // A-4, A-5
                return (4...6).contains(up) ? dbl(.hit) : .hit
            case 17:                           // A-6
                return (3...6).contains(up) ? dbl(.hit) : .hit
            case 18:                           // A-7
                if (3...6).contains(up) { return dbl(.stand) }
                if up == 2 { return h17 ? dbl(.stand) : .stand }
                if up == 7 || up == 8 { return .stand }
                return .hit                    // 9, 10, A
            case 19:                           // A-8
                if h17 && up == 6 { return dbl(.stand) }
                return .stand
            default:
                return v.total >= 20 ? .stand : .hit
            }
        }

        // Hard totals.
        switch v.total {
        case ...8: return .hit
        case 9: return (3...6).contains(up) ? dbl(.hit) : .hit
        case 10: return (2...9).contains(up) ? dbl(.hit) : .hit
        case 11:
            if up == 11 { return h17 ? dbl(.hit) : .hit }
            return dbl(.hit)
        case 12: return (4...6).contains(up) ? .stand : .hit
        case 13...16: return (2...6).contains(up) ? .stand : .hit
        default: return .stand
        }
    }

    /// Flat, personality-sized bet. Result is within [minBet, maxBet], a
    /// multiple of `betStep`, and never more than the bankroll allows.
    /// Returns nil when the seat cannot afford the minimum.
    public static func chooseBet(chips: Int, config: BlackjackConfig,
                                 personality: BlackjackBetPersonality,
                                 rng: inout SeededGenerator) -> Int? {
        let step = config.betStep
        // Largest legal wager: capped by table max, bankroll, and the step grid.
        var cap = min(config.maxBet, chips)
        cap -= cap % step
        var floorBet = config.minBet
        if floorBet % step != 0 { floorBet += step - floorBet % step }
        guard cap >= floorBet else { return nil }

        let weights = personality.tierWeights
        let roll = Int.random(in: 0..<weights.reduce(0, +), using: &rng)
        var tier = 1
        var acc = 0
        for (i, w) in weights.enumerated() {
            acc += w
            if roll < acc { tier = i + 1; break }
        }
        let base = max(Double(floorBet), Double(chips) * personality.bankrollFraction)
        var bet = Int(base.rounded()) * tier
        bet -= bet % step
        return min(max(bet, floorBet), cap)
    }

    /// The next action this seat should send, or nil when it has nothing to
    /// do right now (waiting on others / round over). `.nextRound` is NOT
    /// returned: advancing is the host's call.
    public static func nextAction(state: BlackjackState, seat: Int,
                                  personality: BlackjackBetPersonality = .steady,
                                  rng: inout SeededGenerator) -> BlackjackAction? {
        guard seat >= 0, seat < state.seats.count else { return nil }
        let legal = state.legalActions(for: seat)
        guard !legal.isEmpty else { return nil }
        switch state.phase {
        case .betting:
            guard let bet = chooseBet(chips: state.seats[seat].chips, config: state.config,
                                      personality: personality, rng: &rng) else { return .sitOut }
            return .placeBet(bet)
        case .insurance:
            return .takeInsurance(false)       // basic strategy: never insure
        case .playing:
            guard state.activeHand < state.seats[seat].hands.count,
                  let up = state.dealerCards.first else { return nil }
            let hand = state.seats[seat].hands[state.activeHand].cards
            let m = move(hand: hand, dealerUp: up,
                         canDouble: legal.contains(.doubleDown),
                         canSplit: legal.contains(.split),
                         canSurrender: legal.contains(.surrender),
                         dealerHitsSoft17: state.config.dealerHitsSoft17)
            switch m {
            case .hit: return .hit
            case .stand: return .stand
            case .double: return .doubleDown
            case .split: return .split
            case .surrender: return .surrender
            }
        case .roundComplete, .sessionOver:
            return nil
        }
    }
}
