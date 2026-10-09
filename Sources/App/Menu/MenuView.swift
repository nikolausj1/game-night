import SwiftUI

/// The iPad home screen: the felt stage before a game exists. Resume strip
/// up top when there's something to pick back up, then three category
/// shelves of chips (Card Games, Dice Games, Board & Paper), the live seat
/// builder, house rules, and the deal.
struct MenuView: View {
    @Bindable var host: GameHostController

    /// One shelf selection across every game that goes through the
    /// seats-builder → deal-button flow (card games, dice games, Cribbage).
    /// Local games (Solitaire, Dots & Boxes, Quarto) skip this state
    /// entirely — they own their own setup screen and launch straight into
    /// a full-screen cover instead of arming the deal button; see
    /// `localGameRoute`.
    @State private var selection: MenuSelection = .card(.wizard)
    @State private var localGameRoute: LocalGameRoute?
    @State private var rules = RulesConfig()
    @State private var botDrafts: [BotSeatDraft] = []
    @State private var savedGames: [SavedGame] = []
    @State private var showSettings = false

    /// Sim-verify hook: -autoStart deals free play as soon as anyone sits.
    private var autoStarts: Bool { CommandLine.arguments.contains("-autoStart") }

    /// Shelf order for the dice-games row — L·R·C first (the original),
    /// then the three that landed alongside it tonight.
    private static let diceShelfOrder: [DiceKind] = [.lcr, .yahtzee, .zilch, .shutTheBox]

    /// Per-kind table seat window. LCR's 3–6 comes from its neighbor-passing
    /// rule (a 2-player "circle" makes no sense); Yahtzee is solitaire-
    /// friendly down to 1; Zilch and Shut the Box need at least 2 to have
    /// a turn to pass. All four cap at 6 — `TableGeometry.seatAnchors`
    /// only lays out distinct positions up to 6, same ceiling LCR always had.
    private static func diceSeatRange(for kind: DiceKind) -> ClosedRange<Int> {
        switch kind {
        case .lcr: return 3...6
        case .yahtzee: return 1...6
        case .zilch, .shutTheBox: return 2...6
        }
    }

    private var seatRange: ClosedRange<Int> {
        switch selection {
        case .card(let kind): return kind.minPlayers...kind.maxPlayers
        case .dice(let kind): return Self.diceSeatRange(for: kind)
        case .cribbage: return 2...2 // CribbageEngine is fixed 2-player.
        }
    }

    private var totalSeats: Int { host.lobbyPlayers.count + botDrafts.count }
    private var canStart: Bool { seatRange.contains(totalSeats) }

    var body: some View {
        ZStack {
            // The felt behind the lobby is a SET table: place settings, a
            // deck by the dealer, and quiet ambient life when idle. All of
            // it lives in AttractMode.swift; this is its only mount.
            LobbyStage(seats: lobbySeats, minSeats: seatRange.lowerBound,
                       capacity: seatRange.upperBound,
                       suspended: showSettings || localGameRoute != nil)
            ScrollView {
            VStack(spacing: 26) {
                if !savedGames.isEmpty {
                    ResumeStripView(games: savedGames, onResume: resume, onDelete: delete)
                        .padding(.horizontal, 30)
                }

                masthead

                gameShelves
                    .padding(.horizontal, 30)

                // One seat builder serves every launch path — see
                // `SeatsBuilderView`'s own doc comment for how `seatRange`
                // covers card games, dice games, and Cribbage's fixed pair.
                SeatsBuilderView(host: host, minPlayers: seatRange.lowerBound,
                                 maxPlayers: seatRange.upperBound, botDrafts: $botDrafts)

                if let cardKind = selection.cardKind, cardKind.hasHouseRules {
                    RulesPanelView(game: cardKind, rules: $rules)
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
        .onChange(of: selection) { _, _ in
            // Any shelf switch may shrink the seat window (a 6-player Oh
            // Hell table to Cribbage's fixed 2, say) — trim drafted bots
            // that no longer fit rather than leaving a phantom overflow
            // seat the new selection can't actually field.
            let allowed = max(0, seatRange.upperBound - host.lobbyPlayers.count)
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
            // Sim-verify hook: an all-bot Yahtzee game — solitaire dice
            // scoring on film. Mirrors -autoStartLcr's shape exactly, just
            // with `kind: .yahtzee` and gating on `game` (not `controller`,
            // which only ever unwraps the `.lcr` case) so it doesn't try to
            // stack a second game atop whichever one is already live.
            if CommandLine.arguments.contains("-autoStartYahtzee"),
               DiceLauncher.shared.game == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                DiceLauncher.shared.start(kind: .yahtzee, host: host, seats: bots)
            }
            // Sim-verify hook: an all-bot Zilch game.
            if CommandLine.arguments.contains("-autoStartZilch"),
               DiceLauncher.shared.game == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                DiceLauncher.shared.start(kind: .zilch, host: host, seats: bots)
            }
            // Sim-verify hook: an all-bot Shut the Box game.
            if CommandLine.arguments.contains("-autoStartShutBox"),
               DiceLauncher.shared.game == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                DiceLauncher.shared.start(kind: .shutTheBox, host: host, seats: bots)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $localGameRoute) { route in
            switch route {
            case .solitaire:
                SolitaireView(onClose: { localGameRoute = nil })
            case .dotsAndBoxes:
                DotsAndBoxesView(onClose: { localGameRoute = nil })
            case .quarto:
                QuartoView(onClose: { localGameRoute = nil })
            }
        }
    }

    // MARK: lobby stage feed

    /// Occupied seats for `LobbyStage`'s place settings: humans in lobby
    /// order, then drafted bots (colors matched to SeatsBuilderView's).
    private var lobbySeats: [LobbySeat] {
        let humans = host.lobbyPlayers.enumerated().map { LobbySeat(name: $0.element.name, colorIndex: $0.offset) }
        let bots = botDrafts.enumerated().map {
            LobbySeat(name: $0.element.name,
                      colorIndex: BotRoster.identity(named: $0.element.name)?.colorIndex
                        ?? (host.lobbyPlayers.count + $0.offset))
        }
        return humans + bots
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

    // MARK: game shelves

    /// Three labeled shelves in the house serif/gold voice — the owner's
    /// call over one long picker row, so 13 games read as a browsable
    /// counter (cards / dice / board-and-paper) rather than a settings
    /// list. Each shelf scrolls horizontally on its own (same pattern
    /// `ResumeStripView` already uses above), so a crowded shelf never
    /// wraps or crowds the next one.
    private var gameShelves: some View {
        VStack(alignment: .leading, spacing: 22) {
            cardGamesShelf
            diceGamesShelf
            boardAndPaperShelf
        }
    }

    /// Wizard through Free Play, in the owner's specified order, plus the
    /// two chips that aren't a `GameKind` at all: Cribbage (its own
    /// seats-builder → deal flow, just a fixed 2-seat one) and Solitaire
    /// (no seats at all — it launches straight into `localGameRoute`, with
    /// a small "Solo" badge marking it as the one card game that isn't
    /// played at the table).
    private var cardGamesShelf: some View {
        shelf(title: "Card Games") {
            GameChip(kind: .wizard, isSelected: selection == .card(.wizard)) { select(.card(.wizard)) }
            GameChip(kind: .ohHell, isSelected: selection == .card(.ohHell)) { select(.card(.ohHell)) }
            GameChip(kind: .crazyEights, isSelected: selection == .card(.crazyEights)) { select(.card(.crazyEights)) }
            GameChip(kind: .uno, isSelected: selection == .card(.uno)) { select(.card(.uno)) }
            CribbageChip(isSelected: selection == .cribbage) { select(.cribbage) }
            SolitaireChip { openLocalGame(.solitaire) }
            GameChip(kind: .freePlay, isSelected: selection == .card(.freePlay)) { select(.card(.freePlay)) }
        }
    }

    private var diceGamesShelf: some View {
        shelf(title: "Dice Games") {
            ForEach(Self.diceShelfOrder, id: \.self) { kind in
                DiceGameChip(kind: kind, isSelected: selection == .dice(kind)) { select(.dice(kind)) }
            }
        }
    }

    private var boardAndPaperShelf: some View {
        shelf(title: "Board & Paper") {
            DotsAndBoxesChip { openLocalGame(.dotsAndBoxes) }
            QuartoChip { openLocalGame(.quarto) }
        }
    }

    @ViewBuilder
    private func shelf<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.leading, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { content() }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
    }

    private func select(_ new: MenuSelection) {
        Haptics.tick()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selection = new
        }
    }

    private func openLocalGame(_ route: LocalGameRoute) {
        Haptics.tick()
        localGameRoute = route
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
                performDeal()
            } label: {
                Text(dealButtonTitle)
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

    private var dealButtonTitle: String {
        switch selection {
        case .card: return "Deal the cards"
        case .dice: return "Roll the dice"
        case .cribbage: return "Deal cribbage"
        }
    }

    private var neededLabel: String {
        let need = seatRange.lowerBound - totalSeats
        return need > 0 ? "Waiting for \(need) more…" : "Too many for \(selection.displayName)"
    }

    /// One shared seat list for cards, dice, and Cribbage: humans in lobby
    /// order, then the drafted bots.
    private var seatSpecs: [SeatSpec] {
        let humans = host.lobbyPlayers.enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: false)
        }
        let bots = botDrafts.enumerated().map {
            SeatSpec(id: humans.count + $0.offset, name: $0.element.name, isBot: true)
        }
        return humans + bots
    }

    /// Routes the deal to whichever engine the current shelf selection
    /// actually launches through — the card engine, `DiceLauncher`, or
    /// Cribbage's own `startCribbage`. All three are otherwise armed the
    /// same way (seats builder fills up, this button lights up gold).
    private func performDeal() {
        Haptics.arm()
        switch selection {
        case .card(let kind):
            host.startGame(kind: kind, rules: rules, seats: seatSpecs)
        case .dice(let kind):
            // Dice mode never touches the card engine: DiceLauncher spins
            // up the matching controller and TableRootView switches to its
            // table view on `DiceLauncher.shared.game != nil` (host.state
            // stays nil).
            DiceLauncher.shared.start(kind: kind, host: host, seats: seatSpecs)
        case .cribbage:
            host.startCribbage(seats: seatSpecs, seed: UInt64.random(in: UInt64.min...UInt64.max))
        }
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

// MARK: - Shelf selection

/// Which chip is currently armed for a deal — one selection across every
/// game that goes through the seats-builder → deal-button flow. `Equatable`
/// synthesizes for free here (declared in this file, its two payload types
/// — `GameKind` and `DiceKind` — are themselves plain case-only enums with
/// automatic `Equatable`), which is all `onChange(of: selection)` and the
/// chips' `isSelected` checks below need.
enum MenuSelection: Equatable {
    case card(GameKind)
    case dice(DiceKind)
    case cribbage

    var cardKind: GameKind? {
        if case .card(let kind) = self { return kind }
        return nil
    }

    var displayName: String {
        switch self {
        case .card(let kind): return kind.displayName
        case .dice(let kind): return kind.displayName
        case .cribbage: return "Cribbage"
        }
    }
}

/// Local games skip the table entirely: no lobby seats, no Multipeer,
/// launched straight from the menu into their own full-screen flow
/// (`SolitaireView`/`DotsAndBoxesView`/`QuartoView` each own their own
/// setup → play → close loop internally). `Identifiable` so
/// `.fullScreenCover(item:)` can key off it directly.
private enum LocalGameRoute: Identifiable {
    case solitaire, dotsAndBoxes, quarto
    var id: Self { self }
}

extension DiceKind {
    var displayName: String {
        switch self {
        case .lcr: return "L·R·C"
        case .yahtzee: return "Yahtzee"
        case .zilch: return "Zilch"
        case .shutTheBox: return "Shut the Box"
        }
    }

    /// VoiceOver reads the spelled-out name — the glyph shorthand above is
    /// for sighted players only.
    var accessibilityLabel: String {
        self == .lcr ? "Left, Right, Center" : displayName
    }
}

// MARK: - Chip shell

/// The shared shell every shelf chip renders through: the felt tile, its
/// emblem slot, and its label — one place chip sizing/selection styling
/// lives so all 13 games (card, dice, Cribbage, and the 3 local games) read
/// as one family instead of a slightly different tile per game as new ones
/// landed tonight.
private struct ChipTile<Emblem: View>: View {
    let label: String
    let isSelected: Bool
    let accessibilityLabel: String
    var accessibilityHint: String = ""
    let onTap: () -> Void
    @ViewBuilder let emblem: () -> Emblem

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                emblem()
                    .frame(height: GameEmblem.height)
                Text(label)
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
        // The emblem underneath is real miniature card/dice/board art —
        // without this, VoiceOver reads every shape inside it instead of
        // one clean "Wizard, selected" chip label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Card Games shelf chips

private struct GameChip: View {
    let kind: GameKind
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: kind.displayName, isSelected: isSelected,
                 accessibilityLabel: kind.displayName, onTap: onTap) {
            GameEmblem(kind: kind)
        }
    }
}

/// Cribbage's chip: its own fixed-2-seat deal flow, same as a card game,
/// just not a `GameKind` — see `MenuSelection.cribbage`.
private struct CribbageChip: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: "Cribbage", isSelected: isSelected,
                 accessibilityLabel: "Cribbage", onTap: onTap) {
            MiniPegboard()
        }
    }
}

/// Solitaire never arms the deal button — tapping launches it immediately,
/// full-screen, with its own setup-free single-player table. The small
/// gold "Solo" badge is the one visual break from every other Card Games
/// chip, flagging that this is the one game in the row that isn't played
/// at the table with other seats.
private struct SolitaireChip: View {
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: "Solitaire", isSelected: false,
                 accessibilityLabel: "Solitaire, solo game",
                 accessibilityHint: "Opens a solo game of Solitaire", onTap: onTap) {
            MiniCascadeFan()
        }
        .overlay(alignment: .topTrailing) {
            Text("Solo")
                .font(.system(size: 10, weight: .bold, design: .serif))
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(CardStyle.gold))
                .overlay(Capsule().strokeBorder(CardStyle.ink.opacity(0.25), lineWidth: 0.5))
                .offset(x: -6, y: 6)
                .accessibilityHidden(true) // folded into the chip's own label above
        }
    }
}

// MARK: - Dice Games shelf chips

private struct DiceGameChip: View {
    let kind: DiceKind
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: kind.displayName, isSelected: isSelected,
                 accessibilityLabel: kind.accessibilityLabel, onTap: onTap) {
            DiceGameEmblem(kind: kind)
        }
    }
}

// MARK: - Board & Paper shelf chips

private struct DotsAndBoxesChip: View {
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: "Dots & Boxes", isSelected: false,
                 accessibilityLabel: "Dots and Boxes",
                 accessibilityHint: "Opens a game of Dots and Boxes", onTap: onTap) {
            MiniPencilSquare()
        }
    }
}

private struct QuartoChip: View {
    let onTap: () -> Void

    var body: some View {
        ChipTile(label: "Quarto", isSelected: false,
                 accessibilityLabel: "Quarto",
                 accessibilityHint: "Opens a game of Quarto", onTap: onTap) {
            MiniQuartoPieces()
        }
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
        case .hearts: return "♥️"
        case .spades: return "♠️"
        case .freePlay: return "🃏"
        }
    }
}

// MARK: - Chip emblems (real card/dice/board art, not emoji)

/// Miniature art for each game chip, built from the app's own card views —
/// tiny, unmistakable, and consistent with the felt everyone actually plays
/// on, instead of an emoji standing in for it. Not private: `ResumeStripView`
/// reuses it too, so a suspended game's resume card shows the same brass/
/// card-art mark as the picker instead of a raw emoji glyph.
struct GameEmblem: View {
    /// Common target height for every chip's emblem, card, dice, or board.
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
        case .hearts:
            CardView(card: Card(id: "h12", kind: .standard(suit: .hearts, rank: 12)))
                .frame(height: Self.height)
        case .spades:
            CardView(card: Card(id: "s12", kind: .standard(suit: .spades, rank: 12)))
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

/// Solitaire's chip art: three mini faces cascading in a diagonal
/// staircase — a real legal Klondike run (alternating color, descending
/// rank), the same "build" shape every tableau column makes mid-game.
private struct MiniCascadeFan: View {
    var body: some View {
        let height = GameEmblem.height
        ZStack {
            CardView(card: Card(id: "s9", kind: .standard(suit: .spades, rank: 9)))
                .frame(height: height)
                .offset(x: -height * 0.22, y: -height * 0.14)
            CardView(card: Card(id: "h8", kind: .standard(suit: .hearts, rank: 8)))
                .frame(height: height)
            CardView(card: Card(id: "s7", kind: .standard(suit: .spades, rank: 7)))
                .frame(height: height)
                .offset(x: height * 0.22, y: height * 0.14)
        }
    }
}

/// Cribbage's chip art: the real walnut pegboard photo (`CribbageBoardWood`,
/// the same asset `CribbagePegBoardView` plays the full game on) at chip
/// scale, with two mini pegs — brass for seat 0, ivory for seat 1 —
/// echoing that view's own two-peg leapfrog pairing.
private struct MiniPegboard: View {
    /// Matches `CribbagePegBoardView`'s own `.aspectRatio(700.0/327.0, …)`.
    private static let widthOverHeight: CGFloat = 700.0 / 327.0

    var body: some View {
        let height = GameEmblem.height
        let width = height * Self.widthOverHeight
        ZStack {
            Image("CribbageBoardWood")
                .resizable()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            HStack(spacing: width * 0.2) {
                Circle().fill(CardStyle.gold).frame(width: 5, height: 5)
                Circle().fill(CardStyle.stockTop).frame(width: 5, height: 5)
            }
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
        }
        .frame(width: width, height: height)
    }
}

/// The two Board & Paper chips' shared wood/paper vocabulary lives with
/// each chip below rather than a third shelf-level file — see
/// `MiniPencilSquare` and `MiniQuartoPieces`.

/// Dots & Boxes' chip art: a scrap of the real paper texture
/// (`PaperGraph`) with a tiny printed dot grid and one claimed pencil
/// stroke — the two elements `DotsAndBoxesPaperView` draws at full scale,
/// shrunk to a single square.
private struct MiniPencilSquare: View {
    var body: some View {
        let size = GameEmblem.height
        ZStack {
            Image("PaperGraph")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Canvas { context, canvasSize in
                let dotRadius: CGFloat = 1.1
                for row in 0..<3 {
                    for col in 0..<3 {
                        let point = CGPoint(x: canvasSize.width * (0.22 + CGFloat(col) * 0.28),
                                            y: canvasSize.height * (0.22 + CGFloat(row) * 0.28))
                        let dot = CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                         width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: dot), with: .color(DotsAndBoxesTheme.inkFaded))
                    }
                }
                var stroke = Path()
                stroke.move(to: CGPoint(x: canvasSize.width * 0.22, y: canvasSize.height * 0.22))
                stroke.addLine(to: CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.22))
                context.stroke(stroke, with: .color(DotsAndBoxesTheme.pencilColor(for: 0)), lineWidth: 1.5)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// Quarto's chip art: two real turned pieces (`QuartoPieceView`, the same
/// programmatic wood rendering the actual board plays with) standing side
/// by side — tall dark round vs. short light square, the starkest possible
/// contrast the piece set offers.
private struct MiniQuartoPieces: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            QuartoPieceView(piece: QuartoPiece(id: 7), diameter: 12) // tall, dark, round, solid
            QuartoPieceView(piece: QuartoPiece(id: 0), diameter: 10) // short, light, square, solid
        }
        .frame(height: GameEmblem.height, alignment: .bottom)
    }
}

/// L·R·C's chip art: three tiny dice faces, drawn as rounded squares with
/// letter pips — the game's whole identity is "roll an L, R, or C". The
/// other three dice games show a real pip die instead (`MiniPipDie`) or the
/// physical box they're played on (`MiniShutBox`) — see `DiceGameEmblem`.
private struct DiceGameEmblem: View {
    let kind: DiceKind

    var body: some View {
        switch kind {
        case .lcr:
            MiniDiceTrio()
        case .yahtzee:
            MiniPipDie(pips: 5, size: 30)
        case .zilch:
            MiniPipDie(pips: 6, size: 30)
        case .shutTheBox:
            MiniShutBox()
        }
    }
}

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

/// A miniature 1-6 pip die face, same rounded-square material as
/// `MiniDieFace` (LCR's letter dice) but real dot pips instead of a
/// printed glyph — Yahtzee and Zilch are "real dice" games that read by
/// face value, not a house-invented letter. Only 5 and 6 pips are wired
/// (tonight's two callers); the layout table is written generally enough
/// that adding the rest later is one more array entry.
private struct MiniPipDie: View {
    let pips: Int
    var size: CGFloat = 26

    /// Unit-square pip layout, the same grid every physical die uses.
    private static let layouts: [Int: [(CGFloat, CGFloat)]] = [
        5: [(0.24, 0.24), (0.76, 0.24), (0.5, 0.5), (0.24, 0.76), (0.76, 0.76)],
        6: [(0.24, 0.20), (0.76, 0.20), (0.24, 0.5), (0.76, 0.5), (0.24, 0.80), (0.76, 0.80)],
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [CardStyle.stockTop, CardStyle.stockBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(CardStyle.ink.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                GeometryReader { geo in
                    ForEach(Array((Self.layouts[pips] ?? []).enumerated()), id: \.offset) { _, unit in
                        Circle()
                            .fill(CardStyle.ink)
                            .frame(width: size * 0.15, height: size * 0.15)
                            .position(x: unit.0 * geo.size.width, y: unit.1 * geo.size.height)
                    }
                }
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

/// Shut the Box's chip art: the real wooden rail image (`ShutBoxFrame`,
/// the same asset `ShutBoxBoxView` plays the full game on) at chip scale —
/// the box itself is distinctive enough not to need any overlay at this size.
private struct MiniShutBox: View {
    /// Matches `ShutBoxBoxView.nativeAspect` (height / width).
    private static let heightOverWidth: CGFloat = 493.0 / 640.0

    var body: some View {
        let height = GameEmblem.height
        let width = height / Self.heightOverWidth
        Image("ShutBoxFrame")
            .resizable()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
