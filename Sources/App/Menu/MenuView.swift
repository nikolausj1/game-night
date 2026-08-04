import SwiftUI

/// The iPad home screen: the felt stage before a game exists. Resume strip
/// up top when there's something to pick back up, then the game picker,
/// the live seat builder, house rules, and the deal.
struct MenuView: View {
    @Bindable var host: GameHostController

    @State private var selectedGame: GameKind = .wizard
    @State private var rules = RulesConfig()
    @State private var botDrafts: [BotSeatDraft] = []
    @State private var savedGames: [SavedGame] = []
    @State private var showSettings = false

    /// Sim-verify hook: -autoStart deals free play as soon as anyone sits.
    private var autoStarts: Bool { CommandLine.arguments.contains("-autoStart") }

    private var totalSeats: Int { host.lobbyPlayers.count + botDrafts.count }
    private var canStart: Bool {
        totalSeats >= selectedGame.minPlayers && totalSeats <= selectedGame.maxPlayers
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 26) {
                    if !savedGames.isEmpty {
                        ResumeStripView(games: savedGames, onResume: resume, onDelete: delete)
                            .padding(.horizontal, 30)
                    }

                    masthead

                    gamePicker

                    SeatsBuilderView(host: host, game: selectedGame, botDrafts: $botDrafts)

                    if selectedGame.hasHouseRules {
                        RulesPanelView(game: selectedGame, rules: $rules)
                            .frame(maxWidth: 480)
                            .padding(.horizontal, 40)
                    }

                    dealButton
                        .padding(.bottom, 24)
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
            }
            settingsGear
        }
        .onAppear { refreshSavedGames() }
        .onChange(of: selectedGame) { _, newGame in
            let allowed = max(0, newGame.maxPlayers - host.lobbyPlayers.count)
            if botDrafts.count > allowed {
                botDrafts.removeLast(botDrafts.count - allowed)
            }
        }
        .onChange(of: host.lobbyPlayers.count) { _, count in
            guard autoStarts, count >= 1 else { return }
            let seats = host.lobbyPlayers.enumerated().map {
                SeatSpec(id: $0.offset, name: $0.element.name, isBot: false)
            }
            host.startGame(kind: .freePlay, rules: rules, seats: seats)
        }
        .onAppear {
            // Sim-verify hook: an all-bot UNO game that plays itself.
            if CommandLine.arguments.contains("-autoStartUno"), host.state == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                host.startGame(kind: .uno, rules: RulesConfig(), seats: bots)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: masthead

    private var masthead: some View {
        VStack(spacing: 4) {
            Text("Game Night")
                .font(.system(size: 54, weight: .bold, design: .serif))
                .foregroundStyle(CardStyle.stockTop)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text("Open Game Night on your phone to take a seat")
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
        }
    }

    private var settingsGear: some View {
        Button {
            Haptics.tick()
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(CardStyle.stockTop.opacity(0.5))
                .padding(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: game picker

    private var gamePicker: some View {
        HStack(spacing: 14) {
            ForEach(GameKind.allCases, id: \.self) { kind in
                GameChip(kind: kind, isSelected: selectedGame == kind) {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedGame = kind }
                }
            }
            DiceComingSoonChip()
        }
    }

    // MARK: deal

    private var dealButton: some View {
        Button {
            dealTheCards()
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

    private var neededLabel: String {
        let need = selectedGame.minPlayers - totalSeats
        return need > 0 ? "Waiting for \(need) more…" : "Too many for \(selectedGame.displayName)"
    }

    private func dealTheCards() {
        let humans = host.lobbyPlayers.enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: false)
        }
        let bots = botDrafts.enumerated().map {
            SeatSpec(id: humans.count + $0.offset, name: $0.element.name, isBot: true)
        }
        Haptics.arm()
        host.startGame(kind: selectedGame, rules: rules, seats: humans + bots)
        botDrafts = []
    }

    // MARK: resume strip plumbing

    private func refreshSavedGames() {
        savedGames = GameStateStore.list()
    }

    private func resume(_ saved: SavedGame) {
        saved.resume(into: host)
        refreshSavedGames()
    }

    private func delete(_ saved: SavedGame) {
        GameStateStore.delete(saved)
        refreshSavedGames()
    }
}

// MARK: - Game picker chips

private struct GameChip: View {
    let kind: GameKind
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(kind.emblem)
                    .font(.system(size: 30))
                Text(kind.displayName)
                    .font(.system(.headline, design: .serif))
            }
            .foregroundStyle(isSelected ? CardStyle.ink : CardStyle.stockTop)
            .frame(width: 130, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? CardStyle.gold : .white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }
}

/// The Dice game doesn't exist yet — the card is here so the picker reads
/// as a roster with more coming, not a finished set.
private struct DiceComingSoonChip: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("🎲")
                .font(.system(size: 30))
            Text("Dice")
                .font(.system(.headline, design: .serif))
            Text("coming soon")
                .font(.system(size: 10, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.55))
        }
        .foregroundStyle(CardStyle.stockTop.opacity(0.35))
        .frame(width: 130, height: 88)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(CardStyle.stockTop.opacity(0.18),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
        )
    }
}

extension GameKind {
    var emblem: String {
        switch self {
        case .wizard: return "🧙"
        case .ohHell: return "♠️"
        case .crazyEights: return "8️⃣"
        case .uno: return "🌈"
        case .freePlay: return "🃏"
        }
    }

    /// Free Play has no legality/bidding rules to expose.
    var hasHouseRules: Bool { self != .freePlay }
}
