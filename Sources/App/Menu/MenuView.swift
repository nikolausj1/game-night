import SwiftUI

/// The iPad home screen: the felt stage before a game exists. Resume strip
/// up top when there's something to pick back up, then five category
/// shelves of game tiles (Card Games, Kids' Pack, Dice Games, Board Games,
/// Solo & Table), the live seat builder, house rules, and the deal.
struct MenuView: View {
    @Bindable var host: GameHostController

    /// One shelf selection across every game that goes through the
    /// seats-builder → deal-button flow: card games, dice games, Cribbage,
    /// and the hosted side games (Battleship, Gin Rummy, Blackjack, Liar's
    /// Dice, the kids' pack). Local games (Solitaire, the board games) skip
    /// this state entirely: they own their own setup screen and launch
    /// straight into a full-screen cover instead of arming the deal button;
    /// see `localGameRoute`.
    @State private var selection: MenuSelection = .card(.wizard)
    @State private var localGameRoute: LocalGameRoute?
    @State private var rules = RulesConfig()
    @State private var sideRules = SideGameRules()
    @State private var botDrafts: [BotSeatDraft] = []
    /// Engine-game saves only, kept for the quick-start chips (they rebuild
    /// a fresh table from a save's seat setup). The resume strip itself
    /// reads the all-kinds `ResumeCatalog` below.
    @State private var savedGames: [SavedGame] = []
    /// Every resumable game (engine, Cribbage, side games, dice, board,
    /// Solitaire) in one observable list; see its MENU CONTRACT doc.
    @State private var catalog = ResumeCatalog.shared
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sim-verify hook: -autoStart deals free play as soon as anyone sits.
    private var autoStarts: Bool { CommandLine.arguments.contains("-autoStart") }

    // MARK: shelf order

    /// Wizard through Blackjack in the owner's order. Gin Rummy and
    /// Blackjack are side games (their own engines) but they're card games
    /// to anyone standing at the counter, so they shelve with the rest.
    private static let cardShelf: [MenuSelection] = [
        .card(.wizard), .card(.ohHell), .card(.hearts), .card(.spades),
        .card(.crazyEights), .card(.uno), .side(.ginRummy), .cribbage, .side(.blackjack),
    ]
    private static let kidsShelf: [MenuSelection] = [.side(.goFish), .side(.oldMaid), .side(.war)]
    /// L·R·C first (the original), then the three that landed alongside
    /// it, then Liar's Dice (cups on the phones, a side game underneath).
    private static let diceShelf: [MenuSelection] = [
        .dice(.lcr), .dice(.yahtzee), .dice(.zilch), .dice(.shutTheBox), .side(.liarsDice),
    ]
    private static let boardShelf: [LocalGameRoute] = [.mancala, .checkers, .connectFour, .dotsAndBoxes, .quarto]

    private var info: MenuGameInfo { selection.info }
    private var seatRange: ClosedRange<Int> { info.seats }
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
                if !catalog.entries.isEmpty {
                    ResumeStripView(entries: catalog.entries, onResume: resumeEntry, onDelete: deleteEntry)
                        .padding(.horizontal, 30)
                }

                masthead

                gameShelves
                    .padding(.horizontal, 30)

                // One seat builder serves every launch path. See
                // `SeatsBuilderView`'s own doc comment for how `seatRange`
                // covers card games, dice games, side games, and Cribbage's
                // fixed pair.
                SeatsBuilderView(host: host, minPlayers: seatRange.lowerBound,
                                 maxPlayers: seatRange.upperBound, botDrafts: $botDrafts)

                if let cardKind = selection.cardKind, cardKind.hasHouseRules {
                    RulesPanelView(game: cardKind, rules: $rules)
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 40)
                } else if let sideKind = selection.sideKind, sideKind.hasHouseRules {
                    SideRulesPanelView(game: sideKind, rules: $sideRules)
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
        .onChange(of: localGameRoute) { _, route in
            // Coming back from a local game: its save slot may have been
            // written (mid-game) or cleared (finished), so the strip
            // re-reads before it is visible again.
            if route == nil { refreshSavedGames() }
        }
        .onChange(of: selection) { _, _ in
            // Any shelf switch may shrink the seat window (a 6-player Oh
            // Hell table to Battleship's fixed 2, say). Trim drafted bots
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
            // human seat 0 (+2 bots): exercises the remote pour → table
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
            // Sim-verify hook: an all-bot L·R·C game, dice physics on film.
            if CommandLine.arguments.contains("-autoStartLcr"),
               DiceLauncher.shared.controller == nil {
                let bots = BotRoster.random(count: 3).enumerated().map {
                    SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
                }
                DiceLauncher.shared.start(host: host, seats: bots)
            }
            // Sim-verify hook: L·R·C with a phoneless HUMAN in seat 0
            // (tap the plate to roll), exercises the pending-coin drags.
            if CommandLine.arguments.contains("-autoStartLcrHuman"),
               DiceLauncher.shared.controller == nil {
                var seats = [SeatSpec(id: 0, name: "You", isBot: false)]
                for (index, bot) in BotRoster.random(count: 2).enumerated() {
                    seats.append(SeatSpec(id: index + 1, name: bot.name, isBot: true))
                }
                DiceLauncher.shared.start(host: host, seats: seats)
            }
            // Sim-verify hook: an all-bot Yahtzee game, solitaire dice
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
            case .mancala:
                MancalaView(onClose: { localGameRoute = nil })
            case .checkers:
                CheckersView(onClose: { localGameRoute = nil })
            case .connectFour:
                ConnectFourView(onClose: { localGameRoute = nil })
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

    /// Five labeled shelves in the house serif/gold voice, so two dozen
    /// games read as a browsable counter (cards, kids, dice, board, solo)
    /// rather than a settings list. Each shelf scrolls horizontally on its
    /// own (same pattern `ResumeStripView` uses above), so a crowded shelf
    /// never wraps or crowds the next one.
    private var gameShelves: some View {
        VStack(alignment: .leading, spacing: 22) {
            shelf(title: "Card Games", note: "Hands on the phones, tricks on the table") {
                ForEach(Self.cardShelf, id: \.self) { item in
                    HostedGameTile(selection: item, isSelected: selection == item) { select(item) }
                }
            }
            shelf(title: "Kids' Pack", note: "Quick to learn, big cards, no reading required") {
                ForEach(Self.kidsShelf, id: \.self) { item in
                    HostedGameTile(selection: item, isSelected: selection == item) { select(item) }
                }
            }
            shelf(title: "Dice Games", note: "Shake a phone to roll, or tap your plate") {
                ForEach(Self.diceShelf, id: \.self) { item in
                    HostedGameTile(selection: item, isSelected: selection == item) { select(item) }
                }
            }
            shelf(title: "Board Games", note: "Right here on the iPad, pass it or sit across") {
                ForEach(Self.boardShelf, id: \.self) { route in
                    LocalGameTile(route: route) { openLocalGame(route) }
                }
                HostedGameTile(selection: .side(.battleship),
                               isSelected: selection == .side(.battleship)) { select(.side(.battleship)) }
            }
            shelf(title: "Solo & Table", note: "One player, or any game the table doesn't know yet") {
                LocalGameTile(route: .solitaire) { openLocalGame(.solitaire) }
                HostedGameTile(selection: .card(.freePlay),
                               isSelected: selection == .card(.freePlay)) { select(.card(.freePlay)) }
            }
        }
    }

    @ViewBuilder
    private func shelf<Content: View>(title: String, note: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.85))
                Text(note)
                    .font(.system(.caption, design: .serif).italic())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
    }

    private func select(_ new: MenuSelection) {
        Haptics.tick()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            selection = new
        }
    }

    private func openLocalGame(_ route: LocalGameRoute) {
        Haptics.tick()
        localGameRoute = route
    }

    // MARK: deal

    /// Two entirely different looks, not one button toggling `.disabled`:
    /// a real gold CTA when the table can start, and, while waiting, a
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
            .accessibilityHint("Starts \(info.title) with the seats above")
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
        case .side(let kind): return kind.dealTitle
        }
    }

    /// The waiting pill names what's missing. A phones-required game with
    /// nobody seated says so in those words; the generic count covers the
    /// rest (and the over-capacity case).
    private var neededLabel: String {
        let need = seatRange.lowerBound - totalSeats
        if need > 0 {
            if info.phones == .required, totalSeats == 0 {
                return need == 1 ? "Waiting for a phone to join…" : "Waiting for \(need) phones to join…"
            }
            return "Waiting for \(need) more…"
        }
        return "Too many for \(info.title)"
    }

    /// One shared seat list for cards, dice, side games, and Cribbage:
    /// humans in lobby order, then the drafted bots.
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
    /// actually launches through: the card engine, `DiceLauncher`,
    /// Cribbage's own `startCribbage`, or a side game's documented factory
    /// via `host.startSideGame`. All of them are armed the same way (seats
    /// builder fills up, this button lights up gold).
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
        case .side(let kind):
            startSideGame(kind)
        }
        botDrafts = []
    }

    /// Each side game's own launch factory, exactly as its integration
    /// notes document them. Humans map onto connected phones in lobby
    /// order and bots are the game's business (the generic side-game seat
    /// contract, same as Cribbage). TableRootView switches to the
    /// registry's table view on `host.sideGame != nil`.
    private func startSideGame(_ kind: SideGameMenuKind) {
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        switch kind {
        case .battleship:
            let salvo = sideRules.battleshipSalvo
            host.startSideGame(seats: seatSpecs, seed: seed) { BattleshipHost(seats: $0, seed: $1, salvo: salvo) }
        case .ginRummy:
            GinRummyLaunch.start(on: host, seats: seatSpecs, seed: seed)
        case .blackjack:
            BlackjackLaunch.start(on: host, seats: seatSpecs, config: sideRules.blackjack)
        case .liarsDice:
            let config = sideRules.liarsDice
            host.startSideGame(seats: seatSpecs, seed: seed) { LiarsDiceHost(seats: $0, seed: $1, config: config) }
        case .goFish:
            KidsPackIntegration.startGoFish(on: host, seats: seatSpecs, seed: seed)
        case .oldMaid:
            KidsPackIntegration.startOldMaid(on: host, seats: seatSpecs, seed: seed)
        case .war:
            KidsPackIntegration.startWar(on: host, seats: seatSpecs, seed: seed)
        }
    }

    // MARK: quick actions

    /// Compact convenience row under the deal button: jump back into the
    /// last game, hop straight to Settings, or one-tap start one of the two
    /// game kinds played most recently (no picker, no seat builder).
    private var quickActionsRow: some View {
        HStack(spacing: 10) {
            if let mostRecent = catalog.entries.first {
                QuickActionChip(title: "Resume Last", systemImage: "arrow.uturn.backward") {
                    Haptics.tick()
                    resumeEntry(mostRecent)
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
    /// last 3 by `GameStateStore.list()`), no extra bookkeeping needed.
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
        catalog.refresh()
    }

    /// Hosted kinds come back live on `host` / `DiceLauncher` and
    /// TableRootView routes to them by itself; a local kind hands back the
    /// route to open. The local views are expected to pick their save up
    /// when mounted with `resumeSaved: true` (ResumeCatalog's contract);
    /// that parameter doesn't exist on them yet, so the cover below mounts
    /// them plain. Once it lands, `fullScreenCover` is the one place to
    /// pass `resumeSaved: resumingLocalSave`.
    private func resumeEntry(_ entry: ResumeEntry) {
        if let route = catalog.resume(entry, host: host) {
            localGameRoute = LocalGameRoute(resumeRoute: route)
        }
        refreshSavedGames()
    }

    private func deleteEntry(_ entry: ResumeEntry) {
        catalog.delete(entry)
        refreshSavedGames()
    }
}

/// One pill in the quick-actions row: felt/serif/gold, matching the game
/// tiles above, a compact affordance, not a redesign.
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

/// Which tile is currently armed for a deal: one selection across every
/// game that goes through the seats-builder → deal-button flow. `Hashable`
/// synthesizes for free (every payload is a plain enum), which is all
/// `onChange(of: selection)`, the tiles' `isSelected` checks, and the
/// shelves' `ForEach(id: \.self)` need.
enum MenuSelection: Hashable {
    case card(GameKind)
    case dice(DiceKind)
    case cribbage
    case side(SideGameMenuKind)

    var cardKind: GameKind? {
        if case .card(let kind) = self { return kind }
        return nil
    }

    var sideKind: SideGameMenuKind? {
        if case .side(let kind) = self { return kind }
        return nil
    }

    var displayName: String { info.title }

    /// Everything a tile and the deal gate need to know about this game.
    var info: MenuGameInfo {
        switch self {
        case .card(let kind):
            return MenuGameInfo(title: kind.displayName, hook: kind.menuHook,
                                seats: kind.minPlayers...kind.maxPlayers,
                                phones: kind == .freePlay ? .optional : .required)
        case .dice(let kind):
            return MenuGameInfo(title: kind.displayName, hook: kind.menuHook,
                                seats: kind.menuSeats, phones: .optional,
                                spokenName: kind.accessibilityLabel)
        case .cribbage:
            // CribbageEngine is fixed 2-player.
            return MenuGameInfo(title: "Cribbage",
                                hook: "Fifteen-two, fifteen-four, and a pair for the pegs.",
                                seats: 2...2, phones: .required)
        case .side(let kind):
            return kind.info
        }
    }
}

/// The hosted side games the menu can arm. Each maps onto one documented
/// launch factory in `MenuView.startSideGame` and one `SideGameRegistry`
/// entry; the registry key is the engine's `kind` string, which this enum
/// deliberately does not duplicate (the factories own it).
enum SideGameMenuKind: Hashable, CaseIterable {
    case battleship, ginRummy, blackjack, liarsDice, goFish, oldMaid, war

    /// The registry key (`SideGameHost.kind`) this menu kind launches; the
    /// four literal keys match `SideGameRegistry.entries`, the kids' three
    /// come from their engines. Used to pick a resume card's emblem.
    init?(registryKey: String) {
        switch registryKey {
        case "battleship": self = .battleship
        case "ginRummy": self = .ginRummy
        case "blackjack": self = .blackjack
        case "liarsDice": self = .liarsDice
        case GoFishEngine.kind: self = .goFish
        case OldMaidEngine.kind: self = .oldMaid
        case WarEngine.kind: self = .war
        default: return nil
        }
    }

    /// Seat windows come from the engines and hosts themselves, never the
    /// menu's wishes: `BlackjackHost` clamps to 1...5 seats, the kids'
    /// engines cap at `GoFishEngine.maxPlayers` / `OldMaidEngine.maxPlayers`
    /// (4), War and Gin and Battleship are strictly two-handed, and Liar's
    /// Dice runs 2 to 6 (the table lays out six distinct places).
    var info: MenuGameInfo {
        switch self {
        case .battleship:
            return MenuGameInfo(title: "Battleship", hook: "Hide your fleet, then call your shots.",
                                seats: 2...2, phones: .required)
        case .ginRummy:
            return MenuGameInfo(title: "Gin Rummy", hook: "Build runs and sets, knock when your deadwood is low.",
                                seats: 2...2, phones: .required)
        case .blackjack:
            return MenuGameInfo(title: "Blackjack", hook: "Beat the dealer to twenty-one without going bust.",
                                seats: 1...5, phones: .required, seatsCaption: "1–5 + dealer")
        case .liarsDice:
            return MenuGameInfo(title: "Liar's Dice", hook: "Bid on everyone's hidden dice, then call the bluff.",
                                seats: 2...6, phones: .required, spokenName: "Liar's Dice")
        case .goFish:
            return MenuGameInfo(title: "Go Fish", hook: "Ask for a rank, make books of four.",
                                seats: GoFishEngine.minPlayers...GoFishEngine.maxPlayers, phones: .required)
        case .oldMaid:
            return MenuGameInfo(title: "Old Maid", hook: "Pair them off, and don't get stuck with the odd queen.",
                                seats: OldMaidEngine.minPlayers...OldMaidEngine.maxPlayers, phones: .required)
        case .war:
            return MenuGameInfo(title: "War", hook: "High card takes the pile, ties go to war.",
                                seats: 2...2, phones: .required)
        }
    }

    /// Only the three with engine-level option flags get a House Rules
    /// panel; see `SideRulesPanelView`.
    var hasHouseRules: Bool {
        switch self {
        case .blackjack, .liarsDice, .battleship: return true
        case .ginRummy, .goFish, .oldMaid, .war: return false
        }
    }

    var dealTitle: String {
        switch self {
        case .battleship: return "Call the fleets"
        case .ginRummy: return "Deal gin rummy"
        case .blackjack: return "Open the shoe"
        case .liarsDice: return "Shake the cups"
        case .goFish: return "Deal Go Fish"
        case .oldMaid: return "Deal Old Maid"
        case .war: return "Deal for war"
        }
    }
}

/// Local games skip the table entirely: no lobby seats, no Multipeer,
/// launched straight from the menu into their own full-screen flow (each
/// view owns its own setup → play → close loop internally). `Identifiable`
/// so `.fullScreenCover(item:)` can key off it directly.
private enum LocalGameRoute: Hashable, Identifiable {
    case solitaire, dotsAndBoxes, quarto, mancala, checkers, connectFour
    var id: Self { self }

    /// The menu's route for a `ResumeCatalog` local entry.
    init(resumeRoute: LocalResumeRoute) {
        switch resumeRoute {
        case .solitaire: self = .solitaire
        case .dotsAndBoxes: self = .dotsAndBoxes
        case .quarto: self = .quarto
        case .mancala: self = .mancala
        case .checkers: self = .checkers
        case .connectFour: self = .connectFour
        }
    }

    /// `ResumeKind.board`'s key ("mancala", "checkers", ...), for the
    /// resume card's emblem.
    init?(saveKey: String) {
        guard let route = LocalResumeRoute(rawValue: saveKey) else { return nil }
        self.init(resumeRoute: route)
    }

    var info: MenuGameInfo {
        switch self {
        case .solitaire:
            return MenuGameInfo(title: "Solitaire", hook: "Klondike on the felt, one player, no phones.",
                                seats: 1...1, phones: .tableOnly)
        case .dotsAndBoxes:
            // DotsAndBoxesSetupView seats 2 to 4.
            return MenuGameInfo(title: "Dots & Boxes", hook: "Draw a line, close a box, take another turn.",
                                seats: 2...4, phones: .tableOnly, spokenName: "Dots and Boxes")
        case .quarto:
            return MenuGameInfo(title: "Quarto", hook: "Hand your rival a piece, line up four alike.",
                                seats: 2...2, phones: .tableOnly)
        case .mancala:
            return MenuGameInfo(title: "Mancala", hook: "Sow the stones around, capture the pits.",
                                seats: 2...2, phones: .tableOnly)
        case .checkers:
            return MenuGameInfo(title: "Checkers", hook: "Jump, capture, get crowned.",
                                seats: 2...2, phones: .tableOnly)
        case .connectFour:
            return MenuGameInfo(title: "Connect Four", hook: "Drop discs, line up four.",
                                seats: 2...2, phones: .tableOnly)
        }
    }
}

/// Everything a shelf tile says about one game: its name, a one-line hook,
/// the seat window the deal gate enforces, and whether phones are needed.
struct MenuGameInfo {
    let title: String
    let hook: String
    let seats: ClosedRange<Int>
    let phones: PhoneNeed
    /// Overrides the computed seat caption ("1–5 + dealer").
    var seatsCaption: String? = nil
    /// VoiceOver name when the printed title is a glyph or an abbreviation.
    var spokenName: String? = nil

    var seatsLabel: String {
        if let seatsCaption { return seatsCaption }
        if seats.lowerBound == seats.upperBound {
            return seats.lowerBound == 1 ? "1 player" : "\(seats.lowerBound) players"
        }
        return "\(seats.lowerBound)–\(seats.upperBound) players"
    }

    var spokenTitle: String { spokenName ?? title }
}

/// Whether a game needs phones at the table. Hidden-information games
/// (private hands, hidden dice, a secret fleet) require them; the dice
/// games and Free Play let a phoneless player tap their plate on the iPad;
/// the local board games never talk to a phone at all.
enum PhoneNeed: Equatable {
    case required, optional, tableOnly

    var label: String {
        switch self {
        case .required: return "Needs phones"
        case .optional: return "Phones optional"
        case .tableOnly: return "Table only"
        }
    }

    var symbol: String {
        switch self {
        case .required: return "iphone.radiowaves.left.and.right"
        case .optional: return "iphone"
        case .tableOnly: return "ipad.landscape"
        }
    }

    var spoken: String {
        switch self {
        case .required: return "needs phones"
        case .optional: return "phones optional"
        case .tableOnly: return "played on the table only"
        }
    }
}

extension GameKind {
    /// Free Play has no legality/bidding rules to expose.
    var hasHouseRules: Bool { self != .freePlay }

    /// The one line under each tile's name.
    var menuHook: String {
        switch self {
        case .wizard: return "Call your tricks exactly, wizards and jesters wild."
        case .ohHell: return "Bid your tricks, hit the number or eat it."
        case .hearts: return "Dodge the hearts and the black queen, or shoot the moon."
        case .spades: return "Partners across the table, spades always trump."
        case .crazyEights: return "Match suit or rank, eights change everything."
        case .uno: return "Match the color, stack the draws, call it at one."
        case .freePlay: return "Any game you know, the table just deals."
        }
    }

    /// Still used by `ResumeStripView`'s compact resume cards. The game
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

extension DiceKind {
    var displayName: String {
        switch self {
        case .lcr: return "L·R·C"
        case .yahtzee: return "Yahtzee"
        case .zilch: return "Zilch"
        case .shutTheBox: return "Shut the Box"
        }
    }

    /// VoiceOver reads the spelled-out name; the glyph shorthand above is
    /// for sighted players only.
    var accessibilityLabel: String {
        self == .lcr ? "Left, Right, Center" : displayName
    }

    var menuHook: String {
        switch self {
        case .lcr: return "Roll it, pass your chips left, right, or to the pot."
        case .yahtzee: return "Five dice, three rolls, fill the scoresheet."
        case .zilch: return "Push your luck for points, roll nothing and lose it all."
        case .shutTheBox: return "Flip the tiles that add up, shut them all."
        }
    }

    /// Per-kind table seat window. LCR's 3–6 comes from its neighbor-passing
    /// rule (a 2-player "circle" makes no sense); Yahtzee is solitaire-
    /// friendly down to 1; Zilch and Shut the Box need at least 2 to have
    /// a turn to pass. All four cap at 6: `TableGeometry.seatAnchors`
    /// only lays out distinct positions up to 6, same ceiling LCR always had.
    var menuSeats: ClosedRange<Int> {
        switch self {
        case .lcr: return 3...6
        case .yahtzee: return 1...6
        case .zilch, .shutTheBox: return 2...6
        }
    }
}

// MARK: - Tiles

/// The shared shell every shelf tile renders through: felt plate, emblem,
/// name, hook line, and the seats + phones footer. One place tile sizing
/// and selection styling live so every game, hosted or local, reads as one
/// family. Widths and the emblem slot scale with Dynamic Type; the hook
/// wraps to two lines rather than clipping.
private struct GameTile<Emblem: View>: View {
    let info: MenuGameInfo
    let isSelected: Bool
    let accessibilityHint: String
    let onTap: () -> Void
    @ViewBuilder let emblem: () -> Emblem

    @ScaledMetric(relativeTo: .headline) private var width: CGFloat = 176
    @ScaledMetric(relativeTo: .headline) private var emblemHeight: CGFloat = GameEmblem.height

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                emblem()
                    .frame(maxWidth: .infinity)
                    .frame(height: emblemHeight)
                Text(info.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(info.hook)
                    .font(.system(.caption, design: .serif).italic())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Label(info.seatsLabel, systemImage: "person.2")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    PhoneNeedBadge(need: info.phones, onGold: isSelected)
                }
            }
            .padding(12)
            .frame(width: width, alignment: .leading)
            .foregroundStyle(isSelected ? CardStyle.ink : CardStyle.stockTop)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? CardStyle.gold : .white.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? CardStyle.ink.opacity(0.12) : CardStyle.gold.opacity(0.22),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // The emblem underneath is real miniature card/dice/board art.
        // Without this, VoiceOver reads every shape inside it instead of
        // one clean "Wizard, 3 to 6 players, needs phones" tile.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.spokenTitle), \(info.seatsLabel), \(info.phones.spoken)")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The footer chip saying whether phones are needed. Inverts on the gold
/// selected tile so it stays legible in both states.
private struct PhoneNeedBadge: View {
    let need: PhoneNeed
    let onGold: Bool

    var body: some View {
        Label(need.label, systemImage: need.symbol)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(onGold ? CardStyle.ink.opacity(0.12) : .black.opacity(0.28))
            )
            .overlay(
                Capsule().strokeBorder(onGold ? CardStyle.ink.opacity(0.18) : CardStyle.gold.opacity(0.35),
                                       lineWidth: 0.75)
            )
            .foregroundStyle(onGold ? CardStyle.ink : (need == .required ? CardStyle.gold : CardStyle.stockTop.opacity(0.8)))
    }
}

/// A tile for any game that arms the deal button (card, dice, Cribbage,
/// side games). Picks the emblem by selection.
private struct HostedGameTile: View {
    let selection: MenuSelection
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let info = selection.info
        GameTile(info: info, isSelected: isSelected,
                 accessibilityHint: "Selects \(info.spokenTitle) for the next deal",
                 onTap: onTap) {
            switch selection {
            case .card(let kind): GameEmblem(kind: kind)
            case .dice(let kind): DiceGameEmblem(kind: kind)
            case .cribbage: MiniPegboard()
            case .side(let kind): SideGameEmblem(kind: kind)
            }
        }
    }
}

/// A tile for a local game: never armed, never selected. Tapping launches
/// it immediately into its own full-screen flow.
private struct LocalGameTile: View {
    let route: LocalGameRoute
    let onTap: () -> Void

    var body: some View {
        let info = route.info
        GameTile(info: info, isSelected: false,
                 accessibilityHint: "Opens a game of \(info.spokenTitle)",
                 onTap: onTap) {
            switch route {
            case .solitaire: MiniCascadeFan()
            case .dotsAndBoxes: MiniPencilSquare()
            case .quarto: MiniQuartoPieces()
            case .mancala: MiniMancalaBoard()
            case .checkers: MiniCheckersBoard()
            case .connectFour: MiniConnectFourFrame()
            }
        }
    }
}

// MARK: - Tile emblems (real card/dice/board art, not emoji)

/// Miniature art for each card-game tile, built from the app's own card
/// views: tiny, unmistakable, and consistent with the felt everyone
/// actually plays on, instead of an emoji standing in for it. Not private:
/// `ResumeStripView` reuses it too, so a suspended game's resume card shows
/// the same brass/card-art mark as the picker instead of a raw emoji glyph.
struct GameEmblem: View {
    /// Common target height for every tile's emblem, card, dice, or board.
    static let height: CGFloat = 34

    let kind: GameKind

    var body: some View {
        switch kind {
        case .wizard:
            // A wizard card fanned against a heart ace: the two things
            // that make Wizard Wizard, the special card and trump suit.
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

/// Miniature art for the hosted side games, in the same card/dice/board
/// vocabulary as `GameEmblem`.
struct SideGameEmblem: View {
    let kind: SideGameMenuKind

    var body: some View {
        switch kind {
        case .battleship:
            MiniBattleshipChart()
        case .ginRummy:
            // A real run (7-8-9 of hearts), the meld every Gin hand chases.
            MiniRun()
        case .blackjack:
            // A natural: ace and a paint card, 21 off the deal.
            FannedPair(height: GameEmblem.height,
                       leftCard: Card(id: "s14", kind: .standard(suit: .spades, rank: 14)),
                       rightCard: Card(id: "h13", kind: .standard(suit: .hearts, rank: 13)))
        case .liarsDice:
            MiniCupAndDice()
        case .goFish:
            // A book: three of a rank already laid, the fourth is what you
            // ask for.
            MiniBook()
        case .oldMaid:
            // The odd queen next to the card that never pairs with her.
            MiniOddQueen()
        case .war:
            // Two cards flipped head to head.
            MiniFaceOff()
        }
    }
}

/// The resume strip's emblem for any `ResumeKind`: the same tile art the
/// shelves use, looked up by save kind. Not private: `ResumeStripView`
/// mounts it; the emblems it dispatches to stay file-private here.
struct ResumeKindEmblem: View {
    let kind: ResumeKind

    var body: some View {
        switch kind {
        case .hostEngine(let gameKind):
            GameEmblem(kind: gameKind)
        case .cribbage:
            MiniPegboard()
        case .sideGame(let key):
            if let side = SideGameMenuKind(registryKey: key) {
                SideGameEmblem(kind: side)
            } else {
                FannedBacks(height: GameEmblem.height)
            }
        case .dice(let diceKind):
            DiceGameEmblem(kind: diceKind)
        case .board(let key):
            switch LocalGameRoute(saveKey: key) {
            case .dotsAndBoxes: MiniPencilSquare()
            case .quarto: MiniQuartoPieces()
            case .mancala: MiniMancalaBoard()
            case .checkers: MiniCheckersBoard()
            case .connectFour: MiniConnectFourFrame()
            case .solitaire, .none: FannedBacks(height: GameEmblem.height)
            }
        case .solitaire:
            MiniCascadeFan()
        }
    }
}

/// Two mini card faces fanned in a shallow V, center-anchored. The wizard
/// tile's wizard + heart-ace pair; Blackjack's ace + king.
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

/// Three mini card backs spread in a shallow fan, Free Play's tile art:
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

/// Gin Rummy's tile art: 7-8-9 of hearts overlapped left to right the way
/// a melded run sits in a hand.
private struct MiniRun: View {
    var body: some View {
        let height = GameEmblem.height
        ZStack {
            CardView(card: Card(id: "h7", kind: .standard(suit: .hearts, rank: 7)))
                .frame(height: height)
                .offset(x: -height * 0.34)
            CardView(card: Card(id: "h8", kind: .standard(suit: .hearts, rank: 8)))
                .frame(height: height)
            CardView(card: Card(id: "h9", kind: .standard(suit: .hearts, rank: 9)))
                .frame(height: height)
                .offset(x: height * 0.34)
        }
    }
}

/// Go Fish's tile art: three sevens fanned, one short of a book.
private struct MiniBook: View {
    var body: some View {
        let height = GameEmblem.height
        ZStack {
            CardView(card: Card(id: "c7", kind: .standard(suit: .clubs, rank: 7)))
                .frame(height: height)
                .rotationEffect(.degrees(-14))
                .offset(x: -height * 0.26, y: height * 0.04)
            CardView(card: Card(id: "h7", kind: .standard(suit: .hearts, rank: 7)))
                .frame(height: height)
            CardView(card: Card(id: "s7", kind: .standard(suit: .spades, rank: 7)))
                .frame(height: height)
                .rotationEffect(.degrees(14))
                .offset(x: height * 0.26, y: height * 0.04)
        }
    }
}

/// Old Maid's tile art: the queen of clubs face up beside a face-down
/// card, the pair that never comes.
private struct MiniOddQueen: View {
    var body: some View {
        let height = GameEmblem.height
        ZStack {
            CardBackView()
                .frame(height: height)
                .rotationEffect(.degrees(8))
                .offset(x: height * 0.18)
            CardView(card: Card(id: "c12", kind: .standard(suit: .clubs, rank: 12)))
                .frame(height: height)
                .rotationEffect(.degrees(-8))
                .offset(x: -height * 0.18)
        }
    }
}

/// War's tile art: two faces turned up against each other, a gap between
/// them like the two piles on the felt.
private struct MiniFaceOff: View {
    var body: some View {
        let height = GameEmblem.height
        HStack(spacing: height * 0.18) {
            CardView(card: Card(id: "d13", kind: .standard(suit: .diamonds, rank: 13)))
                .frame(height: height)
                .rotationEffect(.degrees(-6))
            CardView(card: Card(id: "c14", kind: .standard(suit: .clubs, rank: 14)))
                .frame(height: height)
                .rotationEffect(.degrees(6))
        }
    }
}

/// Liar's Dice's tile art: the leather cup (`LiarsDiceCupArt`, the same
/// `TableCup` asset the game turns over on the felt) face-down beside two
/// of its photoreal pip dice, a wild one and a five.
private struct MiniCupAndDice: View {
    var body: some View {
        let height = GameEmblem.height
        let die = height * 0.62
        HStack(alignment: .bottom, spacing: 4) {
            LiarsDiceCupArt(width: height * 0.78, flip: 1, grounded: false)
                .frame(height: height, alignment: .bottom)
            LiarsPipDie(value: 1, size: die)
                .padding(.bottom, 2)
            LiarsPipDie(value: 5, size: die)
                .padding(.bottom, 2)
        }
        .frame(height: height, alignment: .bottom)
    }
}

/// Battleship's tile art: a scrap of the real chart (`BattleshipGrid`, the
/// same asset each seat's chart is drawn on) with a cruiser laid across it
/// and one red hit peg, the game's whole vocabulary in a square inch.
private struct MiniBattleshipChart: View {
    var body: some View {
        let side = GameEmblem.height * 1.1
        let geometry = BattleshipChartGeometry(side: side)
        let bow = geometry.center(row: 3, col: 2)
        let stern = geometry.center(row: 3, col: 4)
        ZStack {
            Image("BattleshipGrid")
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            BattleshipSprite(kind: .cruiser, alongPitch: geometry.pitchX, acrossPitch: geometry.pitchY)
                .position(x: (bow.x + stern.x) / 2, y: bow.y)
            Image("PegHit")
                .resizable()
                .frame(width: geometry.pitchX * 0.9, height: geometry.pitchY * 0.9)
                .position(geometry.center(row: 6, col: 7))
        }
        .frame(width: side, height: side)
    }
}

/// Solitaire's tile art: three mini faces cascading in a diagonal
/// staircase, a real legal Klondike run (alternating color, descending
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

/// Cribbage's tile art: the real walnut pegboard photo (`CribbageBoardWood`,
/// the same asset `CribbagePegBoardView` plays the full game on) at tile
/// scale, with two mini pegs, brass for seat 0, ivory for seat 1,
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

/// Dots & Boxes' tile art: a scrap of the real paper texture
/// (`PaperGraph`) with a tiny printed dot grid and one claimed pencil
/// stroke, the two elements `DotsAndBoxesPaperView` draws at full scale,
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

/// Quarto's tile art: two real turned pieces (`QuartoPieceView`, the same
/// programmatic wood rendering the actual board plays with) standing side
/// by side, tall dark round vs. short light square, the starkest possible
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

/// Mancala's tile art: the real carved board photo (`MancalaBoard`, the
/// same asset `MancalaBoardView` sows on) at tile scale with three glass
/// gems resting in its pits.
private struct MiniMancalaBoard: View {
    /// Matches `MancalaGeometry.aspect` (height / width).
    private static let heightOverWidth: CGFloat = MancalaGeometry.aspect

    var body: some View {
        let height = GameEmblem.height * 0.8
        let width = height / Self.heightOverWidth
        ZStack {
            Image("MancalaBoard")
                .resizable()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            HStack(spacing: width * 0.09) {
                gem(Color(red: 0.36, green: 0.68, blue: 0.86))
                gem(MancalaBoardPainter.gold)
                gem(Color(red: 0.78, green: 0.32, blue: 0.40))
            }
            .offset(y: height * 0.12)
        }
        .frame(width: width, height: GameEmblem.height)
    }

    private func gem(_ color: Color) -> some View {
        Circle()
            .fill(RadialGradient(colors: [.white.opacity(0.9), color, color.opacity(0.7)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 3.5))
            .frame(width: 5.5, height: 5.5)
            .shadow(color: .black.opacity(0.5), radius: 0.8, y: 0.6)
    }
}

/// Checkers' tile art: the real board photo (`CheckersBoard`) with one red
/// and one black man (`CheckerRed` / `CheckerBlack`, the exact sprites
/// `CheckersPainter` draws) facing each other across it, scaled up past
/// true size so they read at a glance.
private struct MiniCheckersBoard: View {
    var body: some View {
        let side = GameEmblem.height
        let piece = side * 0.42
        ZStack {
            Image("CheckersBoard")
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            Image("CheckerRed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: piece, height: piece)
                .position(x: side * 0.31, y: side * 0.69)
            Image("CheckerBlack")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: piece, height: piece)
                .position(x: side * 0.69, y: side * 0.31)
        }
        .frame(width: side, height: side)
    }
}

/// Connect Four's tile art: the real standing frame (`ConnectFourFrame`,
/// whose 42 holes are alpha 0) with a few discs resting BEHIND it, the
/// same back-to-front layering `ConnectFourFrameView` uses so each disc
/// shows through its own hole.
private struct MiniConnectFourFrame: View {
    var body: some View {
        let height = GameEmblem.height
        let width = height / ConnectFourGeometry.aspect
        let disc = ConnectFourGeometry.disc * width * 1.25
        ZStack {
            ForEach(Self.discs.indices, id: \.self) { index in
                let (row, column, asset) = Self.discs[index]
                Image(asset)
                    .resizable()
                    .frame(width: disc, height: disc)
                    .position(x: ConnectFourGeometry.colX[column] * width,
                              y: ConnectFourGeometry.rowY[row] * height)
            }
            Image("ConnectFourFrame")
                .resizable()
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }

    /// (row, column, asset): a short game in progress, red stacking toward
    /// a vertical four.
    private static let discs: [(Int, Int, String)] = [
        (5, 2, "ConnectFourDiscRed"), (5, 3, "ConnectFourDiscYellow"),
        (4, 3, "ConnectFourDiscRed"), (5, 4, "ConnectFourDiscYellow"),
        (3, 3, "ConnectFourDiscRed"),
    ]
}

/// L·R·C's tile art: three tiny dice faces, drawn as rounded squares with
/// letter pips, the game's whole identity is "roll an L, R, or C". The
/// other three dice games show a real pip die instead (`MiniPipDie`) or the
/// physical box they're played on (`MiniShutBox`).
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
/// printed glyph. Yahtzee and Zilch are "real dice" games that read by
/// face value, not a house-invented letter. Only 5 and 6 pips are wired
/// (the two callers); the layout table is written generally enough that
/// adding the rest later is one more array entry.
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

/// Shut the Box's tile art: the real wooden rail image (`ShutBoxFrame`,
/// the same asset `ShutBoxBoxView` plays the full game on) at tile scale.
/// The box itself is distinctive enough not to need any overlay at this size.
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
