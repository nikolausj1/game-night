import SwiftUI

/// Player name plate with a little checker for their colour. The far
/// player's is rotated 180 degrees by the parent.
struct CheckersPlaqueView: View {
    let name: String
    let isBot: Bool
    let owner: Int
    let status: String
    let isActive: Bool
    let capturedCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(owner == 0 ? "CheckerRed" : "CheckerBlack")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(.headline, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.stockTop)
                    if isBot {
                        Image(systemName: "gearshape.2.fill")
                            .font(.caption)
                            .foregroundStyle(CardStyle.gold.opacity(0.8))
                    }
                }
                Text(status.isEmpty ? " " : status)
                    .font(.system(.caption, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
            }
            if capturedCount > 0 {
                Text("\u{00D7}\(capturedCount)")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(CardStyle.stockTop.opacity(0.75))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.black.opacity(0.42))
                .overlay(Capsule().strokeBorder(isActive ? CardStyle.gold : .white.opacity(0.1),
                                                lineWidth: isActive ? 2 : 1))
                .shadow(color: isActive ? CardStyle.gold.opacity(0.6) : .clear, radius: 8)
        )
        .animation(.easeInOut(duration: 0.3), value: isActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: capturedCount)
        .accessibilityElement(children: .combine)
    }
}

/// Brass-edged notice ("You must capture", "Draw in 6 moves").
struct CheckersNoticeChip: View {
    let text: String
    var urgent = false

    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: .serif).weight(.semibold).italic())
            .foregroundStyle(urgent ? CardStyle.ink : CardStyle.stockTop)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(urgent ? AnyShapeStyle(CardStyle.gold) : AnyShapeStyle(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.8), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            )
    }
}
