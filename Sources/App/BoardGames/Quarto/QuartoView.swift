import SwiftUI

/// Quarto: table-only pass-and-play. Entry contract for the menu worker:
/// `QuartoView(onClose: @escaping () -> Void)` — everything else (setup,
/// the engine, the bot, rematch) is owned internally, exactly like
/// `DiceTableView` is dropped into `TableRootView` behind its own
/// launcher. Not wired into `TableRootView`/`MenuView` by this file (out
/// of this worker's file scope) — see `QuartoDemo.swift` for what's
/// pending there.
///
/// The whole table lives inside ONE `GeometryReader` + one named
/// coordinate space ("quartoTable"), so every drag gesture — whether it
/// starts in a felt-well or a side tray — reports `value.location` in the
/// SAME coordinate frame the board math (`QuartoBoardGeometry`) already
/// uses. That sidesteps the usual cross-view "what's my frame in the
/// parent's space" plumbing entirely: a drop point is just arithmetic
/// against numbers this view already computed for layout.
struct QuartoView: View {
    var onClose: () -> Void
    /// Mount straight into the parked game (`ResumeCatalog`), skipping setup.
    var resumeSaved = false

    @State private var controller: QuartoController?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    // Drag ceremony state — presentation only; the engine never sees any
    // of this until a drag actually completes onto a legal target.
    @State private var heldDragLocation: CGPoint?
    @State private var hoveredCell: Int?
    @State private var draggingTrayPieceID: Int?
    @State private var trayDragLocation: CGPoint?

    private let coordinateSpace = "quartoTable"

    var body: some View {
        ZStack {
            TableSurface()
            if let controller {
                gameLayer(controller: controller)
            } else {
                QuartoSetupView(onStart: startGame)
            }
        }
        .statusBarHidden()
        .onAppear {
            if QuartoDemo.wantsQuartoDemo, controller == nil {
                controller = QuartoDemo.makeMidGameController()
            }
            if controller == nil, resumeSaved, let saved = LocalGameSave.loadQuarto() {
                let restored = QuartoController(restoring: saved)
                controller = restored
                restored.scheduleBotIfNeeded()
            }
        }
        .onChange(of: controller?.revision) { _, _ in
            // Autosave 2s after the last placement; game over clears it.
            if let controller { LocalGameSave.noteQuarto(controller.state) }
        }
    }

    private func startGame(playerOneName: String, playerTwoName: String,
                           playerOneIsBot: Bool, playerTwoIsBot: Bool, use2x2Variant: Bool) {
        LocalGameSave.clear(.board("quarto"))
        let players = [QuartoPlayer(name: playerOneName, isBot: playerOneIsBot),
                       QuartoPlayer(name: playerTwoName, isBot: playerTwoIsBot)]
        let fresh = QuartoController(players: players, use2x2Variant: use2x2Variant, firstPlayer: 0)
        controller = fresh
        fresh.scheduleBotIfNeeded() // covers bot-vs-bot and "bot opens"
    }

    // MARK: - Game layer

    @ViewBuilder
    private func gameLayer(controller: QuartoController) -> some View {
        GeometryReader { geo in
            let layout = QuartoTableLayout(size: geo.size)
            ZStack {
                boardLayer(controller: controller, layout: layout)
                trayLayer(controller: controller, layout: layout, side: .left)
                trayLayer(controller: controller, layout: layout, side: .right)
                labelsLayer(controller: controller, layout: layout)
                wellLayer(controller: controller, layout: layout)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: coordinateSpace)
        }
        .overlay(alignment: .topTrailing) {
            GameHUD(title: "Quarto", onExit: onClose).padding(16)
        }
        .overlay {
            if controller.state.phase == .gameOver {
                recap(controller: controller)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.state.phase)
    }

    // MARK: - Game over

    /// A win names the shared attribute ("Four tall, four dark!"), a draw
    /// gets its own honest line. The player who did NOT win (or, on a
    /// draw, whoever wasn't left holding the last move) opens the rematch
    /// — a small, familiar "loser breaks" courtesy.
    private func recap(controller: QuartoController) -> some View {
        let state = controller.state
        let placed = [0, 1].map { seat in
            // Pieces alternate: whoever placed last placed the odd one out.
            let total = state.moveCount
            let lastPlacer = state.winner ?? state.currentPlayer
            return total / 2 + (total % 2 == 1 && seat == lastPlacer ? 1 : 0)
        }
        let order = [0, 1].sorted { (state.winner == $0) || (state.winner != $1 && $0 < $1) }
        let rows = order.map { seat in
            RecapRow(id: seat, name: state.players[seat].name, colorIndex: seat,
                     score: "\(placed[seat])", detail: "pieces placed", isWinner: state.winner == seat)
        }
        let title = state.winner.map { "\(state.players[$0].name) wins Quarto" } ?? "It's a draw"
        var highlight = "Every cell is full and no line ever matched: a clean stalemate"
        if state.winner != nil, let line = state.winningLine {
            highlight = QuartoRules.winCallout(attributes: state.winningAttributes, line: line, board: state.board)
        }
        return GameRecapCard(title: title, rows: rows, highlight: highlight, onRematch: {
            let lastActor = state.winner ?? state.currentPlayer
            controller.restart(players: state.players, use2x2Variant: state.use2x2Variant,
                               firstPlayer: 1 - lastActor)
        }, onDone: onClose)
    }

    // MARK: - Board

    private func boardLayer(controller: QuartoController, layout: QuartoTableLayout) -> some View {
        ZStack {
            QuartoBoardView(size: layout.boardSize)
                .position(layout.boardCenter)

            // Legal-cell highlight while a placement drag is live.
            if heldDragLocation != nil {
                ForEach(controller.state.emptyCells, id: \.self) { cell in
                    let center = layout.boardPoint(forCell: cell)
                    Circle()
                        .strokeBorder(CardStyle.gold.opacity(hoveredCell == cell ? 0.9 : 0.28),
                                     lineWidth: hoveredCell == cell ? 3 : 1.5)
                        .frame(width: layout.cellSize * 0.62, height: layout.cellSize * 0.62)
                        .position(center)
                        .allowsHitTesting(false)
                }
            }

            ForEach(0..<16, id: \.self) { cell in
                if let pieceID = controller.state.board[cell] {
                    QuartoPieceView(piece: QuartoPiece(id: pieceID), diameter: layout.pieceDiameter)
                        .position(layout.boardPoint(forCell: cell))
                        .accessibilityAddTraits(.isImage)
                }
            }

            if let line = controller.state.winningLine, controller.state.winner != nil {
                winningLineGlow(line: line, layout: layout)
            }
        }
    }

    private func winningLineGlow(line: [Int], layout: QuartoTableLayout) -> some View {
        let isSquare = QuartoLines.squares.contains(line)
        let ordered = isSquare ? [line[0], line[1], line[3], line[2], line[0]] : line
        let points = ordered.map(layout.boardPoint(forCell:))
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(CardStyle.gold, style: StrokeStyle(lineWidth: layout.boardSize * 0.018, lineCap: .round, lineJoin: .round))
        .shadow(color: CardStyle.gold.opacity(0.85), radius: 14)
        .shadow(color: CardStyle.gold.opacity(0.6), radius: 28)
        .allowsHitTesting(false)
    }

    // MARK: - Trays

    private func trayLayer(controller: QuartoController, layout: QuartoTableLayout,
                           side: QuartoTableLayout.TraySide) -> some View {
        let pieces = side == .left ? QuartoTableLayout.lightPieces : QuartoTableLayout.darkPieces
        let canDragFromHere = controller.state.phase == .selecting
            && !controller.state.players[controller.state.currentPlayer].isBot
        return ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
            let slot = layout.traySlot(side: side, index: index)
            if controller.state.remainingPieces.contains(piece.id) {
                let isDragging = draggingTrayPieceID == piece.id
                QuartoPieceView(piece: piece, diameter: layout.trayPieceDiameter, isHighlighted: isDragging)
                    .position(isDragging ? (trayDragLocation ?? slot) : slot)
                    .zIndex(isDragging ? 10 : 1)
                    .accessibilityLabel(Text("Remaining piece: \(piece.accessibleName)"))
                    .accessibilityHint(canDragFromHere ? Text("Drag to the opponent's felt well to hand it over") : Text(""))
                    .gesture(trayDragGesture(controller: controller, layout: layout, piece: piece))
            }
        }
    }

    /// Guards internally rather than being conditionally attached — SwiftUI
    /// has no clean "optional gesture" overload, and re-checking permission
    /// fresh from `controller.state` on every callback (instead of a value
    /// captured once at attach time) is the more correct behavior anyway:
    /// a gesture that started mid-turn and outlives a state change (e.g. a
    /// bot's move landing while a stray touch is still down) should stop
    /// mattering the moment it's no longer that piece's moment, not act on
    /// stale permission.
    private func trayDragGesture(controller: QuartoController, layout: QuartoTableLayout, piece: QuartoPiece) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard controller.state.phase == .selecting,
                      !controller.state.players[controller.state.currentPlayer].isBot,
                      controller.state.remainingPieces.contains(piece.id) else { return }
                draggingTrayPieceID = piece.id
                trayDragLocation = value.location
            }
            .onEnded { value in
                guard draggingTrayPieceID == piece.id else { return }
                let receiver = 1 - controller.state.currentPlayer
                let targetWell = layout.wellCenter(forPlayer: receiver)
                let distance = hypot(value.location.x - targetWell.x, value.location.y - targetWell.y)
                if distance < layout.wellCaptureRadius {
                    Haptics.tick()
                    let settle = { controller.perform(.selectPiece(piece.id)) }
                    if motionReduced {
                        settle()
                        draggingTrayPieceID = nil
                        trayDragLocation = nil
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { trayDragLocation = targetWell }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            settle()
                            draggingTrayPieceID = nil
                            trayDragLocation = nil
                        }
                    }
                } else {
                    withAnimation(motionReduced ? .none : .spring(response: 0.4, dampingFraction: 0.72)) {
                        trayDragLocation = nil
                    }
                    draggingTrayPieceID = nil
                }
            }
    }

    // MARK: - Wells (the felt-well ceremony)

    private func wellLayer(controller: QuartoController, layout: QuartoTableLayout) -> some View {
        ZStack {
            ForEach([0, 1], id: \.self) { player in
                wellShape(diameter: layout.wellDiameter)
                    .position(layout.wellCenter(forPlayer: player))
            }
            if controller.state.phase == .placing, let held = controller.state.heldPiece {
                let placer = controller.state.currentPlayer
                let restPosition = layout.wellCenter(forPlayer: placer)
                let canDrag = !controller.state.players[placer].isBot
                let piece = QuartoPiece(id: held)
                QuartoPieceView(piece: piece, diameter: layout.wellPieceDiameter, isHighlighted: heldDragLocation != nil)
                    .position(heldDragLocation ?? restPosition)
                    .zIndex(20)
                    .accessibilityLabel(Text("Your piece to place: \(piece.accessibleName)"))
                    .accessibilityHint(canDrag ? Text("Drag onto any empty cell on the board") : Text(""))
                    .gesture(placeDragGesture(controller: controller, layout: layout, held: held, restPosition: restPosition))
            }
        }
    }

    private func placeDragGesture(controller: QuartoController, layout: QuartoTableLayout,
                                  held: Int, restPosition: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard controller.state.phase == .placing, controller.state.heldPiece == held,
                      !controller.state.players[controller.state.currentPlayer].isBot else { return }
                heldDragLocation = value.location
                hoveredCell = layout.cell(nearestTo: value.location)
            }
            .onEnded { value in
                guard heldDragLocation != nil else { return }
                if let cell = layout.cell(nearestTo: value.location), controller.state.board[cell] == nil {
                    Haptics.play()
                    let target = layout.boardPoint(forCell: cell)
                    let settle = { controller.perform(.placePiece(held, at: cell)) }
                    hoveredCell = nil
                    if motionReduced {
                        settle()
                        heldDragLocation = nil
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { heldDragLocation = target }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            settle()
                            heldDragLocation = nil
                        }
                    }
                } else {
                    hoveredCell = nil
                    withAnimation(motionReduced ? .none : .spring(response: 0.4, dampingFraction: 0.72)) {
                        heldDragLocation = nil
                    }
                }
            }
    }

    private func wellShape(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [.black.opacity(0.55), .black.opacity(0.22), .clear],
                                 center: .center, startRadius: 0, endRadius: diameter * 0.55))
            .overlay(Circle().strokeBorder(CardStyle.gold.opacity(0.32), lineWidth: 1.5))
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }

    // MARK: - Turn labels (outward-facing, matching SeatPlateView's rim language)

    private func labelsLayer(controller: QuartoController, layout: QuartoTableLayout) -> some View {
        ZStack {
            turnLabel(controller: controller, player: 0)
                .position(layout.labelCenter(forPlayer: 0))
            turnLabel(controller: controller, player: 1)
                .position(layout.labelCenter(forPlayer: 1))
                .rotationEffect(.degrees(180)) // reads right-side-up across the table
        }
    }

    private func turnLabel(controller: QuartoController, player: Int) -> some View {
        let isTheirTurn = controller.state.phase != .gameOver && controller.state.currentPlayer == player
        let name = controller.state.players[player].name
        var waiting = ""
        if isTheirTurn {
            switch controller.state.phase {
            case .selecting: waiting = "choosing a piece to give"
            case .placing: waiting = "placing"
            case .gameOver: waiting = ""
            }
        }
        return VStack(spacing: 3) {
            Text(name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
            if isTheirTurn, !waiting.isEmpty {
                Text(waiting)
                    .font(.caption)
                    .foregroundStyle(CardStyle.gold)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.42))
                .overlay(Capsule().strokeBorder(isTheirTurn ? CardStyle.gold : .white.opacity(0.1),
                                                lineWidth: isTheirTurn ? 2 : 1))
                .shadow(color: isTheirTurn ? CardStyle.gold.opacity(0.6) : .clear, radius: 8)
        )
        .animation(.easeInOut(duration: 0.3), value: isTheirTurn)
    }
}

private extension QuartoPiece {
    var accessibleName: String {
        "\(isTall ? "tall" : "short") \(isDark ? "dark" : "light") \(isRound ? "round" : "square") \(isHollow ? "hollow" : "solid")"
    }
}
