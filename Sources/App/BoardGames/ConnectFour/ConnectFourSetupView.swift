import SwiftUI

/// Pre-game overlay: names and a human/bot switch per colour.
struct ConnectFourSetupView: View {
    var onStart: (_ names: [String], _ bots: [Bool]) -> Void

    @State private var nameOne = "Player 1"
    @State private var nameTwo = "Player 2"
    @State private var oneIsBot = false
    @State private var twoIsBot = true

    var body: some View {
        ScorecardPanel(title: "Connect Four") {
            Text("Slide to aim, let go to drop. First to line up four wins.")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
                .multilineTextAlignment(.center)
            row(seat: 0, name: $nameOne, isBot: $oneIsBot, placeholder: "Player 1")
            row(seat: 1, name: $nameTwo, isBot: $twoIsBot, placeholder: "Player 2")
        } action: {
            Button {
                Haptics.arm()
                onStart([nameOne.trimmed.isEmpty ? "Player 1" : nameOne,
                         nameTwo.trimmed.isEmpty ? "Player 2" : nameTwo],
                        [oneIsBot, twoIsBot])
            } label: {
                Text("Drop in")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }

    private func row(seat: Int, name: Binding<String>, isBot: Binding<Bool>, placeholder: String) -> some View {
        HStack(spacing: 14) {
            Image(seat == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                .resizable().frame(width: 30, height: 30)
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

#Preview("Connect Four setup") {
    ZStack {
        CardStyle.feltGreen.ignoresSafeArea()
        ConnectFourSetupView(onStart: { _, _ in })
    }
}
