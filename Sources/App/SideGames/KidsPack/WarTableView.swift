import SwiftUI

// MARK: - Presentation stage

/// What the War table SHOWS. The engine resolves a whole battle (wars and
/// all) in one call; the stage replays it as drama: both cards fly out of
/// their piles and land face-up, the higher card glows, and the winner
/// sweeps the lot. A tie slaps three cards down and flips a fourth,
/// recursively, for as many wars as the battle contained.
@MainActor
@Observable
final class WarStage {
    struct Placed: Identifiable {
        let id = UUID()
        var card: Card?
        var seat: Int
        var faceDown: Bool
        var depth: Int
        var position: CGPoint
        var angle: Double
    }

    var size: CGSize = .zero
    var counts: [Int: Int] = [0: 0, 1: 0]
    var round = 0
    var maxRounds = WarEngine.defaultMaxRounds
    var placed: [Placed] = []
    var flights: [KidsFlightSpec] = []
    var callout: KidsCallout?
    var sweeping = false
    var sweepTarget: CGPoint = .zero
    var glowSeat: Int?
    var dimSeat: Int?
    var warDepth = 0
    var finished = false
    var busy = false
    var reduceMotion = false

    @ObservationIgnored let queue = KidsBeatQueue()
    @ObservationIgnored private(set) var lastSeq = 0
    @ObservationIgnored private weak var game: WarHost?

    // MARK: geometry

    var cardWidth: CGFloat { TableGeometry.tableCardWidth(for: size) }
    var cardHeight: CGFloat { cardWidth * 1.4 }
    func pilePoint(_ seat: Int) -> CGPoint {
        seat == 0 ? CGPoint(x: size.width * 0.15, y: size.height * 0.76)
                  : CGPoint(x: size.width * 0.85, y: size.height * 0.24)
    }
    func spot(_ seat: Int) -> CGPoint {
        CGPoint(x: size.width * 0.5 + (seat == 0 ? -1 : 1) * cardWidth * 0.62, y: size.height * 0.46)
    }
    /// Where a face-down war card sits: a short stack outboard of the flip spot.
    func downPoint(seat: Int, depth: Int, index: Int) -> CGPoint {
        let s = spot(seat)
        let dir: CGFloat = seat == 0 ? -1 : 1
        let vertical: CGFloat = seat == 0 ? 1 : -1
        return CGPoint(x: s.x + dir * (cardWidth * 1.08 + CGFloat(depth - 1) * 9),
                       y: s.y + vertical * (CGFloat(index) - 1) * 22)
    }
    func flipPoint(seat: Int, depth: Int) -> CGPoint {
        let s = spot(seat)
        return CGPoint(x: s.x + CGFloat(depth) * 5, y: s.y + CGFloat(depth) * 4)
    }
    var calloutPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.69) }

    private func name(_ seat: Int) -> String { game?.name(seat) ?? "Player \(seat + 1)" }

    // MARK: lifecycle

    func attach(_ game: WarHost) {
        self.game = game
        maxRounds = game.engine.state.maxRounds
        queue.onIdle = { [weak self] in self?.settle() }
        if let batch = game.lastBatch, batch.seq == 1 {
            counts = [0: 0, 1: 0]
            round = 0
            finished = false
            ingest(batch)
        } else {
            lastSeq = game.lastBatch?.seq ?? 0
            settle()
        }
    }

    func ingest(_ batch: KidsEventBatch<WarEvent>) {
        guard batch.seq > lastSeq else { return }
        lastSeq = batch.seq
        busy = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            await self.play(batch.events)
        }
    }

    func settle() {
        guard let game else { return }
        let state = game.engine.state
        counts = game.engine.counts()
        round = state.round
        placed = []
        flights = []
        sweeping = false
        glowSeat = nil
        dimSeat = nil
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

    private func tilt(_ salt: String) -> Double { TableGeometry.jitterDegrees(cardID: salt) * 0.5 }

    // MARK: the battle

    private func play(_ events: [WarEvent]) async {
        var i = 0
        while i < events.count {
            switch events[i] {
            case .dealt:
                await deal()
                i += 1

            case .flipped(let seat, let card, _, let depth):
                // Both flips of a depth are thrown together.
                var pair: [(seat: Int, card: Card)] = [(seat, card)]
                if i + 1 < events.count, case .flipped(let seat2, let card2, _, let depth2) = events[i + 1],
                   depth2 == depth {
                    pair.append((seat2, card2))
                }
                await flip(pair, depth: depth)
                i += pair.count

            case .warDeclared:
                await war()
                i += 1

            case .faceDownPlaced:
                // Gather the consecutive per-seat events so both seats slap
                // their cards down at the same time.
                var downs: [(seat: Int, count: Int)] = []
                while i < events.count, case .faceDownPlaced(let seat, let count) = events[i] {
                    downs.append((seat, count))
                    i += 1
                }
                await slap(downs)

            case .captured:
                var takes: [(seat: Int, count: Int)] = []
                while i < events.count, case .captured(let seat, let count, _) = events[i] {
                    takes.append((seat, count))
                    i += 1
                }
                await capture(takes)

            case .forfeited(let seat, _):
                let other = 1 - seat
                show(KidsCallout(title: "\(name(seat)) has no cards left to flip",
                                 subtitle: "\(name(other)) takes the pile", tone: .good))
                await pause(WarTiming.forfeit)
                i += 1

            case .gameOver:
                TableSFX.shared.play(.fanfareWin)
                i += 1

            case .illegalAttempt:
                i += 1
            }
        }
    }

    private func deal() async {
        counts = [0: 0, 1: 0]
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        TableSFX.shared.play(.shuffle)
        await pause(0.7)
        TableSFX.shared.play(.cardDeal)
        var specs: [KidsFlightSpec] = []
        for n in 0..<52 {
            let seat = n % 2
            let delay = Double(n) * WarTiming.dealStagger
            specs.append(KidsFlightSpec(card: nil, face: .back, from: center, to: pilePoint(seat),
                                        width: cardWidth * 0.8, lift: 20,
                                        duration: WarTiming.dealFlight, delay: delay))
            let landing = KidsMotion.pause(delay + WarTiming.dealFlight, reduce: reduceMotion)
            Task { @MainActor [weak self] in
                await kidsWait(landing)
                self?.counts[seat] = (self?.counts[seat] ?? 0) + 1
            }
        }
        await launch(specs)
        counts = game?.engine.counts() ?? [0: 26, 1: 26]
        await pause(0.4)
    }

    private func flip(_ pair: [(seat: Int, card: Card)], depth: Int) async {
        glowSeat = nil
        dimSeat = nil
        TableSFX.shared.play(.cardSlide, intensity: 0.8)
        let specs = pair.map { item in
            KidsFlightSpec(card: item.card, face: .flipUp, from: pilePoint(item.seat),
                           to: flipPoint(seat: item.seat, depth: depth), width: cardWidth,
                           toAngle: tilt(item.card.id), lift: 70, duration: WarTiming.flipFlight)
        }
        for item in pair { counts[item.seat] = max(0, (counts[item.seat] ?? 0) - 1) }
        later(WarTiming.flipFlight * 0.5) { TableSFX.shared.play(.cardFlip) }
        await launch(specs)
        for item in pair {
            placed.append(Placed(card: item.card, seat: item.seat, faceDown: false, depth: depth,
                                 position: flipPoint(seat: item.seat, depth: depth), angle: tilt(item.card.id)))
        }
        if pair.count == 2 {
            let ra = pair[0].card.rank ?? 0, rb = pair[1].card.rank ?? 0
            if ra != rb {
                let high = ra > rb ? pair[0].seat : pair[1].seat
                withAnimation(.easeOut(duration: 0.3)) {
                    glowSeat = high
                    dimSeat = 1 - high
                }
                let word = { (r: Int) in KidsRank.singular(r) }
                show(KidsCallout(title: "\(KidsRank.symbol(max(ra, rb))) beats \(KidsRank.symbol(min(ra, rb)))",
                                 subtitle: "\(word(max(ra, rb)).capitalized) over \(word(min(ra, rb)))", tone: .soft))
            } else {
                withAnimation(.easeOut(duration: 0.3)) { glowSeat = nil; dimSeat = nil }
                show(KidsCallout(title: "A tie - \(KidsRank.symbol(ra)) and \(KidsRank.symbol(rb))", tone: .soft))
            }
        }
        await pause(WarTiming.compare)
    }

    private func war() async {
        warDepth += 1
        withAnimation(.easeOut(duration: 0.2)) { glowSeat = nil; dimSeat = nil }
        show(KidsCallout(title: "WAR!", subtitle: "Three cards down, then flip the next one", tone: .big))
        TableSFX.shared.play(.tableKnock, intensity: 1.0)
        later(0.25) { TableSFX.shared.play(.tableKnock, intensity: 0.8) }
        await pause(WarTiming.warCallout)
    }

    private func slap(_ downs: [(seat: Int, count: Int)]) async {
        let warDepth = max(1, self.warDepth)
        var specs: [KidsFlightSpec] = []
        var landed: [Placed] = []
        for down in downs {
            counts[down.seat] = max(0, (counts[down.seat] ?? 0) - down.count)
            for k in 0..<down.count {
                let target = downPoint(seat: down.seat, depth: warDepth, index: k)
                let angle = Double(k - 1) * 4 + tilt("\(down.seat)-\(warDepth)-\(k)") * 0.3
                specs.append(KidsFlightSpec(card: nil, face: .back, from: pilePoint(down.seat), to: target,
                                            width: cardWidth, toAngle: angle, lift: 36,
                                            duration: WarTiming.downFlight, delay: Double(k) * WarTiming.downStagger))
                landed.append(Placed(card: nil, seat: down.seat, faceDown: true, depth: warDepth,
                                     position: target, angle: angle))
                later(KidsMotion.pause(Double(k) * WarTiming.downStagger + WarTiming.downFlight, reduce: reduceMotion)) {
                    TableSFX.shared.play(.tableKnock, intensity: 0.6)
                }
            }
        }
        TableSFX.shared.play(.cardDeal)
        await launch(specs)
        placed.append(contentsOf: landed)
        await pause(WarTiming.downSettle)
    }

    private func capture(_ takes: [(seat: Int, count: Int)]) async {
        guard let first = takes.first else { return }
        let winner = first.seat
        let total = takes.reduce(0) { $0 + $1.count }
        show(KidsCallout(title: takes.count > 1 ? "The pile is split" : "\(name(winner)) takes \(total) cards",
                         tone: .good))
        TableSFX.shared.play(.trickSweep)
        sweepTarget = pilePoint(winner)
        withAnimation(.easeIn(duration: reduceMotion ? 0.3 : WarTiming.sweep - 0.1)) { sweeping = true }
        await kidsWait(reduceMotion ? 0.35 : WarTiming.sweep)
        placed = []
        sweeping = false
        glowSeat = nil
        dimSeat = nil
        for take in takes { counts[take.seat] = (counts[take.seat] ?? 0) + take.count }
        round += 1
        warDepth = 0
        await pause(WarTiming.counted)
    }
}

// MARK: - Table

/// The War felt: two piles, the battle in the middle, the winner sweeping
/// the cards. Registered through `SideGameRegistry`; reads the host's
/// `WarHost` and, for a tap-to-flip table, sends `.flip` as the table.
struct WarTableView: View {
    @Bindable var host: GameHostController
    var onClose: (() -> Void)? = nil

    var body: some View {
        let _ = host.stateVersion
        if let game = host.sideGame as? WarHost {
            WarTableContent(game: game, controllerNames: host.sideGameSeatNames,
                            onFlip: {
                                if let payload = KidsWire.payload(WarEngine.kind, WarAction.flip) {
                                    host.sideGameTableAction(payload)
                                }
                            },
                            onPlayAgain: { host.restartSideGame() }, onClose: onClose)
                .id(ObjectIdentifier(game))
        } else {
            Color.clear
        }
    }
}

struct WarTableContent: View {
    let game: WarHost
    var controllerNames: [Int: String] = [:]
    /// Defaults to the host itself (previews); the live wrapper routes
    /// through `GameHostController.sideGameTableAction`.
    var onFlip: (() -> Void)? = nil
    var onPlayAgain: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var stage = WarStage()
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

    private var canTapToFlip: Bool {
        !game.runsItself && !stage.finished && !stage.busy && game.isReady
    }

    private func flipNow() {
        guard canTapToFlip else { return }
        Haptics.arm()
        if let onFlip {
            onFlip()
        } else if let payload = KidsWire.payload(WarEngine.kind, WarAction.flip) {
            game.handle(action: payload, from: -1)
        }
    }

    @ViewBuilder
    private var content: some View {
        let geometry = KidsSeatGeometry(size: stage.size, count: 2)
        ZStack {
            // Tap-to-flip zone: the middle of the felt.
            Color.clear
                .frame(width: stage.size.width * 0.5, height: stage.size.height * 0.5)
                .contentShape(Rectangle())
                .position(x: stage.size.width * 0.5, y: stage.size.height * 0.5)
                .onTapGesture { flipNow() }
                .accessibilityHidden(true)

            ForEach(0..<2, id: \.self) { seat in
                WarPileView(count: stage.counts[seat] ?? 0, width: stage.cardWidth * 0.95)
                    .position(stage.pilePoint(seat))
            }

            ForEach(0..<2, id: \.self) { seat in
                KidsSeatPlate(name: game.name(seat), colorIndex: seat,
                              isTurn: stage.glowSeat == seat,
                              stat: "\(stage.counts[seat] ?? 0) cards")
                    .rotationEffect(geometry.angle(seat))
                    .position(geometry.anchorPoint(seat))
            }

            // Cards sitting on the felt.
            let topDepth = stage.placed.map(\.depth).max() ?? 0
            ForEach(Array(stage.placed.enumerated()), id: \.element.id) { order, item in
                let isWinner = stage.glowSeat == item.seat && !item.faceDown && item.depth == topDepth
                let isLoser = stage.dimSeat == item.seat && !item.faceDown && item.depth == topDepth
                CardView(card: item.card ?? KidsCards.back, faceUp: !item.faceDown && item.card != nil,
                         elevation: isWinner ? 0.4 : 0)
                    .frame(width: stage.cardWidth)
                    .shadow(color: CardStyle.gold.opacity(isWinner ? 0.9 : 0), radius: isWinner ? 16 : 0)
                    .brightness(isLoser ? -0.22 : 0)
                    .rotationEffect(.degrees(item.angle))
                    .scaleEffect(stage.sweeping ? 0.82 : 1)
                    .opacity(stage.sweeping ? 0.0 : 1)
                    .position(stage.sweeping ? stage.sweepTarget : item.position)
                    .animation(.easeIn(duration: 0.65).delay(Double(order) * 0.035), value: stage.sweeping)
                    .zIndex(Double(order) * 0.1)
            }

            Group {
                if let callout = stage.callout {
                    KidsCalloutView(callout: callout).id(callout.id)
                } else if canTapToFlip {
                    flipPrompt
                }
            }
            .position(stage.calloutPoint)
            .zIndex(5)

            KidsFlightLayer(flights: stage.flights)
                .zIndex(8)

            battleChip
                .zIndex(9)

            if stage.finished {
                finishedPanel
                    .zIndex(20)
            }

            GameHUD(title: "War", onExit: { onClose?() }, toggles: [])
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(30)
        }
        .animation(.easeInOut(duration: 0.25), value: stage.finished)
    }

    private var flipPrompt: some View {
        Button(action: flipNow) {
            Text("Tap to flip")
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, 34).padding(.vertical, 14)
                .background(Capsule().fill(CardStyle.gold))
                .shadow(color: CardStyle.gold.opacity(0.6), radius: 14)
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
        .accessibilityHint("Both players flip their top card")
    }

    private var battleChip: some View {
        Text("Battle \(stage.round) of \(stage.maxRounds)")
            .font(.system(.subheadline, design: .serif).weight(.semibold).monospacedDigit())
            .foregroundStyle(CardStyle.gold)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.4))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .allowsHitTesting(false)
    }

    // MARK: end of game

    private var finishedPanel: some View {
        let state = game.engine.state
        let counts = game.engine.counts()
        let c0 = counts[0] ?? 0, c1 = counts[1] ?? 0
        let title: String
        let highlight: String
        if state.endReason == .roundCap {
            if let w = state.winner {
                title = "\(game.name(w)) wins!"
                highlight = "Time's up after \(state.round) battles: \(max(c0, c1)) cards to \(min(c0, c1))"
            } else {
                title = "It's a tie!"
                highlight = "Time's up after \(state.round) battles, \(c0) cards each"
            }
        } else if let w = state.winner {
            title = "\(game.name(w)) wins!"
            highlight = "Every card, in \(state.round) battles"
        } else {
            title = "Good game!"
            highlight = ""
        }
        let rows = [0, 1].sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }.map { seat in
            RecapRow(id: seat, name: game.name(seat), colorIndex: seat,
                     score: "\(counts[seat] ?? 0) cards", isWinner: state.winner == seat)
        }
        return GameRecapCard(title: title, rows: rows, highlight: highlight, kidMode: true,
                             rematchLabel: onPlayAgain == nil ? nil : "Rematch",
                             onRematch: onPlayAgain, onDone: { onClose?() })
    }
}

/// A player's pile: a thick stack of backs (thickness follows the count)
/// with the count badge underneath.
struct WarPileView: View {
    let count: Int
    let width: CGFloat

    var body: some View {
        ZStack {
            if count == 0 {
                RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: width), style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(width: width, height: width * 1.4)
            } else {
                ForEach(0..<min(9, max(1, (count + 3) / 4)), id: \.self) { i in
                    CardView(card: KidsCards.back, faceUp: false)
                        .frame(width: width)
                        .offset(x: CGFloat(i) * 0.9, y: -CGFloat(i) * 1.7)
                }
            }
        }
        .frame(width: width + 12, height: width * 1.4 + 14)
        .overlay(alignment: .bottom) {
            Text("\(count)")
                .font(.system(.title3, design: .serif).weight(.bold).monospacedDigit())
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 14).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.45), lineWidth: 1)))
                .offset(y: 24)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) cards in the pile")
    }
}

// MARK: - Previews

private func warPreviewSeats(bots: Bool) -> [SeatSpec] {
    [SeatSpec(id: 0, name: "Chase", isBot: bots), SeatSpec(id: 1, name: "Vinny", isBot: bots)]
}

/// Two bots playing a full game of War, wars and all.
#Preview("War - bots playing", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        WarTableContent(game: WarHost(seats: warPreviewSeats(bots: true), seed: 7, maxRounds: 40))
    }
}

/// Humans seated: the tap-to-flip prompt on the felt.
#Preview("War - tap to flip", traits: .landscapeLeft) {
    ZStack {
        TableSurface()
        WarTableContent(game: WarHost(seats: warPreviewSeats(bots: false), seed: 21))
    }
}
