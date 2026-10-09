import SwiftUI
import UIKit

// MARK: - Palette

enum BattleshipPalette {
    /// Chart ink: the navy the printed grid and letters use.
    static let ink = Color(red: 0.13, green: 0.19, blue: 0.33)
    static let water = Color(red: 0.22, green: 0.40, blue: 0.62)
    static let ember = Color(red: 0.96, green: 0.48, blue: 0.14)
    static let danger = Color(red: 0.78, green: 0.17, blue: 0.14)
    static let brassLight = Color(red: 0.99, green: 0.92, blue: 0.72)
    static let brassDark = Color(red: 0.52, green: 0.39, blue: 0.19)
    static let walnut = Color(red: 0.24, green: 0.15, blue: 0.09)
    static let walnutLight = Color(red: 0.36, green: 0.23, blue: 0.14)
}

// MARK: - Chart geometry

/// Where the printed 10x10 lives inside the `BattleshipGrid` art. Every
/// number is a fraction of the image's own side (measured from the art).
struct BattleshipChartGeometry {
    static let unitPitchX: CGFloat = 0.0738
    static let unitPitchY: CGFloat = 0.0735
    static let unitFirstCenterX: CGFloat = 0.2036
    static let unitFirstCenterY: CGFloat = 0.2112
    static let unitLeft: CGFloat = 0.2036 - 0.0738 / 2
    static let unitTop: CGFloat = 0.2112 - 0.0735 / 2

    let side: CGFloat
    var pitchX: CGFloat { side * Self.unitPitchX }
    var pitchY: CGFloat { side * Self.unitPitchY }

    func center(row: Int, col: Int) -> CGPoint {
        CGPoint(x: side * (Self.unitFirstCenterX + CGFloat(col) * Self.unitPitchX),
                y: side * (Self.unitFirstCenterY + CGFloat(row) * Self.unitPitchY))
    }

    func center(_ cell: BattleshipCell) -> CGPoint { center(row: cell.row, col: cell.col) }

    /// Continuous grid coordinates: (0,0) is the top-left corner of cell
    /// A1, (10,10) the bottom-right corner of J10.
    func units(at point: CGPoint) -> (u: CGFloat, v: CGFloat) {
        ((point.x / side - Self.unitLeft) / Self.unitPitchX,
         (point.y / side - Self.unitTop) / Self.unitPitchY)
    }

    /// The cell under `point`, or nil outside the printed grid.
    func cell(at point: CGPoint) -> BattleshipCell? {
        let (u, v) = units(at: point)
        guard u >= 0, v >= 0, u < 10, v < 10 else { return nil }
        return BattleshipCell(row: Int(v), col: Int(u))
    }

    /// Center and (unrotated) size of a ship laid on the chart.
    func shipRect(_ ship: BattleshipShip) -> (center: CGPoint, length: CGFloat, thickness: CGFloat, vertical: Bool) {
        let a = center(row: ship.row, col: ship.col)
        let n = CGFloat(ship.kind.length)
        let vertical = ship.orientation == .vertical
        let c = vertical
            ? CGPoint(x: a.x, y: a.y + (n - 1) * pitchY / 2)
            : CGPoint(x: a.x + (n - 1) * pitchX / 2, y: a.y)
        return (c, n * (vertical ? pitchY : pitchX), vertical ? pitchX : pitchY, vertical)
    }
}

func battleshipCellName(_ cell: BattleshipCell) -> String {
    let letters = Array("ABCDEFGHIJ")
    let col = max(0, min(9, cell.col))
    return "\(letters[col])\(cell.row + 1)"
}

// MARK: - Ship silhouettes (cropped from the sheet)

enum BattleshipArt {
    /// Each row of `ShipSilhouette`: left-aligned, y/w/h as fractions of
    /// the sheet. Rows are cropped out individually so a stretched ship
    /// never bleeds its neighbour.
    private static let rows: [BattleshipShipKind: (y: CGFloat, w: CGFloat, h: CGFloat)] = [
        .carrier: (0.0, 1.0, 0.2816),
        .battleship: (0.3036, 0.9406, 0.2047),
        .cruiser: (0.5302, 0.8705, 0.2074),
        .submarine: (0.7596, 0.4460, 0.1195),
        .destroyer: (0.9011, 0.3330, 0.0989),
    ]
    private static var cache: [BattleshipShipKind: UIImage] = [:]

    static func silhouette(_ kind: BattleshipShipKind) -> UIImage {
        if let hit = cache[kind] { return hit }
        guard let sheet = UIImage(named: "ShipSilhouette"), let cg = sheet.cgImage, let row = rows[kind] else {
            return UIImage()
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: 0, y: row.y * h, width: row.w * w, height: row.h * h).integral
        let image = cg.cropping(to: rect).map { UIImage(cgImage: $0, scale: sheet.scale, orientation: .up) } ?? sheet
        cache[kind] = image
        return image
    }
}

/// A ship drawn along its own length. Non-uniformly scaled on purpose:
/// the source rows don't hold a 5:4:3:3:2 ratio, so each is stretched to
/// exactly its cell run.
struct BattleshipSprite: View {
    let kind: BattleshipShipKind
    /// Distance covered per cell ALONG the ship.
    let alongPitch: CGFloat
    /// Cell thickness ACROSS the ship.
    let acrossPitch: CGFloat

    var body: some View {
        Image(uiImage: BattleshipArt.silhouette(kind))
            .resizable()
            .interpolation(.high)
            .frame(width: CGFloat(kind.length) * alongPitch * 0.96, height: acrossPitch * 0.82)
    }
}

// MARK: - Fleet tracker row

/// The five ships in a row; sunk ones go red and get struck through. Used
/// under each table chart and on the phone.
struct BattleshipFleetRow: View {
    var sunk: Set<BattleshipShipKind>
    var pitch: CGFloat
    var spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(BattleshipRules.fleet, id: \.self) { kind in
                let isSunk = sunk.contains(kind)
                BattleshipSprite(kind: kind, alongPitch: pitch, acrossPitch: pitch)
                    .colorMultiply(isSunk ? Color(red: 0.95, green: 0.42, blue: 0.36) : .white)
                    .saturation(isSunk ? 0.9 : 1)
                    .brightness(isSunk ? -0.12 : 0)
                    .opacity(isSunk ? 0.8 : 1)
                    .overlay {
                        if isSunk {
                            Rectangle().fill(BattleshipPalette.danger)
                                .frame(height: max(1.5, pitch * 0.16))
                                .rotationEffect(.degrees(-8))
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .accessibilityLabel("\(kind.displayName)\(isSunk ? ", sunk" : "")")
            }
        }
    }
}

// MARK: - Brass button

/// Brass / gold lozenge: the one button voice for Battleship.
struct BrassButtonStyle: ButtonStyle {
    enum Tone { case gold, brass }
    var tone: Tone = .gold
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        BrassBody(configuration: configuration, tone: tone, large: large)
    }

    private struct BrassBody: View {
        let configuration: ButtonStyleConfiguration
        let tone: Tone
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let top = tone == .gold ? BattleshipPalette.brassLight : Color(red: 0.86, green: 0.76, blue: 0.52)
            let mid = tone == .gold ? CardStyle.gold : Color(red: 0.66, green: 0.52, blue: 0.28)
            configuration.label
                .font(.system(large ? .title3 : .headline, design: .serif).weight(.bold))
                .tracking(large ? 1.5 : 0.3)
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, large ? 30 : 20)
                .padding(.vertical, large ? 13 : 10)
                .background(
                    Capsule()
                        .fill(LinearGradient(colors: [top, mid, BattleshipPalette.brassDark],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1).padding(1))
                        .overlay(Capsule().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: configuration.isPressed ? 2 : 6,
                                y: configuration.isPressed ? 1 : 4)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .saturation(isEnabled ? 1 : 0.2)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Shake

/// Horizontal shake that settles to rest at every whole number of
/// `animatableData`: bump a counter inside `withAnimation` to trigger.
struct BattleshipShake: GeometryEffect {
    var amount: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * 7), y: 0))
    }
}

// MARK: - Impact effects

enum ChartEffectKind { case splash, burst }

/// A short-lived impact flourish pinned to a cell. Owners append and prune.
struct ChartEffect: Identifiable, Equatable {
    let id = UUID()
    var cell: BattleshipCell
    var kind: ChartEffectKind
    /// Previews / render harness: draw frozen at this progress (0...1)
    /// instead of running on the clock.
    var frozenProgress: Double?
}

/// Splash (miss) / burst (hit), drawn from elapsed time so arcs and ripples
/// are real curves rather than two-keyframe tweens. Reduce Motion swaps the
/// whole thing for a single soft pulse in place.
struct ChartEffectView: View {
    let effect: ChartEffect
    let pitch: CGFloat
    let reduceMotion: Bool

    @State private var start = Date()
    @State private var finished = false

    private var duration: Double { effect.kind == .burst ? 1.05 : 1.0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished || effect.frozenProgress != nil)) { context in
            let t = effect.frozenProgress ?? max(0, min(1, context.date.timeIntervalSince(start) / duration))
            Canvas { gc, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                if reduceMotion {
                    drawStatic(gc, c, t)
                } else if effect.kind == .burst {
                    drawBurst(gc, c, t)
                } else {
                    drawSplash(gc, c, t)
                }
            }
        }
        .frame(width: pitch * 4, height: pitch * 4)
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000))
            finished = true
        }
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func drawStatic(_ gc: GraphicsContext, _ c: CGPoint, _ t: Double) {
        let color = effect.kind == .burst ? BattleshipPalette.ember : BattleshipPalette.water
        let r = pitch * 0.55
        gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(0.5 * (1 - t))))
    }

    private func drawSplash(_ gc: GraphicsContext, _ c: CGPoint, _ t: Double) {
        // Three staggered ripples, navy ink with a bright inner lip.
        for i in 0..<3 {
            let local = max(0, min(1, (t - Double(i) * 0.14) / 0.72))
            guard local > 0 else { continue }
            let r = pitch * (0.12 + 0.95 * ease(local))
            let alpha = (1 - local) * 0.85
            let rect = CGRect(x: c.x - r, y: c.y - r * 0.82, width: r * 2, height: r * 1.64)
            gc.stroke(Path(ellipseIn: rect), with: .color(BattleshipPalette.water.opacity(alpha)), lineWidth: 2.0)
            gc.stroke(Path(ellipseIn: rect.insetBy(dx: 1.6, dy: 1.3)), with: .color(.white.opacity(alpha * 0.8)), lineWidth: 1.0)
        }
        // Droplets on little parabolas.
        for i in 0..<8 {
            let a = Double(i) / 8 * 2 * .pi + 0.4
            let reach = pitch * (0.45 + 0.35 * Double((i * 5) % 3) / 2)
            let x = c.x + CGFloat(cos(a) * reach * ease(t))
            let rise = sin(t * .pi) * Double(pitch) * (0.5 + 0.25 * Double(i % 3))
            let y = c.y + CGFloat(sin(a) * reach * 0.6 * ease(t)) - CGFloat(rise)
            let r = max(0.6, pitch * 0.075 * (1 - t * 0.6))
            let drop = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: drop), with: .color(.white.opacity(1 - t)))
            gc.stroke(Path(ellipseIn: drop), with: .color(BattleshipPalette.water.opacity(0.8 * (1 - t))), lineWidth: 0.8)
        }
    }

    private func drawBurst(_ gc: GraphicsContext, _ c: CGPoint, _ t: Double) {
        // Smoke puff drifting up, behind everything.
        let smokeR = pitch * (0.35 + 0.7 * ease(t))
        let smokeC = CGPoint(x: c.x + pitch * 0.1 * CGFloat(t), y: c.y - pitch * 0.55 * CGFloat(ease(t)))
        gc.fill(Path(ellipseIn: CGRect(x: smokeC.x - smokeR, y: smokeC.y - smokeR, width: smokeR * 2, height: smokeR * 2)),
                with: .color(Color(white: 0.25).opacity(0.38 * pow(1 - t, 1.5))))
        // Flash: white-hot core fading through orange.
        let flashR = pitch * (0.25 + 1.0 * ease(min(1, t * 1.6)))
        let flashAlpha = pow(max(0, 1 - t * 1.25), 1.6)
        gc.fill(Path(ellipseIn: CGRect(x: c.x - flashR, y: c.y - flashR, width: flashR * 2, height: flashR * 2)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(flashAlpha), Color(red: 1, green: 0.85, blue: 0.35).opacity(flashAlpha * 0.9),
                                      BattleshipPalette.ember.opacity(flashAlpha * 0.55), .clear]),
                    center: c, startRadius: 0, endRadius: flashR))
        // Rays.
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi + 0.2
            let inner = pitch * (0.2 + 0.4 * ease(t))
            let outer = pitch * (0.5 + 1.0 * ease(t)) * (i.isMultiple(of: 2) ? 1 : 0.7)
            var p = Path()
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * outer, y: c.y + CGFloat(sin(a)) * outer))
            gc.stroke(p, with: .color(BattleshipPalette.ember.opacity(0.9 * (1 - t))),
                      style: StrokeStyle(lineWidth: max(1, pitch * 0.06), lineCap: .round))
        }
        // Embers with a touch of gravity.
        for i in 0..<9 {
            let a = Double(i) / 9 * 2 * .pi + 0.9
            let speed = pitch * (0.7 + 0.5 * Double((i * 7) % 4) / 3)
            let x = c.x + CGFloat(cos(a) * speed * ease(t))
            let y = c.y + CGFloat(sin(a) * speed * ease(t) + 0.9 * Double(pitch) * t * t) - pitch * 0.2
            let r = max(0.5, pitch * 0.05 * (1 - t))
            gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(red: 1, green: 0.78, blue: 0.3).opacity(1 - t)))
        }
    }
}
