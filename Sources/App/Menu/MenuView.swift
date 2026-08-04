import SwiftUI

/// The iPad home screen: the felt stage before a game exists. Resume strip
/// up top when there's something to pick back up, then the game picker,
/// the live seat builder, house rules, and the deal.
struct MenuView: View {
    @Bindable var host: GameHostController

    @State private var selectedGame: GameKind = .wizard
    /// Dice mode (L·R·C) selected in the picker. Dice games live outside
    /// GameKind — this flag trumps `selectedGame` while set.
    @State private var diceSelected = false
    @State private var rules = RulesConfig()
    @State private var botDrafts: [BotSeatDraft] = []
    @State private var savedGames: [SavedGame] = []
    @State private var showSettings = false

    /// Sim-verify hook: -autoStart deals free play as soon as anyone sits.
    private var autoStarts: Bool { CommandLine.arguments.contains("-autoStart") }

    /// LCR seat window; also .wizard's, which is why the seats builder
    /// gets .wizard for its limits while dice mode is selected.
    private static let diceSeatRange = 3...6

    private var totalSeats: Int { host.lobbyPlayers.count + botDrafts.count }
    private var canStart: Bool {
        if diceSelected { return Self.diceSeatRange.contains(totalSeats) }
        return totalSeats >= selectedGame.minPlayers && totalSeats <= selectedGame.maxPlayers
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

                    // Dice games use the same seats builder; .wizard shares
                    // LCR's 3–6 seat window, so its limits stand in.
                    SeatsBuilderView(host: host, game: diceSelected ? .wizard : selectedGame,
                                     botDrafts: $botDrafts)

                    if !diceSelected && selectedGame.hasHouseRules {
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
        .onChange(of: diceSelected) { _, isDice in
            guard isDice else { return }
            let allowed = max(0, Self.diceSeatRange.upperBound - host.lobbyPlayers.count)
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
            // Sim-verify hook: an all-bot L·R·C game — dice physics on film.
            if CommandLine.arguments.contains("-autoStartLcr"),
               DiceLauncher.shared.controller == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                DiceLauncher.shared.start(host: host, seats: bots)
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
                GameChip(kind: kind, isSelected: !diceSelected && selectedGame == kind) {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        diceSelected = false
                        selectedGame = kind
                    }
                }
            }
            DiceGameChip(isSelected: diceSelected) {
                Haptics.tick()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    diceSelected = true
                }
            }
        }
    }

    // MARK: deal

    private var dealButton: some View {
        Button {
            if diceSelected { rollTheDice() } else { dealTheCards() }
        } label: {
            Text(canStart ? (diceSelected ? "Roll the dice" : "Deal the cards") : neededLabel)
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
        let minSeats = diceSelected ? Self.diceSeatRange.lowerBound : selectedGame.minPlayers
        let need = minSeats - totalSeats
        let gameName = diceSelected ? "L·R·C" : selectedGame.displayName
        return need > 0 ? "Waiting for \(need) more…" : "Too many for \(gameName)"
    }

    /// One shared seat list for cards and dice: humans in lobby order,
    /// then the drafted bots.
    private var seatSpecs: [SeatSpec] {
        let humans = host.lobbyPlayers.enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: false)
        }
        let bots = botDrafts.enumerated().map {
            SeatSpec(id: humans.count + $0.offset, name: $0.element.name, isBot: true)
        }
        return humans + bots
    }

    private func dealTheCards() {
        Haptics.arm()
        host.startGame(kind: selectedGame, rules: rules, seats: seatSpecs)
        botDrafts = []
    }

    /// Dice mode never touches the card engine: DiceLauncher spins up a
    /// DiceGameController and TableRootView switches to DiceTableView on
    /// `DiceLauncher.shared.controller != nil` (host.state stays nil).
    private func rollTheDice() {
        Haptics.arm()
        DiceLauncher.shared.start(host: host, seats: seatSpecs)
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

/// The first dice game: Left-Right-Center. Same silhouette as GameChip,
/// but dice games live outside GameKind so it carries its own selection.
private struct DiceGameChip: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text("🎲")
                    .font(.system(size: 30))
                Text("L·R·C")
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
