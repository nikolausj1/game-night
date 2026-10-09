import SwiftUI

/// Pre-game overlay: names and a human/bot switch per colour. Red sits on
/// the near side and moves first.
struct CheckersSetupView: View {
    var onStart: (_ names: [String], _ bots: [Bool]) -> Void

    @State private var nameOne = "Player 1"
    @State private var nameTwo = "Player 2"
    @State private var oneIsBot = false
    @State private var twoIsBot = true

    var body: some View {
        ScorecardPanel(title: "Checkers") {
            Text("Jump to capture. Reach the far row to be crowned. Captures are compulsory.")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
                .multilineTextAlignment(.center)
            row(owner: 0, name: $nameOne, isBot: $oneIsBot, placeholder: "Player 1")
            row(owner: 1, name: $nameTwo, isBot: $twoIsBot, placeholder: "Player 2")
        } action: {
            Button {
                Haptics.arm()
                onStart([nameOne.trimmed.isEmpty ? "Player 1" : nameOne,
                         nameTwo.trimmed.isEmpty ? "Player 2" : nameTwo],
                        [oneIsBot, twoIsBot])
            } label: {
                Text("Set up the board")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }

    private func row(owner: Int, name: Binding<String>, isBot: Binding<Bool>, placeholder: String) -> some View {
        HStack(spacing: 14) {
            Image(owner == 0 ? "CheckerRed" : "CheckerBlack")
                .resizable().scaledToFit().frame(width: 34, height: 34)
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

#Preview("Checkers setup") {
    ZStack {
        CardStyle.feltGreen.ignoresSafeArea()
        CheckersSetupView(onStart: { _, _ in })
    }
}
