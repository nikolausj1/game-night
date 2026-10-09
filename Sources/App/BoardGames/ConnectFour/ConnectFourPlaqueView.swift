import SwiftUI

/// Player name plate with a little disc in their colour (rotated by the
/// parent for the far seat).
struct ConnectFourPlaqueView: View {
    let name: String
    let isBot: Bool
    let seat: Int
    let status: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(seat == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                .resizable()
                .frame(width: 28, height: 28)
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
        .accessibilityElement(children: .combine)
    }
}
