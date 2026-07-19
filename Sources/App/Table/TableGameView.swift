import SwiftUI

/// The live table: plates around the rim, deck and trump on the felt,
/// the current trick landing in the middle.
struct TableGameView: View {
    @Bindable var host: GameHostController

    var body: some View {
        GeometryReader { geo in
            if let state = host.state {
                ZStack {
                    seatPlates(state: state, size: geo.size)
                    DeckAndTrumpView(state: state)
                        .position(x: geo.size.width * 0.20, y: geo.size.height * 0.47)
                    trickCards(state: state, size: geo.size)
                    phaseOverlay(state: state)
                }
                .onChange(of: state.phase) { _, newPhase in
                    autoAdvance(from: newPhase)
                }
            }
        }
    }

    // MARK: plates

    private func seatPlates(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        return ForEach(state.seats) { seat in
            SeatPlateView(seat: seat, state: state)
                .position(x: anchors[seat.id].x * size.width,
                          y: anchors[seat.id].y * size.height)
        }
    }

    // MARK: trick

    private func trickCards(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        let trick = state.round?.currentTrick ?? []
        let winnerSeat: Int? = {
            if case .trickComplete(let winner) = state.phase { return winner }
            return nil
        }()
        let cardWidth = min(size.width * 0.105, 120)

        return ForEach(trick, id: \.card.id) { play in
            let pose = TableGeometry.trickCardPose(seatAnchor: anchors[play.seat], cardID: play.card.id)
            let sweeping = winnerSeat != nil
            let target = sweeping ? anchors[winnerSeat!] : pose.position

            CardView(card: play.card, faceUp: true, elevation: sweeping ? 0.3 : 0)
                .frame(width: cardWidth)
                .rotationEffect(pose.rotation)
                .position(x: target.x * size.width, y: target.y * size.height)
                .opacity(sweeping ? 0 : 1)
                .transition(.asymmetric(
                    insertion: .offset(y: 60).combined(with: .scale(scale: 1.15)).combined(with: .opacity),
                    removal: .identity))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: sweeping)
                .animation(.spring(response: 0.38, dampingFraction: 0.75), value: trick.count)
        }
    }

    // MARK: overlays

    @ViewBuilder
    private func phaseOverlay(state: GameState) -> some View {
        switch state.phase {
        case .bidding:
            TableBanner(text: biddingBanner(state: state))
        case .choosingTrump(let seat):
            TableBanner(text: "\(state.seats[seat].playerName) is choosing trump…")
        case .trickComplete(let winner):
            TrickWonBanner(name: state.seats[winner].playerName,
                           color: PlayerPalette.color(state.seats[winner].colorIndex))
        case .roundComplete:
            RoundRecapOverlay(host: host, state: state)
        case .gameOver:
            GameOverOverlay(host: host, state: state)
        case .lobby, .dealing, .playing:
            EmptyView()
        }
    }

    private func biddingBanner(state: GameState) -> String {
        guard let round = state.round else { return "Bidding…" }
        let waiting = state.seats[round.turnSeat].playerName
        return "Round \(round.roundNumber) — \(waiting) is bidding…"
    }

    // MARK: pacing

    /// The table breathes on its own: give the trick a beat to be seen
    /// (and announced), then sweep it and move on. Rounds wait for a tap.
    private func autoAdvance(from phase: Phase) {
        if case .trickComplete = phase {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if case .trickComplete = host.state?.phase {
                    host.tableAction(.nextTrick)
                }
            }
        }
    }
}

/// Quiet strip along the top edge for narration that isn't a celebration.
struct TableBanner: View {
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.9))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(.top, 34)
            Spacer()
        }
    }
}

/// The trick-winner moment — big, brief, colored like its winner.
struct TrickWonBanner: View {
    let name: String
    let color: Color
    @State private var shown = false

    var body: some View {
        Text("\(name) takes the trick!")
            .font(.system(size: 40, weight: .bold, design: .serif))
            .foregroundStyle(CardStyle.stockTop)
            .padding(.horizontal, 36)
            .padding(.vertical, 18)
            .background(
                Capsule().fill(color.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            )
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { shown = true }
            }
    }
}
