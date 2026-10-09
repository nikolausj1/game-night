import SwiftUI

/// Where everything sits on the table for a given screen size. Shared by
/// the painter, the touch layer and the plaques so nothing can drift.
struct CheckersLayout {
    let size: CGSize

    var boardSize: CGFloat { max(200, min(size.width * 0.92, size.height - 200, 900)) }
    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var origin: CGPoint { CGPoint(x: center.x - boardSize / 2, y: center.y - boardSize / 2) }
    var boardBottom: CGFloat { center.y + boardSize / 2 }
    var boardTop: CGFloat { center.y - boardSize / 2 }
    /// Vertical distance from the board edge to the middle of a plaque row.
    var plaqueOffset: CGFloat { min(max((size.height - boardSize) / 4, 44), 84) }

    func plaqueCenter(seat: Int) -> CGPoint {
        CGPoint(x: center.x, y: seat == 0 ? boardBottom + plaqueOffset : boardTop - plaqueOffset)
    }

    /// Where the `index`-th piece `seat` has captured rests, in BOARD UNITS
    /// (may lie off the board). Seat 0's pile runs rightward from its plaque;
    /// seat 1's mirrors it through the table centre so it reads naturally
    /// from across the table.
    func pileSlot(seat: Int, index: Int) -> CGPoint {
        let spacing = 0.034
        let stepX = CGFloat(min(index, 11)) * boardSize * CGFloat(spacing) + CGFloat(index / 12) * 6
        let dx = 150 + stepX
        let y = plaqueCenter(seat: seat).y
        let x = seat == 0 ? center.x + dx : center.x - dx
        return CGPoint(x: (x - origin.x) / boardSize, y: (y - origin.y) / boardSize - CGFloat(index / 12) * 0.03 * (seat == 0 ? 1 : -1))
    }

    func screen(_ unit: CGPoint) -> CGPoint { CGPoint(x: origin.x + unit.x * boardSize, y: origin.y + unit.y * boardSize) }
}

/// Pure Canvas drawing for the checkers table: destination glows, shadows,
/// wooden men, crowns, the tumbling captured pieces and the piles.
enum CheckersPainter {
    static let gold = Color(red: 0.96, green: 0.80, blue: 0.40)

    struct Drag {
        var square: Int          // the held piece's current square
        var point: CGPoint       // finger, in board units
    }

    // swiftlint:disable:next function_parameter_count
    static func paint(_ context: inout GraphicsContext, layout: CheckersLayout, t: Double, clock: Double,
                      plan: CheckersPlan?, tokens: [CheckersToken], pile: [Int],
                      targets: [Int], selected: Int?, drag: Drag?, nudge: CheckersController.Nudge?) {
        let S = layout.boardSize
        func px(_ u: CGPoint) -> CGPoint { layout.screen(u) }

        let red = context.resolve(Image("CheckerRed"))
        let black = context.resolve(Image("CheckerBlack"))
        let crown = context.resolve(Image("CheckerCrownOverlay"))
        func sprite(_ owner: Int) -> GraphicsContext.ResolvedImage { owner == 0 ? red : black }

        let w = CheckersGeometry.pieceDiameter * S
        let h = w * CheckersGeometry.spriteAspect

        // 1) Square lighting: the selected piece's pool of light and the
        //    glowing landing squares.
        let pulse = 0.5 + 0.5 * sin(clock * 3.2)
        if let sq = selected {
            glowDisc(&context, at: px(CheckersGeometry.center(of: sq)), radius: w * 0.78, strength: 0.55, ring: true)
        }
        for sq in targets {
            glowDisc(&context, at: px(CheckersGeometry.center(of: sq)), radius: w * 0.72, strength: 0.50 + 0.30 * pulse, ring: true)
        }
        if let nudge {
            let age = clock - nudge.start.timeIntervalSinceReferenceDate
            if age >= 0, age < 1.6 {
                let s = 0.9 * (0.5 + 0.5 * cos(age * 7.0)) * max(0, 1 - age / 1.6)
                for sq in nudge.squares { glowDisc(&context, at: px(CheckersGeometry.center(of: sq)), radius: w * 0.80, strength: s, ring: true) }
            }
        }

        // 2) Captured piles (small, stacked).
        for seat in 0..<2 {
            let count = plan?.pileCount(seat: seat, at: t, base: pile) ?? pile[seat]
            for i in 0..<count {
                drawPiece(&context, image: sprite(1 - seat), at: px(layout.pileSlot(seat: seat, index: i)),
                          w: w * 0.62, h: h * 0.62, lift: 0, flip: 1, alpha: 1, S: S, shadow: true)
            }
        }

        // 3) Men on the board.
        struct Item { var token: CheckersToken; var pose: CheckersPose; var isMover: Bool; var isDragged: Bool }
        var items: [Item] = []
        for token in tokens {
            var pose = CheckersPose(position: CheckersGeometry.center(of: token.square), lift: 0)
            var mover = false
            var dragged = false
            if let drag, drag.square == token.square {
                pose = CheckersPose(position: drag.point, lift: CheckersGeometry.liftHeight * 0.9)
                dragged = true
            } else if let plan, token.id == plan.moverID, let p = plan.moverPose(at: t) {
                pose = p; mover = true
            } else if let plan, let cap = plan.captures.first(where: { $0.tokenID == token.id }) {
                guard let p = plan.capturePose(cap, at: t, pileSlot: layout.pileSlot(seat: cap.seat, index: cap.pileIndex)) else { continue }
                pose = p
            }
            items.append(Item(token: token, pose: pose, isMover: mover, isDragged: dragged))
        }
        items.sort { a, b in
            let la = a.pose.lift > 0.0005, lb = b.pose.lift > 0.0005
            if la != lb { return !la }
            if la { return a.pose.lift < b.pose.lift }
            return a.pose.position.y < b.pose.position.y
        }
        for item in items {
            let p = px(item.pose.position)
            drawPiece(&context, image: sprite(item.token.owner), at: p, w: w, h: h,
                      lift: item.pose.lift * S, flip: item.pose.flip, alpha: item.pose.alpha, S: S,
                      shadow: true, scale: item.pose.scale)
            let lifted = item.pose.lift * S
            let liftedCentre = CGPoint(x: p.x, y: p.y - lifted * 0.6)
            let scale = (1 + item.pose.lift * 2.4) * item.pose.scale
            // Crown: static for a king; for a piece being crowned right now,
            // it settles on from above with a brass glint across the face.
            var crownProgress: Double?
            if item.isMover, let plan { crownProgress = plan.crownProgress(at: t) }
            if item.token.isKing || crownProgress != nil {
                let u = min(1, max(0, (crownProgress ?? 1) * 3))
                let ease = 1 - pow(1 - u, 3)
                let cw = w * 0.583 * scale * (1 + (1 - ease) * 0.9)
                let ch = cw * (20.0 / 28.0)
                let drop = (1 - ease) * S * 0.05
                var layer = context
                layer.translateBy(x: liftedCentre.x, y: liftedCentre.y - drop)
                layer.scaleBy(x: item.pose.flip, y: 1)
                layer.opacity = crownProgress == nil ? 1 : min(1, ease * 1.4)
                layer.draw(crown, in: CGRect(x: -cw / 2, y: -ch / 2 - h * 0.02, width: cw, height: ch))
            }
            if let cp = crownProgress, cp > 0.25, cp < 1.0 {
                let g = (cp - 0.25) / 0.75
                var layer = context
                layer.translateBy(x: liftedCentre.x, y: liftedCentre.y)
                layer.clip(to: Path(ellipseIn: CGRect(x: -w * 0.5 * scale, y: -w * 0.5 * scale, width: w * scale, height: w * scale)))
                layer.blendMode = .plusLighter
                let cx = (g * 2 - 1) * w * 0.75
                let band = Path(CGRect(x: cx - w * 0.16, y: -w * 0.7, width: w * 0.32, height: w * 1.4))
                    .applying(CGAffineTransform(rotationAngle: .pi / 7))
                layer.fill(band, with: .linearGradient(
                    Gradient(colors: [.clear, Color(red: 1.0, green: 0.90, blue: 0.55).opacity(0.85), .clear]),
                    startPoint: CGPoint(x: cx - w * 0.16, y: 0), endPoint: CGPoint(x: cx + w * 0.16, y: 0)))
            }
        }
    }

    private static func glowDisc(_ context: inout GraphicsContext, at c: CGPoint, radius r: CGFloat, strength s: Double, ring: Bool) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: gold.opacity(0.55 * s), location: 0.0),
                        .init(color: gold.opacity(0.28 * s), location: 0.6),
                        .init(color: gold.opacity(0), location: 1.0)]),
                                           center: c, startRadius: 0, endRadius: r))
        if ring {
            let inner = rect.insetBy(dx: r * 0.28, dy: r * 0.28)
            context.stroke(Path(ellipseIn: inner), with: .color(gold.opacity(0.75 * s)), lineWidth: max(1.5, r * 0.07))
        }
    }

    private static func drawPiece(_ context: inout GraphicsContext, image: GraphicsContext.ResolvedImage, at p: CGPoint,
                                  w: CGFloat, h: CGFloat, lift: CGFloat, flip: CGFloat, alpha: CGFloat, S: CGFloat,
                                  shadow: Bool, scale: CGFloat = 1) {
        let liftFactor = lift / max(S, 1)
        let s = (1 + liftFactor * 2.4) * scale
        if shadow {
            // Contact shadow stays on the wood; it widens and softens as the
            // piece rises, and slides away from the lamp.
            let r = w * 0.55 * (1 + liftFactor * 5) * scale
            let c = CGPoint(x: p.x + w * 0.05 + lift * 0.35, y: p.y + w * 0.10 + lift * 0.45)
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.92, width: r * 2, height: r * 1.84)),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: .black.opacity(0.46 / (1 + liftFactor * 22) * alpha), location: 0.45),
                            .init(color: .black.opacity(0), location: 1.0)]),
                                               center: c, startRadius: 0, endRadius: r))
        }
        var layer = context
        layer.opacity = alpha
        layer.translateBy(x: p.x, y: p.y - lift * 0.6)
        layer.scaleBy(x: flip * s, y: s)
        // Sprite face is centred at (0.5, 0.49) of its frame.
        layer.draw(image, in: CGRect(x: -w / 2, y: -0.49 * h, width: w, height: h))
    }
}
