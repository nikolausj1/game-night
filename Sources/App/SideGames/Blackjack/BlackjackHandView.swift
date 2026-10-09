import SwiftUI

/// The phone: this player's private action pad. Routed from `HandRootView`
/// via `SideGameRegistry` whenever `client.sideGameState` is a blackjack
/// state. Decodes the wire and hands plain values to `BlackjackPadView`,
/// which is also what the previews drive.
struct BlackjackHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        let state = client.sideGameState?.decode(BlackjackPhoneState.self)
        let batch = client.sideGameEvents?.decode(BlackjackEventBatch.self)
        Group {
            if let state {
                BlackjackPadView(state: state, events: batch) { action in
                    client.sendSideGameAction(kind: BlackjackEngine.kind, action)
                }
            } else {
                ZStack {
                    FeltBackground()
                    Text("Taking a seat\u{2026}")
                        .font(.system(.title3, design: .serif).italic())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.7))
                }
            }
        }
        .statusBarHidden()
    }
}

/// The pad itself. The table is the truth and runs the show, so everything
/// here that would spoil it is HELD until the felt would have caught up:
/// the dealer's drawn cards, the outcome banner, the bankroll after a
/// settlement, and the action buttons while the table is still dealing.
struct BlackjackPadView: View {
    let state: BlackjackPhoneState
    var events: BlackjackEventBatch?
    var send: (BlackjackAction) -> Void
    /// Previews turn the presentation holds off so a static state shows fully.
    var holds = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var betAmount = 0
    @State private var lastBet = 0
    @State private var controlsLocked = false
    @State private var dealerShown: Int?
    @State private var lockedChips: Int?
    @State private var resultsHidden = false
    @State private var toast: String?
    @State private var generation = 0

    private var snap: BlackjackSnapshot { state.snapshot }
    private var me: Int { snap.mySeat }
    private var seat: BlackjackSeatState? { snap.seats.indices.contains(me) ? snap.seats[me] : nil }
    private var cfg: BlackjackConfig { snap.config }
    private var legal: [BlackjackActionKind] { snap.legalActions }
    private var bankroll: Int { lockedChips ?? seat?.chips ?? 0 }
    private var myTurn: Bool { snap.phase == .playing && snap.activeSeat == me }

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                header
                dealerStrip
                    .padding(.top, 10)
                Spacer(minLength: 8)
                myHands
                Spacer(minLength: 8)
                statusLine
                pad
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 16)
            if let toast {
                Text(toast)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.ink)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(CardStyle.gold))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { resetBet(); dealerShown = nil }
        .onChange(of: events?.seq) { _, _ in if let events { ingest(events) } }
        .onChange(of: snap.phase) { old, new in
            if new == .betting { resetBet() }
            if new == .roundComplete { dealerShown = nil }
        }
        .onChange(of: myTurn) { _, mine in if mine { Haptics.arm() } }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: snap.phase)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Blackjack")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Text("Round \(snap.roundNumber)")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.5))
            Spacer()
            BJChipFace(denom: .five, width: 22)
            Text("\(bankroll)")
                .font(.system(.title3, design: .serif).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(CardStyle.gold)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: bankroll)
                .accessibilityLabel("\(bankroll) chips")
        }
        .padding(.top, 14)
    }

    // MARK: the dealer, small

    private var dealerStrip: some View {
        let shown = min(dealerShown ?? snap.dealerCards.count, snap.dealerCards.count)
        let cards = Array(snap.dealerCards.prefix(shown))
        let hiddenHole = snap.dealerHoleHidden || shown < snap.dealerCards.count
        return HStack(spacing: 10) {
            Text("DEALER")
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(2)
                .foregroundStyle(CardStyle.gold.opacity(0.6))
                .frame(width: 58, alignment: .leading)
            HStack(spacing: -22) {
                ForEach(cards) { c in
                    CardView(card: c, faceUp: true).frame(width: 44)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if hiddenHole && !snap.dealerCards.isEmpty {
                    CardView(card: Card(id: "pad-hole", kind: .standard(suit: .spades, rank: 2)), faceUp: false)
                        .frame(width: 44)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: cards.map(\.id))
            if !cards.isEmpty {
                let t = BlackjackText.total(cards)
                BJTotalChip(text: hiddenHole ? "\(t)+" : t, bust: t == "BUST", diameter: 28)
            }
            Spacer()
        }
        .frame(minHeight: 62)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dealerLabel(cards, hidden: hiddenHole))
    }

    private func dealerLabel(_ cards: [Card], hidden: Bool) -> String {
        guard !cards.isEmpty else { return "Dealer has no cards yet" }
        return "Dealer shows " + cards.map(\.accessibleName).joined(separator: ", ")
            + (hidden ? ", and one card face down" : "")
    }

    // MARK: my hands, mirrored small (the table is the truth)

    @ViewBuilder
    private var myHands: some View {
        if let seat, !seat.hands.isEmpty {
            HStack(alignment: .top, spacing: seat.hands.count > 1 ? 18 : 0) {
                ForEach(Array(seat.hands.enumerated()), id: \.offset) { i, hand in
                    handColumn(hand, index: i, split: seat.hands.count > 1)
                }
            }
        } else if snap.phase == .betting, legal.contains(.placeBet) {
            betPreview
        } else {
            Color.clear.frame(height: 100)
        }
    }

    private func handColumn(_ hand: BlackjackHand, index: Int, split: Bool) -> some View {
        let w: CGFloat = split ? 52 : 68
        let active = myTurn && snap.activeHand == index
        let showOutcome = !resultsHidden && hand.outcome != nil
        return VStack(spacing: 8) {
            HStack(spacing: -w * 0.5) {
                ForEach(hand.cards) { c in
                    CardView(card: c, faceUp: true).frame(width: w)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hand.cards.map(\.id))
            HStack(spacing: 8) {
                let t = BlackjackText.total(hand.cards)
                BJTotalChip(text: t, bust: t == "BUST", diameter: 30)
                if hand.bet > 0 {
                    HStack(spacing: 4) {
                        BJChipFace(denom: .ten, width: 15)
                        Text("\(hand.bet)")
                            .font(.system(.footnote, design: .serif).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(CardStyle.gold)
                    }
                }
            }
            if showOutcome, let o = hand.outcome {
                BJTagView(tag: BJDisplay.tag(for: o, net: hand.payout - hand.bet), size: 13)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? CardStyle.gold : .clear, lineWidth: 2)
                .shadow(color: active ? CardStyle.gold.opacity(0.6) : .clear, radius: 8)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your hand: " + hand.cards.map(\.accessibleName).joined(separator: ", ")
                            + ", total \(BlackjackText.total(hand.cards)), bet \(hand.bet)")
    }

    // MARK: status

    @ViewBuilder
    private var statusLine: some View {
        if let text = statusText {
            Text(text)
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.3)))
                .padding(.bottom, 10)
                .multilineTextAlignment(.center)
        }
    }

    private var statusText: String? {
        guard let seat else { return nil }
        switch snap.phase {
        case .betting:
            if seat.isOut { return "You're out of chips. Watch the table." }
            if seat.sittingOut { return "Sitting this round out." }
            if seat.hasBet { return "Bet placed. Waiting for the others\u{2026}" }
            return nil
        case .insurance:
            return legal.contains(.takeInsurance) ? nil : "Insurance is being decided\u{2026}"
        case .playing:
            if myTurn { return nil }
            if let a = snap.activeSeat { return "Waiting on \(name(of: a))\u{2026}" }
            return "Dealer's turn"
        case .roundComplete:
            if resultsHidden { return "Dealer's turn" }
            if seat.isOut { return "Out of chips. Great game." }
            if !seat.hasBet { return "Next hand coming up\u{2026}" }
            let net = seat.lastRoundNet
            if net > 0 { return "You won \(net). Next hand coming up\u{2026}" }
            if net < 0 { return "Down \(abs(net)). Next hand coming up\u{2026}" }
            return "Even this hand. Next one coming up\u{2026}"
        case .sessionOver:
            return "The table is cleaned out. Thanks for playing."
        }
    }

    private func name(of seat: Int) -> String {
        state.names.indices.contains(seat) ? state.names[seat] : "player \(seat + 1)"
    }

    // MARK: the pad

    @ViewBuilder
    private var pad: some View {
        switch snap.phase {
        case .betting where legal.contains(.placeBet):
            betComposer
        case .insurance where legal.contains(.takeInsurance):
            insurancePad
        case .playing where myTurn:
            actionPad
        default:
            Color.clear.frame(height: 8)
        }
    }

    // MARK: betting

    private var betFloor: Int { BlackjackBetMath.floorBet(cfg) }
    private var betCap: Int {
        var cap = min(cfg.maxBet, bankroll)
        cap -= cap % cfg.betStep
        return cap
    }

    private func resetBet() {
        let want = lastBet > 0 ? lastBet : betFloor
        betAmount = min(max(want, betFloor), max(betFloor, betCap))
    }

    private var betPreview: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(.black.opacity(0.4), lineWidth: 2).offset(y: 1.5)
                Circle().strokeBorder(CardStyle.gold.opacity(0.65), lineWidth: 2)
                if betAmount > 0 {
                    BJChipStackView(amount: betAmount, chipWidth: 44)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(width: 128, height: 128)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: betAmount)
            Text("Bet \(betAmount)")
                .font(.system(.title2, design: .serif).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(CardStyle.stockTop)
            Text("Table takes \(cfg.minBet) to \(cfg.maxBet)")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your bet is \(betAmount) chips")
    }

    private var betComposer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(BJChipDenom.allCases) { dn in
                    let next = BlackjackBetMath.add(dn.rawValue, to: betAmount, config: cfg, bankroll: bankroll)
                    Button {
                        Haptics.tick()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { betAmount = next }
                    } label: {
                        BJTrayChip(denom: dn, size: 56, enabled: next > betAmount)
                    }
                    .buttonStyle(.plain)
                    .disabled(next <= betAmount)
                    .accessibilityLabel("Add \(dn.rawValue) chips")
                }
            }
            HStack(spacing: 10) {
                smallPadButton("Clear") { betAmount = betFloor }
                if lastBet > 0 && lastBet != betAmount {
                    smallPadButton("Same \(lastBet)") { betAmount = min(max(lastBet, betFloor), max(betFloor, betCap)) }
                }
                smallPadButton("Max") { betAmount = max(betFloor, betCap) }
            }
            let ok = BlackjackBetMath.isValid(betAmount, config: cfg, bankroll: bankroll) && !controlsLocked
            BrassPadButton(title: "PLACE BET  \(betAmount)", enabled: ok) {
                lastBet = betAmount
                send(.placeBet(betAmount))
            }
            Button("Sit this one out") { send(.sitOut) }
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.55))
        }
    }

    private func smallPadButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { action() }
        } label: {
            Text(title)
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.34)).overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: playing

    private var actionPad: some View {
        let go = !controlsLocked
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                BrassPadButton(title: "HIT", enabled: legal.contains(.hit) && go, tall: true) { send(.hit) }
                BrassPadButton(title: "STAND", enabled: legal.contains(.stand) && go, tall: true) { send(.stand) }
            }
            if legal.contains(.doubleDown) || legal.contains(.split) || legal.contains(.surrender) {
                HStack(spacing: 12) {
                    if legal.contains(.doubleDown) {
                        BrassPadButton(title: "DOUBLE", enabled: go, secondary: true) { send(.doubleDown) }
                    }
                    if legal.contains(.split) {
                        BrassPadButton(title: "SPLIT", enabled: go, secondary: true) { send(.split) }
                    }
                    if legal.contains(.surrender) {
                        BrassPadButton(title: "SURRENDER", enabled: go, secondary: true) { send(.surrender) }
                    }
                }
            }
        }
    }

    private var insurancePad: some View {
        VStack(spacing: 10) {
            Text("Dealer shows an ace. Insure your bet for \((seat?.hands.first?.bet ?? 0) / 2)?")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                BrassPadButton(title: "INSURE", enabled: !controlsLocked) { send(.takeInsurance(true)) }
                BrassPadButton(title: "NO THANKS", enabled: !controlsLocked, secondary: true) { send(.takeInsurance(false)) }
            }
        }
    }

    // MARK: presentation holds

    /// A new batch of events: hold what would spoil the table's show.
    private func ingest(_ batch: BlackjackEventBatch) {
        for e in batch.events {
            if case .illegalAttempt(let s, let reason) = e, s == me { showToast(reason) }
        }
        guard holds, BlackjackTimeline.isVisible(batch.events) else { return }
        generation += 1
        let gen = generation
        let sched = BlackjackTimeline.schedule(batch.events)
        let slow = reduceMotion ? 0.6 : 1.0

        // Buttons wait for the dealing / dealer play to finish.
        controlsLocked = true
        later(sched.advance * slow + 0.25, gen) { controlsLocked = false }

        // The dealer's cards appear when the table turns them.
        var newCards = 0
        for beat in sched.beats {
            switch beat.event {
            case .dealerRevealed, .dealerDrew: newCards += 1
            default: break
            }
        }
        if newCards > 0 {
            dealerShown = max(0, snap.dealerCards.count - newCards)
            var k = 0
            for beat in sched.beats {
                switch beat.event {
                case .dealerRevealed, .dealerDrew:
                    k += 1
                    later(beat.at * slow + 0.5, gen) { dealerShown = (dealerShown ?? 0) + 1 }
                default: break
                }
            }
            later(sched.total * slow + 0.2, gen) { dealerShown = nil }
        }

        // Results and the bankroll wait for the settlement to play out.
        let settles = sched.beats.filter { if case .handSettled = $0.event { return true }; return false }
        if let first = settles.first {
            var returned = 0
            for beat in sched.beats {
                switch beat.event {
                case .handSettled(let s, _, _, _, let payout, _) where s == me: returned += payout
                case .insuranceSettled(let s, let payout, _) where s == me: returned += payout
                default: break
                }
            }
            let included = snap.phase == .roundComplete || snap.phase == .sessionOver
            lockedChips = included ? (seat?.chips ?? 0) - returned : (seat?.chips ?? 0)
            resultsHidden = true
            later((first.at + 0.7) * slow + 0.9, gen) {
                resultsHidden = false
                lockedChips = nil
            }
        }
    }

    private func later(_ delay: Double, _ gen: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard gen == generation else { return }
            work()
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toast == text { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Brass pad button

/// The big brass buttons: beveled, a little heavy, and they press in.
struct BrassPadButton: View {
    let title: String
    var enabled = true
    var tall = false
    var secondary = false
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            Haptics.arm()
            action()
        } label: {
            Text(title)
                .font(.system(tall ? .title : .title3, design: .serif).weight(.heavy))
                .foregroundStyle(CardStyle.ink.opacity(enabled ? 1 : 0.55))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: tall ? 76 : 54)
        }
        .buttonStyle(BrassPressStyle(secondary: secondary, enabled: enabled))
        .disabled(!enabled)
        .accessibilityLabel(title.capitalized)
    }
}

private struct BrassPressStyle: ButtonStyle {
    let secondary: Bool
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let top = secondary ? Color(red: 0.80, green: 0.72, blue: 0.56) : Color(red: 0.94, green: 0.80, blue: 0.48)
        let mid = secondary ? Color(red: 0.62, green: 0.55, blue: 0.42) : CardStyle.gold
        let bottom = secondary ? Color(red: 0.42, green: 0.36, blue: 0.26) : Color(red: 0.52, green: 0.39, blue: 0.17)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [top, mid, bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .black.opacity(0.35)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    )
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.25)).frame(height: 3).padding(.horizontal, 18).padding(.top, 5)
                    }
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.25 : 0.55),
                            radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 4)
            )
            .saturation(enabled ? 1 : 0.15)
            .opacity(enabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
