import SwiftUI

// MARK: - Phone-side moments

struct OldMaidMoment: Identifiable, Equatable {
    enum Tone { case info, good, soft }
    let id = UUID()
    var text: String
    var subtitle: String?
    var cards: [Card] = []
    var tone: Tone = .info
}

@MainActor
@Observable
final class OldMaidHandStage {
    var moment: OldMaidMoment?
    /// Card ids that just arrived in my hand (gold glow for a few seconds).
    var glowIDs: Set<String> = []
    @ObservationIgnored let queue = KidsBeatQueue()
    @ObservationIgnored private var lastSeq = 0

    init() {
        queue.onIdle = { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.moment = nil }
        }
    }

    func ingest(_ batch: KidsEventBatch<OldMaidEvent>, me: Int, name: @escaping (Int) -> String) {
        guard batch.seq > lastSeq else { return }
        lastSeq = batch.seq
        queue.enqueue { [weak self] in
            guard let self else { return }
            for event in batch.events { await self.beat(event, me: me, name: name) }
        }
    }

    func markArrived(_ ids: Set<String>) {
        glowIDs.formUnion(ids)
        Task { @MainActor [weak self] in
            await kidsWait(3.0)
            self?.glowIDs.subtract(ids)
        }
    }

    private func show(_ new: OldMaidMoment) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { moment = new }
    }

    private func beat(_ event: OldMaidEvent, me: Int, name: (Int) -> String) async {
        switch event {
        case .dealt:
            show(OldMaidMoment(text: "Cards are out!"))
            await kidsWait(0.9)

        case .pairsDiscarded(let seat, let pairs, let onDeal):
            if seat == me {
                let cards = pairs.flatMap { $0 }
                if onDeal {
                    show(OldMaidMoment(text: pairs.count == 1 ? "You start with a pair" : "You start with \(pairs.count) pairs",
                                       subtitle: "Matching cards are laid down for you", cards: cards, tone: .good))
                } else {
                    let rank = pairs.first?.first?.rank ?? 0
                    show(OldMaidMoment(text: "A pair of \(GoFishText.plural(rank))!", cards: cards, tone: .good))
                    Haptics.play()
                }
                await kidsWait(onDeal ? 1.8 : 1.7)
            } else if !onDeal {
                show(OldMaidMoment(text: "\(name(seat)) made a pair"))
                await kidsWait(1.0)
            }

        case .drew(let seat, let from, _):
            if from == me {
                show(OldMaidMoment(text: "\(name(seat)) took a card from your hand"))
                Haptics.tick()
            } else if seat == me {
                show(OldMaidMoment(text: "You took a card from \(name(from))"))
            } else {
                show(OldMaidMoment(text: "\(name(seat)) picks from \(name(from))"))
            }
            await kidsWait(1.3)

        case .handShuffled(let seat):
            if seat == me {
                show(OldMaidMoment(text: "Shuffled", tone: .soft))
                await kidsWait(0.8)
            } else {
                show(OldMaidMoment(text: "\(name(seat)) shuffles their cards", tone: .soft))
                await kidsWait(0.9)
            }

        case .playerOut(let seat):
            if seat == me {
                show(OldMaidMoment(text: "You're out of cards - you're safe!", tone: .good))
                Haptics.play()
            } else {
                show(OldMaidMoment(text: "\(name(seat)) is safe!", tone: .good))
            }
            await kidsWait(1.5)

        case .turnChanged:
            withAnimation(.easeOut(duration: 0.2)) { moment = nil }

        case .gameOver, .illegalAttempt:
            break
        }
    }
}

// MARK: - Hand view

/// The phone during Old Maid. On your turn the neighbor's hand hangs in
/// front of you as a fan of card backs: drag across it to look, tap one to
/// lift it, tap again (or press the button) to take it. Your own hand is
/// fanned at the bottom, in the true order the next player picks from, with
/// a button to shuffle it.
struct OldMaidHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        let wire = client.sideGameState.flatMap { payload in
            payload.kind == OldMaidEngine.kind ? payload.decode(OldMaidWireState.self) : nil
        }
        let batch = client.sideGameEvents.flatMap { payload in
            payload.kind == OldMaidEngine.kind ? payload.decode(KidsEventBatch<OldMaidEvent>.self) : nil
        }
        OldMaidHandContent(wire: wire, batch: batch) { action in
            client.sendSideGameAction(kind: OldMaidEngine.kind, action)
        }
    }
}

struct OldMaidHandContent: View {
    let wire: OldMaidWireState?
    let batch: KidsEventBatch<OldMaidEvent>?
    let send: (OldMaidAction) -> Void

    @State private var stage = OldMaidHandStage()
    @State private var pickIndex: Int?
    @State private var browseIndex: Int?
    @State private var touching = false
    @State private var startedOn: Int?
    @State private var justDrew = false
    @State private var knownIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    private var snap: OldMaidSnapshot? { wire?.snapshot }
    private var me: Int { snap?.seat ?? 0 }
    private func name(_ seat: Int) -> String { wire?.names[seat] ?? "Player \(seat + 1)" }

    private var playing: Bool { snap?.phase == .playing }
    private var isMyTurn: Bool { playing && snap?.turnSeat == me }
    private var pickTarget: Int? { isMyTurn && !justDrew ? snap?.drawTarget : nil }
    private var iAmOut: Bool { (snap?.outSeats.contains(me) ?? false) }
    private var beingPickedFrom: Bool {
        guard playing, let snap, snap.turnSeat != me else { return false }
        return snap.drawTarget == me
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                VStack(spacing: 0) {
                    header
                    players
                    Spacer(minLength: 4)
                    middle(in: geo.size)
                    Spacer(minLength: 4)
                    shuffleRow
                    myFan(in: geo.size)
                        .frame(height: geo.size.height * 0.28)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            knownIDs = Set(snap?.hand.map(\.id) ?? [])
            if let batch { stage.ingest(batch, me: me, name: name) }
        }
        .onChange(of: batch) { _, new in
            if let new { stage.ingest(new, me: me, name: name) }
        }
        .onChange(of: snap?.hand.map(\.id) ?? []) { _, ids in
            let now = Set(ids)
            let arrived = now.subtracting(knownIDs)
            knownIDs = now
            if !arrived.isEmpty { stage.markArrived(arrived) }
        }
        .onChange(of: snap?.turnSeat) { _, _ in
            pickIndex = nil
            browseIndex = nil
            justDrew = false
        }
        .onChange(of: snap?.drawTarget) { _, _ in
            pickIndex = nil
            browseIndex = nil
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            Text("Old Maid")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Spacer()
            if let snap {
                let pairs = snap.laidPairs[me]?.count ?? 0
                Text("\(pairs) pair\(pairs == 1 ? "" : "s") laid")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var players: some View {
        let seats = (0..<(snap?.playerCount ?? 0)).filter { $0 != me }
        return HStack(spacing: 8) {
            ForEach(seats, id: \.self) { seat in
                let safe = snap?.outSeats.contains(seat) ?? false
                let turn = playing && snap?.turnSeat == seat
                let target = playing && snap?.drawTarget == seat && snap?.turnSeat == me
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(PlayerPalette.color(seat)).frame(width: 10, height: 10)
                        Text(name(seat))
                            .font(.system(.footnote, design: .serif).weight(.bold))
                            .foregroundStyle(CardStyle.stockTop)
                            .lineLimit(1)
                    }
                    Text(safe ? "Safe!" : "\(snap?.handCounts[seat] ?? 0) cards")
                        .font(.system(.caption2, design: .serif).weight(.semibold))
                        .foregroundStyle(safe ? Color(red: 0.62, green: 0.86, blue: 0.62) : CardStyle.gold.opacity(0.9))
                        .monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.32))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(target ? CardStyle.gold : (turn ? PlayerPalette.color(seat) : .white.opacity(0.1)),
                                          lineWidth: target || turn ? 2 : 1))
                )
                .opacity(safe ? 0.65 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: the middle of the screen

    @ViewBuilder
    private func middle(in size: CGSize) -> some View {
        VStack(spacing: 10) {
            // While choosing a card the fan needs the room; the last draw's
            // moment has long since played out.
            if pickTarget == nil, let moment = stage.moment {
                momentView(moment)
                    .id(moment.id)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            if let target = pickTarget {
                pickZone(target: target, in: size)
            } else {
                prompt
            }
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: stage.moment?.id)
    }

    private func momentView(_ moment: OldMaidMoment) -> some View {
        VStack(spacing: 6) {
            if !moment.cards.isEmpty {
                HStack(spacing: -18) {
                    ForEach(Array(moment.cards.prefix(4).enumerated()), id: \.element.id) { i, card in
                        CardView(card: card, faceUp: true, elevation: 0.2)
                            .frame(width: 46)
                            .rotationEffect(.degrees(Double(i) * 4 - Double(min(4, moment.cards.count) - 1) * 2))
                    }
                }
            }
            Text(moment.text)
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(moment.tone == .good ? CardStyle.gold : CardStyle.stockTop)
                .multilineTextAlignment(.center)
            if let subtitle = moment.subtitle {
                Text(subtitle)
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.38))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.28), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var prompt: some View {
        if let snap {
            if snap.phase == .gameOver {
                resultBanner(snap)
            } else if iAmOut {
                pill("You're safe! Cheer for the others.")
            } else if isMyTurn {
                pill("Taking your card…")
            } else if beingPickedFrom {
                VStack(spacing: 4) {
                    pill("\(name(snap.turnSeat)) is picking from YOUR hand")
                    Text("Want to mix it up? Shuffle below.")
                        .font(.system(.footnote, design: .serif).italic())
                        .foregroundStyle(.white.opacity(0.65))
                }
            } else if let target = snap.drawTarget {
                pill("\(name(snap.turnSeat)) is picking from \(name(target))")
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.3)))
    }

    private func resultBanner(_ snap: OldMaidSnapshot) -> some View {
        let iLost = snap.loser == me
        return VStack(spacing: 6) {
            if iLost {
                Text("You have the Old Maid")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                Text("That's just how the cards fell. Good game - shall we go again?")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else {
                Text("You're safe!")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                if let loser = snap.loser {
                    Text("\(name(loser)) ended up with the Old Maid. Good game!")
                        .font(.system(.subheadline, design: .serif).italic())
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    // MARK: picking from the neighbor

    private func pickCardWidth(count: Int, in size: CGSize) -> CGFloat {
        let cap = min(size.width * 0.20, 82)
        guard count > 1 else { return cap }
        return max(44, min(cap, size.width * 0.9 / (1 + 0.3 * CGFloat(count - 1))))
    }

    private func pickZone(target: Int, in size: CGSize) -> some View {
        let count = snap?.handCounts[target] ?? 0
        let width = pickCardWidth(count: count, in: size)
        let layout = HandFanLayout(cardCount: count, containerWidth: size.width, cardWidth: width)
        let lifted = browseIndex ?? pickIndex
        return VStack(spacing: 8) {
            Text("YOUR TURN")
                .font(.system(.footnote, design: .serif).weight(.heavy))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
            Text("Pick a card from \(name(target))'s hand")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.9))
            ZStack {
                // The neighbor's fan hangs toward us: same arc as our own
                // hand, turned upside down so the cards reach down at us.
                ForEach(0..<count, id: \.self) { index in
                    let slot = layout.slot(for: index)
                    let isLifted = lifted == index
                    CardView(card: KidsCards.back, faceUp: false, elevation: isLifted ? 0.7 : 0)
                        .frame(width: width)
                        .shadow(color: CardStyle.gold.opacity(isLifted ? 0.85 : 0), radius: isLifted ? 12 : 0)
                        .rotationEffect(.degrees(-slot.angle.degrees))
                        .offset(x: slot.offset.width, y: -slot.offset.height + (isLifted ? width * 0.55 : 0))
                        .zIndex(isLifted ? 100 : slot.zIndex)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isLifted)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: width * 1.4 + 70)
            .contentShape(Rectangle())
            .gesture(browseGesture(layout: layout, count: count, width: size.width))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name(target))'s hand, \(count) cards")
            .accessibilityHint("Swipe to browse. Double-tap to take the card in the middle.")
            .accessibilityAdjustableAction { direction in
                let current = pickIndex ?? count / 2
                switch direction {
                case .increment: pickIndex = min(count - 1, current + 1)
                case .decrement: pickIndex = max(0, current - 1)
                @unknown default: break
                }
            }

            if let pickIndex {
                Button { take(pickIndex) } label: {
                    Text("Take this card")
                        .font(.headline.weight(.bold))
                        .padding(.horizontal, 26).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("Slide across the cards, then tap one")
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pickIndex)
    }

    private func browseGesture(layout: HandFanLayout, count: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard count > 0 else { return }
                if !touching {
                    touching = true
                    startedOn = pickIndex
                }
                let index = layout.nearestIndex(toDisplayedX: value.location.x - width / 2, scrollOffset: 0)
                if browseIndex != index {
                    browseIndex = index
                    Haptics.tick()
                }
            }
            .onEnded { value in
                defer { touching = false; browseIndex = nil }
                guard count > 0 else { return }
                let index = layout.nearestIndex(toDisplayedX: value.location.x - width / 2, scrollOffset: 0)
                let barelyMoved = abs(value.translation.width) < 10 && abs(value.translation.height) < 10
                if barelyMoved, startedOn == index {
                    take(index) // a second tap on the lifted card takes it
                } else {
                    pickIndex = index
                    Haptics.arm()
                }
            }
    }

    private func take(_ index: Int) {
        guard isMyTurn, !justDrew else { return }
        Haptics.play()
        justDrew = true
        pickIndex = nil
        browseIndex = nil
        send(.draw(index: index))
        // If the host never answers (a dropped link), hand the turn back.
        Task { @MainActor in
            await kidsWait(6)
            if justDrew, isMyTurn { justDrew = false }
        }
    }

    // MARK: my own hand

    @ViewBuilder
    private var shuffleRow: some View {
        if playing, (snap?.hand.count ?? 0) > 1 {
            HStack {
                Spacer()
                Button {
                    Haptics.arm()
                    send(.shuffleMyHand)
                } label: {
                    Label("Shuffle my hand", systemImage: "shuffle")
                        .font(.system(.footnote, design: .serif).weight(.semibold))
                        .foregroundStyle(CardStyle.stockTop)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            Capsule().fill(.black.opacity(beingPickedFrom ? 0.5 : 0.32))
                                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(beingPickedFrom ? 0.9 : 0.3),
                                                                lineWidth: beingPickedFrom ? 2 : 1))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Mixes up the order of your cards")
            }
            .padding(.horizontal, 16)
        }
    }

    private func handCardWidth(for count: Int, in size: CGSize) -> CGFloat {
        let cap = min(size.width * 0.22, 92)
        guard count > 1 else { return cap }
        return max(48, min(cap, size.width * 0.9 / (1 + 0.3 * CGFloat(count - 1))))
    }

    private func myFan(in size: CGSize) -> some View {
        // True order, NOT sorted: this is the order the next player picks from.
        let hand = snap?.hand ?? []
        let width = handCardWidth(for: hand.count, in: size)
        let layout = HandFanLayout(cardCount: hand.count, containerWidth: size.width, cardWidth: width)
        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.element.id) { index, card in
                let slot = layout.slot(for: index)
                let arrived = stage.glowIDs.contains(card.id)
                CardView(card: card, faceUp: true)
                    .frame(width: width)
                    .shadow(color: CardStyle.gold.opacity(arrived ? 0.9 : 0), radius: arrived ? 12 : 0)
                    .rotationEffect(slot.angle)
                    .offset(x: slot.offset.width, y: slot.offset.height)
                    .zIndex(slot.zIndex)
                    .transition(.asymmetric(
                        insertion: .offset(y: -size.height * 0.5).combined(with: .opacity),
                        removal: .offset(y: -size.height * 0.4).combined(with: .opacity)))
                    .accessibilityLabel(card.accessibleName)
            }
        }
        .frame(maxWidth: .infinity)
        .offset(y: 24)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: hand.map(\.id))
    }
}

// MARK: - Previews

private func oldMaidDemoCard(_ suit: Suit, _ rank: Int) -> Card {
    let prefix = ["c", "d", "h", "s"][Suit.allCases.firstIndex(of: suit) ?? 0]
    return Card(id: "\(prefix)\(rank)", kind: .standard(suit: suit, rank: rank))
}

private func oldMaidDemoWire(myTurn: Bool, over: Bool = false, loser: Int? = nil) -> OldMaidWireState {
    let hand = [oldMaidDemoCard(.clubs, 4), oldMaidDemoCard(.hearts, 9), oldMaidDemoCard(.spades, 12),
                oldMaidDemoCard(.diamonds, 9 + 1), oldMaidDemoCard(.clubs, 13), oldMaidDemoCard(.hearts, 14),
                oldMaidDemoCard(.spades, 6)]
    let snapshot = OldMaidSnapshot(
        seat: 0, playerCount: 3, hand: hand, handCounts: [0: hand.count, 1: 9, 2: 6],
        laidPairs: [0: [[oldMaidDemoCard(.clubs, 2), oldMaidDemoCard(.hearts, 2)]], 1: [], 2: []],
        turnSeat: myTurn ? 0 : 1, drawTarget: over ? nil : (myTurn ? 1 : 0), outSeats: [],
        phase: over ? .gameOver : .playing, loser: loser, lastDraw: nil, lastDrawnCardID: nil)
    return OldMaidWireState(snapshot: snapshot, names: [0: "Chase", 1: "Vinny", 2: "Mae"])
}

#Preview("Old Maid hand - my pick") {
    OldMaidHandContent(wire: oldMaidDemoWire(myTurn: true), batch: nil, send: { _ in })
}

#Preview("Old Maid hand - being picked from") {
    OldMaidHandContent(wire: oldMaidDemoWire(myTurn: false), batch: nil, send: { _ in })
}

#Preview("Old Maid hand - I have the Old Maid") {
    OldMaidHandContent(wire: oldMaidDemoWire(myTurn: false, over: true, loser: 0), batch: nil, send: { _ in })
}
