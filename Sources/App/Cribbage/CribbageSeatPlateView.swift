import SwiftUI

/// Cribbage's own rim plate — the same rim-tab visual language as
/// `SeatPlateView` (rounded toward the felt, squared at the rail, a brass
/// seam, a turn glow), rebuilt standalone because `SeatPlateView` is keyed
/// to `Seat`/`GameState`, which cribbage's own bare 2-seat engine has
/// neither of.
struct CribbageSeatPlateView: View {
    let name: String
    let colorIndex: Int
    let isDealer: Bool
    let isTurn: Bool
    let score: Int
    var edgeAngle: Angle = .degrees(0)

    private var color: Color { PlayerPalette.color(colorIndex) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
            Text(name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
            if isDealer {
                DealerBadge()
            }
            Text("\(score)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(CardStyle.gold)
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                   bottomTrailingRadius: 4, topTrailingRadius: 15,
                                   style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CardStyle.gold.opacity(0.55))
                        .frame(height: 2)
                        .padding(.horizontal, 3)
                }
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15,
                                           style: .continuous)
                        .strokeBorder(isTurn ? color : .white.opacity(0.08),
                                      lineWidth: isTurn ? 2.5 : 1)
                )
                .shadow(color: isTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(score) points\(isDealer ? ", dealing" : "")\(isTurn ? ", their turn" : "")")
    }

    /// Same brass dealer button as `SeatPlateView.DealerBadge`, kept as its
    /// own tiny copy rather than exposing that one across files.
    private struct DealerBadge: View {
        var body: some View {
            Circle()
                .fill(
                    RadialGradient(colors: [
                        Color(red: 0.99, green: 0.92, blue: 0.72),
                        CardStyle.gold,
                        Color(red: 0.52, green: 0.39, blue: 0.19)
                    ], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 13)
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.5), lineWidth: 3)
                        .blur(radius: 1.5)
                        .clipShape(Circle())
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                .overlay(
                    Text("D")
                        .font(.system(size: 11, weight: .black, design: .serif))
                        .foregroundStyle(CardStyle.ink)
                        .shadow(color: .white.opacity(0.35), radius: 0, x: 0, y: 0.7)
                )
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
        }
    }
}
