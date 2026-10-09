import SwiftUI

/// The inlaid board photo, the Canvas that paints every wooden man over it,
/// and the single touch recognizer that turns pick-up / drag / drop / tap
/// into `CheckersController` calls.
struct CheckersBoardView: View {
    let controller: CheckersController
    let layout: CheckersLayout

    @State private var gestureStartSquare: Int?
    @State private var grabbed = false
    @State private var canDrag = false
    @State private var justSelected = false
    @State private var dragPoint: CGPoint?
    @State private var started = false

    var body: some View {
        let stage = controller.stage
        let plan = stage.plan
        let tokens = stage.tokens
        let pile = stage.pile
        let start = stage.startDate
        let targets = controller.targets
        let selected = controller.selectedSquare
        let drag: CheckersPainter.Drag? = (grabbed && selected != nil && dragPoint != nil)
            ? CheckersPainter.Drag(square: selected!, point: dragPoint!) : nil
        let nudge = controller.nudge
        let paused = plan == nil && targets.isEmpty && selected == nil && nudge == nil
        let S = layout.boardSize

        ZStack {
            Image("CheckersBoard")
                .resizable()
                .frame(width: S, height: S)
                .shadow(color: .black.opacity(0.55), radius: S * 0.03, y: S * 0.02)
                .position(layout.center)

            TimelineView(.animation(minimumInterval: plan == nil ? 1.0 / 30.0 : nil, paused: paused)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas { context, _ in
                    CheckersPainter.paint(&context, layout: layout, t: t, clock: timeline.date.timeIntervalSinceReferenceDate,
                                          plan: plan, tokens: tokens, pile: pile, targets: targets,
                                          selected: selected, drag: drag, nudge: nudge)
                }
                .frame(width: layout.size.width, height: layout.size.height)
            }
            .allowsHitTesting(false)

            touchLayer
                .frame(width: S, height: S)
                .position(layout.center)

            accessibilityLayer
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    // MARK: - Touch

    private func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / layout.boardSize, y: p.y / layout.boardSize) }

    /// One recognizer for everything. Touch-down on your own piece picks it
    /// up (its landing squares light); dragging carries it; lift-off over a
    /// lit square plays it. A plain tap works too: tap a piece, tap a lit
    /// square. Tapping the held piece again puts it back.
    private var touchLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !started {
                            started = true
                            begin(at: unit(value.startLocation))
                        }
                        let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                        if canDrag, moved > 7 {
                            grabbed = true
                            dragPoint = unit(value.location)
                        }
                    }
                    .onEnded { value in
                        end(at: unit(value.location))
                        started = false
                        grabbed = false
                        dragPoint = nil
                        canDrag = false
                        justSelected = false
                        gestureStartSquare = nil
                    }
            )
    }

    private func begin(at point: CGPoint) {
        guard controller.humanTurn else { return }
        let sq = CheckersGeometry.square(at: point, tolerance: 0.7)
        gestureStartSquare = sq
        guard let sq else { return }
        let mine = controller.state.board[sq]?.owner == controller.state.currentPlayer
        if controller.prefix.isEmpty {
            if mine { justSelected = controller.select(square: sq); canDrag = justSelected }
        } else if sq == controller.selectedSquare {
            canDrag = true                                  // re-grab the held piece
        } else if controller.prefix.count == 1, mine, !controller.targets.contains(sq) {
            controller.deselect()                           // change your mind: pick another piece
            justSelected = controller.select(square: sq)
            canDrag = justSelected
        }
    }

    private func end(at point: CGPoint) {
        guard controller.humanTurn else { return }
        if grabbed {
            if let target = CheckersGeometry.square(at: point, tolerance: 0.7), target != controller.selectedSquare {
                controller.attemptStep(to: target)         // an unlit target is simply refused (and may nudge)
            }
            return
        }
        // A tap.
        guard let sq = gestureStartSquare else { controller.deselect(); return }
        if controller.targets.contains(sq) {
            controller.attemptStep(to: sq)
        } else if sq == controller.selectedSquare {
            if !justSelected { controller.deselect() }     // tap the held piece again: put it back
        } else if controller.prefix.count == 1, controller.state.board[sq] == nil {
            controller.attemptStep(to: sq)                 // may raise the "must capture" nudge
            controller.deselect()
        }
    }

    private var accessibilityLayer: some View {
        ZStack {
            ForEach(controller.stage.tokens) { token in
                let c = layout.screen(CheckersGeometry.center(of: token.square))
                Color.clear
                    .frame(width: layout.boardSize * 0.09, height: layout.boardSize * 0.09)
                    .position(c)
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(token.owner == 0 ? "Red" : "Black")\(token.isKing ? " king" : " man"), row \(CheckersGeometry.row(token.square) + 1), column \(CheckersGeometry.col(token.square) + 1)"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { controller.select(square: token.square) }
            }
            ForEach(controller.targets, id: \.self) { sq in
                let c = layout.screen(CheckersGeometry.center(of: sq))
                Color.clear
                    .frame(width: layout.boardSize * 0.09, height: layout.boardSize * 0.09)
                    .position(c)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Move here, row \(CheckersGeometry.row(sq) + 1), column \(CheckersGeometry.col(sq) + 1)"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { controller.attemptStep(to: sq) }
            }
        }
        .allowsHitTesting(false)
    }
}
