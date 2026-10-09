import SwiftUI

// MARK: - Phone-side moments

/// A beat the phone dwells on: "Vinny gives you two sevens" with the cards
/// themselves shown, "Go fish!", "You fished your wish!", a laid book.
struct GoFishMoment: Identifiable, Equatable {
    enum Tone { case info, good, fish, book }
    let id = UUID()
    var text: String
    var subtitle: String?
    var cards: [Card] = []
    var tone: Tone = .info
}

@MainActor
@Observable
final class GoFishHandStage {
    var moment: GoFishMoment?
    var goAgain = false
    /// Card ids that just arrived in my hand (wear a gold glow for a bit).
    var glowIDs: Set<String> = []
    @ObservationIgnored let queue = KidsBeatQueue()
    @ObservationIgnored private var lastSeq = 0
    /// Set the instant a "fished, no match" event ARRIVES; consumed when the
    /// new card shows up in my snapshot.
    @ObservationIgnored var awaitingDraw = false

    init() {
        queue.onIdle = { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.moment = nil }
        }
    }

    func ingest(_ batch: KidsEventBatch<GoFishEvent>, me: Int, name: @escaping (Int) -> String) {
        guard batch.seq > lastSeq else { return }
        lastSeq = batch.seq
        for event in batch.events {
            if case .fished(let seat, let matched, _) = event, seat == me, !matched { awaitingDraw = true }
        }
        queue.enqueue { [weak self] in
            guard let self else { return }
            for event in batch.events { await self.beat(event, me: me, name: name) }
        }
    }

    func showDrawn(_ card: Card) {
        queue.enqueue { [weak self] in
            guard let self else { return }
            self.show(GoFishMoment(text: "You drew a card", subtitle: card.accessibleName,
                                   cards: [card], tone: .fish))
            Haptics.tick()
            await kidsWait(1.8)
        }
    }

    func markArrived(_ ids: Set<String>) {
        glowIDs.formUnion(ids)
        let snapshot = ids
        Task { @MainActor [weak self] in
            await kidsWait(3.0)
            self?.glowIDs.subtract(snapshot)
        }
    }

    private func show(_ new: GoFishMoment) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { moment = new }
    }

    private func beat(_ event: GoFishEvent, me: Int, name: (Int) -> String) async {
        switch event {
        case .asked(let asker, let target, let rank):
            let plural = GoFishText.plural(rank)
            if asker == me {
                show(GoFishMoment(text: "You ask \(name(target)) for \(plural)"))
            } else if target == me {
                show(GoFishMoment(text: "\(name(asker)) asks you for \(plural)"))
                Haptics.tick()
            } else {
                show(GoFishMoment(text: "\(name(asker)) asks \(name(target)) for \(plural)"))
            }
            await kidsWait(1.5)

        case .gave(let from, let to, let rank, let cards):
            let noun = cards.count == 1 ? KidsRank.singular(rank) : GoFishText.plural(rank)
            let count = cards.count == 1 ? "a" : KidsRank.countWord(cards.count)
            if to == me {
                show(GoFishMoment(text: "\(name(from)) gives you \(count) \(noun)", cards: cards, tone: .good))
                Haptics.play()
            } else if from == me {
                show(GoFishMoment(text: "You hand over \(count) \(noun)", cards: cards))
            } else {
                show(GoFishMoment(text: "\(name(from)) hands \(name(to)) \(count) \(noun)"))
            }
            await kidsWait(1.8)

        case .goFish(let seat, _):
            show(GoFishMoment(text: seat == me ? "Go fish!" : "\(name(seat)) goes fishing",
                              subtitle: seat == me ? "Drawing from the pool" : nil,
                              tone: .fish))
            if seat == me { Haptics.arm() }
            await kidsWait(1.2)

        case .fished(let seat, let matched, let card):
            if matched, let card {
                if seat == me {
                    show(GoFishMoment(text: "You fished your wish!", subtitle: "A \(KidsRank.singular(card.rank ?? 0)), just what you asked for",
                                      cards: [card], tone: .good))
                    Haptics.play()
                } else {
                    show(GoFishMoment(text: "\(name(seat)) fished their wish!", tone: .good))
                }
                await kidsWait(1.9)
            } else {
                await kidsWait(0.5)
            }

        case .goesAgain(let seat):
            if seat == me {
                goAgain = true
                show(GoFishMoment(text: "Go again!", subtitle: "Ask someone else, or the same player", tone: .good))
                Haptics.arm()
                await kidsWait(1.6)
                goAgain = false
            }

        case .bookLaid(let seat, let rank, let cards):
            if seat == me {
                show(GoFishMoment(text: "You laid down a book of \(GoFishText.plural(rank))!", cards: cards, tone: .book))
                Haptics.play()
                await kidsWait(2.0)
            } else {
                show(GoFishMoment(text: "\(name(seat)) laid down a book of \(GoFishText.plural(rank))"))
                await kidsWait(1.3)
            }

        case .refilled(let seat, let count):
            if seat == me {
                show(GoFishMoment(text: "You drew \(count) fresh cards", tone: .fish))
                await kidsWait(1.4)
            }

        case .turnChanged:
            withAnimation(.easeOut(duration: 0.2)) { moment = nil }

        case .poolEmpty(let seat):
            show(GoFishMoment(text: seat == me ? "The pool is empty" : "The pool is empty - \(name(seat)) passes"))
            await kidsWait(1.2)

        case .dealt:
            show(GoFishMoment(text: "Cards are out!", tone: .info))
            await kidsWait(0.8)

        case .gameOver, .illegalAttempt:
            break
        }
    }
}

// MARK: - Hand view

/// The phone during Go Fish: your hand fanned at the bottom (tap any card to
/// pick that RANK), the other players across the top (tap one to ask them),
/// and the table's narration in between. Routed by `SideGameRegistry`.
struct GoFishHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        let wire = client.sideGameState.flatMap { payload in
            payload.kind == GoFishEngine.kind ? payload.decode(GoFishWireState.self) : nil
        }
        let batch = client.sideGameEvents.flatMap { payload in
            payload.kind == GoFishEngine.kind ? payload.decode(KidsEventBatch<GoFishEvent>.self) : nil
        }
        GoFishHandContent(wire: wire, batch: batch) { action in
            client.sendSideGameAction(kind: GoFishEngine.kind, action)
        }
    }
}

struct GoFishHandContent: View {
    let wire: GoFishWireState?
    let batch: KidsEventBatch<GoFishEvent>?
    let send: (GoFishAction) -> Void

    @State private var stage = GoFishHandStage()
    @State private var selectedRank: Int?
    @State private var sentAsk: (target: Int, rank: Int)?
    @State private var knownIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    private var snap: GoFishSnapshot? { wire?.snapshot }
    private var me: Int { snap?.seat ?? 0 }
    private func name(_ seat: Int) -> String { wire?.names[seat] ?? "Player \(seat + 1)" }

    private var isMyTurn: Bool {
        guard let snap else { return false }
        return snap.phase == .playing && snap.turnSeat == snap.seat
    }
    private var asking: Bool { sentAsk != nil || (wire?.askInFlight ?? false) }
    private var canPick: Bool { isMyTurn && !asking }

    private var sortedHand: [Card] {
        (snap?.hand ?? []).sorted {
            if ($0.rank ?? 0) != ($1.rank ?? 0) { return ($0.rank ?? 0) < ($1.rank ?? 0) }
            return $0.id < $1.id
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                VStack(spacing: 0) {
                    header
                    opponents
                    myBooks
                    Spacer(minLength: 4)
                    centerStage
                    Spacer(minLength: 4)
                    fan(in: geo.size)
                        .frame(height: geo.size.height * 0.40)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            knownIDs = Set(snap?.hand.map(\.id) ?? [])
            if let batch { stage.ingest(batch, me: me, name: name) }
        }
        .onChange(of: batch) { _, new in
            guard let new else { return }
            stage.ingest(new, me: me, name: name)
            // An answer arrived: the ask is no longer "in the air".
            if new.events.contains(where: { event in
                switch event {
                case .gave, .goFish: return true
                default: return false
                }
            }) { sentAsk = nil }
        }
        .onChange(of: snap?.hand.map(\.id) ?? []) { _, ids in
            let now = Set(ids)
            let arrived = now.subtracting(knownIDs)
            knownIDs = now
            if !arrived.isEmpty {
                stage.markArrived(arrived)
                if stage.awaitingDraw, arrived.count == 1,
                   let card = snap?.hand.first(where: { arrived.contains($0.id) }) {
                    stage.awaitingDraw = false
                    stage.showDrawn(card)
                }
            }
            if let rank = selectedRank, !(snap?.hand.contains { $0.rank == rank } ?? false) { selectedRank = nil }
        }
        .onChange(of: snap?.turnSeat) { _, _ in
            if !isMyTurn { selectedRank = nil }
            sentAsk = nil
        }
        .onChange(of: wire?.askInFlight) { old, new in
            if old == true, new == false { sentAsk = nil }
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            Text("Go Fish")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Spacer()
            if let snap {
                Text("Pool \(snap.poolCount)")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // MARK: the other players

    private var opponents: some View {
        let seats = (0..<(snap?.playerCount ?? 0)).filter { $0 != me }
        return HStack(spacing: 10) {
            ForEach(seats, id: \.self) { seat in opponentChip(seat) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func opponentChip(_ seat: Int) -> some View {
        let lit = canPick && selectedRank != nil && (snap?.askableTargets.contains(seat) ?? false)
        let theirTurn = snap?.phase == .playing && snap?.turnSeat == seat
        let cards = snap?.handCounts[seat] ?? 0
        let books = snap?.books[seat]?.count ?? 0
        let color = PlayerPalette.color(seat)
        return Button {
            askSelected(of: seat)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 11, height: 11)
                    Text(name(seat))
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.stockTop)
                        .lineLimit(1)
                }
                Text("\(cards) card\(cards == 1 ? "" : "s") · \(books) book\(books == 1 ? "" : "s")")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(CardStyle.gold.opacity(0.9))
                    .monospacedDigit()
                if lit, let rank = selectedRank {
                    Text("Ask for \(GoFishText.plural(rank))")
                        .font(.system(.caption, design: .serif).weight(.heavy))
                        .foregroundStyle(CardStyle.ink)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(CardStyle.gold))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(lit ? 0.5 : 0.32))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(lit ? CardStyle.gold : (theirTurn ? color : .white.opacity(0.1)),
                                      lineWidth: lit ? 2.5 : (theirTurn ? 2 : 1)))
                    .shadow(color: lit ? CardStyle.gold.opacity(0.55) : .clear, radius: 10)
            )
            .opacity(isMyTurn && selectedRank != nil && !lit ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!lit)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lit)
        .accessibilityLabel("\(name(seat)), \(cards) cards, \(books) books")
        .accessibilityHint(lit ? "Double-tap to ask them for \(GoFishText.plural(selectedRank ?? 0))" : "")
    }

    @ViewBuilder
    private var myBooks: some View {
        let mine = snap?.books[me] ?? []
        if !mine.isEmpty {
            HStack(spacing: 8) {
                Text("Your books")
                    .font(.system(.caption, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.85))
                ForEach(mine, id: \.self) { rank in
                    Text(KidsRank.symbol(rank))
                        .font(.system(.footnote, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.ink)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(CardStyle.gold))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    // MARK: narration + prompt

    private var centerStage: some View {
        VStack(spacing: 12) {
            if let moment = stage.moment {
                momentView(moment)
                    .id(moment.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            prompt
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: stage.moment?.id)
    }

    private func momentView(_ moment: GoFishMoment) -> some View {
        VStack(spacing: 8) {
            if !moment.cards.isEmpty {
                HStack(spacing: -22) {
                    ForEach(Array(moment.cards.prefix(4).enumerated()), id: \.element.id) { i, card in
                        CardView(card: card, faceUp: true, elevation: 0.25)
                            .frame(width: moment.cards.count > 2 ? 54 : 66)
                            .rotationEffect(.degrees(Double(i) * 4 - Double(moment.cards.count - 1) * 2))
                    }
                }
                .padding(.bottom, 4)
            }
            Text(moment.text)
                .font(.system(moment.tone == .fish || moment.tone == .book ? .title2 : .title3, design: .serif).weight(.bold))
                .foregroundStyle(moment.tone == .good || moment.tone == .book ? CardStyle.gold : CardStyle.stockTop)
                .multilineTextAlignment(.center)
            if let subtitle = moment.subtitle {
                Text(subtitle)
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.3), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var prompt: some View {
        if let snap {
            if snap.phase == .gameOver {
                resultBanner(snap)
            } else if let ask = sentAsk {
                pill("Asking \(name(ask.target)) for \(GoFishText.plural(ask.rank))…")
            } else if wire?.askInFlight == true {
                pill("Waiting for the answer…")
            } else if isMyTurn {
                yourTurn(snap)
            } else {
                pill("\(name(snap.turnSeat))'s turn")
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.3)))
    }

    private func yourTurn(_ snap: GoFishSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(stage.goAgain ? "GO AGAIN" : "YOUR TURN")
                .font(.system(.headline, design: .serif).weight(.heavy))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
                .scaleEffect(stage.goAgain && !motionReduced ? 1.12 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: stage.goAgain)
            Text(selectedRank == nil
                 ? "Tap a card to choose what to ask for"
                 : "Now tap a player to ask for \(GoFishText.plural(selectedRank ?? 0))")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(
            Capsule().fill(.black.opacity(0.3))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1.5))
        )
    }

    private func resultBanner(_ snap: GoFishSnapshot) -> some View {
        let iWon = snap.winners.contains(snap.seat)
        let tie = snap.winners.count > 1
        let mine = snap.books[snap.seat]?.count ?? 0
        let title: String
        if tie {
            title = iWon ? "It's a tie - you shared the win!" : "\(KidsRank.joined(snap.winners.map(name))) tie"
        } else if iWon {
            title = "You win!"
        } else if let w = snap.winners.first {
            title = "\(name(w)) wins"
        } else {
            title = "Good game!"
        }
        return VStack(spacing: 6) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(iWon ? CardStyle.gold : .white)
            Text("You made \(mine) book\(mine == 1 ? "" : "s")")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    // MARK: fan

    private func cardWidth(for count: Int, in size: CGSize) -> CGFloat {
        let cap = min(size.width * 0.26, 104)
        guard count > 1 else { return cap }
        return max(56, min(cap, size.width * 0.9 / (1 + 0.3 * CGFloat(count - 1))))
    }

    private func fan(in size: CGSize) -> some View {
        let hand = sortedHand
        let width = cardWidth(for: hand.count, in: size)
        let layout = HandFanLayout(cardCount: hand.count, containerWidth: size.width, cardWidth: width)
        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.element.id) { index, card in
                let isSelected = card.rank != nil && card.rank == selectedRank
                let slot = layout.slot(for: index, selected: isSelected)
                let arrived = stage.glowIDs.contains(card.id)
                CardView(card: card, faceUp: true, elevation: isSelected ? 0.5 : 0)
                    .frame(width: width)
                    .shadow(color: CardStyle.gold.opacity(arrived ? 0.9 : 0), radius: arrived ? 12 : 0)
                    .rotationEffect(slot.angle)
                    .offset(x: slot.offset.width, y: slot.offset.height)
                    .zIndex(isSelected ? 100 : slot.zIndex)
                    .onTapGesture { tap(card) }
                    .transition(.asymmetric(
                        insertion: .offset(y: -size.height * 0.5).combined(with: .opacity),
                        removal: .offset(y: -size.height * 0.35).combined(with: .opacity)))
                    .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isSelected)
                    .accessibilityLabel(card.accessibleName)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(canPick ? (isSelected ? "Selected. Double-tap to put it back."
                                                              : "Double-tap to ask for \(GoFishText.plural(card.rank ?? 0))")
                                               : "")
            }
        }
        .frame(maxWidth: .infinity)
        .offset(y: 30)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: hand.map(\.id))
    }

    // MARK: actions

    private func tap(_ card: Card) {
        guard canPick, let rank = card.rank, snap?.askableRanks.contains(rank) == true else { return }
        Haptics.tick()
        selectedRank = selectedRank == rank ? nil : rank
    }

    private func askSelected(of target: Int) {
        guard canPick, let rank = selectedRank,
              snap?.askableTargets.contains(target) == true else { return }
        Haptics.play()
        sentAsk = (target, rank)
        selectedRank = nil
        send(.ask(target: target, rank: rank))
        // Safety: if the host never answers (a dropped link), give the ask back.
        Task { @MainActor in
            await kidsWait(8)
            if sentAsk?.target == target { sentAsk = nil }
        }
    }
}

// MARK: - Previews

private func goFishDemoCard(_ suit: Suit, _ rank: Int) -> Card {
    let prefix = ["c", "d", "h", "s"][Suit.allCases.firstIndex(of: suit) ?? 0]
    return Card(id: "\(prefix)\(rank)", kind: .standard(suit: suit, rank: rank))
}

private func goFishDemoWire(myTurn: Bool, over: Bool = false) -> GoFishWireState {
    let hand = [goFishDemoCard(.clubs, 4), goFishDemoCard(.hearts, 4), goFishDemoCard(.spades, 7),
                goFishDemoCard(.diamonds, 9), goFishDemoCard(.clubs, 12), goFishDemoCard(.hearts, 14)]
    let snapshot = GoFishSnapshot(
        seat: 0, playerCount: 3, hand: hand, handCounts: [0: hand.count, 1: 5, 2: 3],
        books: [0: [8], 1: [], 2: [3, 10]], poolCount: 21, turnSeat: myTurn ? 0 : 1,
        phase: over ? .gameOver : .playing, winners: over ? [0] : [], askLog: [],
        askableRanks: myTurn ? [4, 7, 9, 12, 14] : [], askableTargets: myTurn ? [1, 2] : [])
    return GoFishWireState(snapshot: snapshot, names: [0: "Chase", 1: "Vinny", 2: "Mae"], askInFlight: false)
}

#Preview("Go Fish hand - my turn") {
    GoFishHandContent(wire: goFishDemoWire(myTurn: true), batch: nil, send: { _ in })
}

#Preview("Go Fish hand - waiting") {
    GoFishHandContent(wire: goFishDemoWire(myTurn: false), batch: nil, send: { _ in })
}

#Preview("Go Fish hand - won") {
    GoFishHandContent(wire: goFishDemoWire(myTurn: false, over: true), batch: nil, send: { _ in })
}
