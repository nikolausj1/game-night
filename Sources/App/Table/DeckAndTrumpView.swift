import SwiftUI

/// The draw pile and the flipped trump card, sitting together on the felt
/// like a dealer left them: stacked backs with visible depth, trump turned
/// beside the pile.
struct DeckAndTrumpView: View {
    let state: GameState

    private var deckCount: Int { state.drawPile.count }

    var body: some View {
        HStack(spacing: 26) {
            deckStack
            if let trump = state.round?.trumpCard {
                trumpCard(trump)
            } else if state.round != nil, state.gameKind.isTrickTaking {
                Text("No trump")
                    .font(.system(.caption, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.4)))
            }
        }
    }

    private var deckStack: some View {
        ZStack {
            // Three offset backs suggest the pile's thickness; the count
            // does the honest bookkeeping.
            ForEach(0..<min(3, max(deckCount, 1)), id: \.self) { layer in
                CardView(card: Card(id: "deck\(layer)", kind: .standard(suit: .spades, rank: 2)),
                         faceUp: false)
                    .frame(width: 96)
                    .offset(x: CGFloat(layer) * -2.5, y: CGFloat(layer) * -3)
                    .rotationEffect(.degrees(Double(layer) * -1.2))
            }
            if deckCount > 0 {
                Text("\(deckCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .offset(y: 62)
            }
        }
        .opacity(deckCount == 0 ? 0.25 : 1)
    }

    private func trumpCard(_ trump: Card) -> some View {
        VStack(spacing: 8) {
            CardView(card: trump, faceUp: true)
                .frame(width: 96)
                .rotationEffect(.degrees(90))
            Text(trumpLabel)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.4)))
        }
    }

    private var trumpLabel: String {
        if let suit = state.round?.trumpSuit { return "Trump \(suit.symbol)" }
        return "No trump"
    }
}
