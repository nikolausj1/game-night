import SwiftUI

/// The live table: plates around the rim, deck and trump on the felt,
/// the current trick landing in the middle.
struct TableGameView: View {
    @Bindable var host: GameHostController
    @Environment(\.accessibilityReduceMotion) private var motionReduced

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

    /// FeltSim: every loose card on the felt (free play, plus the shed
    /// pile's landings) is a body in ONE small rigid-ish simulation, so
    /// cards can nudge, rotate, and rail-bounce off each other. The store
    /// runs a display link only while something moves.
    @State private var feltSim = FeltSimStore()
    @State private var demoScatterStarted = false

    /// Sandbox dice in free play — a physics toy, no rules attached.
    /// `-demoFreePlayDice` (sim-verify hook): starts with the dice toy on,
    /// so the cup-by-the-plate flow is screenshot-testable — simctl can't
    /// tap the tray toggle.
    @State private var freePlayDiceOn = CommandLine.arguments.contains("-demoFreePlayDice")
    @State private var freePlayCoinsOn = CommandLine.arguments.contains("-demoFreePlayCoins")
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
    /// Pulled in closer to the true screen edge than a plate's own footprint
    /// would suggest: the plate sits at the seam between itself and its
    /// rail hand fan (see `RailHandFan`/`seatPlates`), so nudging the seam
    /// toward the bezel is what puts the PLATE flush against the rail with
    /// the fan's cards bleeding off past it, not the plate itself floating
    /// mid-felt.
    private func snapToEdge(_ p: CGPoint) -> CGPoint {
        let dLeft = p.x, dRight = 1 - p.x, dTop = p.y, dBottom = 1 - p.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return CGPoint(x: min(0.86, max(0.14, p.x)), y: 0.965) }
        if nearest == dTop { return CGPoint(x: min(0.86, max(0.14, p.x)), y: 0.035) }
        if nearest == dLeft { return CGPoint(x: 0.035, y: min(0.84, max(0.16, p.y))) }
        return CGPoint(x: 0.965, y: min(0.84, max(0.16, p.y)))
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
                            // The full cup experience, sandbox edition:
                            // FreePlayDiceLayer wires the cup at seat 0's
                            // plate, manual loading, and touch-through —
                            // the old bare DiceTableSceneView mount had
                            // hit-testing disabled, so dice could never
                            // be picked up ("I can't use DICE on free
                            // play").
                            FreePlayDiceLayer(host: host, size: geo.size,
                                              roll: freePlayRoll,
                                              onResult: { _, _ in freePlayRoll = nil })
                                // Above the rail (1): the cup mounts at
                                // seat 0's plate, and the rail-hand card
                                // backs would otherwise paint right over
                                // it (they did — screenshot-caught).
                                .zIndex(1.5)
                            Button {
                                guard host.freePlayCanRoll else { return }
                                Haptics.arm()
                                freePlayRollCounter += 1
                                freePlayRoll = DiceGameController.Roll(
                                    id: freePlayRollCounter, seat: 0, count: 3,
                                    intensity: Double.random(in: 0.5...1.3))
                            } label: {
                                Label("Roll", systemImage: "dice.fill")
                                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                                    .foregroundStyle(host.freePlayCanRoll
                                        ? CardStyle.gold : CardStyle.gold.opacity(0.4))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(.black.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .disabled(!host.freePlayCanRoll)
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
                    // The ActiveColorChip overlay is gone per owner feedback:
                    // the wild card's own panel glow (UnoCardViews, wired via
                    // the `.unoActiveColor` environment key set in shedPile)
                    // is now the sole "what color is live" indicator — a
                    // second badge floating above it was redundant noise.
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
                .coordinateSpace(name: "felt")
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
                    pileDropProgress = pileDropProgress.filter { current.contains($0.key) }
                    // Bodies follow the cards: a buried / handed-off /
                    // shuffled-away card leaves the sim. Shed games only
                    // ever draw the top 4.
                    if state.gameKind == .freePlay {
                        feltSim.retain(only: current)
                    } else {
                        feltSim.retain(only: Set(state.discardPile.suffix(4).map(\.id)))
                    }
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
                    feltSim.configure(size: geo.size,
                                      cardWidth: TableGeometry.tableCardWidth(for: geo.size))
                    wireFeltMirror()
                    wireTableMotion(size: geo.size)
                    runDemoScatterIfAsked(size: geo.size)
                    TableMotion.shared.start()
                    TableNudgeTip.isEligible = TableMotion.isEnabled
                }
                .onChange(of: geo.size) { _, newSize in
                    feltSim.configure(size: newSize,
                                      cardWidth: TableGeometry.tableCardWidth(for: newSize))
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
    /// makes everything hop once and resettle. In free play the response is
    /// an impulse field into FeltSim (so a drifting card can bump a
    /// neighbor); neat piles only shiver (decays to zero, never committed).
    private func wireTableMotion(size: CGSize) {
        TableMotion.shared.onNudge = { direction, strength in
            // Reduce Motion: the nudge drift is pure vestibular flourish —
            // damp it to zero rather than sliding cards on their own.
            guard !motionReduced else { return }
            guard host.state?.gameKind == .freePlay else { return }
            // Same reach as the old per-nudge step (0.0012 of the table
            // width per unit strength), now as a felt-friction slide.
            feltSim.nudge(direction: direction,
                          distance: 0.0012 * strength * Double(size.width))
        }
        TableMotion.shared.onBump = { intensity in
            TableSFX.shared.play(.tableKnock, intensity: 0.7 + intensity * 0.3)
            // Reduce Motion: the thump still sounds, but the hop/shiver
            // that follows it is damped to zero.
            guard !motionReduced else { return }
            if host.state?.gameKind == .freePlay {
                // The hop: everything lifts with the thump and settles
                // back down; the scatter itself is an impulse field,
                // stronger toward the struck edge.
                feltSim.shock(direction: TableMotion.shared.lastBumpDirection,
                              strength: 140 * intensity)
                for id in host.freePlayLayout.keys {
                    withAnimation(.easeOut(duration: 0.10)) {
                        fpLifts[id] = CGFloat(4 + intensity * 5)
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.62).delay(0.10)) {
                        fpLifts[id] = 0
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

    /// FeltSim is the source of truth for where a loose card is; the host's
    /// `freePlayLayout`/`rotationByCard` stay as a resting-pose MIRROR so
    /// everything that still reads them (first-sighting guard, rejoin)
    /// keeps working. Written when a body falls asleep.
    private func wireFeltMirror() {
        feltSim.onSettled = { id, normalized, angle in
            guard host.state?.gameKind == .freePlay else { return }
            host.freePlayLayout[id] = normalized
            rotationByCard[id] = angle
        }
    }

    /// Sim-verify hook (`-demoScatter`): one second after launch, flick 8
    /// fresh cards in from random edges so they collide with each other and
    /// with the cards already resting near the middle. Seeded, so every run
    /// is the same scatter. Real engine cards, real sim bodies.
    private func runDemoScatterIfAsked(size: CGSize) {
        guard CommandLine.arguments.contains("-demoScatter"), !demoScatterStarted,
              !isSpectator else { return }
        demoScatterStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let before = host.state?.discardPile.map(\.id) else { return }
            for _ in 0..<8 { host.tableAction(.flipTopCard) }
            guard let pile = host.state?.discardPile else { return }
            let known = Set(before)
            let fresh = pile.filter { !known.contains($0.id) }
            var rng: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double { // SplitMix64 -> 0..<1
                rng = rng &+ 0x9E3779B97F4A7C15
                var z = rng
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z ^= z >> 31
                return Double(z >> 11) / Double(1 << 53)
            }
            let w = size.width, h = size.height
            for (i, card) in fresh.enumerated() {
                seenCardIDs.insert(card.id) // we place it; no ordinary arrival
                let edge = Int(next() * 4)
                let t = 0.2 + next() * 0.6
                let from: CGPoint
                switch edge {
                case 0: from = CGPoint(x: w * t, y: -60)
                case 1: from = CGPoint(x: w + 60, y: h * t)
                case 2: from = CGPoint(x: w * t, y: h + 60)
                default: from = CGPoint(x: -60, y: h * t)
                }
                // Aim near the middle (where the resting cards are), with
                // enough overshoot that the winners reach a rail.
                let aim = CGPoint(x: w * 0.5 + (next() - 0.5) * 220,
                                  y: h * 0.47 + (next() - 0.5) * 160)
                let reach = 1.0 + next() * 0.9
                let to = CGPoint(x: from.x + (aim.x - from.x) * reach,
                                 y: from.y + (aim.y - from.y) * reach)
                let rot = (next() - 0.5) * 50
                let delay = Double(i) * 0.09
                let duration = 0.55 + next() * 0.2
                host.freePlayLayout[card.id] = CGPoint(x: aim.x / w, y: aim.y / h)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    feltSim.toss(id: card.id, from: from, to: to,
                                 duration: duration,
                                 angleFrom: rot - 40, angleTo: rot)
                    TableSFX.shared.play(.cardSlide, intensity: 0.9)
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
        // Real table-card scale, a touch under the felt cards' own size so
        // a full-width hand fan doesn't overwhelm the rail — still the same
        // object class as everything else on the table, not a miniature.
        let railCardWidth = TableGeometry.tableCardWidth(for: size) * 0.88
        return ForEach(state.seats) { seat in
            let anchor = anchors[seat.id]
            VStack(spacing: 2) {
                SeatPlateView(seat: seat, state: state,
                              edgeAngle: outwardAngle(anchor))
                // The player's hand, ON the table: a real-scale fan of card
                // backs bleeding off the rail past the plate — the count
                // mirror of what their remote holds, and the landing spot
                // for deals/draws. Sits snug against the plate (spacing 2)
                // so the two read as one object: nameplate against the
                // rail, cards poking in from the hand holding them there.
                RailHandFan(count: state.hands[seat.id]?.count ?? 0,
                            cardWidth: railCardWidth)
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
    /// Free play "arc" throws in flight: one progress scalar per card,
    /// same single-progress treatment as the shed pile (see
    /// `PileTossCardView`/`FeltPhysics.evaluate`) — no separate lift/
    /// position/rotation animations to fall out of step with each other.
    /// Present only while a pile-drop card is airborne; removed on landing,
    /// at which point `host.freePlayLayout`/`rotationByCard` (the normal
    /// felt-card state) take back over.
    @State private var pileDropProgress: [String: CGFloat] = [:]
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

    /// The deterministic toss geometry for a free-play "arc" throw (dev
    /// sandbox toggle) — same solve the shed pile uses, just landing at a
    /// slightly-jittered center point instead of the discard pile. `nil`
    /// unless this card actually arrived via `host.pileDropCards`.
    private func pileDropToss(for cardID: String, state: GameState, size: CGSize) -> FeltPhysics.PileToss? {
        guard host.pileDropCards.contains(cardID) else { return nil }
        let anchors = effectiveAnchors(state)
        let seat = host.seatByPlayedCard[cardID]
        let anchor = seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }
        let restPoint = CGPoint(x: 0.52 + Double(TableGeometry.jitterDegrees(cardID: cardID)) * 0.0004,
                                y: 0.47 + Double(TableGeometry.jitterDegrees(cardID: cardID + "y")) * 0.0003)
        let toss = FeltPhysics.pileToss(cardID: cardID, seatAnchor: anchor, restPoint: restPoint, tableSize: size)
        return motionReduced ? FeltPhysics.flatSlide(toss) : toss
    }

    /// One free-play card on the felt. (Its own function — inlined in the
    /// ForEach the expression blew the type-checker's budget.)
    ///
    /// While a card is mid-flight on an "arc" pile-drop throw, this renders
    /// through `PileTossCardView` instead of the normal drag/flip pipeline
    /// below — same single-progress mechanism the shed pile uses, so the
    /// two-part "slide then drop" bug can't happen here either. It swaps
    /// back to the normal rendering the instant the throw lands (see
    /// `animateArrivalIfNew`, which clears `pileDropProgress` on touchdown).
    @ViewBuilder
    private func freePlayCard(card: Card, index: Int, state: GameState,
                              size: CGSize) -> some View {
        if let toss = pileDropToss(for: card.id, state: state, size: size),
           let progress = pileDropProgress[card.id], progress < 1 {
            PileTossCardView(progress: progress, card: card, toss: toss,
                             cardWidth: TableGeometry.tableCardWidth(for: size),
                             tableSize: size, groundZIndex: Double(index))
                .transition(.opacity)
                .onAppear { animateArrivalIfNew(card: card, state: state, size: size) }
        } else {
            freePlayRestingCard(card: card, index: index, state: state, size: size)
        }
    }

    /// The normal, interactive free-play card: draggable, flippable, and
    /// placed by FeltSim. Split out of `freePlayCard` so the in-flight
    /// pile-drop branch above can bypass it entirely.
    ///
    /// Until the card has a sim body (first sighting; its arrival creates
    /// one) it renders as an invisible placeholder that only runs the
    /// arrival. Afterwards `SimPlacedCard` reads the pose from the sim —
    /// per-frame motion invalidates that one small view, not this body.
    @ViewBuilder
    private func freePlayRestingCard(card: Card, index: Int, state: GameState,
                                     size: CGSize) -> some View {
        if let box = feltSim.box(for: card.id) {
            let cardWidth = TableGeometry.tableCardWidth(for: size)
            let isTouched = touchedCardID == card.id
            let flip: Double = flipAngle[card.id] ?? 0
            let lift: CGFloat = fpLifts[card.id] ?? 0

            // Pre-typed sub-expressions: inline, the mixed CGFloat/Double
            // arithmetic blew the type-checker's budget.
            let flipScale: Double = 1 + abs(flip) / 90 * 0.06
            let liftScale: CGFloat = 1 + lift * 0.0032
            let cardScale: CGFloat = CGFloat(flipScale) * liftScale
            let inMotion: Bool = flip != 0 || lift > 0.5
            let zOverride: Double? = isTouched ? 500 : (inMotion ? 400 : nil)

            SimPlacedCard(box: box, lift: lift, cardWidth: cardWidth, zOverride: zOverride) {
                CardView(card: card,
                         faceUp: !host.faceDownCards.contains(card.id),
                         elevation: FeltShadow.cardElevation(lift: lift))
                    .frame(width: cardWidth)
                    // A real flip: the card turns over its own long axis and
                    // lifts slightly at the apex, like a thumb turning it.
                    .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                    .scaleEffect(cardScale)
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
            .transition(.opacity)
            .onAppear { animateArrivalIfNew(card: card, state: state, size: size) }
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { animateArrivalIfNew(card: card, state: state, size: size) }
        }
    }

    /// Drag a free-play card around the felt. (Own function for the same
    /// type-checker-budget reason as freePlayCard.)
    private func freePlayDragGesture(card: Card, state: GameState,
                                     size: CGSize) -> some Gesture {
        // Named space: the gesture lives on a view that is rotated and
        // positioned by the sim, so local coordinates would be card-local.
        DragGesture(minimumDistance: 3, coordinateSpace: .named("felt"))
            .onChanged { value in
                touchedCardID = card.id
                // Once it's being dragged it's off the deck, whatever the
                // gesture ends up doing with it — a plain felt card again,
                // tap-to-flip included.
                deckStackCardIDs.remove(card.id)
                if !feltSim.isHeld(card.id) {
                    // Picked up: lifts off the felt (separated shadow) and
                    // keeps its grab offset instead of snapping to the finger.
                    withAnimation(.easeOut(duration: 0.12)) { fpLifts[card.id] = 10 }
                }
                feltSim.hold(id: card.id, finger: value.location)
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
            fpLifts[card.id] = 0
            feltSim.remove(card.id)
            host.moveTableCard(card.id, to: .deck,
                               seat: host.seatByPlayedCard[card.id] ?? state.seats[0].id)
            return
        }
        // Dropped on a nameplate: into that player's hand.
        if let target = seatHit(at: value.location, anchors: anchors,
                                size: size, seats: state.seats) {
            Haptics.play()
            fpLifts[card.id] = 0
            feltSim.remove(card.id)
            host.moveTableCard(card.id, to: .hand, seat: target)
            return
        }
        // Otherwise: set it down. Released mid-slide, momentum carries it a
        // little farther along the felt (same flick -> distance mapping as
        // ever); FeltSim then lands it by the stack rule and lets it bump
        // whatever is in the way.
        let v = value.velocity
        let vMag = hypot(v.width, v.height)
        var glide: FeltSim.Glide?
        if vMag > 120 {
            let reach: CGFloat = min(0.22, vMag / 9000.0)
            let duration: Double = (0.25 + Double(reach) * 1.3) * (motionReduced ? 0.6 : 1)
            glide = FeltSim.Glide(distance: FeltVec(x: Double(v.width * reach), y: Double(v.height * reach)),
                                  duration: duration)
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { fpLifts[card.id] = 0 }
        feltSim.release(id: card.id, glide: glide)
    }

    /// UNO / Crazy Eights: the discard is the heart of the table. Every
    /// play travels the whole way — off the thrower's edge, onto the pile —
    /// in ONE continuous motion (see `FeltPhysics.PileToss`). `shedProgress`
    /// is the ONLY thing animated: a single scalar per card, driving
    /// `PileTossCardView` below, which derives position/height/rotation/
    /// scale/shadow from it every frame. That's the whole fix for "two-part
    /// motion" — there is structurally only one motion left to desync from.
    @State private var shedProgress: [String: CGFloat] = [:]
    @State private var shedSeen: Set<String> = []

    /// Where a shed-pile card comes to rest: near table center, jittered
    /// per-card so the pile doesn't perfectly overlap. Normalized (0…1).
    private func shedRestPoint(cardID: String, size: CGSize) -> CGPoint {
        CGPoint(x: 0.52 + CGFloat(TableGeometry.jitterDegrees(cardID: cardID)) * 0.35 / size.width,
               y: 0.47 + CGFloat(TableGeometry.jitterDegrees(cardID: cardID + "y")) * 0.3 / size.height)
    }

    private func shedPile(state: GameState, size: CGSize) -> some View {
        let recent = state.discardPile.suffix(4)
        let cardWidth = TableGeometry.tableCardWidth(for: size)
        let anchors = effectiveAnchors(state)
        return ForEach(Array(recent.enumerated()), id: \.element.id) { index, card in
            let seat = host.seatByPlayedCard[card.id]
            let seatAnchor = seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }
            let toss = FeltPhysics.pileToss(cardID: card.id, seatAnchor: seatAnchor,
                                            restPoint: shedRestPoint(cardID: card.id, size: size),
                                            tableSize: size)
            // Cards not yet tracked default to fully home (1) — only a
            // genuinely new arrival (see animateShedArrival) starts at 0.
            let progress = shedProgress[card.id] ?? 1

            shedCard(card: card, toss: toss, progress: progress, index: index,
                     cardWidth: cardWidth, size: size)
                // Top card only: a called wild color makes the wild's own
                // panel glow (UnoCardViews). Scoped here so hands never glow.
                .environment(\.unoActiveColor,
                             (state.gameKind == .uno && index == recent.count - 1)
                                 ? (state.discardPile.last?.unoColor
                                     ?? state.round?.trumpSuit?.unoColor)
                                 : nil)
                .onAppear { animateShedArrival(card: card, toss: toss, state: state, size: size) }
        }
        .onChange(of: state.discardPile.count) { _, _ in
            let current = Set(state.discardPile.map(\.id))
            shedSeen.formIntersection(current)
            shedProgress = shedProgress.filter { current.contains($0.key) }
        }
    }

    /// One shed-pile card: the single-progress throw while airborne, then —
    /// from touchdown on — a FeltSim body (so a landing that only grazes
    /// the pile can shove a card, and the pile's stacking is the sim's
    /// stack rule, not an index).
    @ViewBuilder
    private func shedCard(card: Card, toss: FeltPhysics.PileToss, progress: CGFloat,
                          index: Int, cardWidth: CGFloat, size: CGSize) -> some View {
        if let box = feltSim.box(for: card.id) {
            SimPlacedCard(box: box, lift: 0, cardWidth: cardWidth) {
                CardView(card: card, faceUp: true, elevation: 0)
                    .frame(width: cardWidth)
            }
        } else {
            PileTossCardView(progress: progress, card: card, toss: toss,
                             cardWidth: cardWidth, tableSize: size, groundZIndex: Double(index))
        }
    }

    /// The airborne throw: the card leaves the thrower's edge already in
    /// flight and lands on the pile in ONE motion — one `progress` scalar,
    /// one `withAnimation` call. Position, height, rotation, scale, and the
    /// separated ground shadow are all derived from that single scalar
    /// inside `PileTossCardView` (see `FeltPhysics.evaluate`), so there is
    /// no second animation left to fall out of step with the first.
    private func animateShedArrival(card: Card, toss: FeltPhysics.PileToss, state: GameState,
                                    size: CGSize) {
        guard !shedSeen.contains(card.id) else { return }
        shedSeen.insert(card.id)
        let restPoint = CGPoint(x: toss.rest.x * size.width, y: toss.rest.y * size.height)
        // Cards already down when this view appeared (resume, rejoin)
        // don't replay their landing; they're set down where they rest.
        guard card.id == state.discardPile.last?.id else {
            shedProgress[card.id] = 1
            feltSim.land(id: card.id, at: restPoint, angle: toss.restRotation)
            return
        }

        if motionReduced {
            // Reduce Motion: the same single-progress path, just flattened
            // to a quick, short, flat slide — no rising/falling arc.
            let flat = FeltPhysics.flatSlide(toss)
            shedProgress[card.id] = 0
            DispatchQueue.main.async {
                if !isSpectator {
                    TableSFX.shared.play(.cardSlide, intensity: 0.6)
                }
                withAnimation(.easeOut(duration: flat.duration)) {
                    shedProgress[card.id] = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + flat.duration) {
                    feltSim.land(id: card.id, at: restPoint, angle: toss.restRotation)
                }
            }
            return
        }

        // Leave the hand already airborne at the table's edge.
        shedProgress[card.id] = 0

        // The curve is front-loaded, so the card touches down EARLIER than
        // duration * touchdownFraction: solve the curve for the real instant.
        let curve = (0.25, 0.10, 0.30, 1.0)
        let touchdownAt = toss.duration * FeltTiming.time(
            atProgress: Double(toss.touchdownFraction), curve.0, curve.1, curve.2, curve.3)
        DispatchQueue.main.async {
            withAnimation(.timingCurve(curve.0, curve.1, curve.2, curve.3, duration: toss.duration)) {
                shedProgress[card.id] = 1
            }
            // Touchdown: the contact sound AND the handoff to FeltSim, which
            // owns the card from the felt contact on.
            DispatchQueue.main.asyncAfter(deadline: .now() + touchdownAt) {
                if !isSpectator {
                    TableSFX.shared.play(.cardSlide, intensity: 0.6 + Double(toss.apex) / 90.0 * 0.9)
                }
                handOffTouchdown(id: card.id, toss: toss, size: size,
                                 skidDuration: max(0.05, toss.duration - touchdownAt))
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
        // Lands ON the deck stack: the sim's stack rule puts it on top of
        // any earlier flips there instead of colliding with them.
        feltSim.land(id: card.id,
                     at: CGPoint(x: restPoint.x * size.width, y: restPoint.y * size.height),
                     angle: tilt)
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
        // A card that already has a place (rejoin, relaunch, or dealt off
        // the deck onto open felt, where the drop handler recorded the
        // release point) is simply set down there — by the stack rule.
        if let known = host.freePlayLayout[card.id] {
            feltSim.land(id: card.id,
                         at: CGPoint(x: known.x * size.width, y: known.y * size.height),
                         angle: rotationByCard[card.id]
                            ?? TableGeometry.jitterDegrees(cardID: card.id) * 2.2)
            return
        }

        if deckFlipCardIDs.remove(card.id) != nil {
            animateDeckFlip(card: card, size: size)
            return
        }

        let anchors = effectiveAnchors(state)
        let seat = host.seatByPlayedCard[card.id]
        let anchor = seat.flatMap { anchors.indices.contains($0) ? anchors[$0] : nil }

        if let toss = pileDropToss(for: card.id, state: state, size: size) {
            // ARC: one continuous throw onto the pile, ONE progress scalar
            // driving everything (see FeltPhysics.evaluate / PileTossCardView)
            // — the same single-progress mechanism as the shed pile. The
            // FINAL approach belongs to FeltSim: at touchdown the card
            // becomes a body that skids to rest, rides on whatever it
            // landed on, or shoves a neighbor it only grazed.
            host.freePlayLayout[card.id] = toss.entry
            rotationByCard[card.id] = toss.entryRotation
            pileDropProgress[card.id] = 0
            let curve = (0.25, 0.10, 0.30, 1.0)
            let touchdownAt = toss.duration * FeltTiming.time(
                atProgress: Double(toss.touchdownFraction), curve.0, curve.1, curve.2, curve.3)
            DispatchQueue.main.async {
                withAnimation(.timingCurve(curve.0, curve.1, curve.2, curve.3, duration: toss.duration)) {
                    pileDropProgress[card.id] = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + touchdownAt) {
                    if !isSpectator {
                        TableSFX.shared.play(.cardSlide, intensity: 0.55 + Double(toss.apex) / 96.0 * 0.6)
                    }
                    handOffTouchdown(id: card.id, toss: toss, size: size,
                                     skidDuration: max(0.05, toss.duration - touchdownAt))
                    pileDropProgress[card.id] = nil
                }
            }
            return
        }

        // TOSS: the friction slide, now a body sliding on felt friction —
        // same distance, same stop time, same spin (FeltSim.toss solves
        // v0 = 2d/T, a = 2d/T^2, the quad ease-out), but it can meet things.
        let toss = FeltPhysics.toss(
            cardID: card.id,
            seatAnchor: anchor,
            throwVelocity: host.throwVelocityByCard.removeValue(forKey: card.id),
            tableSize: size)
        // Reduce Motion: shorter slide, same landing spot.
        let duration = motionReduced ? toss.duration * 0.45 : toss.duration

        host.freePlayLayout[card.id] = toss.rest
        rotationByCard[card.id] = toss.restRotation
        feltSim.toss(id: card.id,
                     from: CGPoint(x: toss.entry.x * size.width, y: toss.entry.y * size.height),
                     to: CGPoint(x: toss.rest.x * size.width, y: toss.rest.y * size.height),
                     duration: duration,
                     angleFrom: toss.restRotation - toss.spin, angleTo: toss.restRotation)
        // The slide sound's pitch tracks the throw: toss duration encodes
        // speed (harder = longer).
        DispatchQueue.main.async {
            if !isSpectator {
                let speedNorm = (toss.duration - 0.34) / 0.26 // 0…1 by FeltPhysics
                TableSFX.shared.play(.cardSlide, intensity: 0.55 + speedNorm * 0.85)
            }
        }
    }

    /// The airborne -> felt handoff for a pile toss: the card becomes a sim
    /// body at the touchdown point, still carrying the throw's last skid
    /// and settle twist, so everything after contact is physics.
    private func handOffTouchdown(id: String, toss: FeltPhysics.PileToss, size: CGSize,
                                  skidDuration: Double) {
        let touchdown = CGPoint(x: toss.touchdown.x * size.width, y: toss.touchdown.y * size.height)
        let rest = CGPoint(x: toss.rest.x * size.width, y: toss.rest.y * size.height)
        let glide = FeltSim.Glide(
            distance: FeltVec(x: Double(rest.x - touchdown.x), y: Double(rest.y - touchdown.y)),
            duration: skidDuration, spinDegrees: toss.settleTwist)
        feltSim.land(id: id, at: touchdown, angle: toss.restRotation - toss.settleTwist, glide: glide)
    }

/// One pile-toss card, in flight or at rest. `progress` IS its
/// `animatableData`: SwiftUI tweens this single scalar across the
/// transaction and re-invokes `body` at every intermediate frame, so
/// position, height, rotation, scale, and the separated ground shadow are
/// all read from `FeltPhysics.evaluate` at the SAME instant, every time.
/// That's the structural fix for "two-part motion" — there's only one
/// thing left to animate, so it can't fall out of step with itself.
struct PileTossCardView: View, Animatable {
    var progress: CGFloat
    let card: Card
    let toss: FeltPhysics.PileToss
    let cardWidth: CGFloat
    let tableSize: CGSize
    let groundZIndex: Double

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = FeltPhysics.evaluate(toss, progress: progress, tableSize: tableSize)
        let airborne = frame.heightPoints > 0.5
        ZStack {
            // The ground shadow: lives ON the felt while the card is in the
            // air. Softer, wider, and fainter the higher the card; it
            // merges into a contact shadow exactly at touchdown (p = 1).
            if airborne {
                FeltGroundShadow(lift: frame.heightPoints, cardWidth: cardWidth)
                    .position(frame.position)
            }
            // The card itself: lifted above its ground track, bigger when
            // higher (closer to your eyes), spinning down to rest.
            // Resting = CardView's own contact shadow, nothing more (this
            // used to stack a second .shadow on top of it, so pile cards
            // looked heavier than every other card on the felt).
            CardView(card: card, faceUp: true,
                     elevation: FeltShadow.cardElevation(lift: frame.heightPoints))
                .frame(width: cardWidth)
                .rotationEffect(.degrees(frame.rotation))
                .scaleEffect(frame.scale)
                .position(x: frame.position.x, y: frame.position.y - frame.heightPoints)
        }
        .zIndex(airborne ? 400 : groundZIndex)
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
        case .passing:
            TableBanner(text: passingBanner(state: state))
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

    /// Hearts: the direction plus who the table is still waiting on, so
    /// the iPad narrates the simultaneous phase the way it narrates turns.
    /// The plates carry the per-seat check / pulse (see SeatPlateView).
    private func passingBanner(state: GameState) -> String {
        guard let round = state.round else { return "Passing three cards…" }
        let direction: String
        switch round.passDirection {
        case .left: direction = "left"
        case .right: direction = "right"
        case .across: direction = "across"
        case .hold, nil: direction = ""
        }
        let waiting = state.seats.filter { round.passSelections[$0.id] == nil }.map(\.playerName)
        let lead = direction.isEmpty ? "Passing three cards" : "Passing three cards \(direction)"
        if waiting.isEmpty { return "\(lead)…" }
        if waiting.count == state.seats.count { return "\(lead) — everyone is picking…" }
        return "\(lead) — waiting on \(ListFormatter.localizedString(byJoining: waiting))…"
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
