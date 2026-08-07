import SwiftUI

/// End-of-game overlay: totals written out like a scorekeeper's tally, the
/// winner's line circled in their own pencil color (or every co-leader's
/// line, on a tie), then Play Again / Close.
struct DotsAndBoxesScoreboardView: View {
    let players: [DotsAndBoxesPlayer]
    let winners: [Int]
    var onPlayAgain: () -> Void
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var motionReduced

    private var headline: String {
        guard let firstWinner = winners.first, players.indices.contains(firstWinner) else { return "Game Over" }
        return winners.count > 1 ? "It's a Tie!" : "\(players[firstWinner].name) Wins!"
    }

    private var headlineColor: Color {
        guard winners.count == 1, let w = winners.first, players.indices.contains(w) else { return CardStyle.gold }
        return DotsAndBoxesTheme.pencilColor(for: players[w].colorIndex)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(spacing: 24) {
                Text(headline)
                    .font(.custom(DotsAndBoxesTheme.handwritingFont, size: 42))
                    .foregroundStyle(headlineColor)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                tally

                HStack(spacing: 20) {
                    Button("Close", action: onClose)
                        .font(.system(.body, design: .serif).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))

                    Button(action: onPlayAgain) {
                        Text("Play Again")
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .frame(maxWidth: 200)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                }
            }
            .padding(32)
        }
        .transition(motionReduced ? .opacity : .scale.combined(with: .opacity))
    }

    /// Player rows written on a torn scrap of the same paper stock, the
    /// winning row(s) circled in their pencil color — a scorekeeper's
    /// final tally, not a UI leaderboard.
    private var tally: some View {
        VStack(spacing: 14) {
            ForEach(sortedIndices, id: \.self) { i in
                HStack {
                    Text(players[i].name)
                    Spacer()
                    Text("\(players[i].score)")
                        .fontWeight(.bold)
                }
                .font(.custom(DotsAndBoxesTheme.handwritingFont, size: 26))
                .foregroundStyle(winners.contains(i)
                                  ? DotsAndBoxesTheme.pencilColor(for: players[i].colorIndex)
                                  : DotsAndBoxesTheme.inkFaded)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    winners.contains(i)
                        ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(DotsAndBoxesTheme.pencilColor(for: players[i].colorIndex), lineWidth: 2.5)
                            .rotationEffect(.degrees(Double(PencilJitter.unit(i, 5)) * 3 - 1.5))
                        : nil
                )
            }
        }
        .padding(24)
        .frame(minWidth: 260)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DotsAndBoxesTheme.paperBase))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .rotationEffect(.degrees(-0.6))
    }

    /// Highest score first — the tally reads top-to-bottom like a real
    /// scorekeeper's sheet, not in seating order.
    private var sortedIndices: [Int] {
        players.indices.sorted { players[$0].score > players[$1].score }
    }
}
