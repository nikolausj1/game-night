import SwiftUI

/// The player's name plate (the same capsule language as Quarto's turn
/// labels / `SeatPlateView`). The far player's plate is rotated 180 degrees
/// by the parent so it reads right-side-up from across the table.
struct MancalaPlaqueView: View {
    let name: String
    let isBot: Bool
    let status: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if isBot {
                    Image(systemName: "gearshape.2.fill")
                        .font(.caption)
                        .foregroundStyle(CardStyle.gold.opacity(0.8))
                }
                Text(name)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
            }
            Text(status.isEmpty ? " " : status)
                .font(.system(.caption, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
                .opacity(status.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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

/// A brass-rimmed count medallion under/over a store.
struct MancalaStoreBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 22, weight: .bold, design: .serif))
            .monospacedDigit()
            .foregroundStyle(CardStyle.stockTop)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: count)
            .frame(width: 46, height: 46)
            .background(
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.30, green: 0.19, blue: 0.10), Color(red: 0.14, green: 0.09, blue: 0.05)],
                                         center: .topLeading, startRadius: 2, endRadius: 40))
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [CardStyle.gold, CardStyle.gold.opacity(0.45), CardStyle.gold],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
            )
            .accessibilityLabel(Text("\(count) in store"))
    }
}
