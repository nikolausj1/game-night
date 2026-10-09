import Foundation

/// The one thing the engine is waiting on from a given seat right now.
/// BotDirector detects it from the phase; strategies answer it.
enum BotDecision: Equatable {
    case bid          // trick games, phase .bidding
    case chooseTrump  // Wizard, phase .choosingTrump (wizard flipped)
    case declareSuit  // Crazy Eights / UNO, phase .choosingTrump (eight/wild)
    case play         // phase .playing: play a card or draw
    case pass         // Hearts, phase .passing: choose 3 cards to pass
}

/// A strategy answers one decision with one PlayerAction (or nil to stand
/// pat). Strategies read the full host GameState but must only use what a
/// player could see: their own hand, the trick/discard, and hand COUNTS —
/// never the contents of other hands or the draw pile.
protocol BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction?
}

enum BotStrategyFactory {
    static func strategy(for kind: GameKind) -> BotStrategy? {
        switch kind {
        case .wizard, .ohHell: return TrickTakingBotStrategy()
        case .crazyEights: return CrazyEightsBotStrategy()
        case .uno: return UnoBotStrategy()
        case .hearts, .spades: return EngineTrickBotStrategy()
        case .freePlay: return nil // no rules, no turns, no bot
        }
    }
}

extension BotStrategy {
    /// Cards the ruleset would accept from this seat right now. Pre-filtering
    /// here means bots never spam the engine with rejected attempts.
    func legalCards(state: GameState, seat: Int) -> [Card] {
        let hand = state.hands[seat] ?? []
        let trick = state.round?.currentTrick ?? []
        let trump = state.round?.trumpSuit
        let rules = state.gameKind.ruleset
        return hand.filter {
            rules.legality(of: $0, hand: hand, trick: trick, trump: trump, state: state).isLegal
        }
    }

    /// Play-order successor, honoring UNO's direction of play (RoundState
    /// carries `direction`, +1 or -1; every other game is +1).
    func nextSeat(after seat: Int, state: GameState) -> Int {
        let count = max(state.seats.count, 1)
        let direction = state.round?.direction ?? 1
        let raw = (seat + direction) % count
        return raw < 0 ? raw + count : raw
    }
}

/// Hearts and Spades: the engine ships its own full strategy
/// (`TrickBots` in Sources/Engine — passing, bids incl. nil, partner-aware
/// play), so the app-side strategy just defers to it for every decision.
struct EngineTrickBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        TrickBots.action(for: state, seat: seat)
    }
}
