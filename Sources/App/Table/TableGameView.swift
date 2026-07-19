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
        // Tracked read: every engine mutation bumps this, every bump
        // redraws the felt. Without it, landings wait for unrelated events.
        let _ = host.stateVersion
        return GeometryReader { geo in
            if let state = host.state {
                ZStack {
                    seatPlates(state: state, size: geo.size)
                    DeckAndTrumpView(state: state)
                        .position(x: deckAnchor.x * geo.size.width,
                                  y: deckAnchor.y * geo.size.height)
                    if state.gameKind == .freePlay {
                        dealHotspot(state: state, size: geo.size)
                        freePlayCards(state: state, size: geo.size)
                        dealVisuals(state: state, size: geo.size)
                        gatherButton(size: geo.size)
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

    /// Gesture-only layer UNDER the cards: grab the deck to deal. Cards
    /// resting nearby keep their own drag priority because they're above.
    private func dealHotspot(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        return Color.clear
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
    }

    /// Rendering-only layer ABOVE the cards: the card back under the
    /// finger, the plate glow, and the dealt-card flight.
    @ViewBuilder
    private func dealVisuals(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        if let location = dealDragLocation {
            CardView(card: Card(id: "dealing", kind: .standard(suit: .spades, rank: 2)),
                     faceUp: false, elevation: 1)
                .frame(width: 96)
                .position(location)
                .allowsHitTesting(false)
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
        if let flight = dealFlight {
            DealFlightView(from: CGPoint(x: deckAnchor.x * size.width,
                                         y: deckAnchor.y * size.height),
                           to: flight.to)
                .id(flight.id)
        }
    }

    /// Everything back into one shuffled deck — the "clean up the table"
    /// move between free-play experiments.
    private func gatherButton(size: CGSize) -> some View {
        Button {
            Haptics.arm()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                host.gatherAndShuffle()
            }
        } label: {
            Label("Shuffle it all back", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .position(x: size.width - 130, y: size.height - 44)
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

    /// Free play: played cards are PHYSICAL. They fly in from their
    /// player's edge, then live on the felt: drag to slide them anywhere,
    /// tap to flip, drop on the deck to bury them, drop on a nameplate to
    /// hand them to that player's phone.
    @State private var touchedCardID: String?

    private func freePlayCards(state: GameState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: state.seats.count)
        let recent = state.discardPile.suffix(20)
        let cardWidth = min(size.width * 0.105, 120)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let jitter = TableGeometry.jitterDegrees(cardID: card.id)
            let dx = TableGeometry.jitterDegrees(cardID: String(card.id.reversed())) / 90.0
            let dy = TableGeometry.jitterDegrees(cardID: card.id + "y") / 110.0
            let restPos = host.freePlayLayout[card.id].map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            } ?? CGPoint(x: (0.52 + dx) * size.width, y: (0.47 + dy) * size.height)
            let fromSeat = host.seatByPlayedCard[card.id]
            let origin: CGSize = {
                guard let seat = fromSeat, anchors.indices.contains(seat) else {
                    return CGSize(width: 0, height: 80)
                }
                // Start just OUTSIDE the felt on that player's side.
                let anchor = anchors[seat]
                return CGSize(width: (anchor.x - 0.5) * size.width * 1.35 - (restPos.x - size.width * 0.5),
                              height: (anchor.y - 0.5) * size.height * 1.35 - (restPos.y - size.height * 0.5))
            }()
            let isTouched = touchedCardID == card.id

            CardView(card: card,
                     faceUp: !host.faceDownCards.contains(card.id),
                     elevation: isTouched ? 0.8 : 0)
                .frame(width: cardWidth)
                .rotationEffect(.degrees(jitter * 2.2))
                .position(restPos)
                .zIndex(isTouched ? 500 : Double(index))
                .transition(.asymmetric(
                    insertion: .offset(origin).combined(with: .scale(scale: 1.15)).combined(with: .opacity),
                    removal: .opacity))
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: state.discardPile.count)
                .onTapGesture {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        if host.faceDownCards.contains(card.id) {
                            host.faceDownCards.remove(card.id)
                        } else {
                            host.faceDownCards.insert(card.id)
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            touchedCardID = card.id
                            host.freePlayLayout[card.id] = CGPoint(
                                x: value.location.x / size.width,
                                y: value.location.y / size.height)
                        }
                        .onEnded { value in
                            touchedCardID = nil
                            // Dropped on the deck: bury it back in the pile.
                            let deckPos = CGPoint(x: deckAnchor.x * size.width,
                                                  y: deckAnchor.y * size.height)
                            if hypot(deckPos.x - value.location.x,
                                     deckPos.y - value.location.y) < 110 {
                                Haptics.play()
                                host.moveTableCard(card.id, to: .deck,
                                                   seat: fromSeat ?? state.seats[0].id)
                                return
                            }
                            // Dropped on a nameplate: into that player's hand.
                            if let target = seatHit(at: value.location, anchors: anchors,
                                                    size: size, seats: state.seats) {
                                Haptics.play()
                                host.moveTableCard(card.id, to: .hand, seat: target)
                            }
                        }
                )
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
