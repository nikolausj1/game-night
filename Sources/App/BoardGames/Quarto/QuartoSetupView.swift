import SwiftUI

/// The pre-game overlay: two names, a human/bot toggle per seat, and the
/// 2x2-squares house-rule toggle (off by default — standard Quarto only
/// counts rows/columns/diagonals). Reuses `ScorecardPanel` (RecapOverlays.swift)
/// for the parchment-on-felt frame so this reads as part of the same game
/// family as the card games' round-recap panels, not a bespoke dialog.
struct QuartoSetupView: View {
    var onStart: (_ playerOneName: String, _ playerTwoName: String,
                 _ playerOneIsBot: Bool, _ playerTwoIsBot: Bool, _ use2x2Variant: Bool) -> Void

    @State private var nameOne = "Player 1"
    @State private var nameTwo = "Player 2"
    @State private var oneIsBot = false
    @State private var twoIsBot = true
    @State private var use2x2Variant = false

    var body: some View {
        ScorecardPanel(title: "Quarto") {
            playerRow(name: $nameOne, isBot: $oneIsBot, placeholder: "Player 1")
            playerRow(name: $nameTwo, isBot: $twoIsBot, placeholder: "Player 2")
            Toggle(isOn: $use2x2Variant) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("2x2 squares also win")
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                    Text("Advanced variant — any four adjacent cells in a square count too")
                        .font(.caption)
                        .foregroundStyle(CardStyle.stockTop.opacity(0.6))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: CardStyle.gold))
            .foregroundStyle(CardStyle.stockTop)
            .padding(.top, 4)
        } action: {
            Button {
                Haptics.arm()
                onStart(nameOne.trimmed.isEmpty ? "Player 1" : nameOne,
                       nameTwo.trimmed.isEmpty ? "Player 2" : nameTwo,
                       oneIsBot, twoIsBot, use2x2Variant)
            } label: {
                Text("Deal in")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }

    private func playerRow(name: Binding<String>, isBot: Binding<Bool>, placeholder: String) -> some View {
        HStack(spacing: 14) {
            TextField(placeholder, text: name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .serif))
                .frame(maxWidth: 220)
            Spacer(minLength: 8)
            Toggle(isOn: isBot) {
                Text("Bot")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop)
            }
            .toggleStyle(SwitchToggleStyle(tint: CardStyle.gold))
            .fixedSize()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview("Quarto setup") {
    ZStack {
        CardStyle.feltGreen.ignoresSafeArea()
        QuartoSetupView(onStart: { _, _, _, _, _ in })
    }
}
