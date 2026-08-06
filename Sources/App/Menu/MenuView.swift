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
        ZStack {
            // The felt behind an empty lobby shouldn't read as a void — a
            // faint deck-and-seats motif underneath the real UI.
            attractBackdrop
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

                quickActionsRow
                    .padding(.bottom, 24)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            }
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
        .onChange(of: host.lobbyPlayers.count) { _, count in
            // Sim-verify hook: -autoStartLcrRemote waits for the first
            // PHONE to join, then starts L·R·C with that phone as the
            // human seat 0 (+2 bots) — exercises the remote pour → table
            // roll pipeline end to end.
            guard CommandLine.arguments.contains("-autoStartLcrRemote"),
                  DiceLauncher.shared.controller == nil, count >= 1 else { return }
            var seats = host.lobbyPlayers.enumerated().map {
                SeatSpec(id: $0.offset, name: $0.element.name, isBot: false)
            }
            for bot in BotRoster.random(count: 2) {
                seats.append(SeatSpec(id: seats.count, name: bot.name, isBot: true))
            }
            DiceLauncher.shared.start(host: host, seats: seats)
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
            // Sim-verify hook: L·R·C with a phoneless HUMAN in seat 0
            // (tap the plate to roll) — exercises the pending-coin drags.
            if CommandLine.arguments.contains("-autoStartLcrHuman"),
               DiceLauncher.shared.controller == nil {
                var seats = [SeatSpec(id: 0, name: "You", isBot: false)]
                for (index, bot) in BotRoster.random(count: 2).enumerated() {
                    seats.append(SeatSpec(id: index + 1, name: bot.name, isBot: true))
                }
                DiceLauncher.shared.start(host: host, seats: seats)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: attract backdrop

    /// A faint deck-and-seats motif behind the lobby UI, low-opacity enough
    /// to never compete with the real controls on top — the empty felt
    /// reads as a table that's already set, not blank cloth. Built from
    /// `CardBackView` (this module's plain card back, already used above in
    /// `FannedBacks`) rather than `DeckAndTrumpView`'s draw-pile stack: that
    /// view is driven by a live `GameState` (draw pile count, game kind,
    /// round…) the lobby doesn't have one of yet, and standing up a
    /// throwaway `GameState` purely to paint an idle deck would reach
    /// further into the engine than a cosmetic backdrop warrants. Its own
    /// riffle-shuffle flourish only fires on a real draw-pile reshuffle
    /// anyway, so there's nothing to gain by forcing the dependency.
    private var attractBackdrop: some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                    ForEach(0..<3, id: \.self) { layer in
                        CardBackView()
                            .frame(width: 150)
                            .rotationEffect(.degrees(Double(layer) * 2.2 - 2.2))
                            .offset(x: CGFloat(layer) * 3, y: CGFloat(layer) * -3)
                    }
                }
                .compositingGroup()
                .opacity(0.16)
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.88)

                // Faint open-seat markers — chairs pulled up to a table
                // that's ready and waiting, echoing SeatsBuilderView's own
                // dashed "Open seat" circle language.
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(CardStyle.stockTop.opacity(0.14),
                                      style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                        .frame(width: 46, height: 46)
                        .position(seatMarkerPosition(index: i, size: geo.size))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func seatMarkerPosition(index: Int, size: CGSize) -> CGPoint {
        let points: [CGPoint] = [
            CGPoint(x: 0.06, y: 0.5),
            CGPoint(x: 0.94, y: 0.5),
            CGPoint(x: 0.5, y: 0.05),
            CGPoint(x: 0.5, y: 0.97)
        ]
        let p = points[index % points.count]
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    // MARK: masthead

    private var masthead: some View {
        VStack(spacing: 4) {
            Text("Game Night")
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text("Open Game Night on your phone to take a seat")
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
        }
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

    /// Two entirely different looks, not one button toggling `.disabled`:
    /// a real gold CTA when the table can start, and — while waiting — a
    /// plain informational pill in the same gold-on-dark serif language as
    /// the House Rules chip. SwiftUI's stock `.disabled()` styling desaturates
    /// `.borderedProminent`'s tint to system gray regardless of what tint
    /// you set, which is exactly the low-contrast look this replaces.
    @ViewBuilder
    private var dealButton: some View {
        if canStart {
            Button {
                if diceSelected { rollTheDice() } else { dealTheCards() }
            } label: {
                Text(diceSelected ? "Roll the dice" : "Deal the cards")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 44)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        } else {
            Text(neededLabel)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.22))
                        .overlay(
                            Capsule().strokeBorder(CardStyle.gold.opacity(0.25), lineWidth: 1)
                        )
                )
        }
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

    // MARK: quick actions

    /// Compact convenience row under the deal button: jump back into the
    /// last game, hop straight to Settings, or one-tap start one of the two
    /// game kinds played most recently — no picker, no seat builder.
    private var quickActionsRow: some View {
        HStack(spacing: 10) {
            if let mostRecent = savedGames.first {
                QuickActionChip(title: "Resume Last", systemImage: "arrow.uturn.backward") {
                    Haptics.tick()
                    resume(mostRecent)
                }
            }
            ForEach(quickStartCandidates) { saved in
                QuickActionChip(title: saved.gameKind.displayName, systemImage: "bolt.fill") {
                    quickStart(saved)
                }
            }
            QuickActionChip(title: "Settings", systemImage: "gearshape") {
                Haptics.tick()
                showSettings = true
            }
        }
    }

    /// The two most recently played DISTINCT game kinds, drawn from the same
    /// save history the resume strip already shows (already capped at the
    /// last 3 by `GameStateStore.list()`) — no extra bookkeeping needed.
    private var quickStartCandidates: [SavedGame] {
        var seenKinds = Set<GameKind>()
        var result: [SavedGame] = []
        for saved in savedGames {
            guard seenKinds.insert(saved.gameKind).inserted else { continue }
            result.append(saved)
            if result.count == 2 { break }
        }
        return result
    }

    /// Starts a fresh game of `saved`'s kind using its last-used seat setup:
    /// human slots filled from whoever's connected in the lobby right now
    /// (in lobby order, same as the normal deal path), and the exact bots it
    /// had, re-drafted by name so their color/identity match again.
    private func quickStart(_ saved: SavedGame) {
        Haptics.arm()
        let humanSlots = saved.seats.filter { !$0.isBot }.count
        let humans = host.lobbyPlayers.prefix(humanSlots).enumerated().map { index, player in
            SeatSpec(id: index, name: player.name, isBot: false)
        }
        let bots = saved.seats.filter(\.isBot).enumerated().map { index, spec in
            SeatSpec(id: humans.count + index, name: spec.name, isBot: true)
        }
        host.startGame(kind: saved.gameKind, rules: RulesConfig(), seats: Array(humans) + bots)
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

/// One pill in the quick-actions row: felt/serif/gold, matching the game
/// chips above — a compact affordance, not a redesign.
private struct QuickActionChip: View {
    let title: String
    let systemImage: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label(title, systemImage: systemImage)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .overlay(
                            Capsule().strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
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
                GameEmblem(kind: kind)
                    .frame(height: GameEmblem.height)
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
        // The emblem underneath is real miniature card art (nested Text
        // glyphs for rank/suit) — without this, VoiceOver reads every one
        // of those instead of one clean "Wizard, selected" chip label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                MiniDiceTrio()
                    .frame(height: GameEmblem.height)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Left, Right, Center")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension GameKind {
    /// Free Play has no legality/bidding rules to expose.
    var hasHouseRules: Bool { self != .freePlay }

    /// Still used by `ResumeStripView`'s compact resume cards — the game
    /// picker itself has moved on to real card-art emblems (`GameEmblem`
    /// below), but the resume strip's tighter layout keeps the emoji mark.
    var emblem: String {
        switch self {
        case .wizard: return "🧙"
        case .ohHell: return "♠️"
        case .crazyEights: return "8️⃣"
        case .uno: return "🌈"
        case .freePlay: return "🃏"
        }
    }
}

// MARK: - Chip emblems (real card/dice art, not emoji)

/// Miniature art for each game chip, built from the app's own card views —
/// tiny, unmistakable, and consistent with the felt everyone actually plays
/// on, instead of an emoji standing in for it. Not private: `ResumeStripView`
/// reuses it too, so a suspended game's resume card shows the same brass/
/// card-art mark as the picker instead of a raw emoji glyph.
struct GameEmblem: View {
    /// Common target height for every chip's emblem, card or dice.
    static let height: CGFloat = 34

    let kind: GameKind

    var body: some View {
        switch kind {
        case .wizard:
            // A wizard card fanned against a heart ace — the two things
            // that make Wizard Wizard: the special card and trump suit.
            FannedPair(height: Self.height,
                       leftCard: Card(id: "W0", kind: .wizard),
                       rightCard: Card(id: "h14", kind: .standard(suit: .hearts, rank: 14)))
        case .ohHell:
            CardView(card: Card(id: "s14", kind: .standard(suit: .spades, rank: 14)))
                .frame(height: Self.height)
        case .crazyEights:
            CardView(card: Card(id: "c8", kind: .standard(suit: .clubs, rank: 8)))
                .frame(height: Self.height)
        case .uno:
            UnoCardBackView()
                .frame(height: Self.height)
        case .freePlay:
            // A loose spread of backs: no fixed rules, just cards on felt.
            FannedBacks(height: Self.height)
        }
    }
}

/// Two mini card faces fanned in a shallow V, center-anchored — the
/// wizard chip's wizard + heart-ace pair.
private struct FannedPair: View {
    let height: CGFloat
    let leftCard: Card
    let rightCard: Card

    var body: some View {
        ZStack {
            CardView(card: leftCard)
                .frame(height: height)
                .rotationEffect(.degrees(-9))
                .offset(x: -height * 0.16)
            CardView(card: rightCard)
                .frame(height: height)
                .rotationEffect(.degrees(9))
                .offset(x: height * 0.16)
        }
    }
}

/// Three mini card backs spread in a shallow fan — Free Play's chip art:
/// no fixed rules, just loose cards on felt.
private struct FannedBacks: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            CardBackView()
                .frame(height: height)
                .rotationEffect(.degrees(-12))
                .offset(x: -height * 0.18)
            CardBackView()
                .frame(height: height)
            CardBackView()
                .frame(height: height)
                .rotationEffect(.degrees(12))
                .offset(x: height * 0.18)
        }
    }
}

/// L·R·C's chip art: three tiny dice faces, drawn as rounded squares with
/// letter pips — the game's whole identity is "roll an L, R, or C".
private struct MiniDiceTrio: View {
    var body: some View {
        HStack(spacing: 3) {
            MiniDieFace(label: "L")
            MiniDieFace(label: "R")
            MiniDieFace(label: "C")
        }
    }
}

private struct MiniDieFace: View {
    let label: String
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [CardStyle.stockTop, CardStyle.stockBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(CardStyle.ink.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                Text(label)
                    .font(.system(size: size * 0.52, weight: .heavy, design: .rounded))
                    .foregroundStyle(CardStyle.crimson)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}
