import SwiftUI

/// One card mid-flight: the geometry it's riding plus enough to render it
/// (`SolitaireMotion`/`SolitaireFlightCardView` do the actual math — see
/// that file's header for why a single `progress` scalar, not separate x/y
/// state, is the whole point). Keyed by card id in `SolitaireView.inFlight`
/// — while a card's id is a key there, every static pile (`tableauColumnView`,
/// `wasteView`, `foundationView`) skips rendering it, and the flight
/// overlay renders it instead. That's the entire mechanism behind every
/// animated moment on this board: the engine mutates state instantly and
/// synchronously; the flight overlay is purely a temporary visual stand-in
/// that catches the eye up to where the card already is.
private struct InFlightCard {
    var flight: SolitaireMotion.Flight
    var progress: CGFloat
    let card: Card
    let faceUp: Bool
}

private extension CGPoint {
    func offsetBy(_ size: CGSize) -> CGPoint { CGPoint(x: x + size.width, y: y + size.height) }
}

/// A self-contained, full-screen Klondike solitaire table.
///
/// Contract: `SolitaireView(onClose: @escaping () -> Void)`. Draws its own
/// felt (via the shared `TableSurface`, the same backdrop every other
/// table screen uses) and owns its entire game loop — the menu/lead worker
/// wiring this in only needs to construct it and supply `onClose`; nothing
/// else about solitaire's internal state ever needs to leak out. See
/// `SolitaireDemo` for the `-demoSolitaire` sim-verify hook and how a
/// router would wire it in.
struct SolitaireView: View {
    private let onClose: () -> Void

    @State private var game: SolitaireGame
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    // Opening deal ceremony.
    @State private var dealCompleted: Bool

    // Every card currently mid-animation — see `InFlightCard` above.
    @State private var inFlight: [String: InFlightCard] = [:]

    // Live drag.
    @State private var dragSource: SolitaireMoveSource?
    @State private var dragRunIDs: [String] = []
    @State private var dragCardOrigins: [String: CGPoint] = [:]
    @State private var dragTranslation: CGSize = .zero

    // Stock → waste 3D flip.
    @State private var flipCard: Card?
    @State private var flipFaceUp = false
    @State private var flipAngle: Double = 0
    @State private var flipSlide: CGFloat = 0
    @State private var flipLift: CGFloat = 0

    // Autocomplete / win.
    @State private var isCascading = false
    @State private var showWinCelebration = false

    // Chrome.
    @State private var showRulesSheet = false
    @State private var showNewDealConfirm = false
    @State private var showCloseDial = false
    @State private var closeRingProgress: CGFloat = 0
    @State private var boardSize: CGSize = .zero

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        if SolitaireDemo.wantsDemo {
            // The demo harness wants a static, already-mid-game board for
            // screenshotting — skip the deal ceremony entirely rather than
            // racing a screenshot against a multi-second animation.
            _game = State(initialValue: SolitaireGame(engine: SolitaireDemo.makeDemoEngine()))
            _dealCompleted = State(initialValue: true)
        } else {
            _game = State(initialValue: SolitaireGame(seed: UInt64.random(in: UInt64.min...UInt64.max)))
            _dealCompleted = State(initialValue: false)
        }
    }

    private var drawModeBinding: Binding<SolitaireDrawMode> {
        Binding(get: { game.state.drawMode }, set: { game.setDrawMode($0) })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TableSurface()
                deadFeltTapCatcher
                boardContent(size: geo.size)
                    .allowsHitTesting(dealCompleted && !isCascading)
                stockFlipOverlay(size: geo.size)
                flightOverlay(size: geo.size)
                chromeOverlay(size: geo.size)
                if showWinCelebration {
                    SolitaireWinCelebration()
                        .zIndex(700)
                }
            }
            .onAppear {
                boardSize = geo.size
                runOpeningDeal(size: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in boardSize = newSize }
        }
        .sheet(isPresented: $showRulesSheet) {
            SolitaireRulesSheet(drawMode: drawModeBinding, onNewDeal: { showNewDealConfirm = true })
        }
        .confirmationDialog("Start a new deal? Your current game will be lost.",
                            isPresented: $showNewDealConfirm, titleVisibility: .visible) {
            Button("New Deal", role: .destructive) { startNewDeal() }
            Button("Cancel", role: .cancel) {}
        }
        .persistentSystemOverlays(.hidden)
    }

    private var deadFeltTapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tick()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showCloseDial.toggle()
                }
                if showCloseDial {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation { showCloseDial = false }
                    }
                }
            }
    }

    // MARK: - Board

    @ViewBuilder
    private func boardContent(size: CGSize) -> some View {
        let cardSize = SolitaireLayout.cardSize(for: size)
        stockView(size: size, cardSize: cardSize)
        wasteView(size: size, cardSize: cardSize)
        ForEach(Suit.allCases, id: \.self) { suit in
            foundationView(suit: suit, size: size, cardSize: cardSize)
        }
        ForEach(0..<7, id: \.self) { column in
            tableauColumnView(column: column, size: size, cardSize: cardSize)
        }
    }

    // MARK: - Stock

    private func stockView(size: CGSize, cardSize: CGSize) -> some View {
        let count = game.state.stock.count
        let center = SolitaireLayout.stockCenter(for: size)
        let radius = CardStyle.cornerRadius(width: cardSize.width)
        return ZStack {
            if count == 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.30), lineWidth: 1.5)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay(
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: cardSize.width * 0.24))
                            .foregroundStyle(CardStyle.gold.opacity(game.state.waste.isEmpty ? 0.12 : 0.55))
                    )
            } else {
                // Paper-edge stack language: buried cards show only their
                // stock edge, only the top card wears the printed back —
                // own implementation of the same idea `DeckAndTrumpView`
                // uses for the trick-taking felt (that file isn't in this
                // worker's allowlist, so this is written independently).
                let layers = min(3, count)
                ForEach(0..<layers, id: \.self) { layer in
                    if layer == layers - 1 {
                        CardView(card: Card(id: "solStockTop", kind: .standard(suit: .spades, rank: 2)), faceUp: false)
                            .frame(width: cardSize.width)
                            .offset(x: CGFloat(layer) * -1.6, y: CGFloat(layer) * -2.0)
                    } else {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(CardStyle.stockBottom)
                            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
                            .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
                            .frame(width: cardSize.width)
                            .offset(x: CGFloat(layer) * -1.6, y: CGFloat(layer) * -2.0)
                    }
                }
            }
            Text("\(count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
                .offset(y: cardSize.height * 0.62)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .position(center)
        .contentShape(Rectangle())
        .onTapGesture { tapStock(size: size) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 0
            ? (game.state.waste.isEmpty ? "Stock, empty" : "Stock, empty, double tap to redeal from the waste")
            : "Stock, \(count) cards, double tap to draw")
        .accessibilityAddTraits(.isButton)
    }

    private func tapStock(size: CGSize) {
        guard dealCompleted, !isCascading else { return }
        if game.state.stock.isEmpty {
            guard !game.state.waste.isEmpty else { return }
            Haptics.tick()
            _ = game.draw()
            TableSFX.shared.play(.shuffle)
            return
        }
        guard let cardToFlip = game.state.stock.last else { return }
        Haptics.tick()
        _ = game.draw()
        runStockFlip(card: cardToFlip, size: size)
    }

    /// A real 3D flip: turn edge-on, swap the printed side while invisible,
    /// finish the turn — same two-phase idiom `DeckAndTrumpView`'s trump
    /// reveal uses (own implementation, that file isn't in this worker's
    /// allowlist), sliding a touch toward the waste as it turns.
    private func runStockFlip(card: Card, size: CGSize) {
        guard !motionReduced else {
            TableSFX.shared.play(.cardFlip)
            return
        }
        flipCard = card
        flipFaceUp = false
        flipAngle = 180
        flipSlide = 0
        flipLift = -8
        withAnimation(.easeIn(duration: 0.16)) {
            flipAngle = 90
            flipSlide = 0.5
            flipLift = -16
        } completion: {
            TableSFX.shared.play(.cardFlip)
            flipFaceUp = true
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.18)) {
                flipAngle = 0
                flipSlide = 1
                flipLift = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { flipCard = nil }
        }
    }

    @ViewBuilder
    private func stockFlipOverlay(size: CGSize) -> some View {
        if let flipCard {
            let stockC = SolitaireLayout.stockCenter(for: size)
            let wasteC = SolitaireLayout.wasteCenter(for: size)
            let x = stockC.x + (wasteC.x - stockC.x) * flipSlide
            let y = stockC.y + (wasteC.y - stockC.y) * flipSlide + flipLift
            CardView(card: flipCard, faceUp: flipFaceUp, elevation: 0.3)
                .frame(width: SolitaireLayout.cardSize(for: size).width)
                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .position(x: x, y: y)
                .allowsHitTesting(false)
                .zIndex(650)
        }
    }

    // MARK: - Waste

    private func wasteView(size: CGSize, cardSize: CGSize) -> some View {
        let waste = game.state.waste
        let center = SolitaireLayout.wasteCenter(for: size)
        let visibleCount = min(waste.count, game.state.drawMode == .drawThree ? 3 : 1)
        let visible = Array(waste.suffix(visibleCount))
        return ZStack {
            if visible.isEmpty {
                RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cardSize.width), style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.16), lineWidth: 1)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .position(center)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, c in
                let isTop = i == visible.count - 1
                let hidden = isTop && (flipCard != nil || inFlight[c.id] != nil)
                if !hidden {
                    let isDraggingThis = isTop && dragSource != nil && isWasteSource()
                    CardView(card: c, faceUp: true, elevation: isDraggingThis ? 0.85 : 0)
                        .frame(width: cardSize.width)
                        .offset(x: CGFloat(i) * 14)
                        .offset(isDraggingThis ? dragTranslation : .zero)
                        .zIndex(isDraggingThis ? 500 : Double(i))
                        .position(center)
                        .gesture(wasteDragGesture(card: c, isTop: isTop, size: size))
                        .onTapGesture(count: 2) {
                            guard isTop else { return }
                            attemptAutoFoundation(source: .waste, card: c, entry: center, size: size)
                        }
                        .accessibilityLabel(isTop ? "Waste, \(c.accessibleName)" : "")
                        .accessibilityHint(isTop ? "Double tap to send to its foundation" : "")
                }
            }
        }
    }

    private func isWasteSource() -> Bool {
        if case .waste = dragSource { return true }
        return false
    }

    private func wasteDragGesture(card: Card, isTop: Bool, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isTop, dealCompleted, !isCascading else { return }
                if dragSource == nil {
                    dragSource = .waste
                    dragRunIDs = [card.id]
                    dragCardOrigins = [card.id: SolitaireLayout.wasteCenter(for: size)]
                    Haptics.tick()
                }
                guard isWasteSource() else { return }
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard isTop, isWasteSource() else { return }
                endDrag(at: value.location, size: size)
            }
    }

    // MARK: - Foundations

    private func foundationView(suit: Suit, size: CGSize, cardSize: CGSize) -> some View {
        let center = SolitaireLayout.foundationCenter(suit, boardSize: size)
        let pile = game.state.foundations[suit] ?? []
        let visibleTop = pile.last(where: { inFlight[$0.id] == nil })
        return ZStack {
            RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cardSize.width), style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.22), lineWidth: 1)
                .frame(width: cardSize.width, height: cardSize.height)
                .overlay(
                    Text(suit.symbol)
                        .font(.system(size: cardSize.width * 0.30))
                        .foregroundStyle(CardStyle.gold.opacity(0.22))
                )
            if let top = visibleTop {
                CardView(card: top, faceUp: true, elevation: 0)
                    .frame(width: cardSize.width)
                    .transition(.opacity)
            }
        }
        .position(center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suit.rawValue.capitalized) foundation, \(pile.count) of 13 home")
    }

    // MARK: - Tableau

    private func tableauColumnView(column: Int, size: CGSize, cardSize: CGSize) -> some View {
        let pile = game.state.tableau[column]
        return ZStack(alignment: .top) {
            if pile.isEmpty {
                RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cardSize.width), style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.16), lineWidth: 1)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .position(SolitaireLayout.tableauEmptyCenter(column: column, boardSize: size))
                    .accessibilityHidden(true)
            }
            ForEach(Array(pile.enumerated()), id: \.element.id) { index, sc in
                if inFlight[sc.id] == nil {
                    tableauCard(column: column, index: index, pile: pile, sc: sc, size: size, cardSize: cardSize)
                }
            }
        }
    }

    private func tableauCard(column: Int, index: Int, pile: [SolitaireCard], sc: SolitaireCard,
                             size: CGSize, cardSize: CGSize) -> some View {
        let base = SolitaireLayout.tableauCardCenter(column: column, index: index, pile: pile, boardSize: size)
        let isBeingDragged = dragRunIDs.contains(sc.id)
        return CardView(card: sc.card, faceUp: sc.faceUp, elevation: isBeingDragged ? 0.85 : 0)
            .frame(width: cardSize.width)
            .position(base)
            .offset(isBeingDragged ? dragTranslation : .zero)
            .zIndex(isBeingDragged ? 500 + Double(index) : Double(index))
            .transition(.opacity)
            .gesture(tableauDragGesture(column: column, index: index, size: size))
            .onTapGesture(count: 2) {
                guard sc.faceUp, index == pile.count - 1 else { return }
                attemptAutoFoundation(source: .tableau(column: column, cardID: sc.id), card: sc.card,
                                      entry: base, size: size)
            }
            .accessibilityLabel(sc.faceUp ? sc.card.accessibleName : "Face-down card")
    }

    private func tableauDragGesture(column: Int, index: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard dealCompleted, !isCascading else { return }
                let pile = game.state.tableau[column]
                guard pile.indices.contains(index), pile[index].faceUp else { return }
                if dragSource == nil {
                    let run = Array(pile[index...])
                    dragSource = .tableau(column: column, cardID: pile[index].id)
                    dragRunIDs = run.map(\.id)
                    dragCardOrigins = Dictionary(uniqueKeysWithValues: run.enumerated().map { offset, sc in
                        (sc.id, SolitaireLayout.tableauCardCenter(column: column, index: index + offset,
                                                                  pile: pile, boardSize: size))
                    })
                    Haptics.tick()
                }
                guard case .tableau(let sourceColumn, let sourceID) = dragSource,
                      sourceColumn == column, sourceID == pile[index].id else { return }
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard case .tableau(let sourceColumn, let sourceID) = dragSource,
                      sourceColumn == column,
                      game.state.tableau[column].indices.contains(index),
                      sourceID == game.state.tableau[column][index].id else { return }
                endDrag(at: value.location, size: size)
            }
    }

    // MARK: - Drag resolution

    /// Where a drag release should land: foundations checked first (they're
    /// a small, precise target), then the nearest tableau column whose lane
    /// the release point falls within — the whole column counts as a
    /// target, not just its topmost card, so dropping partway down a long
    /// column still registers (same generous-hit-region idea as
    /// `TableGameView.seatHit`).
    private func dropTarget(excluding source: SolitaireMoveSource, at location: CGPoint,
                            size: CGSize) -> SolitaireMoveDestination? {
        let cardWidth = SolitaireLayout.cardSize(for: size).width
        for suit in Suit.allCases {
            let center = SolitaireLayout.foundationCenter(suit, boardSize: size)
            if hypot(center.x - location.x, center.y - location.y) < cardWidth * 0.68 {
                return .foundation(suit)
            }
        }
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for column in 0..<7 {
            if case .tableau(let sourceColumn, _) = source, sourceColumn == column { continue }
            let x = SolitaireLayout.columnX(column, boardSize: size)
            guard abs(x - location.x) < cardWidth * 0.62,
                  location.y > SolitaireLayout.topRowY(for: size) + cardWidth * 0.3 else { continue }
            let distance = abs(x - location.x)
            if distance < bestDistance { bestDistance = distance; best = column }
        }
        return best.map { .tableau(column: $0) }
    }

    private func endDrag(at location: CGPoint, size: CGSize) {
        guard let source = dragSource else { return }
        let runIDs = dragRunIDs
        let origins = dragCardOrigins
        let releaseTranslation = dragTranslation

        guard let destination = dropTarget(excluding: source, at: location, size: size),
              game.legalMove(from: source, to: destination) else {
            rejectDrag()
            return
        }

        // Commit immediately — clearing the live-drag state and handing off
        // to the flight overlay happen in the same update, so there's no
        // gap where the card is neither the drag ghost nor a flight.
        dragSource = nil; dragRunIDs = []; dragCardOrigins = [:]; dragTranslation = .zero
        guard game.attemptMove(from: source, to: destination) else { return }
        Haptics.play()
        settleRun(runIDs: runIDs, origins: origins, releaseTranslation: releaseTranslation,
                 destination: destination, size: size)
    }

    private func rejectDrag() {
        Haptics.tick()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.68)) {
            dragTranslation = .zero
        }
        TableSFX.shared.play(.cardSlide, intensity: 0.30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            dragSource = nil; dragRunIDs = []; dragCardOrigins = [:]
        }
    }

    /// The landing feel for an ordinary drag-drop: a small settle (barely
    /// any lift) from wherever the run was released to its new home, with
    /// a contact shadow easing back in as it touches down — the flight
    /// arc's built-in ballistic profile already gives that for free.
    private func settleRun(runIDs: [String], origins: [String: CGPoint], releaseTranslation: CGSize,
                           destination: SolitaireMoveDestination, size: CGSize) {
        TableSFX.shared.play(.cardSlide, intensity: 0.6)
        switch destination {
        case .tableau(let column):
            let newPile = game.state.tableau[column]
            for id in runIDs {
                guard let idx = newPile.firstIndex(where: { $0.id == id }) else { continue }
                let entry = (origins[id] ?? SolitaireLayout.tableauEmptyCenter(column: column, boardSize: size))
                    .offsetBy(releaseTranslation)
                let rest = SolitaireLayout.tableauCardCenter(column: column, index: idx, pile: newPile, boardSize: size)
                runFlight(id: id, card: newPile[idx].card, faceUp: true, entry: entry, rest: rest,
                         entryRotation: 0, restRotation: 0, liftFraction: 0.05, duration: 0.16, sound: nil)
            }
        case .foundation(let suit):
            guard let id = runIDs.first, let card = game.state.foundations[suit]?.last else { return }
            let entry = (origins[id] ?? SolitaireLayout.foundationCenter(suit, boardSize: size)).offsetBy(releaseTranslation)
            let rest = SolitaireLayout.foundationCenter(suit, boardSize: size)
            runFlight(id: id, card: card, faceUp: true, entry: entry, rest: rest,
                     entryRotation: 0, restRotation: 0, liftFraction: 0.08, duration: 0.18, sound: nil)
        }
    }

    // MARK: - Double-tap to foundation

    private func attemptAutoFoundation(source: SolitaireMoveSource, card: Card, entry: CGPoint, size: CGSize) {
        guard dealCompleted, !isCascading, let suit = game.autoFoundationSuit(for: source) else { return }
        guard game.attemptMove(from: source, to: .foundation(suit)) else { return }
        Haptics.play()
        let rest = SolitaireLayout.foundationCenter(suit, boardSize: size)
        runFlight(id: card.id, card: card, faceUp: true, entry: entry, rest: rest,
                 entryRotation: 0, restRotation: Double.random(in: -5...5), liftFraction: 0.30, duration: 0.42)
    }

    // MARK: - Opening deal

    /// Card-by-card, staggered, real per-column round-robin order — pass 1
    /// places one card in every column, pass 2 places one in columns
    /// 1...6, and so on, exactly how a human deals (own implementation of
    /// the same idea `TableGameView.runDealStream` uses for the
    /// trick-taking felt; that file isn't in this worker's allowlist). The
    /// engine has already dealt the WHOLE table instantly at init — this
    /// is purely cosmetic, revealing the real, already-final deal in the
    /// order a dealer's hand would.
    private func runOpeningDeal(size: CGSize) {
        guard !dealCompleted else { return }
        let stockOrigin = SolitaireLayout.stockCenter(for: size)
        var order: [(column: Int, index: Int)] = []
        for row in 0..<7 { for column in row..<7 { order.append((column, row)) } }

        // Park every card at the stock, invisible in place, so the very
        // first frame already shows an empty tableau — nothing pops in
        // ahead of its turn in the stream.
        for (column, index) in order {
            guard let sc = tableauCard(at: column, index) else { continue }
            inFlight[sc.id] = InFlightCard(
                flight: SolitaireMotion.Flight(entry: stockOrigin, control: stockOrigin, rest: stockOrigin,
                                              entryRotation: 0, restRotation: 0, apex: 0, duration: 0.01),
                progress: 0, card: sc.card, faceUp: false)
        }

        guard !motionReduced else {
            inFlight.removeAll()
            withAnimation(.easeOut(duration: 0.25)) { dealCompleted = true }
            return
        }

        TableSFX.shared.play(.cardDeal)
        var delay: Double = 0
        for (column, index) in order {
            guard let sc = tableauCard(at: column, index) else { continue }
            let currentDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + currentDelay) { [self] in
                let pile = game.state.tableau[column]
                let rest = SolitaireLayout.tableauCardCenter(column: column, index: index, pile: pile, boardSize: size)
                runFlight(id: sc.id, card: sc.card, faceUp: sc.faceUp, entry: stockOrigin, rest: rest,
                         entryRotation: Double.random(in: -6...6), restRotation: 0, liftFraction: 0.10,
                         duration: 0.26, sound: nil)
            }
            delay += 0.045
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) {
            dealCompleted = true
        }
    }

    private func tableauCard(at column: Int, _ index: Int) -> SolitaireCard? {
        let pile = game.state.tableau[column]
        return pile.indices.contains(index) ? pile[index] : nil
    }

    // MARK: - Flights (shared by settle / double-tap / deal / cascade)

    private func runFlight(id: String, card: Card, faceUp: Bool, entry: CGPoint, rest: CGPoint,
                           entryRotation: Double, restRotation: Double, liftFraction: CGFloat,
                           duration: Double, sound: TableSFX.Effect? = .cardSlide) {
        let baseFlight = SolitaireMotion.arc(from: entry, to: rest, entryRotation: entryRotation,
                                            restRotation: restRotation, liftFraction: liftFraction, duration: duration)
        let flight = motionReduced ? SolitaireMotion.flattened(baseFlight) : baseFlight
        inFlight[id] = InFlightCard(flight: flight, progress: 0, card: card, faceUp: faceUp)
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.25, 0.10, 0.30, 1.0, duration: flight.duration)) {
                inFlight[id]?.progress = 1
            }
            if let sound {
                DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration * 0.8) {
                    TableSFX.shared.play(sound, intensity: 0.55 + Double(flight.apex) / 96.0 * 0.6)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration) {
                inFlight[id] = nil
            }
        }
    }

    @ViewBuilder
    private func flightOverlay(size: CGSize) -> some View {
        let cardWidth = SolitaireLayout.cardSize(for: size).width
        ForEach(Array(inFlight.keys), id: \.self) { id in
            if let entry = inFlight[id] {
                SolitaireFlightCardView(progress: entry.progress, card: entry.card, faceUp: entry.faceUp,
                                        flight: entry.flight, cardWidth: cardWidth)
            }
        }
    }

    // MARK: - Autocomplete cascade (the trophy moment)

    /// Read-only mirror of `SolitaireEngine.autoCompleteStep`'s own
    /// selection order (tableau columns in order, then the waste) — needed
    /// so the view can capture the card's CURRENT board position before
    /// the engine actually performs the move and the card vanishes from
    /// its pile array. Legality itself still goes through
    /// `game.legalMove`, never re-derived here.
    private func peekNextAutoStep(size: CGSize) -> (source: SolitaireMoveSource, entry: CGPoint)? {
        for column in game.state.tableau.indices {
            let pile = game.state.tableau[column]
            guard let top = pile.last, top.faceUp, let suit = top.card.suit else { continue }
            let source = SolitaireMoveSource.tableau(column: column, cardID: top.id)
            if game.legalMove(from: source, to: .foundation(suit)) {
                let entry = SolitaireLayout.tableauCardCenter(column: column, index: pile.count - 1,
                                                              pile: pile, boardSize: size)
                return (source, entry)
            }
        }
        if let top = game.state.waste.last, let suit = top.suit,
           game.legalMove(from: .waste, to: .foundation(suit)) {
            return (.waste, SolitaireLayout.wasteCenter(for: size))
        }
        return nil
    }

    private func runAutoComplete(size: CGSize) {
        guard dealCompleted, !isCascading, game.isAutoCompletable else { return }
        isCascading = true
        Haptics.arm()
        stepCascade(size: size, interval: 0.22)
    }

    /// Every step accelerates the next one (`interval` shrinks each call)
    /// so the cascade reads as gathering momentum, not a metronome.
    private func stepCascade(size: CGSize, interval: Double) {
        guard let peek = peekNextAutoStep(size: size), let result = game.autoCompleteStep() else {
            finishCascade()
            return
        }
        let rest = SolitaireLayout.foundationCenter(result.suit, boardSize: size)
        runFlight(id: result.card.id, card: result.card, faceUp: true, entry: peek.entry, rest: rest,
                 entryRotation: 0, restRotation: Double.random(in: -6...6), liftFraction: 0.32,
                 duration: max(0.15, interval))
        let nextInterval = max(0.05, interval * 0.85)
        DispatchQueue.main.asyncAfter(deadline: .now() + nextInterval * 0.6) {
            stepCascade(size: size, interval: nextInterval)
        }
    }

    private func finishCascade() {
        isCascading = false
        guard game.isWon else { return }
        TableSFX.shared.play(.fanfareWin)
        withAnimation(.easeOut(duration: 0.4)) { showWinCelebration = true }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chromeOverlay(size: CGSize) -> some View {
        GameHUD(title: "Solitaire", onExit: onClose, toggles: [
            HUDToggle(label: "Rules & Draw Mode", action: { showRulesSheet = true }),
            HUDToggle(label: "New Deal", action: { showNewDealConfirm = true }),
        ])
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(10)

        SolitaireBrassButton(systemImage: "arrow.uturn.backward", accessibilityLabel: "Undo",
                             isEnabled: dealCompleted && !isCascading && game.canUndo, action: performUndo)
            .position(x: 44, y: size.height - 44)
            .zIndex(10)

        if dealCompleted, !isCascading, !game.isWon, game.isAutoCompletable {
            SolitaireAutoFinishPrompt(action: { runAutoComplete(size: size) })
                .position(x: size.width / 2, y: SolitaireLayout.topRowY(for: size))
                .zIndex(10)
        }

        if showCloseDial {
            SolitaireHoldToCloseButton(progress: $closeRingProgress, onComplete: onClose)
                .position(x: 64, y: 56)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .zIndex(10)
        }
    }

    private func performUndo() {
        guard dealCompleted, !isCascading, game.canUndo else { return }
        Haptics.tick()
        _ = game.undo()
    }

    private func startNewDeal() {
        Haptics.arm()
        inFlight.removeAll()
        dragSource = nil; dragRunIDs = []; dragCardOrigins = [:]; dragTranslation = .zero
        showWinCelebration = false
        isCascading = false
        dealCompleted = false
        game.newDeal(seed: UInt64.random(in: UInt64.min...UInt64.max))
        let size = boardSize
        DispatchQueue.main.async {
            runOpeningDeal(size: size)
        }
    }
}

extension SolitaireView {
    /// Preview/test-only entry point: builds a `SolitaireView` around a
    /// caller-supplied engine with the deal ceremony already skipped (deal
    /// completed) — a canvas preview or a screenshot pass wants a stable
    /// frame, not a race against a multi-second animation. Real callers
    /// always go through `init(onClose:)`, which decides for itself
    /// whether `-demoSolitaire` applies; this bypasses that check
    /// entirely so a preview never depends on launch arguments.
    init(previewEngine: SolitaireEngine, onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        _game = State(initialValue: SolitaireGame(engine: previewEngine))
        _dealCompleted = State(initialValue: true)
    }
}

#Preview("Solitaire — mid game") {
    SolitaireView(previewEngine: SolitaireDemo.makeDemoEngine())
}

#Preview("Solitaire — fresh deal, ceremony skipped") {
    SolitaireView(previewEngine: SolitaireEngine(seed: 1))
}
