import SwiftUI

/// The live table: plates around the rim, deck and trump on the felt,
/// the current trick landing in the middle.
struct TableGameView: View {
    @Bindable var host: GameHostController

    /// Free play: a card back being dragged off the deck toward a plate.
    @State private var dealDragLocation: CGPoint?
    /// Free play: a just-dealt card flying deck → plate.
    @State private var dealFlight: (id: UUID, to: CGPoint)?

    private let deckAnchor = CGPoint(x: 0.20, y: 0.47)

    var body: some View {
        GeometryReader { geo in
            if let state = host.state {
                ZStack {
                    seatPlates(state: state, size: geo.size)
                    DeckAndTrumpView(state: state)
                        .position(x: deckAnchor.x * geo.size.width,
                                  y: deckAnchor.y * geo.size.height)
                    if state.gameKind == .freePlay {
                        freePlayCards(state: state, size: geo.size)
                        dealLayer(state: state, size: geo.size)
                    } else {
                        trickCards(state: state, size: geo.size)
                    }
                    phaseOverlay(state: state)
                }
                .onChange(of: state.phase) { _, newPhase in
                    autoAdvance(from: newPhase)
                }
            }
        }
    }

    // MARK: free-play dealing (drag the deck onto a nameplate)

    private func dealLayer(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        return ZStack {
            // Hotspot over the deck: grab a card off the top.
            Color.clear
                .frame(width: 150, height: 190)
                .contentShape(Rectangle())
                .position(x: deckAnchor.x * size.width, y: deckAnchor.y * size.height)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in dealDragLocation = value.location }
                        .onEnded { value in
                            defer { dealDragLocation = nil }
                            guard let target = seatHit(at: value.location,
                                                       anchors: anchors, size: size,
                                                       seats: state.seats) else { return }
                            Haptics.play()
                            let plate = CGPoint(x: anchors[target].x * size.width,
                                                y: anchors[target].y * size.height)
                            let flight = (id: UUID(), to: plate)
                            dealFlight = flight
                            host.drawCard(for: target)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if dealFlight?.id == flight.id { dealFlight = nil }
                            }
                        }
                )

            // The card back under the finger.
            if let location = dealDragLocation {
                CardView(card: Card(id: "dealing", kind: .standard(suit: .spades, rank: 2)),
                         faceUp: false, elevation: 1)
                    .frame(width: 96)
                    .position(location)
                    .allowsHitTesting(false)
                // Plates light up when the card hovers close enough.
                if let hover = seatHit(at: location, anchors: anchors, size: size,
                                       seats: state.seats) {
                    Circle()
                        .fill(PlayerPalette.color(state.seats[hover].colorIndex).opacity(0.28))
                        .frame(width: 130, height: 130)
                        .position(x: anchors[hover].x * size.width,
                                  y: anchors[hover].y * size.height)
                        .allowsHitTesting(false)
                }
            }

            // A released deal glides home, then the phone shows the card.
            if let flight = dealFlight {
                DealFlightView(from: CGPoint(x: deckAnchor.x * size.width,
                                             y: deckAnchor.y * size.height),
                               to: flight.to)
                    .id(flight.id)
            }
        }
    }

    private func seatHit(at point: CGPoint, anchors: [CGPoint], size: CGSize,
                         seats: [Seat]) -> Int? {
        for seat in seats {
            let plate = CGPoint(x: anchors[seat.id].x * size.width,
                                y: anchors[seat.id].y * size.height)
            if hypot(plate.x - point.x, plate.y - point.y) < 110 { return seat.id }
        }
        return nil
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

    /// Free play: played cards pile up loosely in the middle of the felt,
    /// newest on top. Each card FLIES IN from its player's edge of the
    /// table — you see it leave the phone and land.
    private func freePlayCards(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        let recent = state.discardPile.suffix(14)
        let cardWidth = min(size.width * 0.105, 120)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let jitter = TableGeometry.jitterDegrees(cardID: card.id)
            let dx = TableGeometry.jitterDegrees(cardID: String(card.id.reversed())) / 90.0
            let dy = TableGeometry.jitterDegrees(cardID: card.id + "y") / 110.0
            let pile = CGPoint(x: (0.52 + dx) * size.width, y: (0.47 + dy) * size.height)
            let fromSeat = host.seatByPlayedCard[card.id]
            let origin: CGSize = {
                guard let seat = fromSeat, anchors.indices.contains(seat) else {
                    return CGSize(width: 0, height: 80)
                }
                // Start just OUTSIDE the felt on that player's side.
                let anchor = anchors[seat]
                return CGSize(width: (anchor.x - 0.5) * size.width * 1.35 - (pile.x - size.width * 0.5),
                              height: (anchor.y - 0.5) * size.height * 1.35 - (pile.y - size.height * 0.5))
            }()
            CardView(card: card, faceUp: true)
                .frame(width: cardWidth)
                .rotationEffect(.degrees(jitter * 2.2))
                .position(pile)
                .zIndex(Double(index))
                .transition(.asymmetric(
                    insertion: .offset(origin).combined(with: .scale(scale: 1.15)).combined(with: .opacity),
                    removal: .opacity))
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: state.discardPile.count)
        }
    }

/// The dealt card back gliding from the deck to a nameplate.
struct DealFlightView: View {
    let from: CGPoint
    let to: CGPoint
    @State private var progress: CGFloat = 0

    var body: some View {
        CardView(card: Card(id: "flight", kind: .standard(suit: .spades, rank: 2)),
                 faceUp: false, elevation: 0.7 * (1 - progress))
            .frame(width: 96)
            .position(x: from.x + (to.x - from.x) * progress,
                      y: from.y + (to.y - from.y) * progress)
            .opacity(progress > 0.92 ? (1 - progress) / 0.08 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) { progress = 1 }
            }
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
