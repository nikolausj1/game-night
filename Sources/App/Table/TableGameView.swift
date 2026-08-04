import SwiftUI

/// The live table: plates around the rim, deck and trump on the felt,
/// the current trick landing in the middle.
struct TableGameView: View {
    @Bindable var host: GameHostController

    /// TV/external-display mode: pure rendering — no gestures, no buttons,
    /// and crucially no auto-advance (the real table owns the game clock).
    var isSpectator: Bool = false

    /// Free play: a card back being dragged off the deck toward a plate.
    @State private var dealDragLocation: CGPoint?
    /// The deal confirmation: one motion from the RELEASE POINT to the
    /// plate, then gone — no ghost replay from the deck.
    @State private var dealFlight: (id: UUID, from: CGPoint, to: CGPoint)?

    /// Seat plates dragged to match where people actually sit
    /// (normalized). Session-scoped; every layer reads through this.
    @State private var plateOverrides: [Int: CGPoint] = [:]
    @State private var draggingPlateSeat: Int?

    /// Exit affordance: tap dead felt → a hold-to-close dial appears.
    @State private var showCloseButton = false
    @State private var closeRingProgress: CGFloat = 0
    /// Wired by TableRootView at integration; closes back to the menu.
    var onClose: (() -> Void)? = nil

    private let deckAnchor = CGPoint(x: 0.20, y: 0.47)

    /// Default geometry bent by wherever the humans dragged their plates.
    private func effectiveAnchors(_ state: GameState) -> [CGPoint] {
        var anchors = TableGeometry.seatAnchors(count: state.seats.count)
        for (seat, point) in plateOverrides where anchors.indices.contains(seat) {
            anchors[seat] = point
        }
        return anchors
    }

    var body: some View {
        // Tracked read: every engine mutation bumps this, every bump
        // redraws the felt. Without it, landings wait for unrelated events.
        let _ = host.stateVersion
        return GeometryReader { geo in
            if let state = host.state {
                ZStack {
                    // Dead-felt tap: summon the exit dial (auto-hides).
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showCloseButton.toggle()
                            }
                            if showCloseButton {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                    withAnimation { showCloseButton = false }
                                }
                            }
                        }
                    seatPlates(state: state, size: geo.size)
                    DeckAndTrumpView(state: state)
                        .position(x: deckAnchor.x * geo.size.width,
                                  y: deckAnchor.y * geo.size.height)
                    if state.gameKind == .freePlay {
                        dealHotspot(state: state, size: geo.size)
                        freePlayCards(state: state, size: geo.size)
                        dealVisuals(state: state, size: geo.size)
                        gatherButton(size: geo.size)
                    } else if state.gameKind.isTrickTaking {
                        trickCards(state: state, size: geo.size)
                    } else {
                        // Shedding games (UNO, Crazy Eights): the play pile.
                        dealHotspot(state: state, size: geo.size)
                        shedPile(state: state, size: geo.size)
                        dealVisuals(state: state, size: geo.size)
                    }
                    phaseOverlay(state: state)
                    if showCloseButton, !isSpectator {
                        HoldToCloseButton(progress: $closeRingProgress) {
                            onClose?()
                        }
                        .position(x: 64, y: 56)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(!isSpectator)
                .onChange(of: state.phase) { _, newPhase in
                    guard !isSpectator else { return }
                    autoAdvance(from: newPhase)
                }
                .onChange(of: state.discardPile.count) { _, _ in
                    // A card that leaves the felt (buried, handed off,
                    // shuffled back) gets a fresh toss if it returns.
                    let current = Set(state.discardPile.map(\.id))
                    seenCardIDs.formIntersection(current)
                    rotationByCard = rotationByCard.filter { current.contains($0.key) }
                }
            }
        }
    }

    // MARK: free-play dealing (drag the deck onto a nameplate)

    /// Gesture-only layer UNDER the cards: grab the deck to deal. Cards
    /// resting nearby keep their own drag priority because they're above.
    private func dealHotspot(state: GameState, size: CGSize) -> some View {
        let anchors = effectiveAnchors(state)
        return Color.clear
            .frame(width: 150, height: 190)
            .contentShape(Rectangle())
            .position(x: deckAnchor.x * size.width, y: deckAnchor.y * size.height)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in dealDragLocation = value.location }
                    .onEnded { value in
                        defer { dealDragLocation = nil }
                        if let target = seatHit(at: value.location,
                                                anchors: anchors, size: size,
                                                seats: state.seats) {
                            // Deal to a player: confirmation continues from
                            // the FINGER to the plate and slides away.
                            Haptics.play()
                            let plate = CGPoint(x: anchors[target].x * size.width,
                                                y: anchors[target].y * size.height)
                            let flight = (id: UUID(), from: value.location, to: plate)
                            dealFlight = flight
                            host.drawCard(for: target)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if dealFlight?.id == flight.id { dealFlight = nil }
                            }
                            return
                        }
                        // Released on open felt: pull the top card straight
                        // onto the table, face-down where it was dropped.
                        let deckPos = CGPoint(x: deckAnchor.x * size.width,
                                              y: deckAnchor.y * size.height)
                        let farFromDeck = hypot(deckPos.x - value.location.x,
                                                deckPos.y - value.location.y) > 130
                        if farFromDeck, let top = state.drawPile.last {
                            Haptics.play()
                            host.moveTableCard(top.id, to: .table, seat: state.seats[0].id)
                            host.freePlayLayout[top.id] = CGPoint(
                                x: min(0.94, max(0.06, value.location.x / size.width)),
                                y: min(0.92, max(0.08, value.location.y / size.height)))
                            host.faceDownCards.insert(top.id)
                        }
                    }
            )
    }

    /// Rendering-only layer ABOVE the cards: the card back under the
    /// finger, the plate glow, and the dealt-card flight.
    @ViewBuilder
    private func dealVisuals(state: GameState, size: CGSize) -> some View {
        let anchors = effectiveAnchors(state)
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
            DealFlightView(from: flight.from, to: flight.to)
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
        let anchors = effectiveAnchors(state)
        return ForEach(state.seats) { seat in
            SeatPlateView(seat: seat, state: state)
                .scaleEffect(draggingPlateSeat == seat.id ? 1.08 : 1)
                .shadow(color: .black.opacity(draggingPlateSeat == seat.id ? 0.5 : 0),
                        radius: 12, y: 6)
                .position(x: anchors[seat.id].x * size.width,
                          y: anchors[seat.id].y * size.height)
                // Sit wherever you like: drag your plate to match your
                // real chair. Everything (deals, tosses, glows) follows.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if draggingPlateSeat != seat.id {
                                draggingPlateSeat = seat.id
                                Haptics.tick()
                            }
                            plateOverrides[seat.id] = CGPoint(
                                x: min(0.96, max(0.04, value.location.x / size.width)),
                                y: min(0.95, max(0.05, value.location.y / size.height)))
                        }
                        .onEnded { _ in
                            draggingPlateSeat = nil
                            Haptics.arm()
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8),
                           value: draggingPlateSeat)
        }
    }

    // MARK: trick

    private func trickCards(state: GameState, size: CGSize) -> some View {
        let anchors = effectiveAnchors(state)
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

            // Entry vector: from this player's edge, so the slide-in
            // direction always matches who threw it.
            let entryOffset = CGSize(
                width: ((anchors[play.seat].x - 0.5) * 1.22 + 0.5 - pose.position.x) * size.width,
                height: ((anchors[play.seat].y - 0.47) * 1.22 + 0.47 - pose.position.y) * size.height)

            CardView(card: play.card, faceUp: true, elevation: sweeping ? 0.3 : 0)
                .frame(width: cardWidth)
                .rotationEffect(pose.rotation)
                .position(x: target.x * size.width, y: target.y * size.height)
                .opacity(sweeping ? 0 : 1)
                .transition(.asymmetric(
                    insertion: .offset(entryOffset)
                        .animation(FeltPhysics.slide(duration: 0.45)),
                    removal: .identity))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: sweeping)
                .animation(FeltPhysics.slide(duration: 0.45), value: trick.count)
        }
    }

    /// Free play: played cards are PHYSICAL. Arrivals run the felt physics
    /// (friction slide + damped spin, scaled by the real flick velocity),
    /// then cards live on the felt: drag to slide them anywhere, tap to
    /// flip, drop on the deck to bury them, drop on a nameplate to hand
    /// them to that player's phone.
    @State private var touchedCardID: String?
    @State private var seenCardIDs: Set<String> = []
    @State private var rotationByCard: [String: Double] = [:]
    @State private var slidingCards: Set<String> = []
    /// 3D flip angle per card while a flip is in motion.
    @State private var flipAngle: [String: Double] = [:]

    private func freePlayCards(state: GameState, size: CGSize) -> some View {
        let recent = state.discardPile.suffix(20)
        let cardWidth = min(size.width * 0.105, 120)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let jitter = TableGeometry.jitterDegrees(cardID: card.id)
            let dx = TableGeometry.jitterDegrees(cardID: String(card.id.reversed())) / 90.0
            let dy = TableGeometry.jitterDegrees(cardID: card.id + "y") / 110.0
            let restPos = host.freePlayLayout[card.id].map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            } ?? CGPoint(x: (0.52 + dx) * size.width, y: (0.47 + dy) * size.height)
            let isTouched = touchedCardID == card.id
            let isSliding = slidingCards.contains(card.id)

            let flip = flipAngle[card.id] ?? 0

            CardView(card: card,
                     faceUp: !host.faceDownCards.contains(card.id),
                     elevation: isTouched ? 0.8 : (isSliding ? 0.45 : 0))
                .frame(width: cardWidth)
                // A real flip: the card turns over its own long axis and
                // lifts slightly at the apex, like a thumb turning it.
                .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .scaleEffect(1 + abs(flip) / 90 * 0.06)
                .rotationEffect(.degrees(rotationByCard[card.id] ?? jitter * 2.2))
                .position(restPos)
                .zIndex(isTouched ? 500 : (isSliding || flip != 0 ? 400 : Double(index)))
                .transition(.opacity)
                .onAppear { animateArrivalIfNew(card: card, state: state, size: size) }
                .onTapGesture { flipCard(card.id) }
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
                            let anchors = effectiveAnchors(state)
                            // Dropped on the deck: bury it back in the pile.
                            let deckPos = CGPoint(x: deckAnchor.x * size.width,
                                                  y: deckAnchor.y * size.height)
                            if hypot(deckPos.x - value.location.x,
                                     deckPos.y - value.location.y) < 110 {
                                Haptics.play()
                                host.moveTableCard(card.id, to: .deck,
                                                   seat: host.seatByPlayedCard[card.id] ?? state.seats[0].id)
                                return
                            }
                            // Dropped on a nameplate: into that player's hand.
                            if let target = seatHit(at: value.location, anchors: anchors,
                                                    size: size, seats: state.seats) {
                                Haptics.play()
                                host.moveTableCard(card.id, to: .hand, seat: target)
                                return
                            }
                            // Otherwise: released mid-slide — let momentum
                            // carry it a little farther on the felt.
                            let v = value.velocity
                            let vMag = hypot(v.width, v.height)
                            if vMag > 120 {
                                let glide = min(0.22, Double(vMag) / 9000.0)
                                let rest = CGPoint(
                                    x: min(0.94, max(0.06, (value.location.x + v.width * glide) / size.width)),
                                    y: min(0.92, max(0.08, (value.location.y + v.height * glide) / size.height)))
                                let duration = 0.25 + glide * 1.3
                                slidingCards.insert(card.id)
                                withAnimation(FeltPhysics.slide(duration: duration)) {
                                    host.freePlayLayout[card.id] = rest
                                    slidingCards.remove(card.id)
                                }
                            }
                        }
                )
        }
    }

    /// UNO / Crazy Eights: the discard is the heart of the table. Every
    /// play travels the whole way — off the thrower's edge, across the
    /// felt, then PLACED on top of the pile: it overshoots a touch high
    /// and drops flat like a hand letting go of a card.
    /// Explicit two-phase animation (never a SwiftUI transition — those
    /// proved unreliable for network-driven insertions).
    @State private var shedPoses: [String: CGPoint] = [:]      // current render pos
    @State private var shedRotations: [String: Double] = [:]
    @State private var shedElevations: [String: CGFloat] = [:] // >0 while airborne
    @State private var shedSeen: Set<String> = []

    private func shedPile(state: GameState, size: CGSize) -> some View {
        let recent = state.discardPile.suffix(4)
        let cardWidth = min(size.width * 0.125, 140)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let jitter = TableGeometry.jitterDegrees(cardID: card.id)
            let restPos = CGPoint(
                x: 0.52 * size.width + CGFloat(jitter) * 0.35,
                y: 0.47 * size.height + CGFloat(TableGeometry.jitterDegrees(cardID: card.id + "y")) * 0.3)
            CardView(card: card, faceUp: true,
                     elevation: shedElevations[card.id] ?? 0)
                .frame(width: cardWidth)
                .rotationEffect(.degrees(shedRotations[card.id] ?? jitter * 1.8))
                .position(shedPoses[card.id] ?? restPos)
                .zIndex((shedElevations[card.id] ?? 0) > 0 ? 400 : Double(index))
                .onAppear { animateShedArrival(card: card, restPos: restPos,
                                               restRotation: jitter * 1.8,
                                               state: state, size: size) }
        }
        .onChange(of: state.discardPile.count) { _, _ in
            let current = Set(state.discardPile.map(\.id))
            shedSeen.formIntersection(current)
            shedPoses = shedPoses.filter { current.contains($0.key) }
            shedRotations = shedRotations.filter { current.contains($0.key) }
        }
    }

    /// Edge → glide across the felt → hang a beat above the pile → drop
    /// flat. The drop is the "someone set it down" moment: elevation and
    /// the last few points of travel land together with a crisp spring.
    private func animateShedArrival(card: Card, restPos: CGPoint,
                                    restRotation: Double,
                                    state: GameState, size: CGSize) {
        guard !shedSeen.contains(card.id) else { return }
        shedSeen.insert(card.id)
        // Cards already down when this view appeared (resume, rejoin)
        // don't replay their landing.
        guard card.id == state.discardPile.last?.id else {
            shedPoses[card.id] = restPos
            shedRotations[card.id] = restRotation
            return
        }

        let anchors = effectiveAnchors(state)
        let seat = host.seatByPlayedCard[card.id]
        let entry: CGPoint = {
            guard let seat, anchors.indices.contains(seat) else {
                return CGPoint(x: restPos.x, y: size.height * 1.08)
            }
            let anchor = anchors[seat]
            return CGPoint(x: ((anchor.x - 0.5) * 1.22 + 0.5) * size.width,
                           y: ((anchor.y - 0.47) * 1.22 + 0.47) * size.height)
        }()
        // Approach point: just short of the pile, still airborne.
        let approach = CGPoint(x: restPos.x + (entry.x - restPos.x) * 0.12,
                               y: restPos.y + (entry.y - restPos.y) * 0.12)

        // Phase 0: materialize at the thrower's edge, high and spinning.
        shedPoses[card.id] = entry
        shedRotations[card.id] = restRotation - TableGeometry.jitterDegrees(cardID: card.id) * 3.5
        shedElevations[card.id] = 0.9

        let travel = hypot(restPos.x - entry.x, restPos.y - entry.y)
        let glide = 0.30 + Double(travel / size.width) * 0.28

        DispatchQueue.main.async {
            // Phase 1: the flight — friction curve across the felt, card
            // stays lifted, spin unwinding.
            withAnimation(FeltPhysics.slide(duration: glide)) {
                shedPoses[card.id] = approach
                shedRotations[card.id] = restRotation
                shedElevations[card.id] = 0.35
            }
            // Phase 2: the placement — last inch + drop, crisp and springy,
            // shadows snapping to contact.
            DispatchQueue.main.asyncAfter(deadline: .now() + glide * 0.92) {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.68)) {
                    shedPoses[card.id] = restPos
                    shedElevations[card.id] = 0
                }
            }
        }
    }

    /// A literal flip: rotate to edge-on (90°), swap the printed side
    /// while the card is invisible, then finish the turn from −90° back
    /// to flat. One continuous motion to the eye.
    private func flipCard(_ id: String) {
        guard (flipAngle[id] ?? 0) == 0 else { return } // one flip at a time
        Haptics.tick()
        withAnimation(.easeIn(duration: 0.14)) {
            flipAngle[id] = 90
        } completion: {
            if host.faceDownCards.contains(id) {
                host.faceDownCards.remove(id)
            } else {
                host.faceDownCards.insert(id)
            }
            flipAngle[id] = -90
            withAnimation(.easeOut(duration: 0.16)) {
                flipAngle[id] = 0
            }
        }
    }

    /// First sighting of a card on the felt → run its toss. Uses the real
    /// flick velocity when the thrower's phone sent one.
    private func animateArrivalIfNew(card: Card, state: GameState, size: CGSize) {
        guard state.gameKind == .freePlay, !seenCardIDs.contains(card.id) else { return }
        seenCardIDs.insert(card.id)
        // Cards present before this view existed (rejoin, relaunch) stay put.
        guard host.freePlayLayout[card.id] == nil else { return }

        let anchors = effectiveAnchors(state)
        let seat = host.seatByPlayedCard[card.id]
        let toss = FeltPhysics.toss(
            cardID: card.id,
            seatAnchor: seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil },
            throwVelocity: host.throwVelocityByCard.removeValue(forKey: card.id),
            tableSize: size)

        // Phase 1: materialize at the entry edge, mid-spin, lifted.
        host.freePlayLayout[card.id] = toss.entry
        rotationByCard[card.id] = toss.restRotation - toss.spin
        slidingCards.insert(card.id)

        // Phase 2: friction takes it from there.
        DispatchQueue.main.async {
            withAnimation(FeltPhysics.slide(duration: toss.duration)) {
                host.freePlayLayout[card.id] = toss.rest
                rotationByCard[card.id] = toss.restRotation
                _ = slidingCards.remove(card.id)
            }
        }
    }

/// Press-and-hold exit: a timer ring fills while you hold; release early
/// and nothing happens. Accidental elbow-proof, kid-resistant.
struct HoldToCloseButton: View {
    @Binding var progress: CGFloat
    let onComplete: () -> Void
    @State private var holding = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 64, height: 64)
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 4)
                .frame(width: 56, height: 56)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(CardStyle.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .scaleEffect(holding ? 1.1 : 1)
        .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 40) {
            Haptics.play()
            progress = 0
            onComplete()
        } onPressingChanged: { pressing in
            holding = pressing
            if pressing {
                Haptics.tick()
                withAnimation(.linear(duration: 1.2)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: holding)
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
