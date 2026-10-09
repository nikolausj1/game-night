import SwiftUI

/// The phone during Gin Rummy: the whole game lives here. Routed by
/// `SideGameRegistry` whenever the table runs kind `ginRummy`.
///
/// Thin wrapper: decodes the table's redacted state and forwards actions.
/// The real UI is `GinRummyHandContent` so previews and the phone-only
/// harness can drive it without a network.
struct GinRummyHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        GinRummyHandContent(state: client.sideGameState?.decode(GinRummyPhoneState.self)) { action in
            client.sendSideGameAction(kind: GinRummyEngine.kind, action)
        }
    }
}

// MARK: - Frames (arrival animations need to know where the piles are)

private struct GinFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func ginFrame(_ id: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: GinFrameKey.self, value: [id: geo.frame(in: .named("ginphone"))])
        })
    }
}

/// A drawn card's entrance: it starts at the pile it came from and settles
/// into its slot in the fan.
private struct GinArrive: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let tilt: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(tilt))
            .offset(offset)
            .opacity(opacity)
    }
}

// MARK: - Content

struct GinRummyHandContent: View {
    let state: GinRummyPhoneState?
    let send: (GinRummyAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Fan interaction
    @State private var selectedID: String?
    @State private var touchStartedSelected = false
    @State private var touchID: String?
    @State private var drag = CardDragState()
    @State private var departing: Set<String> = []
    @State private var knockArmed = false
    @State private var holdID: String?
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var holdFired = false
    // Draw zone
    @State private var upDrag: CGSize = .zero
    @State private var upcardBounce = false
    // Layoff
    @State private var layoffPick: String?
    // Bookkeeping
    @State private var memo = GinGroupMemo()
    @State private var frames: [String: CGRect] = [:]
    @State private var lastDrawnID: String?
    @State private var sentNote: String?

    private var snap: GinRummySnapshot? { state?.snapshot }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                if let snap, let state {
                    content(snap, state, geo.size)
                } else {
                    Text("Waiting for the table…")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .coordinateSpace(name: "ginphone")
            .onPreferenceChange(GinFrameKey.self) { frames = $0 }
        }
        .statusBarHidden()
        .onChange(of: snap?.phase) { _, _ in resetInteraction() }
        .onChange(of: snap?.turnSeat) { _, _ in resetInteraction() }
        .onChange(of: snap?.handNumber) { _, _ in
            resetInteraction()
            lastDrawnID = nil
        }
        .onChange(of: snap?.moves.count) { _, _ in upDrag = .zero }
        .onChange(of: snap?.myHand.map(\.id) ?? []) { old, new in
            // The card that just joined my hand gets a brass hairline until I act.
            if new.count == old.count + 1, let added = new.first(where: { !old.contains($0) }) {
                lastDrawnID = added
            }
        }
    }

    private func resetInteraction() {
        cancelHold()
        selectedID = nil
        drag = CardDragState()
        departing = []
        layoffPick = nil
        sentNote = nil
        if snap?.phase != .discard { knockArmed = false }
        // Gin is always worth going out on: arm the knock the moment it's available.
        if let snap, snap.phase == .discard, snap.isMyTurn, !snap.ginDiscards.isEmpty { knockArmed = true }
    }

    // MARK: layout

    @ViewBuilder
    private func content(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, _ size: CGSize) -> some View {
        let compact = size.height < 560
        VStack(spacing: 0) {
            header(snap, state, compact: compact)
            opponentStrip(snap, state)
            zone(snap, state, size, compact: compact)
            prompt(snap, state)
                .frame(minHeight: compact ? 54 : 84)
                .padding(.top, 4)
            Spacer(minLength: 0)
            controls(snap)
            fan(snap, state, size)
        }
    }

    // MARK: header + opponent

    private func header(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Gin Rummy")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Text("Hand \(snap.handNumber)")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text("\(snap.scores[snap.mySeat] ?? 0) – \(snap.scores[1 - snap.mySeat] ?? 0)")
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.gold)
                .monospacedDigit()
                .accessibilityLabel("Score, you \(snap.scores[snap.mySeat] ?? 0), \(state.name(1 - snap.mySeat)) \(snap.scores[1 - snap.mySeat] ?? 0)")
        }
        .padding(.horizontal, 18)
        .padding(.top, compact ? 4 : 12)
    }

    private func opponentStrip(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState) -> some View {
        let oppSeat = 1 - snap.mySeat
        let name = state.name(oppSeat)
        return HStack(spacing: 8) {
            Circle()
                .fill(PlayerPalette.color(GinSeat.colorIndex(name: name, seat: oppSeat)))
                .frame(width: 10, height: 10)
            Text(name)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            if snap.dealerSeat == oppSeat {
                Text("DEALER")
                    .font(.system(size: 8, weight: .heavy, design: .serif))
                    .tracking(1)
                    .foregroundStyle(CardStyle.ink)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(CardStyle.gold))
            }
            // Their unseen hand, as a little fan of backs.
            HStack(spacing: -7) {
                ForEach(0..<min(snap.opponentHandCount, 11), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(LinearGradient(colors: [CardStyle.feltGreen.opacity(0.9), .black.opacity(0.5)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(CardStyle.gold.opacity(0.7), lineWidth: 0.8))
                        .frame(width: 11, height: 16)
                }
            }
            .accessibilityLabel("\(snap.opponentHandCount) cards in \(name)'s hand")
            Spacer(minLength: 4)
            if !snap.opponentKnownCards.isEmpty {
                HStack(spacing: 4) {
                    Text("holds")
                        .font(.system(size: 10, design: .serif).italic())
                        .foregroundStyle(.white.opacity(0.5))
                    ForEach(snap.opponentKnownCards) { card in
                        Text(GinText.cardGlyph(card, onDark: false, weight: .heavy))
                            .font(.system(.caption, design: .serif))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CardStyle.stockTop))
                    }
                }
                .accessibilityLabel("\(name) is known to hold " + snap.opponentKnownCards.map(\.accessibleName).joined(separator: ", "))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.22)).padding(.horizontal, 10))
        .padding(.top, 6)
    }

    // MARK: the top zone

    @ViewBuilder
    private func zone(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, _ size: CGSize, compact: Bool) -> some View {
        let zw = min(size.width * 0.26, compact ? 66 : 108)
        Group {
            switch snap.phase {
            case .firstUpcard, .draw, .discard:
                drawZone(snap, state, zw: zw)
            case .layoff:
                layoffZone(snap, state, zw: zw, width: size.width)
            case .handComplete, .gameOver:
                resultPanel(snap, state)
            }
        }
        .frame(height: zw * 1.4 + (compact ? 24 : 40))
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 4 : 12)
    }

    private func drawZone(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, zw: CGFloat) -> some View {
        let drawing = snap.isMyTurn && (snap.phase == .draw || snap.phase == .firstUpcard)
        let canTakeUp = drawing && !(snap.phase == .draw && snap.upcardRefused)
        let zh = zw * 1.4
        return HStack(alignment: .top, spacing: zw * 0.42) {
            // Stock
            VStack(spacing: 6) {
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        CardView(card: Card(id: "ginstockp\(i)", kind: .standard(suit: .spades, rank: 2)), faceUp: false)
                            .frame(width: zw, height: zh)
                            .offset(x: CGFloat(i) * 1.5, y: -CGFloat(i) * 1.5)
                    }
                }
                .frame(width: zw + 4, height: zh + 4)
                .ginFrame("stock")
                .overlay { drawGlow(active: drawing && !(snap.phase == .firstUpcard), cw: zw) }
                .opacity(snap.phase == .discard ? 0.55 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard drawing, snap.phase == .draw else {
                        if drawing { nudgeUpcard() } // first upcard: the choice is the upcard's
                        return
                    }
                    Haptics.tick()
                    send(.drawStock)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Stock, \(snap.stockCount) cards")
                .accessibilityHint(drawing && snap.phase == .draw ? "Double-tap to draw from the stock" : "")
                .accessibilityAddTraits(.isButton)
                Text("Stock \(snap.stockCount)")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(snap.stockCount <= 6 ? Color(red: 1, green: 0.72, blue: 0.66) : .white.opacity(0.6))
            }
            // Upcard
            VStack(spacing: 6) {
                ZStack {
                    if let up = snap.upcard {
                        CardView(card: up, faceUp: true, elevation: upDrag == .zero ? 0 : 0.7)
                            .frame(width: zw, height: zh)
                            .offset(x: upDrag.width, y: upDrag.height + (upcardBounce ? -8 : 0))
                            .opacity(snap.phase == .discard ? 0.55 : (canTakeUp || !drawing ? 1 : 0.6))
                            .gesture(upcardGesture(zh: zh), including: canTakeUp ? .all : .none)
                            .accessibilityLabel("Upcard, \(up.accessibleName)")
                            .accessibilityHint(canTakeUp ? "Double-tap to take it" : "")
                            .accessibilityAddTraits(canTakeUp ? .isButton : [])
                            .accessibilityAction(named: "Take the upcard") { if canTakeUp { send(.drawUpcard) } }
                    } else {
                        RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: zw), style: .continuous)
                            .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(width: zw, height: zh)
                    }
                }
                .frame(width: zw + 4, height: zh + 4)
                .ginFrame("upcard")
                .overlay { drawGlow(active: canTakeUp, cw: zw) }
                Text(snap.phase == .draw && snap.upcardRefused ? "Passed" : "Discard")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// A slow brass breathing ring: "this is where you act".
    @ViewBuilder
    private func drawGlow(active: Bool, cw: CGFloat) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 0.7 : 0.5 + 0.5 * sin(t * 2.6)
                RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cw) + 2, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.35 + 0.45 * pulse), lineWidth: 2)
                    .shadow(color: CardStyle.gold.opacity(0.5 * pulse), radius: 6)
                    .padding(-2)
            }
            .allowsHitTesting(false)
        }
    }

    private func upcardGesture(zh: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                upDrag = CGSize(width: value.translation.width * 0.6, height: max(-20, value.translation.height))
            }
            .onEnded { value in
                if value.translation.height > zh * 0.55 || value.predictedEndTranslation.height > zh * 1.8 {
                    Haptics.play()
                    withAnimation(.easeIn(duration: 0.18)) { upDrag = CGSize(width: 0, height: zh * 2.2) }
                    send(.drawUpcard)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { upDrag = .zero }
                }
            }
    }

    private func nudgeUpcard() {
        Haptics.tick()
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { upcardBounce = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { upcardBounce = false }
        }
    }

    // MARK: layoff zone

    private func layoffZone(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, zw: CGFloat, width: CGFloat) -> some View {
        guard let knock = snap.knock else { return AnyView(EmptyView()) }
        let knocker = knock.knockerSeat
        let units = knock.melds.reduce(CGFloat(0)) { $0 + 1 + 0.42 * CGFloat($1.cards.count - 1) }
            + 0.34 * CGFloat(max(0, knock.melds.count - 1))
        let cw = max(26, min(zw * 0.62, (width - 36) / max(units, 1)))
        let pick = layoffPick.flatMap { id in snap.myHand.first { $0.id == id } }
        let laid = Set(snap.layoffs.map(\.card.id))
        return AnyView(
            VStack(spacing: 8) {
                Text("\(state.name(knocker))'s melds")
                    .font(.system(.caption, design: .serif).weight(.bold))
                    .tracking(2)
                    .foregroundStyle(CardStyle.gold)
                HStack(alignment: .bottom, spacing: cw * 0.34) {
                    ForEach(Array(knock.melds.enumerated()), id: \.offset) { index, meld in
                        let target = pick.map { GinMelds.canLayOff($0, onto: meld) } ?? false
                        Button {
                            guard let pick, target else { return }
                            layOff(pick, onto: index)
                        } label: {
                            HStack(spacing: -cw * 0.58) {
                                ForEach(Array(meld.cards.enumerated()), id: \.element.id) { i, card in
                                    CardView(card: card, faceUp: true)
                                        .frame(width: cw, height: cw * 1.4)
                                        .overlay {
                                            if laid.contains(card.id) {
                                                RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cw), style: .continuous)
                                                    .strokeBorder(CardStyle.gold, lineWidth: 1.5)
                                            }
                                        }
                                        .zIndex(Double(i))
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Capsule().fill(CardStyle.gold).frame(height: 2).padding(.horizontal, 3).offset(y: 6)
                            }
                            .padding(.bottom, 8)
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(target ? CardStyle.gold.opacity(0.28) : .clear)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(target ? CardStyle.gold : .clear, lineWidth: 1.5))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!target)
                        .accessibilityLabel("Meld: " + meld.cards.map(\.accessibleName).joined(separator: ", "))
                        .accessibilityHint(target ? "Double-tap to lay off the selected card here" : "")
                    }
                }
                if !knock.deadwood.isEmpty {
                    HStack(spacing: 6) {
                        Text("deadwood \(knock.deadwoodPoints)")
                            .font(.system(size: 11, design: .serif).italic())
                            .foregroundStyle(.white.opacity(0.55))
                        ForEach(knock.deadwood) { card in
                            Text(GinText.cardGlyph(card, onDark: false, weight: .heavy))
                                .font(.system(.caption, design: .serif))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CardStyle.stockTop))
                        }
                    }
                }
            }
        )
    }

    // MARK: result panel (showdown / game over)

    private func resultPanel(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState) -> some View {
        let me = snap.mySeat
        let opp = 1 - me
        let oppName = state.name(opp)
        var headline = ""
        var detail = ""
        var good = false
        if let r = snap.lastResult {
            let iWon = r.winnerSeat == me
            good = iWon
            let myDW = r.knockerSeat == me ? r.knockerDeadwoodPoints : r.defenderDeadwoodPoints
            let oppDW = r.knockerSeat == me ? r.defenderDeadwoodPoints : r.knockerDeadwoodPoints
            switch r.outcome {
            case .drawn:
                headline = "Drawn hand"
                detail = "The stock ran out. No score."
            case .gin:
                headline = iWon ? "GIN!  +\(r.points)" : "\(oppName) went gin"
                detail = iWon ? "25 bonus + \(oppDW) deadwood" : "You were caught with \(myDW) deadwood. \(oppName) +\(r.points)"
            case .knock:
                headline = iWon ? "You win the hand  +\(r.points)" : "\(oppName) wins the hand  +\(r.points)"
                detail = "Deadwood: you \(myDW), \(oppName) \(oppDW)"
            case .undercut:
                headline = iWon ? "UNDERCUT!  +\(r.points)" : "Undercut by \(oppName)  +\(r.points)"
                detail = "Deadwood: you \(myDW), \(oppName) \(oppDW). 25 bonus to the defender."
            }
        }
        return VStack(spacing: 8) {
            Text(headline)
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(good ? CardStyle.gold : .white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            if snap.phase == .gameOver, let game = snap.gameResult {
                let won = game.winnerSeat == me
                Text(won ? "You win the game!" : "\(oppName) wins the game")
                    .font(.system(.headline, design: .serif).weight(.heavy))
                    .foregroundStyle(won ? CardStyle.gold : .white)
                    .padding(.top, 2)
                Text("Final \(game.finalTotals[me] ?? 0) – \(game.finalTotals[opp] ?? 0)"
                     + (game.shutout ? "  (shutout)" : "")
                     + "  incl. \(game.boxBonus[me] ?? 0) box")
                    .font(.system(.footnote, design: .serif).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder((good ? CardStyle.gold : .white).opacity(0.3), lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: prompt

    @ViewBuilder
    private func prompt(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState) -> some View {
        let oppName = state.name(1 - snap.mySeat)
        VStack(spacing: 6) {
            switch snap.phase {
            case .firstUpcard:
                if snap.isMyTurn { firstUpcardOffer(snap, oppName) } else { waiting(snap, state) }
            case .draw:
                if snap.isMyTurn {
                    yourTurn("DRAW", snap.upcardRefused
                             ? "Both passed the upcard. Tap the stock."
                             : "Tap the stock, or drag the upcard into your hand")
                } else { waiting(snap, state) }
            case .discard:
                if snap.isMyTurn { discardPrompt(snap) } else { waiting(snap, state) }
            case .layoff:
                if snap.isMyTurn { layoffPrompt(snap, oppName) } else { waiting(snap, state) }
            case .handComplete:
                note("Next hand dealing…")
            case .gameOver:
                note("Game over. Rematch is on the table.")
            }
            if let line = lastMoveLine(snap, state), snap.phase != .handComplete, snap.phase != .gameOver {
                Text(line)
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: snap.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedID)
    }

    private func lastMoveLine(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState) -> AttributedString? {
        guard let move = snap.moves.last else { return nil }
        let name = move.seat == snap.mySeat ? "You" : state.name(move.seat)
        var a = GinText.ledgerLine(move, name: name, onDark: true)
        a.font = .system(.footnote, design: .serif).italic()
        return a
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(.black.opacity(0.3)))
    }

    private func waiting(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState) -> some View {
        note("Waiting for \(state.name(1 - snap.mySeat))…")
    }

    private func yourTurn(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 3) {
            Text("YOUR TURN · \(title)")
                .font(.system(.subheadline, design: .serif).weight(.heavy))
                .tracking(2.5)
                .foregroundStyle(CardStyle.gold)
            Text(hint)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(
            Capsule().fill(.black.opacity(0.3))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1.5))
        )
    }

    private func firstUpcardOffer(_ snap: GinRummySnapshot, _ oppName: String) -> some View {
        VStack(spacing: 8) {
            yourTurn("FIRST UPCARD", snap.upcard.map { "Take the \($0.ginShort)?" } ?? "Take the upcard?")
            HStack(spacing: 12) {
                Button {
                    Haptics.play()
                    send(.drawUpcard)
                } label: {
                    Text("Take it").font(.headline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(CardStyle.gold).foregroundStyle(CardStyle.ink)
                Button {
                    Haptics.tick()
                    send(.passUpcard)
                } label: {
                    Text("Pass").font(.headline.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(CardStyle.stockTop)
            }
        }
    }

    @ViewBuilder
    private func discardPrompt(_ snap: GinRummySnapshot) -> some View {
        if let id = selectedID, let card = snap.myHand.first(where: { $0.id == id }) {
            selectionPanel(snap, card)
        } else if !snap.ginDiscards.isEmpty {
            VStack(spacing: 3) {
                Text("GIN!")
                    .font(.system(.title3, design: .serif).weight(.heavy))
                    .tracking(4)
                    .foregroundStyle(CardStyle.gold)
                Text("Flick a glowing card to go out. Opponent can't lay off.")
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.35)).overlay(Capsule().strokeBorder(CardStyle.gold, lineWidth: 2)))
        } else if !snap.knockDiscards.isEmpty {
            yourTurn("DISCARD", knockArmed
                     ? "Knock mode on: flick a glowing card to knock"
                     : "Flick up to discard. Hand badge = you could knock.")
        } else {
            yourTurn("DISCARD", "Flick a card up to discard it")
        }
    }

    private func selectionPanel(_ snap: GinRummySnapshot, _ card: Card) -> some View {
        let isKnock = snap.knockDiscards.contains(card.id)
        let isGin = snap.ginDiscards.contains(card.id)
        let blocked = card.id == snap.drawnFromDiscardID
        let after = GinMelds.minDeadwood(snap.myHand.filter { $0 != card })
        return VStack(spacing: 7) {
            Text(blocked ? "You just took the \(card.ginShort). Discard something else."
                 : "\(card.ginShort)  ·  deadwood \(after) after")
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 10) {
                if !blocked {
                    Button {
                        discardSelected(knock: false, snap: snap)
                    } label: {
                        Text("Discard").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).tint(CardStyle.stockTop).foregroundStyle(CardStyle.ink)
                }
                if isKnock && !blocked {
                    Button {
                        discardSelected(knock: true, snap: snap)
                    } label: {
                        Text(isGin ? "Go Gin" : "Knock").font(.subheadline.weight(.heavy)).padding(.horizontal, 18).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).tint(CardStyle.gold).foregroundStyle(CardStyle.ink)
                }
                Button {
                    selectedID = nil
                    drag = CardDragState()
                } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).padding(8)
                }
                .buttonStyle(.bordered).tint(.white.opacity(0.7))
                .accessibilityLabel("Cancel")
            }
            if isKnock && !blocked {
                Text("or hold the card to knock")
                    .font(.system(size: 10, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func layoffPrompt(_ snap: GinRummySnapshot, _ oppName: String) -> some View {
        VStack(spacing: 8) {
            yourTurn("LAY OFF", layoffPick != nil
                     ? "Now tap the meld to add it to"
                     : "Tap a glowing card to add it to \(oppName)'s melds")
            HStack(spacing: 12) {
                Button {
                    Haptics.play()
                    send(.autoLayoff)
                } label: {
                    Text("Lay off best").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).tint(CardStyle.gold).foregroundStyle(CardStyle.ink)
                Button {
                    Haptics.tick()
                    send(.finishLayoff)
                } label: {
                    Text("Done").font(.subheadline.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 7)
                }
                .buttonStyle(.bordered).tint(CardStyle.stockTop)
            }
        }
    }

    // MARK: controls row

    private func controls(_ snap: GinRummySnapshot) -> some View {
        let (_, dwNow) = memo.groups(for: snap.myHand)
        let isDiscard = snap.phase == .discard && snap.isMyTurn
        let dw = isDiscard
            ? GinArrange.bestAfterDiscard(hand: snap.myHand, excluding: snap.drawnFromDiscardID)
            : dwNow
        let canKnock = isDiscard && !snap.knockDiscards.isEmpty
        let gin = isDiscard && !snap.ginDiscards.isEmpty
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.caption)
                Text(isDiscard ? "Deadwood \(dw) after discard" : "Deadwood \(dw)")
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(dw <= GinRummyRules.knockMax ? CardStyle.gold : .white.opacity(0.75))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.3)))
            .accessibilityElement(children: .combine)
            Spacer()
            if canKnock {
                Button {
                    Haptics.arm()
                    knockArmed.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(knockArmed ? CardStyle.gold : .clear)
                            .overlay(Circle().strokeBorder(CardStyle.gold, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                        Text(gin ? "GIN" : "KNOCK")
                            .font(.system(.footnote, design: .serif).weight(.heavy))
                            .tracking(2)
                    }
                    .foregroundStyle(knockArmed ? CardStyle.ink : CardStyle.gold)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        Capsule().fill(knockArmed ? AnyShapeStyle(CardStyle.gold) : AnyShapeStyle(.black.opacity(0.3)))
                            .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.8), lineWidth: 1.5))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(gin ? "Gin mode" : "Knock mode")
                .accessibilityValue(knockArmed ? "On" : "Off")
                .accessibilityHint("When on, flicking a glowing card knocks instead of discarding")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    // MARK: the fan

    private func fan(_ snap: GinRummySnapshot, _ state: GinRummyPhoneState, _ size: CGSize) -> some View {
        let (groups, _) = memo.groups(for: snap.myHand)
        let flat = groups.flatMap(\.cards)
        let specs = groups.map { GinFanLayout.GroupSpec(count: $0.cards.count, isMeld: $0.isMeld) }
        let compact = size.height < 560
        let nominal = min(size.width * 0.22, compact ? 62 : 96)
        let layout = GinFanLayout(groups: specs, containerWidth: size.width, nominalCardWidth: nominal)
        let cw = layout.cardWidth
        let ch = cw * 1.4
        let height = cw * 0.55 + ch + 28
        let baseY = cw * 0.275 - 14
        let gin = snap.phase == .discard && snap.isMyTurn && !snap.ginDiscards.isEmpty
        let arrival = arrivalSource(snap)
        return ZStack {
            ForEach(Array(flat.enumerated()), id: \.element.id) { index, card in
                if index < layout.slots.count {
                    fanCard(card, slot: layout.slots[index], cw: cw, baseY: baseY, snap: snap, size: size,
                            arrival: arrival, fanHeight: height)
                }
            }
            // Thin gold rules under the melds.
            ForEach(Array(layout.underlines.enumerated()), id: \.offset) { _, line in
                Capsule()
                    .fill(CardStyle.gold.opacity(gin ? 1 : 0.85))
                    .frame(width: line.width, height: gin ? 3 : 2)
                    .shadow(color: CardStyle.gold.opacity(gin ? 0.9 : 0.35), radius: gin ? 7 : 2)
                    .rotationEffect(.degrees(line.angle))
                    .offset(x: line.centerX, y: line.y + baseY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: flat.map(\.id))
        .ginFrame("fan")
        .padding(.bottom, 2)
    }

    private enum ArrivalSource { case stock, upcard, none }

    /// Where a card that has just joined the hand came from (my latest public move).
    private func arrivalSource(_ snap: GinRummySnapshot) -> ArrivalSource {
        if snap.moves.isEmpty { return .stock }
        guard let move = snap.moves.last, move.seat == snap.mySeat else { return .none }
        switch move.kind {
        case .tookUpcard: return .upcard
        case .drewStock: return .stock
        default: return .none
        }
    }

    @ViewBuilder
    private func fanCard(_ card: Card, slot: GinFanLayout.Slot, cw: CGFloat, baseY: CGFloat,
                         snap: GinRummySnapshot, size: CGSize, arrival: ArrivalSource, fanHeight: CGFloat) -> some View {
        let isSelected = selectedID == card.id
        let leaving = departing.contains(card.id)
        let myDiscard = snap.isMyTurn && snap.phase == .discard
        let isKnock = myDiscard && snap.knockDiscards.contains(card.id)
        let isGin = myDiscard && snap.ginDiscards.contains(card.id)
        let blocked = myDiscard && card.id == snap.drawnFromDiscardID
        let layoffTargets = layoffTargets(for: card, snap: snap)
        let inLayoff = snap.phase == .layoff && snap.isMyTurn
        let glowing = (knockArmed && isKnock) || isGin || (inLayoff && !layoffTargets.isEmpty)
        let dim = blocked || (inLayoff && layoffTargets.isEmpty) || (knockArmed && myDiscard && !isKnock && !snap.knockDiscards.isEmpty && !isSelected)
        let lift = isSelected ? -cw * 0.5 : (glowing ? -cw * 0.07 : 0)
        let tx = isSelected ? drag.translation : .zero
        let isLaidPick = layoffPick == card.id
        let isNew = lastDrawnID == card.id && snap.phase == .discard
        let from = arrivalOffset(for: arrival, slot: slot, baseY: baseY, cw: cw)

        CardView(card: card, faceUp: true, elevation: isSelected ? drag.elevation(handHeight: size.height * 0.8) + 0.3 : 0)
            .frame(width: cw, height: cw * 1.4)
            .overlay { cardHighlight(cw: cw, glowing: glowing, gin: isGin, isNew: isNew, picked: isLaidPick) }
            .overlay(alignment: .topLeading) {
                if isKnock && !leaving {
                    knockBadge(gin: isGin, cw: cw, armed: knockArmed, labelled: isSelected || knockArmed)
                        .offset(x: cw * 0.06, y: -cw * 0.16)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if holdID == card.id {
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(CardStyle.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: cw * 0.8, height: cw * 0.8)
                        .shadow(color: CardStyle.gold.opacity(0.8), radius: 4)
                        .offset(y: -cw * 0.45)
                        .allowsHitTesting(false)
                }
            }
            .saturation(dim ? 0.55 : 1)
            .opacity(leaving ? 0 : (dim ? 0.62 : 1))
            .rotationEffect(.degrees(isSelected ? slot.angle * 0.35 : slot.angle))
            .offset(x: slot.x + tx.width, y: slot.y + baseY + lift + tx.height)
            .zIndex(isSelected ? 200 : Double(slot.group * 20 + slot.indexInGroup))
            .gesture(cardGesture(card, snap: snap, size: size))
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isSelected)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: glowing)
            .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .modifier(active: GinArrive(offset: from, scale: 0.78, tilt: -10, opacity: 0.0),
                                                            identity: GinArrive(offset: .zero, scale: 1, tilt: 0, opacity: 1)),
                                      removal: .opacity))
            .accessibilityLabel(card.accessibleName + (isKnock ? (isGin ? ", gin available" : ", knock available") : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(accessibilityHint(myDiscard: myDiscard, blocked: blocked, inLayoff: inLayoff, targets: layoffTargets))
    }

    private func accessibilityHint(myDiscard: Bool, blocked: Bool, inLayoff: Bool, targets: [Int]) -> String {
        if blocked { return "Just taken from the pile, can't be discarded this turn" }
        if myDiscard { return "Tap to select, then Discard or Knock. Or flick up." }
        if inLayoff { return targets.isEmpty ? "" : "Double-tap to lay off" }
        return ""
    }

    private func arrivalOffset(for source: ArrivalSource, slot: GinFanLayout.Slot, baseY: CGFloat, cw: CGFloat) -> CGSize {
        guard let fan = frames["fan"] else { return CGSize(width: 0, height: -300) }
        let key = source == .upcard ? "upcard" : "stock"
        guard source != .none, let src = frames[key] else { return CGSize(width: 0, height: -cw * 2) }
        return CGSize(width: src.midX - fan.midX - slot.x, height: src.midY - fan.midY - slot.y - baseY)
    }

    @ViewBuilder
    private func cardHighlight(cw: CGFloat, glowing: Bool, gin: Bool, isNew: Bool, picked: Bool) -> some View {
        let r = CardStyle.cornerRadius(width: cw)
        if picked {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(.white, lineWidth: 2.5)
                .shadow(color: CardStyle.gold, radius: 8)
        } else if glowing {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(CardStyle.gold, lineWidth: gin ? 3 : 2)
                .shadow(color: CardStyle.gold.opacity(0.9), radius: gin ? 9 : 5)
        } else if isNew {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.7), lineWidth: 1)
        }
    }

    /// The subtle "you could knock with this" tag: a brass hand badge on the
    /// card's visible strip; once the card is lifted or knock mode is on, it
    /// grows into the word itself.
    @ViewBuilder
    private func knockBadge(gin: Bool, cw: CGFloat, armed: Bool, labelled: Bool) -> some View {
        let d = max(15, cw * 0.27)
        if labelled {
            Text(gin ? "GIN" : "KNOCK")
                .font(.system(size: max(8, cw * 0.14), weight: .heavy, design: .serif))
                .tracking(0.8)
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    Capsule().fill(CardStyle.gold)
                        .overlay(Capsule().strokeBorder(.black.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                )
                .fixedSize()
        } else {
            Image(systemName: gin ? "star.fill" : "hand.raised.fill")
                .font(.system(size: d * 0.52, weight: .bold))
                .foregroundStyle(CardStyle.ink)
                .frame(width: d, height: d)
                .background(
                    Circle().fill(CardStyle.gold.opacity(gin ? 1 : 0.82))
                        .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                )
        }
    }

    // MARK: card gestures

    private func layoffTargets(for card: Card, snap: GinRummySnapshot) -> [Int] {
        guard snap.phase == .layoff, snap.isMyTurn, let knock = snap.knock else { return [] }
        return knock.melds.indices.filter { GinMelds.canLayOff(card, onto: knock.melds[$0]) }
    }

    private func cardGesture(_ card: Card, snap: GinRummySnapshot, size: CGSize) -> some Gesture {
        let handHeight = size.height * 0.8
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !holdFired else { return }
                switch snap.phase {
                case .discard:
                    guard snap.isMyTurn, !departing.contains(card.id) else { return }
                    if touchID != card.id {
                        touchID = card.id
                        touchStartedSelected = selectedID == card.id
                        if selectedID != card.id {
                            selectedID = card.id
                            drag = CardDragState()
                            Haptics.tick()
                        }
                        beginHold(card, snap: snap)
                    }
                    if card.id == snap.drawnFromDiscardID { return } // selectable (to read), not throwable
                    let wasArmed = drag.playProgress(handHeight: handHeight) >= 1
                    drag.isDragging = true
                    drag.translation = value.translation
                    if hypot(value.translation.width, value.translation.height) > 14 { cancelHold() }
                    let isArmed = drag.playProgress(handHeight: handHeight) >= 1
                    if isArmed != wasArmed { Haptics.arm() }
                default:
                    break
                }
            }
            .onEnded { value in
                let travel = hypot(value.translation.width, value.translation.height)
                touchID = nil
                if holdFired {
                    holdFired = false
                    return
                }
                switch snap.phase {
                case .discard:
                    guard snap.isMyTurn, selectedID == card.id else { return }
                    cancelHold()
                    let progress = drag.playProgress(handHeight: handHeight)
                    let flicked = value.predictedEndTranslation.height < -handHeight * 0.4 && value.translation.height < -20
                    if card.id != snap.drawnFromDiscardID, progress >= 1 || flicked {
                        let knock = knockArmed && snap.knockDiscards.contains(card.id)
                        throwCard(card, knock: knock, size: size)
                    } else if travel < 10 {
                        // A tap: it stays lifted (with its Discard / Knock buttons) until tapped again.
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            drag = CardDragState()
                            if touchStartedSelected { selectedID = nil }
                        }
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                            drag = CardDragState()
                            selectedID = nil
                        }
                    }
                case .layoff:
                    guard snap.isMyTurn, travel < 12 else { return }
                    layoffTap(card, snap: snap)
                default:
                    break
                }
            }
    }

    // MARK: acting

    private func throwCard(_ card: Card, knock: Bool, size: CGSize) {
        cancelHold()
        Haptics.play()
        departing.insert(card.id)
        withAnimation(.easeIn(duration: 0.24)) {
            drag.translation.height = -size.height * 0.75
        }
        send(knock ? .knock(discard: card.id, melds: nil) : .discard(cardID: card.id))
        // If the table never accepted it, bring the card home.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if departing.contains(card.id) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    departing.remove(card.id)
                    drag = CardDragState()
                    selectedID = nil
                }
            }
        }
    }

    private func discardSelected(knock: Bool, snap: GinRummySnapshot) {
        guard let id = selectedID, let card = snap.myHand.first(where: { $0.id == id }) else { return }
        throwCard(card, knock: knock, size: CGSize(width: 390, height: 844))
    }

    private func layoffTap(_ card: Card, snap: GinRummySnapshot) {
        let targets = layoffTargets(for: card, snap: snap)
        switch targets.count {
        case 0:
            Haptics.tick()
        case 1:
            layOff(card, onto: targets[0])
        default:
            Haptics.tick()
            layoffPick = layoffPick == card.id ? nil : card.id
        }
    }

    private func layOff(_ card: Card, onto meldIndex: Int) {
        Haptics.play()
        layoffPick = nil
        send(.layOff(cardID: card.id, meldIndex: meldIndex))
    }

    // MARK: hold-to-knock

    private func beginHold(_ card: Card, snap: GinRummySnapshot) {
        guard snap.knockDiscards.contains(card.id), card.id != snap.drawnFromDiscardID else { return }
        holdID = card.id
        holdProgress = 0
        holdFired = false
        withAnimation(.linear(duration: 0.8)) { holdProgress = 1 }
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, holdID == card.id else { return }
            holdFired = true
            holdID = nil
            holdProgress = 0
            throwCard(card, knock: true, size: CGSize(width: 390, height: 844))
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        if holdID != nil {
            holdID = nil
            withAnimation(.easeOut(duration: 0.12)) { holdProgress = 0 }
        }
    }
}
