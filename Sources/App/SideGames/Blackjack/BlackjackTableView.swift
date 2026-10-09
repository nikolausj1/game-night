import SwiftUI

/// The blackjack table, mounted by `SideGameRegistry` for kind "blackjack".
/// Thin wrapper: pulls the `BlackjackHost` out of the generic host
/// controller and hands the stage plain values and closures, so the stage
/// itself can be previewed with no controller at all.
struct BlackjackTableView: View {
    @Bindable var host: GameHostController
    var onClose: () -> Void = {}

    var body: some View {
        // Tracked read: every side-game mutation bumps this.
        let _ = host.stateVersion
        Group {
            if let bj = host.sideGame as? BlackjackHost {
                BlackjackTableStage(
                    bj: bj,
                    botSeats: bj.botSeats,
                    // Human seats with no phone attached act by tapping the felt.
                    tapSeats: Set(0..<bj.seatCount).subtracting(bj.botSeats)
                        .subtracting(Set(host.sideGameSeatByDevice.values)),
                    onClose: onClose,
                    onTableTap: { seat, action in
                        if let payload = try? SideGamePayload(
                            kind: BlackjackEngine.kind, value: BlackjackTableTap(seat: seat, action: action)) {
                            host.sideGameTableAction(payload)
                        }
                    },
                    onPlayAgain: { host.restartSideGame() })
                // A restart builds a NEW host: re-key so the theater re-attaches.
                .id(ObjectIdentifier(bj))
            }
        }
    }
}

/// The felt. Everything on it is drawn from `BlackjackTheater.display` (the
/// replayed, timed view of the engine), never straight from engine state.
struct BlackjackTableStage: View {
    let bj: BlackjackHost
    let botSeats: Set<Int>
    let tapSeats: Set<Int>
    var onClose: () -> Void = {}
    var onTableTap: (Int, BlackjackAction) -> Void = { _, _ in }
    var onPlayAgain: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var theater = BlackjackTheater()
    /// Table-pad bet being composed per phoneless seat.
    @State private var pads: [Int: Int] = [:]

    var body: some View {
        // Tracked reads: the host's version drives replay; the theater's
        // display drives drawing.
        let version = bj.version
        return GeometryReader { geo in
            let layout = BJLayout(size: geo.size, seats: bj.seatCount)
            ZStack {
                furniture(layout)
                chipsLayer(layout)
                cardsLayer(layout)
                labelsLayer(layout)
                flightsLayer(layout)
                calloutsLayer(layout)
                controlsLayer(layout)
                narrationBar(layout)
                infoCorner
                if theater.display.sessionOver { sessionOverPanel }
                GameHUD(title: "Blackjack", onExit: onClose, toggles: [])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: version) { _, _ in theater.consume() }
        }
        .onAppear { theater.attach(bj, reduceMotion: reduceMotion) }
        .onDisappear { theater.detach() }
        .onChange(of: reduceMotion) { _, v in theater.reduceMotion = v }
    }

    private var d: BJDisplay { theater.display }

    private func handCounts() -> [Int] { d.seats.map { max(1, $0.hands.count) } }

    // MARK: furniture

    private func furniture(_ L: BJLayout) -> some View {
        ZStack {
            BJRulesArc(layout: L, config: bj.config)
            ForEach(0..<bj.seatCount, id: \.self) { seat in
                BJSpotMarking(number: seat + 1, diameter: L.spotD,
                              active: d.activeSeat == seat, reduceMotion: reduceMotion)
                    .position(L.spot(seat))
            }
            BJRackView(size: L.rackSize, chipWidth: L.chipW * 0.8)
                .position(L.rackCenter)
            Text("DEALER")
                .font(.system(size: max(11, L.cw * 0.2), weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(CardStyle.gold.opacity(0.6))
                .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
                .position(L.dealerLabel)
                .accessibilityHidden(true)
            BJTrayView(width: L.trayWidth, count: d.trayCount)
                .position(L.trayCenter)
            BJShoeView(width: L.shoeWidth, kick: reduceMotion ? 0 : theater.shoeKick)
                .position(L.shoeCenter)
        }
        .allowsHitTesting(false)
    }

    // MARK: chips on the spots

    private func chipsLayer(_ L: BJLayout) -> some View {
        ZStack {
            ForEach(Array(d.seats.enumerated()), id: \.offset) { seat, s in
                ForEach(Array(s.hands.enumerated()), id: \.offset) { h, hand in
                    betStack(hand, at: L.betPoint(seat: seat, hand: h, of: max(1, s.hands.count)), L)
                }
                if s.insurance > 0 {
                    BJChipStackView(amount: s.insurance, chipWidth: L.chipW * 0.8)
                        .position(x: L.spot(seat).x - L.spotD * 0.78, y: L.spot(seat).y)
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: d.seats.map { $0.hands.map(\.betShown) })
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func betStack(_ hand: BJHandDisplay, at p: CGPoint, _ L: BJLayout) -> some View {
        if hand.betShown > 0 {
            if hand.doubled && hand.betShown == hand.bet {
                // A double is a second pile next to the first, as at a real table.
                ZStack {
                    BJChipStackView(amount: hand.bet / 2, chipWidth: L.chipW)
                        .offset(x: -L.chipW * 0.45)
                    BJChipStackView(amount: hand.bet - hand.bet / 2, chipWidth: L.chipW)
                        .offset(x: L.chipW * 0.55, y: -L.chipW * 0.18)
                }
                .position(p)
            } else {
                BJChipStackView(amount: hand.betShown, chipWidth: L.chipW)
                    .position(p)
                    .transition(.opacity)
            }
        }
    }

    // MARK: cards

    private func cardsLayer(_ L: BJLayout) -> some View {
        let sweepTarget = L.trayCenter
        return ZStack {
            ForEach(Array(d.dealer.enumerated()), id: \.element.id) { i, slot in
                let rest = L.dealerRest(index: i, id: slot.id)
                let launch = L.shoeSlot
                let toss = L.toss(id: slot.id, from: launch, to: rest.point, rotation: rest.rotation, dealer: true)
                cardView(slot, toss: toss, width: L.cw, size: L.size, peek: i == 1 && theater.peeking ? -16 : 0)
                    .modifier(SweepEffect(sweep: theater.sweep, from: rest.point, to: sweepTarget))
                    .zIndex(Double(i))
            }
            ForEach(Array(d.seats.enumerated()), id: \.offset) { seat, s in
                ForEach(Array(s.hands.enumerated()), id: \.offset) { h, hand in
                    let count = max(1, s.hands.count)
                    let w = L.cardWidth(handCount: count)
                    ForEach(Array(hand.cards.enumerated()), id: \.element.id) { i, slot in
                        let rest = L.playerRest(seat: seat, hand: h, of: count, index: i, id: slot.id)
                        let launch = launchPoint(slot, L)
                        let toss = L.toss(id: slot.id, from: launch, to: rest.point, rotation: rest.rotation, dealer: false)
                        cardView(slot, toss: toss, width: w, size: L.size, peek: 0)
                            .modifier(SweepEffect(sweep: theater.sweep, from: rest.point, to: sweepTarget))
                            .zIndex(Double(seat) * 0.01 + Double(h) * 0.1 + Double(i))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func launchPoint(_ slot: BJCardSlot, _ L: BJLayout) -> CGPoint {
        switch slot.origin {
        case .shoe: return L.shoeSlot
        case .slot(let seat, let hand, let index, let count):
            return L.playerRest(seat: seat, hand: hand, of: count, index: index, id: slot.id).point
        }
    }

    private func cardView(_ slot: BJCardSlot, toss: FeltPhysics.PileToss,
                          width: CGFloat, size: CGSize, peek: Double) -> some View {
        BJCardView(progress: theater.progress[slot.id] ?? 1,
                   flip: slot.faceUp ? 180 : 0, peek: peek,
                   card: slot.card, toss: toss, cardWidth: width,
                   tableSize: size, sideways: slot.sideways,
                   turnsInFlight: slot.origin == .shoe)
            .animation(reduceMotion ? nil : .easeInOut(duration: BJMotion.flipDuration), value: slot.faceUp)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: peek)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slot.faceUp ? slot.card.accessibleName : "Face-down card")
    }

    // MARK: totals, tags, plates

    private func labelsLayer(_ L: BJLayout) -> some View {
        ZStack {
            // Dealer total + tag, left of the dealer's cards.
            let faceUp = d.dealer.filter(\.faceUp).map(\.card)
            if !faceUp.isEmpty {
                let t = BlackjackText.total(faceUp)
                VStack(spacing: 6) {
                    if let tag = d.dealerTag { BJTagView(tag: tag, size: 13) }
                    BJTotalChip(text: t, bust: t == "BUST", diameter: max(30, L.cw * 0.42))
                }
                .position(x: L.dealerTotal.x - 8, y: L.dealerTotal.y - (d.dealerTag != nil ? 14 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: t)
            }
            ForEach(Array(d.seats.enumerated()), id: \.offset) { seat, s in
                seatLabels(seat: seat, s: s, L)
                BJPlateView(name: bj.name(of: seat), colorIndex: seat, chips: s.chips,
                            isBot: botSeats.contains(seat), active: d.activeSeat == seat,
                            sittingOut: s.sittingOut, isOut: s.isOut, actionTag: s.actionTag)
                    .position(L.plate(seat))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(seatSummary(seat, s))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func seatLabels(seat: Int, s: BJSeatDisplay, _ L: BJLayout) -> some View {
        let count = max(1, s.hands.count)
        ForEach(Array(s.hands.enumerated()), id: \.offset) { h, hand in
            if !hand.cards.isEmpty {
                let w = L.cardWidth(handCount: count)
                let x = L.handX(seat: seat, hand: h, of: count)
                let top = L.cardAnchorY(seat) - w * 0.7 - 12 - CGFloat(max(0, hand.cards.count - 1)) * w * 0.07
                let t = BlackjackText.total(hand.cards.map(\.card))
                VStack(spacing: 5) {
                    if let tag = hand.tag { BJTagView(tag: tag, size: 12.5) }
                    BJTotalChip(text: t, bust: t == "BUST", diameter: max(28, w * 0.42))
                }
                .position(x: x, y: top - (hand.tag != nil ? 14 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: t)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: hand.tag)
            }
        }
    }

    private func seatSummary(_ seat: Int, _ s: BJSeatDisplay) -> String {
        var parts = ["\(bj.name(of: seat)), \(s.chips) chips"]
        if s.isOut { parts.append("out of chips") }
        for hand in s.hands where !hand.cards.isEmpty {
            parts.append("hand " + hand.cards.map(\.card.accessibleName).joined(separator: ", ")
                         + ", total " + BlackjackText.total(hand.cards.map(\.card)))
            if hand.bet > 0 { parts.append("bet \(hand.bet)") }
            if let t = hand.tag { parts.append(t.text) }
        }
        if d.activeSeat == seat { parts.append("their turn") }
        return parts.joined(separator: ". ")
    }

    // MARK: flights + callouts

    private func flightsLayer(_ L: BJLayout) -> some View {
        let counts = handCounts()
        return ZStack {
            ForEach(theater.flights) { f in
                BJChipFlightView(progress: theater.flightProgress[f.id] ?? 0,
                                 amount: f.amount, chipWidth: L.chipW,
                                 from: L.point(f.from, handCounts: counts),
                                 to: L.point(f.to, handCounts: counts),
                                 flat: reduceMotion)
            }
        }
        .zIndex(20)
        .allowsHitTesting(false)
    }

    private func calloutsLayer(_ L: BJLayout) -> some View {
        ZStack {
            ForEach(theater.callouts) { c in
                BJCalloutView(callout: c, size: max(26, min(46, L.size.width * 0.036)))
                    .position(calloutPoint(c.anchor, L))
            }
            // The gold burst behind a natural blackjack.
            GoldBurst(trigger: theater.fanfare, reduceMotion: reduceMotion)
                .frame(width: L.size.width, height: L.size.height)
        }
        .zIndex(25)
        .allowsHitTesting(false)
    }

    private func calloutPoint(_ a: BJCallout.Anchor, _ L: BJLayout) -> CGPoint {
        switch a {
        case .seat(let s): return CGPoint(x: L.spot(s).x, y: L.cardAnchorY(s) - L.cw * 0.2)
        case .dealer: return CGPoint(x: L.size.width * 0.5, y: L.size.height * 0.27)
        case .center: return CGPoint(x: L.size.width * 0.5, y: L.size.height * 0.5)
        }
    }

    // MARK: narration + info

    private func narrationBar(_ L: BJLayout) -> some View {
        Group {
            if let text = narration() {
                Text(text)
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.92))
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.38)))
                    .id(text)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: narration())
        .position(x: L.size.width * 0.5, y: L.size.height * 0.4)
        .allowsHitTesting(false)
    }

    private func narration() -> String? {
        if let o = d.statusOverride { return o }
        if d.sessionOver { return nil }
        if let a = d.activeSeat {
            return "\(bj.name(of: a))'s turn"
        }
        let anyCards = !d.dealer.isEmpty || d.seats.contains { $0.hands.contains { !$0.cards.isEmpty } }
        if !anyCards {
            let waiting = d.seats.indices.filter { !d.seats[$0].isOut && !d.seats[$0].sittingOut && d.seats[$0].hands.isEmpty }
            return waiting.isEmpty ? nil : "Place your bets"
        }
        return nil
    }

    private var infoCorner: some View {
        VStack {
            Spacer()
            HStack {
                Text("Round \(d.round)  \u{00B7}  \(bj.engine.state.shoeRemaining) cards in the shoe")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.5))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                Spacer()
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    // MARK: table taps (human seats with no phone)

    private func controlsLayer(_ L: BJLayout) -> some View {
        ZStack {
            ForEach(Array(tapSeats.sorted()), id: \.self) { seat in
                seatControls(seat, L)
            }
        }
        .zIndex(26)
    }

    /// Where a seat's tap buttons live: beside its spot, on the side with
    /// room (the last seat's pad opens to the left), clear of the plates.
    private func sidePadPoint(_ seat: Int, _ L: BJLayout, width: CGFloat) -> CGPoint {
        let s = L.spot(seat)
        let dx = L.spotD / 2 + 10 + width / 2
        let left = seat == L.n - 1 && L.n > 1
        return CGPoint(x: s.x + (left ? -dx : dx), y: s.y)
    }

    @ViewBuilder
    private func seatControls(_ seat: Int, _ L: BJLayout) -> some View {
        if theater.idle, seat < d.seats.count {
            let legal = bj.engine.state.legalActions(for: seat)
            if legal.contains(.placeBet) {
                betPad(seat, L)
            } else if legal.contains(.takeInsurance) {
                VStack(spacing: 5) {
                    BJBrassButton(title: "INSURE", width: 72) { onTableTap(seat, .takeInsurance(true)) }
                    BJBrassButton(title: "NO", prominent: false, width: 72) { onTableTap(seat, .takeInsurance(false)) }
                }
                .position(sidePadPoint(seat, L, width: 72))
            } else if legal.contains(.hit) {
                playPad(seat, legal, L)
            }
        }
    }

    private func playPad(_ seat: Int, _ legal: [BlackjackActionKind], _ L: BJLayout) -> some View {
        let w: CGFloat = 72
        return VStack(spacing: 5) {
            BJBrassButton(title: "HIT", width: w) { onTableTap(seat, .hit) }
            BJBrassButton(title: "STAND", width: w) { onTableTap(seat, .stand) }
            if legal.contains(.doubleDown) { BJBrassButton(title: "DOUBLE", prominent: false, width: w) { onTableTap(seat, .doubleDown) } }
            if legal.contains(.split) { BJBrassButton(title: "SPLIT", prominent: false, width: w) { onTableTap(seat, .split) } }
            if legal.contains(.surrender) { BJBrassButton(title: "FOLD", prominent: false, width: w) { onTableTap(seat, .surrender) } }
        }
        .position(sidePadPoint(seat, L, width: w))
        .transition(.opacity)
    }

    private func betPad(_ seat: Int, _ L: BJLayout) -> some View {
        let cfg = bj.config
        let chips = bj.engine.state.seats[seat].chips
        let cap = max(cfg.minBet, min(cfg.maxBet, chips) - min(cfg.maxBet, chips) % cfg.betStep)
        let amount = pads[seat] ?? min(cap, max(cfg.minBet, cfg.minBet))
        let w = L.chipW * 0.9
        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach([BJChipDenom.five, .ten, .twentyFive, .hundred]) { dn in
                    Button {
                        Haptics.tick()
                        pads[seat] = BlackjackBetMath.add(dn.rawValue, to: amount == cfg.minBet && pads[seat] == nil ? 0 : amount, config: cfg, bankroll: chips)
                    } label: { BJTrayChip(denom: dn, size: w) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(dn.rawValue)")
                }
            }
            HStack(spacing: 6) {
                BJBrassButton(title: "BET \(amount)", width: 86) {
                    onTableTap(seat, .placeBet(amount))
                    pads[seat] = nil
                }
                BJBrassButton(title: "CLEAR", prominent: false, width: 52) { pads[seat] = cfg.minBet }
                BJBrassButton(title: "SIT OUT", prominent: false, width: 64) { onTableTap(seat, .sitOut) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.4)))
        .position(x: L.spot(seat).x, y: L.cardAnchorY(seat))
    }

    // MARK: end of session

    private var sessionOverPanel: some View {
        ScorecardPanel(title: "The table is cleaned out") {
            ForEach(Array(d.seats.enumerated()), id: \.offset) { seat, s in
                HStack {
                    Circle().fill(PlayerPalette.color(seat)).frame(width: 12, height: 12)
                    Text(bj.name(of: seat)).font(.system(.title3, design: .serif))
                    Spacer()
                    Text("\(s.chips)").font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(CardStyle.stockTop)
            }
        } action: {
            HStack(spacing: 14) {
                Button { onPlayAgain() } label: {
                    Text("Play again").font(.title3.weight(.bold)).padding(.horizontal, 30).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(CardStyle.gold).foregroundStyle(CardStyle.ink)
                Button { onClose() } label: {
                    Text("Back to menu").font(.title3.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.bordered).tint(CardStyle.stockTop)
            }
        }
        .zIndex(28)
    }
}

// MARK: - helpers

/// The dealer sweeping a card to the discard tray: drifts toward it, shrinks,
/// fades. One animated scalar from the theater.
struct SweepEffect: ViewModifier {
    var sweep: CGFloat
    let from: CGPoint
    let to: CGPoint

    func body(content: Content) -> some View {
        content
            .offset(x: (to.x - from.x) * sweep, y: (to.y - from.y) * sweep)
            .scaleEffect(1 - 0.35 * sweep)
            .opacity(1 - 0.25 * Double(sweep))
    }
}

/// A short radial gold flash behind a natural blackjack.
struct GoldBurst: View {
    let trigger: Int
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion || trigger == 0 {
            Color.clear
        } else {
            Color.clear
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, v in
                    content.overlay {
                        Circle()
                            .strokeBorder(CardStyle.gold, lineWidth: 6)
                            .frame(width: 80 + v * 520, height: 80 + v * 520)
                            .opacity((1 - v) * 0.8)
                            .blur(radius: 2 + v * 6)
                    }
                } keyframes: { _ in
                    CubicKeyframe(1, duration: 0.9)
                }
        }
    }
}

/// Bet-composer arithmetic shared by the phone pad and the table pad.
enum BlackjackBetMath {
    /// Add a chip to a running bet: round UP to the table's bet step (so a
    /// single 1-chip on a step-2 table becomes 2, never an illegal bet) and
    /// stop at the table max / the bankroll.
    static func add(_ chip: Int, to current: Int, config c: BlackjackConfig, bankroll: Int) -> Int {
        var cap = min(c.maxBet, bankroll)
        cap -= cap % c.betStep
        var next = current + chip
        if next % c.betStep != 0 { next += c.betStep - next % c.betStep }
        return max(0, min(next, cap))
    }

    static func floorBet(_ c: BlackjackConfig) -> Int {
        c.minBet % c.betStep == 0 ? c.minBet : c.minBet + (c.betStep - c.minBet % c.betStep)
    }

    static func isValid(_ amount: Int, config c: BlackjackConfig, bankroll: Int) -> Bool {
        amount >= c.minBet && amount <= c.maxBet && amount % c.betStep == 0 && amount <= bankroll
    }
}
