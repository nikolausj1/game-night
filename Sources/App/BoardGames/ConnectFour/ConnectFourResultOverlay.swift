import SwiftUI

/// Win banner or a draw banner, plus rematch.
struct ConnectFourResultOverlay: View {
    let state: ConnectFourState
    var onRematch: () -> Void
    var onClose: () -> Void

    private var title: String {
        if let w = state.winner, state.players.indices.contains(w) { return "\(state.players[w].name) wins!" }
        return "A draw"
    }

    var body: some View {
        ScorecardPanel(title: title) {
            if let w = state.winner {
                HStack(spacing: 12) {
                    Image(w == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                        .resizable().frame(width: 36, height: 36)
                    Text("Four in a row")
                        .font(.system(.title2, design: .serif).italic())
                        .foregroundStyle(CardStyle.gold)
                }
            } else {
                Text("Every hole is filled and nobody lined up four.")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
                    .multilineTextAlignment(.center)
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
