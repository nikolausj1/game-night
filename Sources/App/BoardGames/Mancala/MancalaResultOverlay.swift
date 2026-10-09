import SwiftUI

/// End of game: winner (or an honest draw), final store counts, rematch.
struct MancalaResultOverlay: View {
    let state: MancalaState
    var onRematch: () -> Void
    var onClose: () -> Void

    private var title: String {
        if let w = state.winner, state.players.indices.contains(w) { return "\(state.players[w].name) wins!" }
        return "A draw"
    }

    var body: some View {
        ScorecardPanel(title: title) {
            ForEach(0..<2, id: \.self) { seat in
                HStack {
                    Text(state.players[seat].name)
                        .font(.system(.title3, design: .serif).weight(state.winner == seat ? .bold : .regular))
                        .foregroundStyle(state.winner == seat ? CardStyle.gold : CardStyle.stockTop)
                    Spacer()
                    Text("\(state.scores[seat])")
                        .font(.system(.title2, design: .serif).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(state.winner == seat ? CardStyle.gold : CardStyle.stockTop)
                }
            }
            if state.winner == nil {
                Text("Twenty-four stones each. Perfectly matched.")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.75))
            }
        } action: {
            HStack(spacing: 14) {
                Button { Haptics.tick(); onRematch() } label: {
                    Text("Rematch").font(.title3.weight(.bold)).padding(.horizontal, 30).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                Button { onClose() } label: {
                    Text("Close").font(.title3.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(CardStyle.stockTop)
            }
        }
    }
}
