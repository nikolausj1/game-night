import Foundation

/// Per-game rule logic, kept out of `HostEngine` so the reducer only
/// sequences turns and phases while the rules decide what's legal and who
/// wins a trick.
public protocol GameRules: Sendable {
    /// May `card` be played right now, given the player's hand and the trick
    /// so far? Non-trick games ignore `trick`/`trump` and read what they need
    /// (top discard, declared suit) from `state`.
    func legality(of card: Card, hand: [Card], trick: [TrickPlay], trump: Suit?, state: GameState) -> PlayLegality

    /// Winning seat of a completed trick. Non-trick games return the first
    /// play's seat (unused).
    func trickWinner(_ trick: [TrickPlay], trump: Suit?) -> Int
}

public extension GameKind {
    var ruleset: any GameRules {
        switch self {
        case .wizard: return WizardRules()
        case .ohHell: return OhHellRules()
        case .crazyEights: return CrazyEightsRules()
        case .freePlay: return FreePlayRules()
        }
    }
}

/// Shared trick math for Wizard and Oh Hell. Oh Hell decks contain no
/// wizards/jesters, so the special-card branches simply never fire there.
enum TrickMath {
    /// The suit that must be followed, given the trick so far.
    /// - wizard led (or any wizard before the first standard card): no led suit
    /// - jesters are skipped; the first standard card sets the led suit
    /// - empty / all-jester trick so far: no led suit yet
    static func ledSuit(in trick: [TrickPlay]) -> Suit? {
        for play in trick {
            switch play.card.kind {
            case .wizard: return nil
            case .jester: continue
            case .standard(let suit, _): return suit
            }
        }
        return nil
    }

    /// Standard Wizard trick resolution:
    /// first wizard wins; all jesters → first jester wins; else highest trump
    /// wins; else highest card of the led suit wins.
    static func standardWinner(_ trick: [TrickPlay], trump: Suit?) -> Int {
        guard let first = trick.first else { return -1 }
        if let wizard = trick.first(where: { $0.card.isWizard }) { return wizard.seat }
        let standards = trick.filter { $0.card.suit != nil }
        guard !standards.isEmpty else { return first.seat } // all jesters
        if let trump {
            let trumps = standards.filter { $0.card.suit == trump }
            if let best = trumps.max(by: { ($0.card.rank ?? 0) < ($1.card.rank ?? 0) }) {
                return best.seat
            }
        }
        let led = ledSuit(in: trick) ?? standards[0].card.suit!
        let followers = standards.filter { $0.card.suit == led }
        let best = followers.max(by: { ($0.card.rank ?? 0) < ($1.card.rank ?? 0) }) ?? first
        return best.seat
    }

    /// Follow-suit legality shared by Wizard and Oh Hell. Wizards/jesters are
    /// always playable and never count as holding the led suit.
    static func followSuitLegality(of card: Card, hand: [Card], trick: [TrickPlay]) -> PlayLegality {
        if card.isWizard || card.isJester { return .legal }
        guard let led = ledSuit(in: trick) else { return .legal }
        if card.suit == led { return .legal }
        let canFollow = hand.contains { $0.suit == led }
        return canFollow ? .illegal(reason: "You must follow \(led.rawValue)") : .legal
    }
}
