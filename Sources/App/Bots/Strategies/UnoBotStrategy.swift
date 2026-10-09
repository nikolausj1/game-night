import Foundation

/// UNO: thin adapter over `UnoBrain` (Sources/Engine/CardBotBrains.swift,
/// where the logic lives so it is headless-testable). The brain counts
/// unseen cards from the discard pile, plays to keep the hand flowing
/// (follow-up cards, color coverage), holds wilds as the guaranteed way
/// out, hits a neighbor who is nearly out with skip/draw-two/Wild Draw
/// Four, and names the wild color it holds most of while steering away
/// from colors the next player probably has. Bold bots dump action cards
/// sooner, cautious ones sit on them (see `BotPersonality`).
struct UnoBotStrategy: BotStrategy {
    func action(_ decision: BotDecision, state: GameState, seat: Int) -> PlayerAction? {
        switch decision {
        case .pass:
            return nil // only Hearts passes; EngineTrickBotStrategy handles it
        case .play:
            return UnoBrain.play(state: state, seat: seat, personality: personality(state, seat))
        case .declareSuit:
            return .declareSuit(UnoBrain.declare(state: state, seat: seat))
        case .bid, .chooseTrump:
            return nil // not UNO decisions
        }
    }

    private func personality(_ state: GameState, _ seat: Int) -> BotPersonality {
        state.seats.indices.contains(seat) ? BotPersonality.forName(state.seats[seat].playerName) : .neutral
    }
}
