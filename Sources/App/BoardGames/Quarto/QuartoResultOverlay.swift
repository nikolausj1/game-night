import SwiftUI

/// End of the game: a win names the shared attribute ("Four tall, four
/// dark!"), a draw gets its own honest, unglamorous line. Same
/// `ScorecardPanel` frame `GameOverOverlay` uses for the card games.
struct QuartoResultOverlay: View {
    let state: QuartoState
    var onRematch: () -> Void
    var onClose: () -> Void

    private var title: String {
        if let winner = state.winner, state.players.indices.contains(winner) {
            return "\(state.players[winner].name) wins!"
        }
        return "It's a draw"
    }

    private var callout: String? {
        guard state.winner != nil, let line = state.winningLine else { return nil }
        return QuartoRules.winCallout(attributes: state.winningAttributes, line: line, board: state.board)
    }

    var body: some View {
        ScorecardPanel(title: title) {
            if let callout {
                Text(callout)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
            } else {
                Text("Every cell is full and no line ever matched — a clean stalemate.")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        } action: {
            HStack(spacing: 14) {
                Button {
                    Haptics.tick()
                    onRematch()
                } label: {
                    Text("Rematch")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)

                Button {
                    onClose()
                } label: {
                    Text("Close")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(CardStyle.stockTop)
            }
        }
    }
}
