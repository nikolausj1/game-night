import SwiftUI

extension Notification.Name {
    /// Fallback exit path for "Leave table" when HandRootView's `onLeave`
    /// hasn't been wired up by whoever owns navigation (see HandRootView's
    /// doc comment). Posted so anything — RoleRouter or otherwise — can
    /// observe it and reset navigation; the session is already stopped by
    /// the time this fires either way.
    static let gameNightLeaveTable = Notification.Name("gameNightLeaveTable")
}

/// Phase router for a phone: connect → wait in lobby → bid → play → recap.
struct HandRootView: View {
    @State private var client: GameClientController
    /// Set by whoever owns role/navigation state (RoleRouter) so "Leave
    /// table" (in HandView's Menu sheet) can pop back to the role picker.
    /// RoleRouter lives outside Sources/App/Hand, so it isn't edited here —
    /// the one-line wiring is:
    ///
    ///     HandRootView(playerName: ..., onLeave: { role = .undecided })
    ///
    /// in RoleRouter.roleSwitch's `.hand` case. If that line is never
    /// added, leaving still stops the Multipeer session (via
    /// client.session.stop()); the phone just won't navigate anywhere on
    /// its own, and a NotificationCenter post named `.gameNightLeaveTable`
    /// fires instead as a fallback for anything that wants to observe it.
    var onLeave: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase

    init(playerName: String, onLeave: (() -> Void)? = nil) {
        // `State(initialValue:)` evaluates on EVERY struct init, so this
        // must never construct a fresh controller inline: each stray
        // controller opened a real second Multipeer session whose hello
        // stole this device's routing on the host (the "table ignores my
        // pour" bug). `obtain` reuses the one live client per phone.
        _client = State(initialValue: GameClientController.obtain(playerName: playerName))
        self.onLeave = onLeave
    }

    var body: some View {
        ZStack {
            FeltBackground()
            content
        }
        .statusBarHidden()
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the lock screen: the Multipeer session is
            // dead even when it claims otherwise. Rebuild and rejoin —
            // the host reseats us by device ID with our exact hand.
            // Demo mode stays fully OFFLINE: this refresh was the one
            // leak that let a -demoHand run open a real browser and
            // join a live table mid-screenshot (field-observed).
            if phase == .active, !DemoData.wantsHandDemo {
                client.session.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .connected = client.connectionState {
            connectedContent
        } else if DemoData.wantsHandDemo {
            connectedContent
                .onAppear {
                    if client.snapshot == nil {
                        client.adoptDemoSnapshot(DemoData.makeHandSnapshot())
                    }
                }
        } else if client.snapshot != nil {
            // Mid-game blip: keep the hand on screen while the session
            // rebuilds — losing your cards to a spinner feels like a crash.
            connectedContent
                .overlay(alignment: .top) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(CardStyle.gold)
                        Text("Reconnecting to the table…")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(CardStyle.stockTop)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.top, 52)
                }
        } else {
            SearchingView(state: client.connectionState)
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        if let sideGameState = client.sideGameState {
            // Generic side-game mode: the registry picks the hand view by
            // kind (see SideGameRegistry.entries).
            SideGameRegistry.handView(kind: sideGameState.kind, client: client)
        } else if client.cribbageSnapshot != nil {
            // Cribbage mode: the table is running a cribbage game — this
            // phone is a cribbage hand, not the trick-game card UI below.
            CribbageHandView(client: client, onLeave: onLeave)
        } else if client.diceState != nil {
            // Dice mode: the table is running a dice game — this phone is
            // a dice cup, not a card hand.
            DiceCupView(client: client)
        } else {
            cardContent
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch client.snapshot?.phase {
        case nil, .lobby:
            LobbyWaitView(playerName: client.playerName)
        case .bidding, .choosingTrump:
            if client.snapshot?.phase == .choosingTrump(seat: client.mySeat ?? -1) {
                if client.snapshot?.gameKind == .uno {
                    // UNO keeps your hand on screen for the color choice —
                    // full-screen replacement would hide the cards you're
                    // about to keep playing with. See HandView's compact
                    // color-choice overlay. Trick-game trump choice and
                    // Crazy Eights still get the full-screen chooser below.
                    HandView(client: client, onLeave: onLeave)
                } else {
                    TrumpChooserView(client: client)
                }
            } else if client.snapshot?.gameKind == .uno {
                // UNO has no bids — someone else is naming a color after a
                // wild. The bid wheel would be nonsense here.
                UnoWaitingForColorView()
            } else {
                BidEntryView(client: client)
            }
        case .dealing, .playing, .trickComplete, .passing:
            // Hearts passing: the hand stays up; the pass-3 selection UI
            // lands with the Hearts/Spades UI wave (HandView reads phase).
            HandView(client: client, onLeave: onLeave)
        case .roundComplete, .gameOver:
            HandRecapView(client: client)
        }
    }
}

/// Looking for the table — reassuring, not technical.
struct SearchingView: View {
    let state: ClientSession.ConnectionState

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(CardStyle.gold)
            Text(label)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(.white.opacity(0.85))
            Text("Make sure the table iPad has Game Night open.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var label: String {
        switch state {
        case .searching: return "Looking for the table…"
        case .connecting(let name): return "Sitting down at \(name)…"
        case .connected(let name): return "At \(name)"
        case .disconnected: return "Reconnecting…"
        }
    }
}

/// Seated, waiting for the host to deal.
struct LobbyWaitView: View {
    let playerName: String
    @ScaledMetric(relativeTo: .largeTitle) private var sealSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: sealSize))
                .foregroundStyle(CardStyle.gold)
                .accessibilityHidden(true)
            Text("You're at the table, \(playerName)!")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            Text("Watch the iPad — the game starts there.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Dealer flipped a Wizard, someone named a wild eight, or an UNO wild
/// landed: choose the new suit/color, privately, on your phone.
struct TrumpChooserView: View {
    @Bindable var client: GameClientController
    @ScaledMetric(relativeTo: .largeTitle) private var suitGlyphSize: CGFloat = 44

    private var isUno: Bool { client.snapshot?.gameKind == .uno }
    private var isCrazyEights: Bool { client.snapshot?.gameKind == .crazyEights }

    var body: some View {
        VStack(spacing: 24) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if isUno {
                unoColorRow
            } else {
                suitRow
            }
        }
    }

    private var title: String {
        if isUno { return "Pick a color" }
        if isCrazyEights { return "Wild eight!\nName the new suit" }
        return "You flipped a Wizard —\npick the trump suit"
    }

    /// UNO's four colors, drawn as rounded swatches rather than suit glyphs.
    private var unoColorRow: some View {
        UnoColorSwatchRow(swatchSize: 74) { color in
            client.declareSuit(color.suit)
        }
    }

    private var suitRow: some View {
        HStack(spacing: 18) {
            ForEach(Suit.allCases, id: \.self) { suit in
                Button {
                    Haptics.play()
                    if isCrazyEights {
                        client.declareSuit(suit)
                    } else {
                        client.chooseTrump(suit)
                    }
                } label: {
                    Text(suit.symbol)
                        .font(.system(size: suitGlyphSize))
                        .foregroundStyle(suit.isRed ? CardStyle.crimson : CardStyle.ink)
                        .frame(width: 74, height: 74)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(CardStyle.stockTop))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(suit.rawValue.capitalized)
            }
        }
    }
}

/// UNO's four color swatches — sized for either the full-screen
/// TrumpChooserView or HandView's compact in-hand strip. Shared so the two
/// pickers stay visually consistent.
struct UnoColorSwatchRow: View {
    let swatchSize: CGFloat
    let onPick: (UnoColor) -> Void

    private var spacing: CGFloat { swatchSize > 50 ? 18 : 10 }
    private var cornerRadius: CGFloat { swatchSize * 0.22 }
    private var borderWidth: CGFloat { swatchSize > 50 ? 3 : 2 }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(UnoColor.allCases, id: \.self) { color in
                Button {
                    Haptics.play()
                    onPick(color)
                } label: {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(UnoStyle.field(for: color))
                        .frame(width: swatchSize, height: swatchSize)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.9), lineWidth: borderWidth)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
            }
        }
    }
}

/// Someone else is naming the color after a wild — the phone just waits.
struct UnoWaitingForColorView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(CardStyle.gold)
            Text("Waiting for a color…")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Between rounds / end of game, the phone shows your own line only —
/// the drama plays out on the table.
struct HandRecapView: View {
    @Bindable var client: GameClientController

    var body: some View {
        VStack(spacing: 16) {
            if client.snapshot?.phase == .gameOver {
                Text("That's the game!")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
            } else {
                Text("Round complete")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(.white)
            }
            if client.snapshot?.gameKind == .hearts {
                // Hearts has no bids: the table carries the penalty points.
                if let taken = myTricksWon {
                    Text(taken == 0 ? "Clean hand: no tricks taken"
                                    : "Took \(taken) trick\(taken == 1 ? "" : "s")")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else if let bid = myBid, let taken = myTricksWon {
                let isNil = client.snapshot?.gameKind == .spades && bid == 0
                Text(isNil ? (taken == 0 ? "Nil made ✓" : "Set on nil: took \(taken)")
                           : (bid == taken ? "Nailed it: \(taken) of \(bid) ✓"
                                           : "Took \(taken), bid \(bid)"))
                    .font(.title3)
                    .foregroundStyle(bid == taken ? Color(red: 0.4, green: 0.8, blue: 0.5)
                                                  : .white.opacity(0.8))
            }
            Text("Scores are on the table.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // Bids/tricks live on RoundState (keyed by seat). By roundComplete/
    // gameOver the host may or may not have cleared `round` yet, so fall
    // back to the just-completed entry in roundHistory.
    private var myBid: Int? {
        guard let snap = client.snapshot else { return nil }
        return snap.round?.bids[snap.mySeat] ?? snap.roundHistory.last?.bids[snap.mySeat]
    }

    private var myTricksWon: Int? {
        guard let snap = client.snapshot else { return nil }
        return snap.round?.tricksWon[snap.mySeat] ?? snap.roundHistory.last?.tricksWon[snap.mySeat]
    }
}
