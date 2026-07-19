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
        let isFreePlay = state.gameKind == .freePlay
        let width: CGFloat = isFreePlay ? 116 : 96
        let layers = min(isFreePlay ? 5 : 3, max(deckCount, 1))
        return ZStack {
            // Buried cards show only their paper EDGES — plain stock, no
            // art — so the pile reads as one deck, not interleaved cards.
            // Only the top card wears the printed back.
            ForEach(0..<layers, id: \.self) { layer in
                if layer == layers - 1 {
                    CardView(card: Card(id: "deck\(layer)", kind: .standard(suit: .spades, rank: 2)),
                             faceUp: false)
                        .frame(width: width)
                        .offset(x: CGFloat(layer) * -2.0, y: CGFloat(layer) * -2.5)
                        .rotationEffect(.degrees(Double(layer) * -0.8))
                } else {
                    RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: width),
                                     style: .continuous)
                        .fill(CardStyle.stockBottom)
                        .overlay(
                            RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: width),
                                             style: .continuous)
                                .strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
                        )
                        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
                        .frame(width: width)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .offset(x: CGFloat(layer) * -2.0, y: CGFloat(layer) * -2.5)
                        .rotationEffect(.degrees(Double(layer) * -0.8))
                }
            }
            if deckCount > 0 {
                VStack(spacing: 4) {
                    Text("\(deckCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45)))
                    if isFreePlay {
                        Text("Drag to a player to deal")
                            .font(.system(.caption2, design: .serif).italic())
                            .foregroundStyle(CardStyle.gold.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.4)))
                    }
                }
                .offset(y: isFreePlay ? 92 : 62)
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
