import SwiftUI

/// One printed nautical chart: the `BattleshipGrid` paper with ship
/// silhouettes laid on it, brass-headed pegs in the holes, impact effects,
/// and (phone only) an aiming reticle or a placement ghost. Pure and
/// stateless about the game: callers hand it exactly what to show, so the
/// phone's secret board, the phone's targeting chart, and the table's two
/// public charts all use the same renderer.
///
/// Newly appearing pegs drop in (top-down: big and shadowed, shrinking onto
/// the paper, then a small settle); newly appearing sunk/revealed ships
/// fade-and-settle in after `appearDelay`. Whatever is present when the
/// chart first appears is drawn static — so reconnects and previews don't
/// replay history.
struct BattleshipChartView: View {
    struct Ship: Identifiable {
        enum Style: String { case plain, sunk, revealed }
        let ship: BattleshipShip
        var style: Style = .plain
        /// Seconds to wait before a newly appearing ship settles in.
        var appearDelay: Double = 0
        /// One ship per kind on any chart, so a style change (plain -> sunk on
        /// your own board) keeps the same view and just re-tints it.
        var id: String { ship.kind.rawValue }
    }

    struct Ghost {
        var kind: BattleshipShipKind
        var row: Int
        var col: Int
        var orientation: BattleshipOrientation
        var legal: Bool
    }

    let side: CGFloat
    var ships: [Ship] = []
    var hiddenKinds: Set<BattleshipShipKind> = []
    var shots: [BattleshipShot] = []
    var effects: [ChartEffect] = []
    var aim: BattleshipCell?
    /// A cell ringed in red (the opponent's latest shot on your own chart).
    var markedCell: BattleshipCell?
    var ghost: Ghost?
    var accessibilitySummary = "Battle chart"
    /// Previews / render harness: skip entrance animations (reticle drawn
    /// already lifted) so a static render shows the finished state.
    var freeze = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialPegIDs: Set<String>
    @State private var initialShipIDs: Set<String>

    init(side: CGFloat, ships: [Ship] = [], hiddenKinds: Set<BattleshipShipKind> = [],
         shots: [BattleshipShot] = [], effects: [ChartEffect] = [], aim: BattleshipCell? = nil,
         markedCell: BattleshipCell? = nil, ghost: Ghost? = nil, accessibilitySummary: String = "Battle chart",
         freeze: Bool = false) {
        self.freeze = freeze
        self.side = side
        self.ships = ships
        self.hiddenKinds = hiddenKinds
        self.shots = shots
        self.effects = effects
        self.aim = aim
        self.markedCell = markedCell
        self.ghost = ghost
        self.accessibilitySummary = accessibilitySummary
        _initialPegIDs = State(initialValue: Set(shots.map(Self.pegID)))
        _initialShipIDs = State(initialValue: Set(ships.map(\.id)))
    }

    private static func pegID(_ s: BattleshipShot) -> String { "\(s.turn)-\(s.row)-\(s.col)" }

    private var geo: BattleshipChartGeometry { BattleshipChartGeometry(side: side) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("BattleshipGrid")
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)

            ForEach(ships) { item in
                if !hiddenKinds.contains(item.ship.kind) {
                    ChartShipView(ship: item.ship, style: item.style, geo: geo,
                                  animated: !initialShipIDs.contains(item.id),
                                  delay: item.appearDelay, reduceMotion: reduceMotion)
                }
            }

            if let ghost { ghostView(ghost) }

            ForEach(shots, id: \.turn) { shot in
                let center = geo.center(row: shot.row, col: shot.col)
                ChartPegView(isHit: shot.result.isHit, size: geo.pitchX * 0.56,
                             animated: !initialPegIDs.contains(Self.pegID(shot)), reduceMotion: reduceMotion)
                    .position(center)
            }

            ForEach(effects) { effect in
                ChartEffectView(effect: effect, pitch: geo.pitchX, reduceMotion: reduceMotion)
                    .position(geo.center(effect.cell))
            }

            if let markedCell {
                MarkedRing(size: geo.pitchX * 0.98, reduceMotion: reduceMotion)
                    .position(geo.center(markedCell))
            }

            if let aim {
                AimReticle(size: geo.pitchX, reduceMotion: reduceMotion, freeze: freeze)
                    .position(geo.center(aim))
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func ghostView(_ ghost: Ghost) -> some View {
        let ship = BattleshipShip(kind: ghost.kind, row: ghost.row, col: ghost.col, orientation: ghost.orientation)
        let tint = ghost.legal ? CardStyle.gold : BattleshipPalette.danger
        ZStack {
            ForEach(ship.cells, id: \.self) { cell in
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint.opacity(0.75), lineWidth: 1.2))
                    .frame(width: geo.pitchX * 0.92, height: geo.pitchY * 0.92)
                    .position(geo.center(cell))
            }
            let r = geo.shipRect(ship)
            BattleshipSprite(kind: ship.kind, alongPitch: r.vertical ? geo.pitchY : geo.pitchX,
                             acrossPitch: r.vertical ? geo.pitchX : geo.pitchY)
                .colorMultiply(ghost.legal ? .white : Color(red: 1, green: 0.35, blue: 0.3))
                .opacity(0.92)
                .rotationEffect(.degrees(r.vertical ? -90 : 0))
                .shadow(color: .black.opacity(0.45), radius: 5, x: 2, y: 5)
                .position(r.center)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Ship on the chart

private struct ChartShipView: View {
    let ship: BattleshipShip
    let style: BattleshipChartView.Ship.Style
    let geo: BattleshipChartGeometry
    let animated: Bool
    let delay: Double
    let reduceMotion: Bool

    @State private var settled: Bool

    init(ship: BattleshipShip, style: BattleshipChartView.Ship.Style, geo: BattleshipChartGeometry,
         animated: Bool, delay: Double, reduceMotion: Bool) {
        self.ship = ship
        self.style = style
        self.geo = geo
        self.animated = animated
        self.delay = delay
        self.reduceMotion = reduceMotion
        _settled = State(initialValue: !animated)
    }

    var body: some View {
        let r = geo.shipRect(ship)
        let look = Self.look(style)
        BattleshipSprite(kind: ship.kind, alongPitch: r.vertical ? geo.pitchY : geo.pitchX,
                         acrossPitch: r.vertical ? geo.pitchX : geo.pitchY)
            .colorMultiply(look.tint)
            .brightness(look.brightness)
            .rotationEffect(.degrees(r.vertical ? -90 : 0))
            // Shadow AFTER the rotation so light always falls down-right.
            .shadow(color: .black.opacity(style == .revealed ? 0.3 : 0.4), radius: settled ? 2 : 7,
                    x: settled ? 1 : 3, y: settled ? 2 : 7)
            .scaleEffect(settled || reduceMotion ? 1 : 1.12)
            .opacity(settled ? 1 : 0)
            .position(r.center)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.6), value: style)
            .onAppear {
                guard animated else { return }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.4).delay(delay)
                    : .spring(response: 0.5, dampingFraction: 0.72).delay(delay)
                withAnimation(animation) { settled = true }
            }
    }

    /// Plain steel; sunk = scorched red-brown; revealed = cool steel.
    private static func look(_ style: BattleshipChartView.Ship.Style) -> (tint: Color, brightness: Double) {
        switch style {
        case .plain: return (.white, 0)
        case .sunk: return (Color(red: 0.86, green: 0.40, blue: 0.34), -0.12)
        case .revealed: return (Color(red: 0.92, green: 0.95, blue: 1.0), 0)
        }
    }
}

// MARK: - Peg

private struct ChartPegView: View {
    let isHit: Bool
    let size: CGFloat
    let animated: Bool
    let reduceMotion: Bool

    @State private var landed: Bool
    @State private var settle = false

    init(isHit: Bool, size: CGFloat, animated: Bool, reduceMotion: Bool) {
        self.isHit = isHit
        self.size = size
        self.animated = animated
        self.reduceMotion = reduceMotion
        _landed = State(initialValue: !animated)
    }

    var body: some View {
        Image(isHit ? "PegHit" : "PegMiss")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            // Top-down drop: starts big (close to the lens), with a long
            // soft shadow, and lands small and crisp.
            .scaleEffect(landed ? (settle ? 0.93 : 1) : (reduceMotion ? 1 : 2.6))
            .shadow(color: .black.opacity(landed ? 0.5 : 0.22), radius: landed ? 1.2 : 9,
                    x: landed ? 0.6 : 6, y: landed ? 1.2 : 12)
            .opacity(landed ? 1 : 0)
            .onAppear {
                guard animated else { return }
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.3)) { landed = true }
                    return
                }
                withAnimation(.easeIn(duration: 0.28)) { landed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.35)) { settle = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { settle = false }
                    }
                }
            }
    }
}

// MARK: - Aim + mark

private struct MarkedRing: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .strokeBorder(BattleshipPalette.danger.opacity(0.85), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(pulse && !reduceMotion ? 1.12 : 1)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// The crosshair: it "lifts" off the paper (scales up with a long shadow)
/// when you aim, and breathes while it waits for FIRE.
private struct AimReticle: View {
    let size: CGFloat
    let reduceMotion: Bool
    var freeze = false
    @State private var lifted: Bool
    @State private var breathe = false

    init(size: CGFloat, reduceMotion: Bool, freeze: Bool = false) {
        self.size = size
        self.reduceMotion = reduceMotion
        self.freeze = freeze
        _lifted = State(initialValue: freeze)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(BattleshipPalette.danger, lineWidth: 2.2)
                .frame(width: size * 0.92, height: size * 0.92)
            Circle()
                .fill(BattleshipPalette.danger.opacity(0.14))
                .frame(width: size * 0.92, height: size * 0.92)
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(BattleshipPalette.danger)
                    .frame(width: 2.2, height: size * 0.42)
                    .offset(y: -size * 0.5)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle().fill(BattleshipPalette.danger).frame(width: 4, height: 4)
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .scaleEffect(lifted ? (breathe && !reduceMotion ? 1.42 : 1.32) : 2.2)
        .shadow(color: .black.opacity(0.45), radius: lifted ? 6 : 0, x: 0, y: lifted ? 7 : 0)
        .opacity(lifted ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.6)) { lifted = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(0.3)) { breathe = true }
        }
        .accessibilityHidden(true)
    }
}
