import SwiftUI

/// Pre-game overlay: two names and a human/bot switch per seat. Parchment-on-
/// felt frame shared with Quarto and the card games (`ScorecardPanel`).
struct MancalaSetupView: View {
    var onStart: (_ names: [String], _ bots: [Bool]) -> Void

    @State private var nameOne = "Player 1"
    @State private var nameTwo = "Player 2"
    @State private var oneIsBot = false
    @State private var twoIsBot = true

    var body: some View {
        ScorecardPanel(title: "Mancala") {
            Text("Sow your pits round the board. End in your store to go again.")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
                .multilineTextAlignment(.center)
            row(seat: "Near side", name: $nameOne, isBot: $oneIsBot, placeholder: "Player 1")
            row(seat: "Far side", name: $nameTwo, isBot: $twoIsBot, placeholder: "Player 2")
        } action: {
            Button {
                Haptics.arm()
                onStart([nameOne.trimmed.isEmpty ? "Player 1" : nameOne,
                         nameTwo.trimmed.isEmpty ? "Player 2" : nameTwo],
                        [oneIsBot, twoIsBot])
            } label: {
                Text("Begin")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }

    private func row(seat: String, name: Binding<String>, isBot: Binding<Bool>, placeholder: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(seat)
                    .font(.system(.caption2, design: .serif).smallCaps())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.55))
                TextField(placeholder, text: name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .serif))
                    .frame(maxWidth: 220)
            }
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

#Preview("Mancala setup") {
    ZStack {
        CardStyle.feltGreen.ignoresSafeArea()
        MancalaSetupView(onStart: { _, _ in })
    }
}
