import SwiftUI

/// The walnut board photo with the glass stones drawn over it.
///
/// Stones are NOT SwiftUI views: all 48 are painted in one `Canvas` driven
/// by a `TimelineView`, because a sowing has a dozen stones in the air at
/// once, each at its own point on its own curve, and the only honest way to
/// draw that is as a pure function of time (`MancalaPlan.pose`). The
/// timeline is paused whenever nothing moves and nothing is highlighted, so
/// an idle board costs nothing.
struct MancalaBoardView: View {
    let controller: MancalaController
    let width: CGFloat
    /// Called with the LOCAL pit (0...5) the current human tapped.
    var onSow: (Int) -> Void

    @State private var pressedSlot: Int?

    private var height: CGFloat { width * MancalaGeometry.aspect }

    var body: some View {
        let stage = controller.stage
        let plan = stage.plan
        let slots = stage.slots
        let start = stage.startDate
        let state = controller.state
        let hintSeat: Int? = (!controller.isBusy && state.phase == .playing && !state.players[state.currentPlayer].isBot)
            ? state.currentPlayer : nil
        let pressed = pressedSlot
        let paused = plan == nil && hintSeat == nil

        ZStack {
            Image("MancalaBoard")
                .resizable()
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.5), radius: width * 0.02, y: width * 0.014)

            TimelineView(.animation(minimumInterval: plan == nil ? 1.0 / 24.0 : nil, paused: paused)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    MancalaBoardPainter.paint(&context, size: size, t: t, plan: plan, slots: slots,
                                              board: state.board, hintSeat: hintSeat, pressed: pressed,
                                              clock: timeline.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: width, height: height)
            }
            .allowsHitTesting(false)

            touchLayer
            accessibilityLayer
        }
        .frame(width: width, height: height)
    }

    // MARK: - Touch

    /// One drag recognizer over the whole board (min distance 0): finger-down
    /// presses a pit (gold ring), lift-off over the SAME pit sows it. Sliding
    /// off cancels, which is how a real fingertip "changes its mind".
    private var touchLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pressedSlot = playableSlot(at: unit(value.location))
                    }
                    .onEnded { value in
                        let slot = playableSlot(at: unit(value.location))
                        let started = playableSlot(at: unit(value.startLocation))
                        pressedSlot = nil
                        guard let slot, slot == started else { return }
                        onSow(localPit(of: slot))
                    }
            )
    }

    private func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / width, y: point.y / width) }

    private func localPit(of slot: Int) -> Int { slot <= 5 ? slot : slot - 7 }

    /// The slot under `point` ONLY if the current human may sow it now.
    private func playableSlot(at point: CGPoint) -> Int? {
        let state = controller.state
        guard !controller.isBusy, state.phase == .playing, !state.players[state.currentPlayer].isBot,
              let slot = MancalaGeometry.pit(at: point),
              MancalaRules.owner(ofPit: slot) == state.currentPlayer,
              state.board[slot] > 0 else { return nil }
        return slot
    }

    private var accessibilityLayer: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { slot in
                if !MancalaGeometry.isStore(slot) {
                    let c = MancalaGeometry.center(of: slot)
                    let count = controller.state.board[slot]
                    let state = controller.state
                    let mine = MancalaRules.owner(ofPit: slot) == state.currentPlayer
                    Color.clear
                        .frame(width: width * MancalaGeometry.pitRadius * 2, height: width * MancalaGeometry.pitRadius * 2)
                        .position(x: c.x * width, y: c.y * width)
                        .accessibilityElement()
                        .accessibilityLabel(Text("\(state.players[MancalaRules.owner(ofPit: slot) ?? 0].name)'s pit, \(count) stone\(count == 1 ? "" : "s")"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(mine && count > 0 ? Text("Double-tap to sow these stones") : Text(""))
                        .accessibilityAction {
                            if playableSlot(at: c) != nil { onSow(localPit(of: slot)) }
                        }
                } else {
                    let c = MancalaGeometry.center(of: slot)
                    let seat = slot == 6 ? 0 : 1
                    Color.clear
                        .frame(width: width * MancalaGeometry.storeHalfWidth * 2, height: width * MancalaGeometry.storeHalfHeight * 2)
                        .position(x: c.x * width, y: c.y * width)
                        .accessibilityElement()
                        .accessibilityLabel(Text("\(controller.state.players[seat].name)'s store, \(controller.state.board[slot]) stones"))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Painter

/// Pure drawing: given time, plan and resting layout, paint glows, shadows
/// and gems. Kept outside the view so it is trivially re-usable for the
/// previews/demo and obviously side-effect free.
enum MancalaBoardPainter {
    static let gold = Color(red: 0.96, green: 0.80, blue: 0.40)

    static func paint(_ context: inout GraphicsContext, size: CGSize, t: Double, plan: MancalaPlan?,
                      slots: [[Int]], board: [Int], hintSeat: Int?, pressed: Int?, clock: Double) {
        let W = size.width
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * W) }

        // 1) Glows on the wood: capture rings, extra-turn store glow,
        //    a faint "you may play this pit" shimmer, and the press ring.
        let shimmer = 0.5 + 0.5 * sin(clock * 2.6)
        for slot in 0..<14 {
            var s = plan?.glowStrength(slot: slot, at: t) ?? 0
            if let seat = hintSeat, MancalaRules.owner(ofPit: slot) == seat, board[slot] > 0 {
                s = max(s, 0.20 + 0.14 * shimmer)
            }
            if pressed == slot { s = max(s, 0.95) }
            guard s > 0.01 else { continue }
            drawGlow(&context, slot: slot, strength: s, W: W)
        }

        // 2) Stones.
        struct Item { var id: Int; var pos: CGPoint; var h: CGFloat; var order: Int }
        var resting: [Item] = []
        var flying: [Item] = []
        for slot in 0..<14 {
            for (index, id) in slots[slot].enumerated() {
                var pos = MancalaGeometry.restPoint(slot: slot, index: index, stoneID: id)
                var h: CGFloat = 0
                var order = index
                if let pose = plan?.pose(of: id, at: t) {
                    pos = pose.position
                    h = pose.height
                    if pose.order >= 0 { order = pose.order }
                }
                let item = Item(id: id, pos: pos, h: h, order: order)
                if h > 0.0008 { flying.append(item) } else { resting.append(item) }
            }
        }
        resting.sort { $0.order < $1.order }
        flying.sort { $0.h < $1.h }

        let d = MancalaGeometry.stoneDiameter * W
        // Shadows first, so no stone is ever shaded by a neighbour's shadow.
        for item in resting + flying {
            let ground = px(item.pos)
            let lift = item.h * W
            let r = d * 0.56 * (1 + item.h * 5)
            let alpha = 0.50 / (1 + item.h * 26)
            let centre = CGPoint(x: ground.x + d * 0.07 + lift * 0.35, y: ground.y + d * 0.13 + lift * 0.55)
            let rect = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: .black.opacity(alpha), location: 0.35),
                            .init(color: .black.opacity(0), location: 1.0)]),
                                               center: centre, startRadius: 0, endRadius: r))
        }

        var resolved: [Int: GraphicsContext.ResolvedImage] = [:]
        for gem in 0..<8 {
            if let sprite = MancalaGems.sprites[gem] { resolved[gem] = context.resolve(Image(uiImage: sprite)) }
        }
        for item in resting + flying {
            guard let image = resolved[MancalaGems.gem(forStone: item.id)] else {
                // Asset missing: a plain ball, so the game stays playable.
                let p = px(item.pos)
                context.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(.teal))
                continue
            }
            let lift = item.h * W
            let scale = 1 + item.h * 4.2
            let side = d * 1.045 * scale
            let p = px(item.pos)
            let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2 - lift * 0.55, width: side, height: side)
            context.draw(image, in: rect)
        }
    }

    private static func drawGlow(_ context: inout GraphicsContext, slot: Int, strength s: Double, W: CGFloat) {
        let c = MancalaGeometry.center(of: slot)
        let centre = CGPoint(x: c.x * W, y: c.y * W)
        if MancalaGeometry.isStore(slot) {
            let rect = CGRect(x: centre.x - MancalaGeometry.storeHalfWidth * W, y: centre.y - MancalaGeometry.storeHalfHeight * W,
                              width: MancalaGeometry.storeHalfWidth * W * 2, height: MancalaGeometry.storeHalfHeight * W * 2)
            let path = Path(roundedRect: rect.insetBy(dx: -W * 0.004, dy: -W * 0.004), cornerRadius: rect.width * 0.5)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: gold.opacity(0.9 * s), radius: W * 0.016))
                layer.stroke(path, with: .color(gold.opacity(0.85 * s)), lineWidth: W * 0.0045)
            }
        } else {
            let r = MancalaGeometry.pitRadius * W * 0.97
            let path = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            context.fill(path, with: .radialGradient(Gradient(colors: [gold.opacity(0.0), gold.opacity(0.22 * s)]),
                                                     center: centre, startRadius: r * 0.45, endRadius: r))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: gold.opacity(0.9 * s), radius: W * 0.012))
                layer.stroke(path, with: .color(gold.opacity(0.80 * s)), lineWidth: W * 0.0035)
            }
        }
    }
}
