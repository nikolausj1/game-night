import SwiftUI

// MARK: - Presentation stage

/// What the Old Maid table SHOWS. Same idea as `GoFishStage`: the host
/// applies a draw instantly, the stage replays it as beats (a card lifts
/// out of the neighbor's fan and travels to the drawer, a pair lays down
/// with a flourish) and the rail hands catch up as the cards land.
@MainActor
@Observable
final class OldMaidStage {
    var size: CGSize = .zero
    var playerCount = 2
    var counts: [Int: Int] = [:]
    var pairs: [Int: [[Card]]] = [:]
    var out: Set<Int> = []
    var turn = 0
    var focus: Set<Int> = []
    var deck = 0
    var callout: KidsCallout?
    var flights: [KidsFlightSpec] = []
    var freshPair: FreshPair?
    var finished = false
    var busy = false
    var reduceMotion = false

    struct FreshPair: Equatable {
        let seat: Int
        let index: Int
    }

    @ObservationIgnored let queue = KidsBeatQueue()
    @ObservationIgnored private(set) var lastSeq = 0
    @ObservationIgnored private weak var game: OldMaidHost?

    // MARK: geometry

    var geometry: KidsSeatGeometry { KidsSeatGeometry(size: size, count: playerCount) }
    var cardWidth: CGFloat { TableGeometry.tableCardWidth(for: size) }
    var pairWidth: CGFloat { cardWidth * 0.34 }
    var pairSpread: CGFloat { pairWidth * 0.5 }
    var laidLayout: KidsLaidLayout {
        KidsLaidLayout(cols: 6, cellW: pairWidth + pairSpread + 10, cellH: pairWidth * 1.4,
                       rowPitch: pairWidth * 1.4 * 0.62)
    }
    var deckPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.42) }
    var calloutPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.645) }

    private func name(_ seat: Int) -> String { game?.name(seat) ?? "Player \(seat + 1)" }

    // MARK: lifecycle

    func attach(_ game: OldMaidHost) {
        self.game = game
        playerCount = game.engine.state.playerCount
        queue.onIdle = { [weak self] in self?.settle() }
        if let batch = game.lastBatch, batch.seq == 1 {
            counts = Dictionary(uniqueKeysWithValues: (0..<playerCount).map { ($0, 0) })
            pairs = [:]
            out = []
            deck = 51
            turn = 0
            finished = false
            ingest(batch)
        } else {
            lastSeq = game.lastBatch?.seq ?? 0
            settle()
        }
    }

    func ingest(_ batch: KidsEventBatch<OldMaidEvent>) {
        guard batch.seq > lastSeq else { return }
        lastSeq = batch.seq
        busy = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            for event in batch.events { await self.beat(event) }
        }
    }

    func settle() {
        guard let game else { return }
        let state = game.engine.state
        playerCount = state.playerCount
        counts = game.engine.handCounts()
        pairs = state.laid
        out = Set(state.outSeats)
        turn = state.turnSeat
        deck = 0
        flights = []
        freshPair = nil
        focus = state.phase == .playing ? Set(game.engine.drawTarget(for: state.turnSeat).map { [$0] } ?? []) : []
        withAnimation(.easeOut(duration: 0.3)) { callout = nil }
        finished = state.phase == .gameOver
        busy = false
    }

    // MARK: helpers

    private func show(_ new: KidsCallout) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { callout = new }
    }

    private func pause(_ seconds: Double) async {
        await kidsWait(KidsMotion.pause(seconds, reduce: reduceMotion))
    }

    @discardableResult
    private func launch(_ specs: [KidsFlightSpec]) async -> Double {
        let calmed = specs.map { $0.calmed(reduceMotion) }
        flights.append(contentsOf: calmed)
        let span = calmed.map { $0.delay + $0.duration }.max() ?? 0
        await kidsWait(span)
        let ids = Set(calmed.map(\.id))
        flights.removeAll { ids.contains($0.id) }
        return span
    }

    private func later(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await kidsWait(seconds)
            block()
        }
    }

    /// Next seat after `seat` that (as displayed) still holds cards.
    private func nextActive(after seat: Int) -> Int? {
        for i in 1...playerCount {
            let s = (seat + i) % playerCount
            if s != seat, (counts[s] ?? 0) > 0 { return s }
        }
        return nil
    }

    // MARK: beats

    private func beat(_ event: OldMaidEvent) async {
        let geo = geometry
        switch event {
        case .dealt(let handCounts):
            await deal(handCounts)

        case .pairsDiscarded(let seat, let newPairs, let onDeal):
            guard !newPairs.isEmpty else { return }
            let existing = pairs[seat]?.count ?? 0
            let total = existing + newPairs.count
            let angle = geo.angle(seat).degrees
            counts[seat] = max(0, (counts[seat] ?? 0) - newPairs.count * 2)
            if onDeal {
                show(KidsCallout(title: "\(name(seat)) lays down \(newPairs.count == 1 ? "a pair" : "\(newPairs.count) pairs")",
                                 tone: .soft))
            } else {
                let rank = newPairs.first?.first?.rank
                show(KidsCallout(title: "\(name(seat)) makes a pair!",
                                 subtitle: rank.map { "Two \(GoFishText.plural($0))" },
                                 rank: rank, tone: .good))
            }
            TableSFX.shared.play(onDeal ? .cardDeal : .chipPlace)
            var specs: [KidsFlightSpec] = []
            for (pi, pair) in newPairs.enumerated() {
                let local = laidLayout.local(index: existing + pi, total: total, containerHeight: geo.containerHeight)
                for (ci, card) in pair.enumerated() {
                    let dx = (CGFloat(ci) - 0.5) * pairSpread
                    let spot = geo.world(seat, local: CGPoint(x: local.x + dx, y: local.y))
                    specs.append(KidsFlightSpec(card: card, face: .flipUp, from: geo.handPoint(seat), to: spot,
                                                width: pairWidth, toAngle: angle + (Double(ci) - 0.5) * 7,
                                                fromScale: 1.7, toScale: 1, lift: 55, duration: 0.65,
                                                delay: Double(pi) * (onDeal ? 0.09 : 0.0) + Double(ci) * 0.07))
                }
            }
            let span = await launch(specs)
            pairs[seat, default: []].append(contentsOf: newPairs)
            if !onDeal { freshPair = FreshPair(seat: seat, index: existing) }
            await pause(max(0.2, (onDeal ? OldMaidTiming.openingPair : OldMaidTiming.pair) - span))
            freshPair = nil

        case .drew(let seat, let from, _):
            turn = seat
            withAnimation { focus = [from] }
            counts[from] = max(0, (counts[from] ?? 0) - 1)
            show(KidsCallout(title: "\(name(seat)) picks a card from \(name(from))", tone: .ask))
            TableSFX.shared.play(.cardSlide, intensity: 0.6)
            let flight = KidsFlightSpec(card: nil, face: .back, from: geo.handPoint(from), to: geo.handPoint(seat),
                                        width: cardWidth * 0.9, lift: 60, duration: 0.8)
            await launch([flight])
            counts[seat] = (counts[seat] ?? 0) + 1
            await pause(0.2)

        case .handShuffled(let seat):
            show(KidsCallout(title: "\(name(seat)) shuffles their cards", tone: .soft))
            TableSFX.shared.play(.shuffle)
            await pause(OldMaidTiming.shuffle)

        case .playerOut(let seat):
            out.insert(seat)
            show(KidsCallout(title: "\(name(seat)) is out of cards", subtitle: "Safe!", tone: .good))
            TableSFX.shared.play(.softChime)
            await pause(OldMaidTiming.out)

        case .turnChanged(let seat):
            turn = seat
            withAnimation(.easeOut(duration: 0.3)) {
                focus = nextActive(after: seat).map { [$0] } ?? []
                callout = nil
            }

        case .gameOver(let loser):
            await reveal(loser: loser)

        case .illegalAttempt:
            break
        }
    }

    private func deal(_ handCounts: [Int: Int]) async {
        let geo = geometry
        counts = Dictionary(uniqueKeysWithValues: (0..<playerCount).map { ($0, 0) })
        deck = handCounts.values.reduce(0, +)
        TableSFX.shared.play(.shuffle)
        await pause(0.8)
        TableSFX.shared.play(.cardDeal)
        let rounds = handCounts.values.max() ?? 0
        var specs: [KidsFlightSpec] = []
        var order = 0
        for round in 0..<rounds {
            for seat in 0..<playerCount where round < (handCounts[seat] ?? 0) {
                let delay = Double(order) * OldMaidTiming.dealStagger
                specs.append(KidsFlightSpec(card: nil, face: .back, from: deckPoint, to: geo.handPoint(seat),
                                            width: cardWidth * 0.85, lift: 24,
                                            duration: OldMaidTiming.dealFlight, delay: delay))
                let landing = KidsMotion.pause(delay + OldMaidTiming.dealFlight, reduce: reduceMotion)
                let remaining = handCounts.values.reduce(0, +) - order - 1
                Task { @MainActor [weak self] in
                    await kidsWait(landing)
                    guard let self else { return }
                    self.counts[seat] = (self.counts[seat] ?? 0) + 1
                    self.deck = remaining
                }
                order += 1
            }
        }
        await launch(specs)
        deck = 0
        await pause(0.5)
    }

    private func reveal(loser: Int) async {
        guard let game else { return }
        let geo = geometry
        let queen = game.engine.state.hands[loser]?.first
        withAnimation { focus = [loser] }
        show(KidsCallout(title: "Old Maid!",
                         subtitle: "\(name(loser)) is holding the last queen. Good game, everyone!",
                         tone: .big))
        TableSFX.shared.play(.softChime)
        if let queen {
            // The lone queen turns over in the middle of the felt, gently.
            let flight = KidsFlightSpec(card: queen, face: .flipUp, from: geo.handPoint(loser), to: deckPoint,
                                        width: cardWidth * 1.15, toAngle: -3, lift: 70, duration: 1.0)
            await launch([flight])
        }
        await pause(OldMaidTiming.finale)
    }
}

// MARK: - Table

/// The Old Maid felt: every seat's plate + rail hand with its laid pairs,
/// the draw narrated card by card, and a gentle "Old Maid!" ending.
struct OldMaidTableView: View {
    @Bindable var host: GameHostController
    var onClose: (() -> Void)? = nil

    var body: some View {
        let _ = host.stateVersion
        if let game = host.sideGame as? OldMaidHost {
            OldMaidTableContent(game: game, controllerNames: host.sideGameSeatNames,
                                onPlayAgain: { host.restartSideGame() }, onClose: onClose)
                .id(ObjectIdentifier(game))
        } else {
            Color.clear
        }
    }
}

struct OldMaidTableContent: View {
    let game: OldMaidHost
    var controllerNames: [Int: String] = [:]
    var onPlayAgain: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var stage = OldMaidStage()
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    var body: some View {
        let _ = game.revision
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    stage.size = geo.size
                    stage.reduceMotion = motionReduced
                    game.updateNames(controllerNames)
                    stage.attach(game)
                }
                .onChange(of: geo.size) { _, new in stage.size = new }
        }
        .onChange(of: game.revision) { _, _ in
            if let batch = game.lastBatch { stage.ingest(batch) }
        }
        .onChange(of: controllerNames) { _, new in game.updateNames(new) }
        .onChange(of: motionReduced) { _, new in stage.reduceMotion = new }
        .onDisappear { stage.queue.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        let geometry = stage.geometry
        ZStack {
            if stage.deck > 0 {
                KidsPoolPile(count: stage.deck, cardWidth: stage.cardWidth, label: "Deck")
                    .position(stage.deckPoint)
                    .transition(.opacity)
            }

            ForEach(0..<stage.playerCount, id: \.self) { seat in
                let safe = stage.out.contains(seat)
                KidsSeatContainer(geometry: geometry, seat: seat, name: game.name(seat),
                                  isTurn: stage.turn == seat && !stage.finished && !safe,
                                  isFocus: stage.focus.contains(seat) && stage.turn != seat,
                                  stat: "\(stage.counts[seat] ?? 0) cards",
                                  status: safe ? "Safe!" : nil,
                                  handCount: stage.counts[seat] ?? 0)
            }

            // Laid pairs, neat little stacks inboard of each plate.
            ForEach(0..<stage.playerCount, id: \.self) { seat in
                let list = stage.pairs[seat] ?? []
                ForEach(Array(list.enumerated()), id: \.offset) { index, pair in
                    KidsCardStack(cards: pair, width: stage.pairWidth, spread: stage.pairSpread, fanStep: 7,
                                  glow: stage.freshPair == OldMaidStage.FreshPair(seat: seat, index: index))
                        .rotationEffect(geometry.angle(seat))
                        .position(geometry.world(seat, local: stage.laidLayout.local(
                            index: index, total: list.count, containerHeight: geometry.containerHeight)))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: list.count)
            }

            Group {
                if let callout = stage.callout {
                    KidsCalloutView(callout: callout).id(callout.id)
                } else if !stage.finished, !stage.busy, let target = stage.focus.first {
                    Text("\(game.name(stage.turn)) is picking a card from \(game.name(target))…")
                        .font(.system(.title3, design: .serif).italic())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.7))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.3)))
                        .transition(.opacity)
                }
            }
            .position(stage.calloutPoint)
            .zIndex(5)

            KidsFlightLayer(flights: stage.flights)
                .zIndex(8)

            if stage.finished {
                finishedPanel
                    .zIndex(20)
            }

            GameHUD(title: "Old Maid", onExit: { onClose?() }, toggles: [])
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(30)
        }
        .animation(.easeInOut(duration: 0.25), value: stage.finished)
    }

    // MARK: end of game

    private var finishedPanel: some View {
        let state = game.engine.state
        let loser = state.loser
        let title = loser.map { "\(game.name($0)) has the Old Maid" } ?? "Good game!"
        let first = state.outSeats.first
        let rows = (0..<state.playerCount).sorted { a, b in
            // Safe players first, in the order they went out; the Old Maid last.
            let ia = state.outSeats.firstIndex(of: a) ?? Int.max
            let ib = state.outSeats.firstIndex(of: b) ?? Int.max
            return ia < ib
        }.map { seat in
            RecapRow(id: seat, name: game.name(seat), colorIndex: seat,
                     score: seat == loser ? "Old Maid" : "safe", isWinner: seat == first)
        }
        return GameRecapCard(title: title, rows: rows,
                             highlight: "Just the luck of the cards. Go again?", kidMode: true,
                             rematchLabel: onPlayAgain == nil ? nil : "Rematch",
                             onRematch: onPlayAgain, onDone: { onClose?() })
    }
}

// MARK: - Previews

private func oldMaidPreviewSeats(_ n: Int) -> [SeatSpec] {
    let names = ["Chase", "Vinny", "Mae", "Ruthie"]
    return (0..<n).map { SeatSpec(id: $0, name: names[$0], isBot: true) }
}

/// An all-bot 4-player game that plays itself to the Old Maid reveal.
#Preview("Old Maid - 4 bots playing", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        OldMaidTableContent(game: OldMaidHost(seats: oldMaidPreviewSeats(4), seed: 3))
    }
}

#Preview("Old Maid - 2 bots playing", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        OldMaidTableContent(game: OldMaidHost(seats: oldMaidPreviewSeats(2), seed: 9))
    }
}
