import SwiftUI

/// Phase router for a phone: connect → wait in lobby → bid → play → recap.
struct HandRootView: View {
    @State private var client: GameClientController
    @Environment(\.scenePhase) private var scenePhase

    init(playerName: String) {
        _client = State(initialValue: GameClientController(playerName: playerName))
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
            if phase == .active { client.session.refresh() }
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
        switch client.snapshot?.phase {
        case nil, .lobby:
            LobbyWaitView(playerName: client.playerName)
        case .bidding, .choosingTrump:
            if client.snapshot?.phase == .choosingTrump(seat: client.mySeat ?? -1) {
                TrumpChooserView(client: client)
            } else {
                BidEntryView(client: client)
            }
        case .dealing, .playing, .trickComplete:
            HandView(client: client)
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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(CardStyle.gold)
            Text("You're at the table, \(playerName)!")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            Text("Watch the iPad — the game starts there.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Dealer flipped a Wizard: choose trump, privately, on your phone.
struct TrumpChooserView: View {
    @Bindable var client: GameClientController

    var body: some View {
        VStack(spacing: 24) {
            Text(client.snapshot?.gameKind == .crazyEights
                 ? "Wild eight!\nName the new suit"
                 : "You flipped a Wizard —\npick the trump suit")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            HStack(spacing: 18) {
                ForEach(Suit.allCases, id: \.self) { suit in
                    Button {
                        Haptics.play()
                        if client.snapshot?.gameKind == .crazyEights {
                            client.declareSuit(suit)
                        } else {
                            client.chooseTrump(suit)
                        }
                    } label: {
                        Text(suit.symbol)
                            .font(.system(size: 44))
                            .foregroundStyle(suit.isRed ? CardStyle.crimson : CardStyle.ink)
                            .frame(width: 74, height: 74)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(CardStyle.stockTop))
                    }
                    .buttonStyle(.plain)
                }
            }
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
            if let bid = client.snapshot?.myBid, let taken = client.snapshot?.myTricksWon {
                Text(bid == taken ? "Nailed it: \(taken) of \(bid) ✓"
                                  : "Took \(taken), bid \(bid)")
                    .font(.title3)
                    .foregroundStyle(bid == taken ? Color(red: 0.4, green: 0.8, blue: 0.5)
                                                  : .white.opacity(0.8))
            }
            Text("Scores are on the table.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
