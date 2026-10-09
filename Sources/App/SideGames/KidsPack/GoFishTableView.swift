import SwiftUI

// MARK: - Presentation stage

/// What the table SHOWS, which deliberately trails the engine by a beat or
/// two. The host applies a move instantly; the stage replays the resulting
/// events as narrated beats (ask, hand over, go fish, lay a book) and only
/// then lets the rail hands, the pool and the books catch up. When the
/// queue goes quiet it re-syncs to the engine, so any drift self-heals.
@MainActor
@Observable
final class GoFishStage {
    struct FreshBook: Equatable {
        let seat: Int
        let rank: Int
    }

    var size: CGSize = .zero
    var playerCount = 2
    var counts: [Int: Int] = [:]
    var pool = 0
    var books: [Int: [Int]] = [:]
    var turn = 0
    var focus: Set<Int> = []
    var callout: KidsCallout?
    var flights: [KidsFlightSpec] = []
    var fresh: FreshBook?
    var revealCard: Card?
    var finished = false
    var busy = false
    var reduceMotion = false

    @ObservationIgnored let queue = KidsBeatQueue()
    @ObservationIgnored private(set) var lastSeq = 0
    @ObservationIgnored private weak var game: GoFishHost?

    // MARK: geometry

    var geometry: KidsSeatGeometry { KidsSeatGeometry(size: size, count: playerCount) }
    var cardWidth: CGFloat { TableGeometry.tableCardWidth(for: size) }
    var bookWidth: CGFloat { cardWidth * 0.40 }
    var laidLayout: KidsLaidLayout {
        KidsLaidLayout(cols: 5, cellW: bookWidth + 14, cellH: bookWidth * 1.4, rowPitch: bookWidth * 1.4 * 0.64)
    }
    var poolPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.42) }
    var revealPoint: CGPoint { CGPoint(x: poolPoint.x + cardWidth * 1.5, y: poolPoint.y) }
    var calloutPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.645) }

    private func name(_ seat: Int) -> String { game?.name(seat) ?? "Player \(seat + 1)" }

    // MARK: lifecycle

    func attach(_ game: GoFishHost) {
        self.game = game
        playerCount = game.engine.state.playerCount
        queue.onIdle = { [weak self] in self?.settle() }
        if let batch = game.lastBatch, batch.seq == 1 {
            // A fresh game: start from an empty table so the deal is DEALT.
            counts = Dictionary(uniqueKeysWithValues: (0..<playerCount).map { ($0, 0) })
            books = Dictionary(uniqueKeysWithValues: (0..<playerCount).map { ($0, []) })
            pool = 52
            turn = 0
            finished = false
            ingest(batch)
        } else {
            lastSeq = game.lastBatch?.seq ?? 0
            settle()
        }
    }

    func ingest(_ batch: KidsEventBatch<GoFishEvent>) {
        guard batch.seq > lastSeq else { return }
        lastSeq = batch.seq
        busy = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            for event in batch.events { await self.beat(event) }
        }
    }

    /// Re-sync every displayed number to the engine and clear transients.
    func settle() {
        guard let game else { return }
        let state = game.engine.state
        playerCount = state.playerCount
        counts = game.engine.handCounts()
        pool = state.pool.count
        books = state.books
        turn = state.turnSeat
        focus = []
        flights = []
        revealCard = nil
        fresh = nil
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

    private func tilt(_ card: Card) -> Double { TableGeometry.jitterDegrees(cardID: card.id) * 0.6 }

    // MARK: beats

    private func beat(_ event: GoFishEvent) async {
        let geo = geometry
        switch event {
        case .dealt(let handCounts, let poolCount):
            await deal(handCounts, poolCount: poolCount)

        case .asked(let asker, let target, let rank):
            turn = asker
            withAnimation { focus = [asker, target] }
            show(KidsCallout(title: "\(name(asker)) asks \(name(target)) for \(GoFishText.plural(rank))",
                             rank: rank, tone: .ask))
            TableSFX.shared.play(.cardSlide, intensity: 0.5)
            await pause(GoFishTiming.ask)

        case .gave(let from, let to, let rank, let cards):
            counts[from] = max(0, (counts[from] ?? 0) - cards.count)
            let noun = cards.count == 1 ? KidsRank.singular(rank) : GoFishText.plural(rank)
            let article = cards.count == 1 ? "a" : KidsRank.countWord(cards.count)
            show(KidsCallout(title: "\(name(from)) hands over \(article) \(noun)", rank: rank, tone: .good))
            TableSFX.shared.play(.cardDeal)
            let specs = cards.enumerated().map { i, card in
                KidsFlightSpec(card: card, face: .flipUp, from: geo.handPoint(from), to: geo.handPoint(to),
                               width: cardWidth * 0.8, fromAngle: tilt(card), toAngle: -tilt(card),
                               lift: 70, duration: 0.8, delay: Double(i) * 0.12)
            }
            let span = await launch(specs)
            counts[to] = (counts[to] ?? 0) + cards.count
            await pause(max(0.2, GoFishTiming.gave - span))

        case .goFish(let seat, let rank):
            withAnimation { focus = [seat] }
            show(KidsCallout(title: "Go fish!", subtitle: "No \(GoFishText.plural(rank)) over there. Draw from the pool.",
                             tone: .big))
            TableSFX.shared.play(.tableKnock, intensity: 0.5)
            await pause(GoFishTiming.goFish)

        case .fished(let seat, let matched, let card):
            pool = max(0, pool - 1)
            if matched, let card {
                let there = KidsFlightSpec(card: card, face: .flipUp, from: poolPoint, to: revealPoint,
                                           width: cardWidth, toAngle: 4, lift: 40, duration: 0.7)
                show(KidsCallout(title: "It's a \(KidsRank.singular(card.rank ?? 0))!",
                                 subtitle: "\(name(seat)) fished their wish", rank: card.rank, tone: .good))
                TableSFX.shared.play(.cardFlip)
                await launch([there])
                revealCard = card
                TableSFX.shared.play(.softChime)
                await pause(GoFishTiming.reveal)
                let home = KidsFlightSpec(card: card, face: .flipDown, from: revealPoint, to: geo.handPoint(seat),
                                          width: cardWidth, fromAngle: 4, lift: 50, duration: 0.7)
                revealCard = nil
                await launch([home])
                counts[seat] = (counts[seat] ?? 0) + 1
            } else {
                show(KidsCallout(title: "\(name(seat)) draws a card", tone: .soft))
                TableSFX.shared.play(.cardSlide, intensity: 0.7)
                let draw = KidsFlightSpec(card: nil, face: .back, from: poolPoint, to: geo.handPoint(seat),
                                          width: cardWidth * 0.9, lift: 50, duration: GoFishTiming.draw)
                await launch([draw])
                counts[seat] = (counts[seat] ?? 0) + 1
            }

        case .poolEmpty:
            show(KidsCallout(title: "The pool is empty", tone: .soft))
            await pause(GoFishTiming.poolEmpty)

        case .goesAgain(let seat):
            turn = seat
            show(KidsCallout(title: "\(name(seat)) goes again!", tone: .good))
            await pause(GoFishTiming.again)

        case .bookLaid(let seat, let rank, let cards):
            counts[seat] = max(0, (counts[seat] ?? 0) - cards.count)
            let index = books[seat]?.count ?? 0
            let total = index + 1
            let target = geo.world(seat, local: laidLayout.local(index: index, total: total,
                                                                  containerHeight: geo.containerHeight))
            let angle = geo.angle(seat).degrees
            show(KidsCallout(title: "\(name(seat)) lays down a book of \(GoFishText.plural(rank))!",
                             subtitle: "All four \(GoFishText.plural(rank)) - that's a book.",
                             rank: rank, tone: .book))
            TableSFX.shared.play(.chipPlace)
            let specs = cards.enumerated().map { i, card in
                KidsFlightSpec(card: card, face: .flipUp, from: geo.handPoint(seat), to: target,
                               width: bookWidth, toAngle: angle, fromScale: 1.7, toScale: 1,
                               lift: 60, duration: 0.7, delay: Double(i) * 0.07)
            }
            let span = await launch(specs)
            books[seat, default: []].append(rank)
            fresh = FreshBook(seat: seat, rank: rank)
            TableSFX.shared.play(.cardSlide)
            await pause(max(0.3, GoFishTiming.book - span))
            fresh = nil

        case .refilled(let seat, let count):
            pool = max(0, pool - count)
            show(KidsCallout(title: "\(name(seat)) draws \(count) fresh cards", tone: .soft))
            TableSFX.shared.play(.cardDeal)
            let specs = (0..<count).map { i in
                KidsFlightSpec(card: nil, face: .back, from: poolPoint, to: geo.handPoint(seat),
                               width: cardWidth * 0.9, lift: 40, duration: 0.55, delay: Double(i) * 0.09)
            }
            await launch(specs)
            counts[seat] = (counts[seat] ?? 0) + count
            await pause(0.3)

        case .turnChanged(let seat):
            turn = seat
            withAnimation(.easeOut(duration: 0.3)) {
                focus = []
                callout = nil
            }

        case .gameOver:
            TableSFX.shared.play(.fanfareWin)

        case .illegalAttempt:
            break
        }
    }

    private func deal(_ handCounts: [Int: Int], poolCount: Int) async {
        let geo = geometry
        counts = Dictionary(uniqueKeysWithValues: (0..<playerCount).map { ($0, 0) })
        pool = poolCount
        TableSFX.shared.play(.shuffle)
        await pause(0.7)
        TableSFX.shared.play(.cardDeal)
        let rounds = handCounts.values.max() ?? 0
        var specs: [KidsFlightSpec] = []
        var order = 0
        for round in 0..<rounds {
            for seat in 0..<playerCount where round < (handCounts[seat] ?? 0) {
                let delay = Double(order) * GoFishTiming.dealStagger
                specs.append(KidsFlightSpec(card: nil, face: .back, from: poolPoint, to: geo.handPoint(seat),
                                            width: cardWidth * 0.85, lift: 30,
                                            duration: GoFishTiming.dealFlight, delay: delay))
                later(KidsMotion.pause(delay + GoFishTiming.dealFlight, reduce: reduceMotion)) { [weak self] in
                    guard let self else { return }
                    self.counts[seat] = (self.counts[seat] ?? 0) + 1
                }
                order += 1
            }
        }
        await launch(specs)
        // Opening books (rare) are laid silently by the engine.
        if let game {
            counts = game.engine.handCounts()
            books = game.engine.state.books
            turn = game.engine.state.turnSeat
        }
        await pause(0.4)
    }
}

// MARK: - Table

/// The Go Fish felt: the pool in the middle, each seat's plate + rail hand
/// with its laid books beside it, and the ask/answer narration in serif.
/// Registered through `SideGameRegistry`; reads the host's `GoFishHost`.
struct GoFishTableView: View {
    @Bindable var host: GameHostController
    var onClose: (() -> Void)? = nil

    var body: some View {
        let _ = host.stateVersion
        if let game = host.sideGame as? GoFishHost {
            GoFishTableContent(game: game, controllerNames: host.sideGameSeatNames,
                               onPlayAgain: { host.restartSideGame() }, onClose: onClose)
                .id(ObjectIdentifier(game))
        } else {
            Color.clear
        }
    }
}

struct GoFishTableContent: View {
    let game: GoFishHost
    var controllerNames: [Int: String] = [:]
    var onPlayAgain: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var stage = GoFishStage()
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    var body: some View {
        let _ = game.revision
        GeometryReader { geo in
            ZStack {
                content
                    .frame(width: geo.size.width, height: geo.size.height)
            }
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
            // Pool in the middle of the felt.
            KidsPoolPile(count: stage.pool, cardWidth: stage.cardWidth)
                .position(stage.poolPoint)

            if let card = stage.revealCard {
                CardView(card: card, faceUp: true, elevation: 0.35)
                    .frame(width: stage.cardWidth)
                    .rotationEffect(.degrees(4))
                    .position(stage.revealPoint)
                    .transition(.opacity)
            }

            // Plates + rail hands.
            ForEach(0..<stage.playerCount, id: \.self) { seat in
                let bookCount = stage.books[seat]?.count ?? 0
                KidsSeatContainer(geometry: geometry, seat: seat, name: game.name(seat),
                                  isTurn: stage.turn == seat && !stage.finished,
                                  isFocus: stage.focus.contains(seat) && stage.turn != seat,
                                  stat: bookCount == 1 ? "1 book" : "\(bookCount) books",
                                  handCount: stage.counts[seat] ?? 0)
            }

            // Laid books.
            ForEach(0..<stage.playerCount, id: \.self) { seat in
                let list = stage.books[seat] ?? []
                ForEach(Array(list.enumerated()), id: \.element) { index, rank in
                    KidsCardStack(cards: KidsCards.book(rank: rank), width: stage.bookWidth,
                                  glow: stage.fresh == GoFishStage.FreshBook(seat: seat, rank: rank))
                        .rotationEffect(geometry.angle(seat))
                        .position(geometry.world(seat, local: stage.laidLayout.local(
                            index: index, total: list.count, containerHeight: geometry.containerHeight)))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel("\(game.name(seat)) has a book of \(GoFishText.plural(rank))")
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: list.count)
            }

            // Narration.
            Group {
                if let callout = stage.callout {
                    KidsCalloutView(callout: callout).id(callout.id)
                } else if !stage.finished, !stage.busy {
                    Text("\(game.name(stage.turn)) is choosing who to ask…")
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

            GameHUD(title: "Go Fish", onExit: { onClose?() }, toggles: [])
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(30)
        }
        .animation(.easeInOut(duration: 0.25), value: stage.finished)
    }

    // MARK: end of game

    private var finishedPanel: some View {
        let state = game.engine.state
        let winners = state.winners
        let counts = state.books.mapValues(\.count)
        let best = counts.values.max() ?? 0
        let title: String
        if winners.count > 1 {
            title = "\(KidsRank.joined(winners.map { game.name($0) })) tie with \(best) books!"
        } else if let w = winners.first {
            title = "\(game.name(w)) wins with \(best) books!"
        } else {
            title = "Good game!"
        }
        let order = (0..<state.playerCount).sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        return ScorecardPanel(title: title) {
            ForEach(order, id: \.self) { seat in
                HStack {
                    Circle().fill(PlayerPalette.color(seat)).frame(width: 12, height: 12)
                    Text(game.name(seat)).font(.system(.title3, design: .serif))
                    Spacer()
                    Text((counts[seat] ?? 0) == 1 ? "1 book" : "\(counts[seat] ?? 0) books")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(winners.contains(seat) ? CardStyle.gold : CardStyle.stockTop)
            }
        } action: {
            HStack(spacing: 14) {
                if let onPlayAgain {
                    Button(action: onPlayAgain) {
                        Text("Play again")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 30).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                }
                Button { onClose?() } label: {
                    Text("Back to menu")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(CardStyle.stockTop)
            }
        }
    }
}

// MARK: - Previews

private func goFishPreviewSeats(_ n: Int, bots: Bool) -> [SeatSpec] {
    let names = ["Chase", "Vinny", "Mae", "Ruthie"]
    return (0..<n).map { SeatSpec(id: $0, name: names[$0], isBot: bots) }
}

/// An all-bot 4-player game that plays itself: the narration, the flights,
/// the books, and the winner panel, start to finish.
#Preview("Go Fish - 4 bots playing", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        GoFishTableContent(game: GoFishHost(seats: goFishPreviewSeats(4, bots: true), seed: 11))
    }
}

#Preview("Go Fish - 2 bots playing", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        GoFishTableContent(game: GoFishHost(seats: goFishPreviewSeats(2, bots: true), seed: 5))
    }
}
