import SwiftUI

/// The physical sheet: a flat imageset if `PaperGraph` is in the asset
/// catalog (an asset worker is generating an aged-paper texture separately,
/// same drop-in convention as `FeltTexture`/`WalnutTexture` — see
/// `CardBackView`'s `UIImage(named:) != nil` check), otherwise a cheap
/// procedural fiber texture so the paper never looks flat while that asset
/// lands. Built once and cached, same pattern as `FeltTile.mirrored`.
enum DotsAndBoxesPaperTexture {
    /// Deterministic (not `Double.random`) so the fiber pattern doesn't
    /// re-roll every launch — a fixed FNV-seeded field, sampled from
    /// `PencilJitter`.
    static let procedural: UIImage = {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(DotsAndBoxesTheme.paperBase).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            // A field of faint short fibers, aged-paper grain rather than
            // flat color. ~900 strokes at low opacity is enough texture to
            // read under normal viewing without ever looking noisy.
            for i in 0..<900 {
                let x = CGFloat(PencilJitter.unit(i, 1)) * size.width
                let y = CGFloat(PencilJitter.unit(i, 2)) * size.height
                let len = 2 + CGFloat(PencilJitter.unit(i, 3)) * 5
                let angle = CGFloat(PencilJitter.unit(i, 4)) * .pi
                let dark = PencilJitter.unit(i, 5) > 0.5
                let tone = dark ? UIColor(DotsAndBoxesTheme.paperShadowEdge) : UIColor.white
                tone.withAlphaComponent(0.10).setStroke()
                cg.setLineWidth(1)
                cg.move(to: CGPoint(x: x, y: y))
                cg.addLine(to: CGPoint(x: x + cos(angle) * len, y: y + sin(angle) * len))
                cg.strokePath()
            }
        }
    }()
}

/// The paper sheet lying on the felt: texture, a whisper of rotation, a
/// drop shadow so it sits ON the table rather than being the table, and
/// the faintest corner curl. Everything else (dots, strokes, initials,
/// gestures) is layered on top by `DotsAndBoxesPaperView`.
private struct PaperBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let named = UIImage(named: "PaperGraph") {
                Image(uiImage: named)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(uiImage: DotsAndBoxesPaperTexture.procedural)
                    .resizable(resizingMode: .tile)
            }
            // Faint vignette toward the edges — real paper under one
            // overhead light is never perfectly even.
            RadialGradient(colors: [.clear, .black.opacity(0.06)], center: .center,
                           startRadius: 80, endRadius: 420)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.75)
        )
        .overlay(alignment: .bottomTrailing) { cornerCurl.opacity(0.35) }
        .overlay(alignment: .topLeading) { cornerCurl.opacity(0.18).rotationEffect(.degrees(180)) }
    }

    /// A tiny triangular fold with its own soft shadow — subtle on
    /// purpose, just enough that the corner reads as paper, not a
    /// perfectly flat card.
    private var cornerCurl: some View {
        Triangle()
            .fill(
                LinearGradient(colors: [DotsAndBoxesTheme.paperShadowEdge.opacity(0.5), .clear],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.15), radius: 2, x: -1, y: -1)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The whole paper stage: background, printed dot grid, every claimed
/// pencil stroke, every completed box's initial, and the drag/tap gesture
/// that turns a finger into a pencil. `DotsAndBoxesView` mounts exactly one
/// of these over the felt.
struct DotsAndBoxesPaperView: View {
    @Bindable var controller: DotsAndBoxesController
    /// Fires (edge, player) when a legal claim is attempted — the caller
    /// (DotsAndBoxesView) routes it through the controller so this view
    /// stays a dumb renderer + gesture surface, same separation TableGameView
    /// keeps from HostEngine.
    var onAttemptClaim: (DotsAndBoxesEdge) -> Void

    var body: some View {
        GeometryReader { geo in
            let margin = min(geo.size.width, geo.size.height) * 0.09
            let paperRect = CGRect(x: margin, y: margin,
                                   width: geo.size.width - margin * 2,
                                   height: geo.size.height - margin * 2)
            let grid = DotsAndBoxesGridGeometry(gridSize: controller.state.gridSize, paperRect: paperRect)

            ZStack {
                PaperBackground(cornerRadius: margin * 0.5)
                dotGrid(grid)
                strokesLayer(grid)
                initialsLayer(grid)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The whole sheet sits very slightly askew, like it was set
            // down rather than perfectly squared to the table.
            .rotationEffect(.degrees(0.5))
            .shadow(color: .black.opacity(0.4), radius: 20, x: 8, y: 14)
            .contentShape(Rectangle())
            .gesture(pencilGesture(grid))
        }
    }

    // MARK: - Dot grid

    private func dotGrid(_ grid: DotsAndBoxesGridGeometry) -> some View {
        Canvas { context, _ in
            let dotRadius: CGFloat = max(1.5, grid.spacing * 0.045)
            for row in 0...grid.gridSize {
                for col in 0...grid.gridSize {
                    let point = grid.dotPosition(row: row, col: col)
                    let rect = CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(DotsAndBoxesTheme.inkFaded.opacity(0.65)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Strokes

    private func strokesLayer(_ grid: DotsAndBoxesGridGeometry) -> some View {
        ZStack {
            ForEach(Array(controller.state.claimedBy.keys), id: \.self) { edge in
                if let playerIndex = controller.state.claimedBy[edge] {
                    let (a, b) = grid.edgeEndpoints(edge)
                    DotsAndBoxesPencilStrokeView(
                        start: a, end: b,
                        color: DotsAndBoxesTheme.pencilColor(for: controller.state.players[safe: playerIndex]?.colorIndex ?? playerIndex),
                        // A plain integer combination, NOT `.hashValue` —
                        // Swift's Hasher is randomly re-seeded every launch
                        // by design, which would reshuffle every stroke's
                        // waviness on every relaunch (and, worse, risks
                        // reseeding mid-session on unrelated hashing
                        // elsewhere). See PencilJitter's doc comment.
                        seed: edge.row * 4001 + edge.col * 17 + (edge.orientation == .horizontal ? 0 : 97),
                        lineWidth: max(2, grid.spacing * 0.06)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Initials

    private func initialsLayer(_ grid: DotsAndBoxesGridGeometry) -> some View {
        ZStack {
            ForEach(0..<controller.state.gridSize, id: \.self) { row in
                ForEach(0..<controller.state.gridSize, id: \.self) { col in
                    if let ownerIndex = controller.state.boxOwner[row][col],
                       let player = controller.state.players[safe: ownerIndex] {
                        let box = DotsAndBoxesBox(row: row, col: col)
                        let center = grid.boxCenter(box)
                        VStack(spacing: 2) {
                            DotsAndBoxesInitialView(
                                initial: player.initial,
                                color: DotsAndBoxesTheme.pencilColor(for: player.colorIndex),
                                fontSize: grid.spacing * 0.55,
                                seed: row * 1000 + col
                            )
                            if controller.extraTurnFlourishBoxes.contains(box) {
                                ExtraTurnFlourish(color: DotsAndBoxesTheme.pencilColor(for: player.colorIndex),
                                                  width: grid.spacing * 0.34)
                            }
                        }
                        .position(center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gesture: drag from dot to dot (hero), or tap the gap

    private func pencilGesture(_ grid: DotsAndBoxesGridGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard canCurrentPlayerAct else { return }
                let travel = hypot(value.translation.width, value.translation.height)
                if travel < grid.spacing * 0.28 {
                    // A tap: find the nearest undrawn line to the tap point.
                    if let edge = grid.nearestEdge(to: value.startLocation, among: controller.engine.legalEdges()) {
                        onAttemptClaim(edge)
                    }
                    return
                }
                // A drag: the hero gesture — snap start and end to their
                // nearest dots and use the edge between them, if adjacent.
                guard let startDot = grid.nearestDot(to: value.startLocation),
                      let endDot = grid.nearestDot(to: value.location),
                      let edge = grid.edge(from: startDot, to: endDot) else { return }
                onAttemptClaim(edge)
            }
    }

    /// Bots hold their own turn via the controller's timer — a stray tap
    /// during a bot's move should do nothing rather than queue up behind
    /// it (this is pass-and-play on one shared iPad, not a live turn
    /// queue).
    private var canCurrentPlayerAct: Bool {
        let players = controller.state.players
        let turn = controller.state.turnIndex
        return !controller.state.isGameOver && players.indices.contains(turn) && !players[turn].isBot
    }
}

/// A short curved underline that rises and fades under a just-completed
/// initial — the felt-side tell that this player earned an extra turn.
/// Purely decorative (`allowsHitTesting(false)` upstream), so it's safe to
/// let it animate freely even under Reduce Motion (a static one-beat
/// fade, not motion that needs suppressing).
private struct ExtraTurnFlourish: View {
    let color: Color
    let width: CGFloat
    @State private var visible = false

    var body: some View {
        Capsule()
            .fill(color.opacity(0.8))
            .frame(width: width * (visible ? 1 : 0.3), height: 2.5)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { visible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeIn(duration: 0.4)) { visible = false }
                }
            }
    }
}

extension Array {
    /// Bounds-safe subscript — a stray index (a resumed/demo state with a
    /// player count mismatch) renders nothing instead of crashing.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
