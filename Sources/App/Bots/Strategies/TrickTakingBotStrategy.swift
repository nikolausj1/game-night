import Foundation

/// Wizard and Oh Hell: thin adapter over `TrickBrain` (Sources/Engine/
/// CardBotBrains.swift). Bids come from a sure-trick estimate recalibrated
/// by self-play (the original under-bid by over a trick a round at small
/// tables); play steers toward the bid, chasing tricks cheaply while short
/// and ducking once level. Bold bots shade bids up, cautious ones down.
struct TrickTakingBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .pass:
            return nil // only Hearts passes; EngineTrickBotStrategy handles it
        case .bid:
            let p = state.seats.indices.contains(seat) ? BotPersonality.forName(state.seats[seat].playerName) : .neutral
            return .placeBid(TrickBrain.bid(state: state, seat: seat, personality: p))
        case .chooseTrump:
            return .chooseTrump(TrickBrain.chooseTrump(state: state, seat: seat))
        case .play:
            return TrickBrain.play(state: state, seat: seat)
        case .declareSuit:
            return nil // not a trick-game decision
        }
    }
}
