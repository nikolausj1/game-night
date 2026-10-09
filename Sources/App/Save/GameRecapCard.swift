import SwiftUI

/// One line of a game-over recap: a seat (or a team), what they finished
/// with, and an optional aside. `id` is the seat index.
struct RecapRow: Identifiable, Equatable {
    var id: Int
    var name: String
    /// `PlayerPalette` index for the seat dot; nil draws no dot (solo games).
    var colorIndex: Int? = nil
    /// The number (or short phrase) in the right column: "231", "7 books".
    var score: String
    /// Small italic aside under the name: "shut the box", "3 dice left".
    var detail: String? = nil
    var isWinner: Bool = false
}

/// The one game-over card every non-engine game shows. Same visual
/// language as the card games' `GameOverOverlay` (felt-dark panel, brass
/// rules, serif numerals, a crown on the winner) so the night feels like
/// one app whether it ended on Hearts or on Go Fish — but written here, in
/// its own file, so the trick-taking recaps and this one can evolve apart.
///
/// REMATCH is uniform across the app: same seats, fresh seed, no trip
/// through the lobby. DONE ends the game and returns to the menu through
/// whatever `onClose` the mounting view already had.
///
/// `kidMode` is for the kids' pack: bigger type, fewer words, "Again!"
/// instead of "Rematch". Reduce Motion drops the entrance spring.
struct GameRecapCard: View {
    let title: String
    var rows: [RecapRow]
    /// The one-line "moment": "Hank shut the box", "21 on the first two cards".
    var highlight: String? = nil
    var kidMode = false
    /// nil hides the rematch button (a game with nothing to rematch).
    var rematchLabel: String? = "Rematch"
    var doneLabel = "Done"
    var onRematch: (() -> Void)? = nil
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            // A soft scrim so the recap owns the moment and stray taps on
            // the felt underneath don't land in a finished game.
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            card
                .scaleEffect(shown ? 1 : 0.92)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { shown = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Game over. \(title)")
    }

    private var card: some View {
        VStack(spacing: kidMode ? 26 : 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(kidMode
                          ? .system(size: 54, weight: .bold, design: .serif)
                          : .system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                if let highlight, !highlight.isEmpty {
                    Text(highlight)
                        .font(kidMode
                              ? .system(size: 26, design: .serif).italic()
                              : .system(.title3, design: .serif).italic())
                        .foregroundStyle(CardStyle.gold)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }

            if !rows.isEmpty {
                VStack(spacing: 0) {
                    BrassRule()
                    ForEach(rows) { row in
                        recapRow(row)
                        BrassRule()
                    }
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 14) {
                if let rematchLabel, let onRematch {
                    Button {
                        Haptics.arm()
                        onRematch()
                    } label: {
                        Text(kidMode && rematchLabel == "Rematch" ? "Again!" : rematchLabel)
                            .font(kidMode ? .system(size: 30, weight: .bold, design: .serif) : .title3.weight(.bold))
                            .padding(.horizontal, kidMode ? 40 : 30)
                            .padding(.vertical, kidMode ? 18 : 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                    .accessibilityLabel("\(rematchLabel), same players, new game")
                }
                Button {
                    Haptics.tick()
                    onDone()
                } label: {
                    Text(doneLabel)
                        .font(kidMode ? .system(size: 26, weight: .semibold, design: .serif) : .title3.weight(.semibold))
                        .padding(.horizontal, kidMode ? 30 : 22)
                        .padding(.vertical, kidMode ? 18 : 12)
                }
                .buttonStyle(.bordered)
                .tint(CardStyle.stockTop)
                .accessibilityLabel("\(doneLabel), back to the menu")
            }
        }
        .padding(kidMode ? 40 : 36)
        .frame(maxWidth: kidMode ? 640 : 580)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.58))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        )
    }

    private func recapRow(_ row: RecapRow) -> some View {
        HStack(spacing: kidMode ? 18 : 14) {
            ZStack {
                if row.isWinner {
                    Image(systemName: "crown.fill")
                        .font(.system(size: kidMode ? 30 : 20, weight: .semibold))
                        .foregroundStyle(CardStyle.gold)
                        .shadow(color: CardStyle.gold.opacity(0.7), radius: 8)
                } else if let colorIndex = row.colorIndex {
                    Circle()
                        .fill(PlayerPalette.color(colorIndex))
                        .frame(width: kidMode ? 18 : 12, height: kidMode ? 18 : 12)
                }
            }
            .frame(width: kidMode ? 40 : 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(kidMode
                          ? .system(size: 34, weight: row.isWinner ? .bold : .regular, design: .serif)
                          : .system(.title2, design: .serif).weight(row.isWinner ? .bold : .regular))
                    .foregroundStyle(row.isWinner ? CardStyle.gold : CardStyle.stockTop)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !kidMode, let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.subheadline, design: .serif).italic())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(row.score)
                .font(kidMode
                      ? .system(size: 38, weight: .bold, design: .serif)
                      : .system(.title2, design: .serif).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(row.isWinner ? CardStyle.gold : CardStyle.stockTop)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, kidMode ? 14 : 10)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(row))
    }

    private func rowAccessibilityLabel(_ row: RecapRow) -> String {
        var parts = [row.name, row.score]
        if let detail = row.detail, !detail.isEmpty { parts.append(detail) }
        if row.isWinner { parts.append("winner") }
        return parts.joined(separator: ", ")
    }
}

/// A one-point brass hairline: bright in the middle, fading to the ends,
/// the way an engraved rule on a scorecard catches light.
struct BrassRule: View {
    var body: some View {
        LinearGradient(colors: [CardStyle.gold.opacity(0.05), CardStyle.gold.opacity(0.55), CardStyle.gold.opacity(0.05)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

#Preview("Recap — Yahtzee") {
    ZStack {
        TableSurface()
        GameRecapCard(
            title: "Mae wins Yahtzee",
            rows: [
                RecapRow(id: 1, name: "Mae", colorIndex: 1, score: "248", detail: "two Yahtzees", isWinner: true),
                RecapRow(id: 0, name: "Hank", colorIndex: 6, score: "203", detail: "upper bonus"),
                RecapRow(id: 2, name: "Ruthie", colorIndex: 5, score: "171"),
            ],
            highlight: "Mae rolled two Yahtzees",
            onRematch: {}, onDone: {})
    }
}

#Preview("Recap — kids") {
    ZStack {
        TableSurface()
        GameRecapCard(
            title: "Vinny wins!",
            rows: [
                RecapRow(id: 1, name: "Vinny", colorIndex: 1, score: "6 books", isWinner: true),
                RecapRow(id: 0, name: "Chase", colorIndex: 0, score: "4 books"),
                RecapRow(id: 2, name: "Mae", colorIndex: 2, score: "3 books"),
            ],
            highlight: "Six books!",
            kidMode: true,
            onRematch: {}, onDone: {})
    }
}
