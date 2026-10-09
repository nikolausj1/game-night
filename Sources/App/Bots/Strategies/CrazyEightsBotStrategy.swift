import Foundation

/// Crazy Eights: thin adapter over `CrazyEightsBrain` (Sources/Engine/
/// CardBotBrains.swift). It keeps eights as escape hatches, plays the card
/// that leaves the most follow-ups, counts unseen cards to avoid handing a
/// nearly-out neighbor an easy match, and names the suit it holds most of.
struct CrazyEightsBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .pass:
            return nil // only Hearts passes; EngineTrickBotStrategy handles it
        case .play:
            let p = state.seats.indices.contains(seat) ? BotPersonality.forName(state.seats[seat].playerName) : .neutral
            return CrazyEightsBrain.play(state: state, seat: seat, personality: p)
        case .declareSuit:
            return .declareSuit(CrazyEightsBrain.declare(state: state, seat: seat))
        case .bid, .chooseTrump:
            return nil // not Crazy Eights decisions
        }
    }
}
