import SwiftUI

/// The live table: plates around the rim, deck and trump on the felt,
/// the current trick landing in the middle.
struct TableGameView: View {
    @Bindable var host: GameHostController
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    /// TV/external-display mode: pure rendering — no gestures, no buttons,
    /// and crucially no auto-advance (the real table owns the game clock).
    var isSpectator: Bool = false

    /// Wired by TableRootView (nil on the spectator screen, which has no
    /// event stream of its own): transient serif callouts for game events.
    var calloutCenter: TableCalloutCenter? = nil

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

    /// The real deal: card backs streaming deck → plates at round start.
    struct DealStreamCard: Identifiable {
        let id = UUID(); let to: CGPoint; let delay: Double
    }
    @State private var dealStream: [DealStreamCard] = []
    @State private var lastDealtRound: Int = -1

    /// Table motion: a decaying whole-layer shiver for neat piles (never
    /// committed — rule games stay tidy), while free-play cards actually
    /// move (they're loose objects; that's the point).
    @State private var motionJitter: CGSize = .zero

    /// Sandbox dice in free play — a physics toy, no rules attached.
    @State private var freePlayDiceOn = false
    @State private var freePlayCoinsOn = false
    @State private var freePlayRoll: DiceGameController.Roll?
    @State private var freePlayRollCounter = 10_000 // clear of LCR roll ids

    private let deckAnchor = CGPoint(x: 0.20, y: 0.47)

    /// Default geometry bent by wherever the humans dragged their plates.
    private func effectiveAnchors(_ state: GameState) -> [CGPoint] {
        var anchors = TableGeometry.seatAnchors(count: state.seats.count)
        for (seat, point) in plateOverrides where anchors.indices.contains(seat) {
            anchors[seat] = point
        }
        return anchors
    }

    /// Plates live ON the table's rim — the iPad lies flat in the middle,
    /// so a plate's text must read for the person sitting past that edge.
    private func snapToEdge(_ p: CGPoint) -> CGPoint {
        let dLeft = p.x, dRight = 1 - p.x, dTop = p.y, dBottom = 1 - p.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return CGPoint(x: min(0.86, max(0.14, p.x)), y: 0.94) }
        if nearest == dTop { return CGPoint(x: min(0.86, max(0.14, p.x)), y: 0.06) }
        if nearest == dLeft { return CGPoint(x: 0.055, y: min(0.84, max(0.16, p.y))) }
        return CGPoint(x: 0.945, y: min(0.84, max(0.16, p.y)))
    }

    /// Reading orientation for the person nearest this plate's edge:
    /// bottom reads normally, top is upside-down to us (right side up to
    /// them), sides rotate toward their owners.
    private func outwardAngle(_ p: CGPoint) -> Angle {
        let dLeft = p.x, dRight = 1 - p.x, dTop = p.y, dBottom = 1 - p.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return .degrees(0) }
        if nearest == dTop { return .degrees(180) }
        if nearest == dLeft { return .degrees(90) }
        return .degrees(-90)
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
                    DeckAndTrumpView(state: state, tableSize: geo.size)
                        .position(x: deckAnchor.x * geo.size.width,
                                  y: deckAnchor.y * geo.size.height)
                    if state.gameKind == .freePlay {
                        dealHotspot(state: state, size: geo.size)
                        freePlayCards(state: state, size: geo.size)
                        dealVisuals(state: state, size: geo.size)
                            .zIndex(2) // above the rail (1): live drag feedback stays under the finger
                        // Sandbox dice: a pure physics toy layered on the felt.
                        if freePlayDiceOn {
                            DiceTableSceneView(roll: freePlayRoll,
                                               anchor: CGPoint(x: 0.5, y: 0.94),
                                               onResult: { _, _ in freePlayRoll = nil })
                                .allowsHitTesting(false)
                            Button {
                                Haptics.arm()
                                freePlayRollCounter += 1
                                freePlayRoll = DiceGameController.Roll(
                                    id: freePlayRollCounter, seat: 0, count: 3,
                                    intensity: Double.random(in: 0.5...1.3))
                            } label: {
                                Label("Roll", systemImage: "dice.fill")
                                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                                    .foregroundStyle(CardStyle.gold)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(.black.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .position(x: geo.size.width - 130, y: geo.size.height - 96)
                        }
                        // Sandbox coins: draggable toy chips, no rules.
                        if freePlayCoinsOn {
                            FreePlayCoinsLayer(size: geo.size)
                        }
                        FreePlayTray(
                            selectedDeck: state.rules.freePlayDeck,
                            diceOn: freePlayDiceOn,
                            coinsOn: freePlayCoinsOn,
                            onDeckChange: { deck in
                                var rules = state.rules
                                rules.freePlayDeck = deck
                                host.tableAction(.startGame(.freePlay, rules,
                                    seed: UInt64.random(in: UInt64.min...UInt64.max)))
                            },
                            onToggleDice: { on in
                                freePlayDiceOn = on
                                // Remotes become dice cups while the toy is
                                // out: a pour anywhere rolls the table.
                                host.onFreePlayDicePour = on ? { intensity in
                                    freePlayRollCounter += 1
                                    freePlayRoll = DiceGameController.Roll(
                                        id: freePlayRollCounter, seat: 0, count: 3,
                                        intensity: intensity)
                                } : nil
                                host.setFreePlayDiceEnabled(on)
                            },
                            onToggleCoins: { freePlayCoinsOn = $0 })
                            .position(x: 205, y: geo.size.height - 44)
                        gatherButton(size: geo.size)
                    } else if state.gameKind.isTrickTaking {
                        trickCards(state: state, size: geo.size)
                            .offset(motionJitter)
                    } else {
                        // Shedding games (UNO, Crazy Eights): the play pile.
                        dealHotspot(state: state, size: geo.size)
                        shedPile(state: state, size: geo.size)
                            .offset(motionJitter)
                        dealVisuals(state: state, size: geo.size)
                            .zIndex(2) // above the rail (1): live drag feedback stays under the finger
                    }
                    // Deal stream: rendered above everything but overlays.
                    ForEach(dealStream) { card in
                        DealStreamFlight(from: CGPoint(x: deckAnchor.x * geo.size.width,
                                                       y: deckAnchor.y * geo.size.height),
                                         to: card.to, delay: card.delay)
                            .zIndex(2)
                    }
                    // Manual dealing: with auto-deal off, the dealing phase
                    // gets the same drag-the-deck affordance as free play.
                    if state.phase == .dealing, !state.rules.autoDeal,
                       state.gameKind != .freePlay {
                        dealHotspot(state: state, size: geo.size)
                        dealVisuals(state: state, size: geo.size)
                            .zIndex(2) // above the rail (1): live drag feedback stays under the finger
                    }
                    // Everything below here is chrome, not felt content —
                    // pinned above the rail (1) and drag/deal feedback (2)
                    // so a dragged plate or an in-flight card can never
                    // paint over a banner or a control.
                    phaseOverlay(state: state)
                        .zIndex(10)
                    // MOUNT(signage): table callouts + direction arc + color chip overlay here
                    if let calloutCenter {
                        TableCalloutView(center: calloutCenter)
                            .position(x: geo.size.width * 0.5,
                                      y: geo.size.height * 0.16)
                            .allowsHitTesting(false)
                            .zIndex(9) // under chrome (10), over everything else
                    }
                    if state.gameKind == .uno {
                        // Ambient, on the felt: below resting cards (0+),
                        // orbiting the pile so turn direction is never a guess.
                        // Sized to orbit OUTSIDE the pile: table cards run
                        // ~140pt, so anything smaller hides under them.
                        DirectionOfPlayArc(clockwise: (state.round?.direction ?? 1) > 0)
                            .frame(width: 260, height: 260)
                            .position(x: 0.52 * geo.size.width,
                                      y: 0.47 * geo.size.height)
                            .allowsHitTesting(false)
                            .zIndex(-0.5)
                        ActiveColorChip(color: state.discardPile.last?.unoColor
                                            ?? state.round?.trumpSuit?.unoColor)
                            .position(x: 0.52 * geo.size.width,
                                      y: 0.34 * geo.size.height)
                            .allowsHitTesting(false)
                            .zIndex(9)
                    }
                    if !isSpectator {
                        GameHUD(title: state.gameKind.displayName,
                                onExit: { onClose?() },
                                toggles: [])
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                            .zIndex(10)
                    }
                    if showCloseButton, !isSpectator {
                        HoldToCloseButton(progress: $closeRingProgress) {
                            onClose?()
                        }
                        .position(x: 64, y: 56)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .zIndex(10)
                    }
                    if !isSpectator {
                        // First game with table motion enabled: a one-shot
                        // TipKit nudge toward bumping the table.
                        GhostHintTipView(tip: TableNudgeTip())
                            .position(x: geo.size.width * 0.5, y: geo.size.height - 40)
                            .zIndex(10)
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
                    deckStackCardIDs.formIntersection(current)
                }
                .onChange(of: state.round?.roundNumber) { _, newRound in
                    // Auto-deal only: manual dealing IS its own animation.
                    guard let newRound, newRound != lastDealtRound,
                          state.gameKind != .freePlay,
                          state.rules.autoDeal else { return }
                    lastDealtRound = newRound
                    runDealStream(state: state, size: geo.size)
                }
                .onChange(of: state.round?.currentTrick.count) { old, new in
                    // Trick plays slide in via transition — voice the slide
                    // here (spectator screens stay silent; audio belongs to
                    // the real table).
                    guard !isSpectator, state.gameKind.isTrickTaking,
                          let old, let new, new > old else { return }
                    TableSFX.shared.play(.cardSlide, intensity: 1.0)
                }
                .onAppear {
                    guard !isSpectator else { return }
                    wireTableMotion(size: geo.size)
                    TableMotion.shared.start()
                    TableNudgeTip.isEligible = TableMotion.isEnabled
                }
                .onDisappear {
                    guard !isSpectator else { return }
                    TableMotion.shared.stop()
                }
            }
        }
    }

    // MARK: table motion (the table feels being touched)

    /// Gentle handling drifts loose cards with the motion; a real thump
    /// makes everything hop once and resettle. Free-play cards genuinely
    /// move (committed); neat piles only shiver (decays to zero).
    private func wireTableMotion(size: CGSize) {
        TableMotion.shared.onNudge = { direction, strength in
            // Reduce Motion: the nudge drift is pure vestibular flourish —
            // damp it to zero rather than sliding cards on their own.
            guard !motionReduced else { return }
            guard host.state?.gameKind == .freePlay else { return }
            let step = 0.0012 * strength
            withAnimation(.easeOut(duration: 0.25)) {
                for (id, point) in host.freePlayLayout where fpLifts[id, default: 0] == 0 {
                    // Per-card variation: heavier "friction" for some cards.
                    let grip = 0.5 + abs(TableGeometry.jitterDegrees(cardID: id)) / 18.0
                    host.freePlayLayout[id] = CGPoint(
                        x: min(0.94, max(0.06, point.x + direction.dx * step * grip)),
                        y: min(0.92, max(0.08, point.y + direction.dy * step * grip)))
                }
            }
        }
        TableMotion.shared.onBump = { intensity in
            TableSFX.shared.play(.tableKnock, intensity: 0.7 + intensity * 0.3)
            // Reduce Motion: the thump still sounds, but the hop/shiver
            // that follows it is damped to zero.
            guard !motionReduced else { return }
            if host.state?.gameKind == .freePlay {
                // The hop: everything lifts with the thump, scatters a
                // touch, and settles back down.
                for (id, point) in host.freePlayLayout {
                    let jx = Double(TableGeometry.jitterDegrees(cardID: id + "bx")) / 9.0
                    let jy = Double(TableGeometry.jitterDegrees(cardID: id + "by")) / 9.0
                    withAnimation(.easeOut(duration: 0.10)) {
                        fpLifts[id] = CGFloat(4 + intensity * 5)
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.62).delay(0.10)) {
                        fpLifts[id] = 0
                        host.freePlayLayout[id] = CGPoint(
                            x: min(0.94, max(0.06, point.x + jx * 0.004 * intensity)),
                            y: min(0.92, max(0.08, point.y + jy * 0.004 * intensity)))
                    }
                }
            } else {
                // Neat piles: one shiver, never committed.
                withAnimation(.easeOut(duration: 0.08)) {
                    motionJitter = CGSize(width: CGFloat.random(in: -3...3) * intensity,
                                          height: CGFloat.random(in: -3...3) * intensity)
                }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.55).delay(0.08)) {
                    motionJitter = .zero
                }
            }
        }
    }

    /// Build the deal stream: one card back per player per pass, deck →
    /// plate in seat order starting left of the dealer, 70ms stagger —
    /// exactly how a human deals. Capped at 5 passes so a 20-card Wizard
    /// endgame round doesn't take 40 seconds of ceremony.
    private func runDealStream(state: GameState, size: CGSize) {
        guard let round = state.round else { return }
        let anchors = effectiveAnchors(state)
        let passes = min(round.cardsPerPlayer, 5)
        let seatOrder = (1...state.seats.count).map {
            (round.dealerSeat + $0) % state.seats.count
        }
        var cards: [DealStreamCard] = []
        var delay = 0.0
        for _ in 0..<passes {
            for seat in seatOrder where anchors.indices.contains(seat) {
                cards.append(DealStreamCard(
                    to: CGPoint(x: anchors[seat].x * size.width,
                                y: anchors[seat].y * size.height),
                    delay: delay))
                delay += 0.07
            }
        }
        dealStream = cards
        // The announcer's .dealt handler plays the card_deal sound; this
        // stream is the matching picture. Clear once the last card lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) {
            dealStream = []
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
            // Free play: TAP the deck to flip its top card over IN PLACE,
            // landing face-up ON TOP of the deck stack — the trump-reveal
            // gesture, sandbox-style. Capture the card's id BEFORE the
            // engine pops it off `drawPile`, so the arrival animation
            // knows to run the deck flip instead of a toss/arc across the
            // felt (see animateDeckFlip / animateArrivalIfNew).
            .onTapGesture {
                guard state.gameKind == .freePlay else { return }
                flipNextFromDeck(state: state)
            }
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
                            if state.phase == .dealing, !state.rules.autoDeal,
                               state.gameKind != .freePlay {
                                // Manual dealing: the dealer distributes the
                                // round by hand, one card per drag.
                                host.tableAction(.dealCardTo(seat: target))
                            } else {
                                host.drawCard(for: target)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if dealFlight?.id == flight.id { dealFlight = nil }
                            }
                            return
                        }
                        // Released on open felt: pull the top card straight
                        // onto the table, face-down where it was dropped.
                        // `.first`, not `.last`, is the real top of the pile
                        // — the engine pops the same end (see
                        // HostEngine.handleFlipTopCard/handleDrawCard).
                        let deckPos = CGPoint(x: deckAnchor.x * size.width,
                                              y: deckAnchor.y * size.height)
                        let farFromDeck = hypot(deckPos.x - value.location.x,
                                                deckPos.y - value.location.y) > 130
                        if farFromDeck, let top = state.drawPile.first {
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
            let anchor = anchors[seat.id]
            VStack(spacing: 6) {
                SeatPlateView(seat: seat, state: state,
                              edgeAngle: outwardAngle(anchor))
                // The player's hand, ON the table: overlapping card backs
                // between the plate and the rim — the count mirror of what
                // their remote holds, and the landing spot for deals/draws.
                RailHandFan(count: state.hands[seat.id]?.count ?? 0)
            }
                .rotationEffect(outwardAngle(anchor))
                .scaleEffect(draggingPlateSeat == seat.id ? 1.08 : 1)
                .shadow(color: .black.opacity(draggingPlateSeat == seat.id ? 0.5 : 0),
                        radius: 12, y: 6)
                .position(x: anchor.x * size.width, y: anchor.y * size.height)
                // Sit wherever you like: drag your plate to match your
                // real chair. It rides the rim (snaps to the nearest edge,
                // always readable from outside) and everything — deals,
                // tosses, glows — follows.
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
                        .onEnded { value in
                            draggingPlateSeat = nil
                            Haptics.arm()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                plateOverrides[seat.id] = snapToEdge(CGPoint(
                                    x: value.location.x / size.width,
                                    y: value.location.y / size.height))
                            }
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8),
                           value: draggingPlateSeat)
                // The rail (plate + hand fan) sits ABOVE felt cards at all
                // times — a played card sliding in from this edge must
                // emerge from UNDER it, never paint across the nameplate.
                // See trickCards()'s matching negative zIndex below.
                .zIndex(1)
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
        let cardWidth = TableGeometry.tableCardWidth(for: size)

        return ForEach(trick, id: \.card.id) { play in
            let pose = TableGeometry.trickCardPose(seatAnchor: anchors[play.seat], cardID: play.card.id)
            let sweeping = winnerSeat != nil
            let target = sweeping ? anchors[winnerSeat!] : pose.position

            // Entry vector: from this player's edge, so the slide-in
            // direction always matches who threw it.
            let entryOffset = CGSize(
                width: ((anchors[play.seat].x - 0.5) * 1.22 + 0.5 - pose.position.x) * size.width,
                height: ((anchors[play.seat].y - 0.47) * 1.22 + 0.47 - pose.position.y) * size.height)

            // Reduce Motion: the same short/no-op treatment as everywhere
            // else on the felt — a quick slide instead of the long,
            // decelerating throw.
            let playDuration = motionReduced ? 0.15 : 0.45
            CardView(card: play.card, faceUp: true, elevation: sweeping ? 0.3 : 0)
                .frame(width: cardWidth)
                .rotationEffect(pose.rotation)
                .position(x: target.x * size.width, y: target.y * size.height)
                .opacity(sweeping ? 0 : 1)
                .transition(.asymmetric(
                    insertion: .offset(entryOffset)
                        .animation(FeltPhysics.slide(duration: playDuration)),
                    removal: .identity))
                .animation(motionReduced ? .easeOut(duration: playDuration)
                                         : .spring(response: 0.5, dampingFraction: 0.8), value: sweeping)
                .animation(FeltPhysics.slide(duration: playDuration), value: trick.count)
                // Real cards slide in LOW: stay under the rail (seat
                // plates + hand fans, zIndex 1) the whole time, so a play
                // emerges from under the thrower's edge onto the felt
                // instead of painting across their nameplate mid-flight.
                .zIndex(-1)
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
    /// Free play, dev-toggle "arc" throws: height above felt (see shedPile).
    @State private var fpLifts: [String: CGFloat] = [:]
    /// 3D flip angle per card while a flip is in motion.
    @State private var flipAngle: [String: Double] = [:]
    /// Free play: card ids about to arrive via tap-the-deck (`flipTopCard`),
    /// captured the instant the tap fires (before the engine mutates
    /// `drawPile`) so `animateArrivalIfNew` can tell "the deck's top card,
    /// flipped in place" apart from a played/tossed card and route it to
    /// `animateDeckFlip` instead of the TOSS/ARC landings. Consumed once.
    @State private var deckFlipCardIDs: Set<String> = []
    /// Cards currently sitting face-up ON the deck stack (the result of
    /// `animateDeckFlip`), still there. Because they render ABOVE
    /// `dealHotspot`'s invisible tap zone, a second tap in that spot hits
    /// the CARD, not the hotspot underneath — so while a card is in this
    /// set, its own tap is redirected to "flip the next one" instead of
    /// the normal flip-this-card-face-down gesture, exactly what tapping
    /// the deck again should do. A card leaves this set the moment it's
    /// dragged (see `freePlayDragGesture`) — once it's off the deck, its
    /// tap goes back to being a normal felt-card flip.
    @State private var deckStackCardIDs: Set<String> = []

    private func freePlayCards(state: GameState, size: CGSize) -> some View {
        let recent = state.discardPile.suffix(20)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            freePlayCard(card: card, index: index, state: state, size: size)
        }
    }

    /// One free-play card on the felt. (Its own function — inlined in the
    /// ForEach the expression blew the type-checker's budget.)
    private func freePlayCard(card: Card, index: Int, state: GameState,
                              size: CGSize) -> some View {
        let cardWidth = TableGeometry.tableCardWidth(for: size)
        let jitter = TableGeometry.jitterDegrees(cardID: card.id)
        let dx = TableGeometry.jitterDegrees(cardID: String(card.id.reversed())) / 90.0
        let dy = TableGeometry.jitterDegrees(cardID: card.id + "y") / 110.0
        let restPos = host.freePlayLayout[card.id].map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        } ?? CGPoint(x: (0.52 + dx) * size.width, y: (0.47 + dy) * size.height)
        let isTouched = touchedCardID == card.id
        let isSliding = slidingCards.contains(card.id)

        let flip: Double = flipAngle[card.id] ?? 0
        let lift: CGFloat = fpLifts[card.id] ?? 0

        // Pre-typed sub-expressions: inline, the mixed CGFloat/Double
        // arithmetic blew the type-checker's budget.
        let shadowAlpha: Double = 0.30 - Double(lift) * 0.0016
        let shadowScale: CGFloat = 0.92 - lift * 0.0022
        let shadowBlur: CGFloat = 3 + lift * 0.16
        let elevation: Double = isTouched ? 0.8 : (isSliding ? 0.45 : 0)
        let flipScale: Double = 1 + abs(flip) / 90 * 0.06
        let liftScale: CGFloat = 1 + lift * 0.0032
        let cardScale: CGFloat = CGFloat(flipScale) * liftScale
        let restRotation: Double = rotationByCard[card.id] ?? jitter * 2.2
        let inMotion: Bool = isSliding || flip != 0 || lift > 0.5
        let zIndexValue: Double = isTouched ? 500 : (inMotion ? 400 : Double(index))

        return ZStack {
            if lift > 0.5 {
                Ellipse()
                    .fill(.black.opacity(shadowAlpha))
                    .frame(width: cardWidth * shadowScale,
                           height: cardWidth * 0.62 * shadowScale)
                    .blur(radius: shadowBlur)
                    .position(restPos)
            }
            CardView(card: card,
                     faceUp: !host.faceDownCards.contains(card.id),
                     elevation: elevation)
                .frame(width: cardWidth)
                // A real flip: the card turns over its own long axis and
                // lifts slightly at the apex, like a thumb turning it.
                .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .scaleEffect(cardScale)
                .rotationEffect(.degrees(restRotation))
                .position(x: restPos.x, y: restPos.y - lift)
                .onTapGesture {
                    // A card resting face-up on the deck stack reads as
                    // "part of the deck" — tapping it continues the deal
                    // ceremony (flip the next one) rather than flipping
                    // this one back face-down. See `deckStackCardIDs`.
                    if deckStackCardIDs.contains(card.id) {
                        flipNextFromDeck(state: state)
                    } else {
                        flipCard(card.id)
                    }
                }
                .gesture(freePlayDragGesture(card: card, state: state, size: size))
        }
        .zIndex(zIndexValue)
        .transition(.opacity)
        .onAppear { animateArrivalIfNew(card: card, state: state, size: size) }
    }

    /// Drag a free-play card around the felt. (Own function for the same
    /// type-checker-budget reason as freePlayCard.)
    private func freePlayDragGesture(card: Card, state: GameState,
                                     size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                touchedCardID = card.id
                // Once it's being dragged it's off the deck, whatever the
                // gesture ends up doing with it — a plain felt card again,
                // tap-to-flip included.
                deckStackCardIDs.remove(card.id)
                let norm = CGPoint(x: value.location.x / size.width,
                                   y: value.location.y / size.height)
                host.freePlayLayout[card.id] = norm
            }
            .onEnded { value in
                endFreePlayDrag(card: card, state: state, size: size, value: value)
            }
    }

    /// Free-play drag release: bury on the deck, hand off on a plate, or
    /// glide to rest on the felt. (Extracted from the gesture closure —
    /// inline, the ForEach expression blew the type-checker's budget.)
    private func endFreePlayDrag(card: Card, state: GameState, size: CGSize,
                                 value: DragGesture.Value) {
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
        // Otherwise: released mid-slide — let momentum carry it a little
        // farther on the felt.
        let v = value.velocity
        let vMag = hypot(v.width, v.height)
        if vMag > 120 {
            let glide: CGFloat = min(0.22, vMag / 9000.0)
            let glideX: CGFloat = value.location.x + v.width * glide
            let glideY: CGFloat = value.location.y + v.height * glide
            let restX: CGFloat = min(0.94, max(0.06, glideX / size.width))
            let restY: CGFloat = min(0.92, max(0.08, glideY / size.height))
            let rest = CGPoint(x: restX, y: restY)
            let duration: Double = 0.25 + Double(glide) * 1.3
            slidingCards.insert(card.id)
            withAnimation(FeltPhysics.slide(duration: duration)) {
                host.freePlayLayout[card.id] = rest
                _ = slidingCards.remove(card.id)
            }
        }
    }

    /// UNO / Crazy Eights: the discard is the heart of the table. Every
    /// play travels the whole way — off the thrower's edge, across the
    /// felt, then PLACED on top of the pile: it overshoots a touch high
    /// and drops flat like a hand letting go of a card.
    /// Explicit two-phase animation (never a SwiftUI transition — those
    /// proved unreliable for network-driven insertions).
    @State private var shedPoses: [String: CGPoint] = [:]      // ground-track position
    @State private var shedRotations: [String: Double] = [:]
    /// Height above the felt in points. The card renders LIFTED above its
    /// ground position and casts a SEPARATED shadow at ground level — the
    /// gap between card and shadow is what reads as "flying".
    @State private var shedLifts: [String: CGFloat] = [:]
    @State private var shedSeen: Set<String> = []

    private func shedPile(state: GameState, size: CGSize) -> some View {
        let recent = state.discardPile.suffix(4)
        let cardWidth = TableGeometry.tableCardWidth(for: size)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let jitter = TableGeometry.jitterDegrees(cardID: card.id)
            let restPos = CGPoint(
                x: 0.52 * size.width + CGFloat(jitter) * 0.35,
                y: 0.47 * size.height + CGFloat(TableGeometry.jitterDegrees(cardID: card.id + "y")) * 0.3)
            let ground = shedPoses[card.id] ?? restPos
            let lift = shedLifts[card.id] ?? 0

            ZStack {
                // The ground shadow: lives ON the felt while the card is in
                // the air. Softer, wider, and fainter the higher the card;
                // it merges into a contact shadow exactly at touchdown.
                if lift > 0.5 {
                    Ellipse()
                        .fill(.black.opacity(0.30 - Double(lift) * 0.0016))
                        .frame(width: cardWidth * (0.92 - lift * 0.0022),
                               height: cardWidth * 0.62 * (0.92 - lift * 0.0022))
                        .blur(radius: 3 + lift * 0.16)
                        .position(ground)
                }
                // The card itself: lifted above its ground track, bigger
                // when higher (closer to your eyes), spinning down to rest.
                CardView(card: card, faceUp: true, elevation: 0)
                    .frame(width: cardWidth)
                    .rotationEffect(.degrees(shedRotations[card.id] ?? jitter * 1.8))
                    .scaleEffect(1 + lift * 0.0032)
                    .position(x: ground.x, y: ground.y - lift)
                    .shadow(color: .black.opacity(lift > 0.5 ? 0 : 0.28),
                            radius: 2, y: 1) // contact shadow only when down
            }
            .zIndex(lift > 0.5 ? 400 : Double(index))
            // Top card only: a called wild color makes the wild's own
            // panel glow (UnoCardViews). Scoped here so hands never glow.
            .environment(\.unoActiveColor,
                         (state.gameKind == .uno && index == recent.count - 1)
                             ? (state.discardPile.last?.unoColor
                                 ?? state.round?.trumpSuit?.unoColor)
                             : nil)
            .onAppear { animateShedArrival(card: card, restPos: restPos,
                                           restRotation: jitter * 1.8,
                                           state: state, size: size) }
        }
        .onChange(of: state.discardPile.count) { _, _ in
            let current = Set(state.discardPile.map(\.id))
            shedSeen.formIntersection(current)
            shedPoses = shedPoses.filter { current.contains($0.key) }
            shedRotations = shedRotations.filter { current.contains($0.key) }
            shedLifts = shedLifts.filter { current.contains($0.key) }
        }
    }

    /// The airborne throw: the card leaves the thrower's edge already in
    /// flight, ARCS over the table — rising, growing (closer to your
    /// eyes), its shadow racing along the felt beneath it — then descends
    /// onto the pile in one continuous motion (see FeltPhysics.pileDropArc)
    /// and settles with a crisp landing.
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
        let seatAnchor = seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }
        let restNorm = CGPoint(x: restPos.x / size.width, y: restPos.y / size.height)
        let arc = FeltPhysics.pileDropArc(cardID: card.id, seatAnchor: seatAnchor,
                                          restPoint: restNorm, tableSize: size)
        func toPoints(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }
        let entryPt = toPoints(arc.entry)
        let touchdownPt = toPoints(arc.touchdown)
        let restPt = toPoints(arc.rest)
        let settleTwist = TableGeometry.jitterDegrees(cardID: card.id) >= 0 ? 2.4 : -2.4

        if motionReduced {
            // Reduce Motion: no rising/falling arc — a quick, short, flat
            // slide straight onto the pile instead.
            shedPoses[card.id] = entryPt
            shedRotations[card.id] = restRotation
            shedLifts[card.id] = 0
            DispatchQueue.main.async {
                if !isSpectator {
                    TableSFX.shared.play(.cardSlide, intensity: 0.6)
                }
                withAnimation(.easeOut(duration: 0.15)) {
                    shedPoses[card.id] = restPt
                    shedRotations[card.id] = restRotation
                }
            }
            return
        }

        // Leave the hand already airborne at the table's edge.
        shedPoses[card.id] = entryPt
        shedRotations[card.id] = restRotation - TableGeometry.jitterDegrees(cardID: card.id) * 3.0
        shedLifts[card.id] = arc.apex * 0.5

        // ONE continuous motion, no phase seams: the ground track glides
        // entry → pile on a guaranteed-monotonic decelerating curve (it
        // keeps advancing all the way to touchdown — never finishes
        // early and hovers); the lift rises and falls in two halves that
        // MEET AT ZERO VELOCITY at the apex (easeOut up, easeIn down =
        // C1-continuous). Both share the same duration, so they touch
        // down on the same frame.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: arc.duration)) {
                shedPoses[card.id] = touchdownPt
                shedRotations[card.id] = restRotation - settleTwist
            }
            withAnimation(.easeOut(duration: arc.duration * 0.46)) {
                shedLifts[card.id] = arc.apex
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + arc.duration * 0.46) {
                withAnimation(.easeIn(duration: arc.duration * 0.54)) {
                    shedLifts[card.id] = 0
                }
            }
            // Contact settle: a tiny 2–4pt skid-with-rotation onto the
            // pile's top surface — the ground shadow (tied to this same
            // position) converges onto the card exactly here.
            DispatchQueue.main.asyncAfter(deadline: .now() + arc.duration) {
                if !isSpectator {
                    TableSFX.shared.play(.cardSlide, intensity: 0.6 + Double(arc.apex) / 90.0 * 0.9)
                }
                withAnimation(.easeOut(duration: FeltPhysics.PileDropArc.settleDuration)) {
                    shedPoses[card.id] = restPt
                    shedRotations[card.id] = restRotation
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

    /// Tap the deck (or tap a card already sitting face-up on top of it —
    /// see `deckStackCardIDs`): flip the next card over in place. Shared
    /// so both hit-test paths produce the exact same result.
    private func flipNextFromDeck(state: GameState) {
        Haptics.tick()
        // The engine pops the top of the pile with `removeFirst()` (see
        // HostEngine.handleFlipTopCard) — `.first`, not `.last`, is the
        // card that's actually about to flip.
        if let topID = state.drawPile.first?.id {
            deckFlipCardIDs.insert(topID)
        }
        host.tableAction(.flipTopCard)
    }

    /// Free play, tap-the-deck: the top card 3D-flips over IN PLACE and
    /// lands face-up ON TOP of the deck stack, staying there — it never
    /// travels, and it never originates from a seat. Mirrors
    /// `DeckAndTrumpView`'s trump reveal (two-phase rotation, content
    /// swapped at the edge-on midpoint) so the two flips read as one
    /// visual language. Repeated taps stack another flipped card on the
    /// last one, exactly what the engine's `flipTopCard` does: top of
    /// draw pile → discard pile, over and over.
    private func animateDeckFlip(card: Card, size: CGSize) {
        // A small stable per-card offset so a run of taps fans into a
        // loose little stack sitting on the deck, not a perfect overlap.
        let jx = CGFloat(TableGeometry.jitterDegrees(cardID: card.id)) * 0.5
        let jy = CGFloat(TableGeometry.jitterDegrees(cardID: card.id + "y")) * 0.35
        let restPoint = CGPoint(x: deckAnchor.x + jx / size.width,
                                y: deckAnchor.y + jy / size.height)
        let tilt = TableGeometry.jitterDegrees(cardID: card.id) * 0.4

        host.freePlayLayout[card.id] = restPoint
        host.faceDownCards.insert(card.id) // starts as a back, mid-flip reveals the face
        deckStackCardIDs.insert(card.id) // "on the deck" until dragged off
        rotationByCard[card.id] = tilt
        flipAngle[card.id] = 180
        fpLifts[card.id] = 8
        withAnimation(.easeIn(duration: 0.16)) {
            flipAngle[card.id] = 90
            fpLifts[card.id] = 14
        } completion: {
            TableSFX.shared.play(.cardFlip)
            host.faceDownCards.remove(card.id)
            flipAngle[card.id] = -90
            withAnimation(.easeOut(duration: 0.18)) {
                flipAngle[card.id] = 0
                fpLifts[card.id] = 0
            }
        }
    }

    /// First sighting of a card on the felt → run its arrival. Three
    /// styles: the deck flip (tap-the-deck, in place — see
    /// `animateDeckFlip`), the friction TOSS (slides on the felt), or the
    /// airborne ARC (free play's dev sandbox for comparing throw styles,
    /// phone-toggled) — a thrown card landing on a neat pile.
    private func animateArrivalIfNew(card: Card, state: GameState, size: CGSize) {
        guard state.gameKind == .freePlay, !seenCardIDs.contains(card.id) else { return }
        seenCardIDs.insert(card.id)
        // Cards present before this view existed (rejoin, relaunch) stay put.
        guard host.freePlayLayout[card.id] == nil else { return }

        if deckFlipCardIDs.remove(card.id) != nil {
            animateDeckFlip(card: card, size: size)
            return
        }

        let anchors = effectiveAnchors(state)
        let seat = host.seatByPlayedCard[card.id]
        let anchor = seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }

        if host.pileDropCards.contains(card.id) {
            // ARC: one continuous descending throw onto the pile — see
            // FeltPhysics.pileDropArc for why this replaced the old
            // two-phase (fly in, hang above the pile, then drop) version.
            let restPoint = CGPoint(x: 0.52 + Double(TableGeometry.jitterDegrees(cardID: card.id)) * 0.0004,
                                    y: 0.47 + Double(TableGeometry.jitterDegrees(cardID: card.id + "y")) * 0.0003)
            let arc = FeltPhysics.pileDropArc(cardID: card.id, seatAnchor: anchor,
                                              restPoint: restPoint, tableSize: size)
            let settleTwist = TableGeometry.jitterDegrees(cardID: card.id) >= 0 ? 2.4 : -2.4

            host.freePlayLayout[card.id] = arc.entry
            rotationByCard[card.id] = arc.entryRotation
            fpLifts[card.id] = arc.apex * 0.5
            DispatchQueue.main.async {
                // The ground track decelerates smoothly all the way to
                // touchdown (a guaranteed-monotonic easeOut — the old
                // hand-rolled bezier's out-of-order control points let it
                // "finish" early and hover); the lift rises and falls in
                // two halves meeting at zero velocity at the apex. Both
                // span the SAME duration, so they touch down on the same
                // frame — no seam, no hang.
                withAnimation(.easeOut(duration: arc.duration)) {
                    host.freePlayLayout[card.id] = arc.touchdown
                    rotationByCard[card.id] = arc.restRotation - settleTwist
                }
                withAnimation(.easeOut(duration: arc.duration * 0.46)) {
                    fpLifts[card.id] = arc.apex
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + arc.duration * 0.46) {
                    withAnimation(.easeIn(duration: arc.duration * 0.54)) {
                        fpLifts[card.id] = 0
                    }
                }
                // Contact settle: a tiny 2–4pt skid-with-rotation into its
                // final resting spot ON the pile — sells the landing
                // instead of a dead stop. The ground shadow (tied to this
                // same position) converges onto the card exactly here,
                // since lift is already back to 0 by touchdown.
                DispatchQueue.main.asyncAfter(deadline: .now() + arc.duration) {
                    if !isSpectator {
                        TableSFX.shared.play(.cardSlide, intensity: 0.55 + Double(arc.apex) / 96.0 * 0.6)
                    }
                    withAnimation(.easeOut(duration: FeltPhysics.PileDropArc.settleDuration)) {
                        host.freePlayLayout[card.id] = arc.rest
                        rotationByCard[card.id] = arc.restRotation
                    }
                }
            }
            return
        }

        // TOSS: the friction slide.
        let toss = FeltPhysics.toss(
            cardID: card.id,
            seatAnchor: anchor,
            throwVelocity: host.throwVelocityByCard.removeValue(forKey: card.id),
            tableSize: size)

        // Phase 1: materialize at the entry edge, mid-spin, lifted.
        host.freePlayLayout[card.id] = toss.entry
        rotationByCard[card.id] = toss.restRotation - toss.spin
        slidingCards.insert(card.id)

        // Phase 2: friction takes it from there. The slide sound's pitch
        // tracks the throw: toss duration encodes speed (harder = longer).
        DispatchQueue.main.async {
            if !isSpectator {
                let speedNorm = (toss.duration - 0.34) / 0.26 // 0…1 by FeltPhysics
                TableSFX.shared.play(.cardSlide, intensity: 0.55 + speedNorm * 0.85)
            }
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
        .accessibilityLabel("Close table")
        .accessibilityHint("Press and hold to close")
        .accessibilityAddTraits(.isButton)
    }
}

/// One card of the deal stream: waits its turn, then snaps deck → plate
/// with a slight lift, fading as it "reaches" the player.
struct DealStreamFlight: View {
    let from: CGPoint
    let to: CGPoint
    let delay: Double
    @State private var progress: CGFloat = 0

    var body: some View {
        CardView(card: Card(id: "dealstream", kind: .standard(suit: .spades, rank: 2)),
                 faceUp: false, elevation: 0.5 * (1 - progress))
            .frame(width: 76)
            .rotationEffect(.degrees(Double(progress) * 18 - 9))
            .position(x: from.x + (to.x - from.x) * progress,
                      y: from.y + (to.y - from.y) * progress)
            .opacity(progress < 0.02 ? 0 : (progress > 0.88 ? (1 - progress) / 0.12 : 1))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.34).delay(delay)) { progress = 1 }
            }
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
            // Same phase, different vocabulary: UNO and Crazy Eights pick a
            // color/suit after a wild — "trump" is trick-game language.
            TableBanner(text: state.gameKind == .uno
                ? "\(state.seats[seat].playerName) is choosing a color…"
                : state.gameKind == .crazyEights
                ? "\(state.seats[seat].playerName) is naming a suit…"
                : "\(state.seats[seat].playerName) is choosing trump…")
        case .trickComplete(let winner):
            TrickWonBanner(name: state.seats[winner].playerName,
                           color: PlayerPalette.color(state.seats[winner].colorIndex))
        case .roundComplete:
            RoundRecapOverlay(host: host, state: state)
        case .gameOver:
            GameOverOverlay(host: host, state: state, onMenu: onClose)
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
            .font(.system(.largeTitle, design: .serif).weight(.bold))
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
