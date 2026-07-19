import SwiftUI
import CoreImage.CIFilterBuiltins

/// The table before the deal: seats fill in live as phones arrive.
struct TableLobbyView: View {
    @Bindable var host: GameHostController

    @State private var selectedGame: GameKind = .wizard
    @State private var rules = RulesConfig()

    private var canStart: Bool {
        host.lobbyPlayers.count >= selectedGame.minPlayers &&
        host.lobbyPlayers.count <= selectedGame.maxPlayers
    }

    /// Sim-verify hook: -autoStart deals free play as soon as anyone sits.
    private var autoStarts: Bool { CommandLine.arguments.contains("-autoStart") }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 4) {
                Text("Game Night")
                    .font(.system(size: 54, weight: .bold, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                Text("Open Game Night on your phone to take a seat")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
            }

            gamePicker

            seatRow

            Button {
                host.startGame(kind: selectedGame, rules: rules)
            } label: {
                Text(canStart ? "Deal the cards" : neededLabel)
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 44)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
            .disabled(!canStart)
            .animation(.easeInOut(duration: 0.2), value: canStart)
        }
        .padding(40)
        .onChange(of: host.lobbyPlayers.count) { _, count in
            if autoStarts, count >= 1 {
                host.startGame(kind: .freePlay, rules: rules)
            }
        }
    }

    private var neededLabel: String {
        let need = selectedGame.minPlayers - host.lobbyPlayers.count
        return need > 0 ? "Waiting for \(need) more…" : "Too many for \(selectedGame.displayName)"
    }

    private var gamePicker: some View {
        HStack(spacing: 14) {
            ForEach(GameKind.allCases, id: \.self) { kind in
                Button {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedGame = kind }
                } label: {
                    VStack(spacing: 6) {
                        Text(kind.emblem)
                            .font(.system(size: 30))
                        Text(kind.displayName)
                            .font(.system(.headline, design: .serif))
                    }
                    .foregroundStyle(selectedGame == kind ? CardStyle.ink : CardStyle.stockTop)
                    .frame(width: 130, height: 88)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selectedGame == kind ? CardStyle.gold : .white.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var seatRow: some View {
        HStack(spacing: 20) {
            ForEach(0..<max(host.lobbyPlayers.count, selectedGame.minPlayers), id: \.self) { index in
                if index < host.lobbyPlayers.count {
                    FilledSeat(name: host.lobbyPlayers[index].name, colorIndex: index)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    EmptySeat()
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: host.lobbyPlayers.count)
    }
}

struct FilledSeat: View {
    let name: String
    let colorIndex: Int

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(PlayerPalette.color(colorIndex))
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(.title, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
            }
            Text(name)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CardStyle.stockTop)
        }
    }
}

struct EmptySeat: View {
    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(CardStyle.stockTop.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .frame(width: 64, height: 64)
            Text("Open seat")
                .font(.subheadline)
                .foregroundStyle(CardStyle.stockTop.opacity(0.4))
        }
    }
}

/// Fixed player colors, one voice for plates, seats, and score rows.
enum PlayerPalette {
    private static let colors: [Color] = [
        Color(red: 0.75, green: 0.29, blue: 0.24), // brick
        Color(red: 0.24, green: 0.44, blue: 0.66), // lake
        Color(red: 0.80, green: 0.58, blue: 0.22), // amber
        Color(red: 0.42, green: 0.32, blue: 0.58), // plum
        Color(red: 0.30, green: 0.55, blue: 0.42), // pine
        Color(red: 0.72, green: 0.42, blue: 0.55), // rose
        Color(red: 0.45, green: 0.50, blue: 0.55), // slate
        Color(red: 0.60, green: 0.46, blue: 0.32), // saddle
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

extension GameKind {
    var emblem: String {
        switch self {
        case .wizard: return "🧙"
        case .ohHell: return "♠️"
        case .crazyEights: return "8️⃣"
        case .freePlay: return "🃏"
        }
    }
}
