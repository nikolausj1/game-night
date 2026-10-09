import SwiftUI

/// Win banner (with how it ended) or the 40-move draw banner, plus rematch.
struct CheckersResultOverlay: View {
    let state: CheckersState
    var onRematch: () -> Void
    var onClose: () -> Void

    private var title: String {
        if let w = state.winner, state.players.indices.contains(w) { return "\(state.players[w].name) wins!" }
        return "A draw"
    }

    private var detail: String {
        switch state.endReason {
        case .noPieces: return "Every one of their pieces was captured."
        case .noMoves: return "They have no legal move left."
        case .noCaptureLimit: return "Forty moves each without a capture. Honours even."
        case nil: return ""
        }
    }

    var body: some View {
        ScorecardPanel(title: title) {
            if state.winner == nil {
                Image(systemName: "equal.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(CardStyle.gold)
            }
            Text(detail)
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
                .multilineTextAlignment(.center)
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
