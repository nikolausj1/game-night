import SwiftUI

/// A stable (non-random-per-frame) pseudo-random source for stroke jitter.
/// Swift's `Hasher` is deliberately re-seeded every process launch — fine
/// for dictionaries, wrong here, since it would make every claimed line's
/// waviness reshuffle on every redraw within the SAME launch (view identity
/// churn, SwiftUI diffing) and look like it's crawling. FNV-1a over the
/// edge's own coordinates gives the exact same jitter every time the exact
/// same line is drawn, in this session or the next.
enum PencilJitter {
    static func hash(_ values: [Int]) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for v in values {
            h ^= UInt64(bitPattern: Int64(v))
            h = h &* 1099511628211
        }
        return h
    }

    /// A stable value in `0..<1` for a given set of integer seeds.
    static func unit(_ values: Int...) -> CGFloat {
        CGFloat(hash(values) % 10_000) / 10_000
    }
}

/// One jittered polyline between two dots: a few short segments (not one
/// straight line — a real pencil stroke wavers), with a slight overshoot
/// past each endpoint, the way a hand doesn't stop exactly on the mark.
/// `seed` should be unique per rendered stroke (derived from the edge's own
/// coordinates) so the waviness is reproducible, not re-rolled per frame.
struct PencilStrokeShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let seed: Int

    private let segmentCount = 5
    private let overshootFraction: CGFloat = 0.09
    private let jitterFraction: CGFloat = 0.045

    func path(in rect: CGRect) -> Path {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        var path = Path()
        guard length > 0.5 else { return path }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let overshoot = length * overshootFraction
        let trueStart = CGPoint(x: start.x - unit.x * overshoot, y: start.y - unit.y * overshoot)
        let trueEnd = CGPoint(x: end.x + unit.x * overshoot, y: end.y + unit.y * overshoot)

        path.move(to: trueStart)
        for i in 1...segmentCount {
            let t = CGFloat(i) / CGFloat(segmentCount)
            let base = CGPoint(x: trueStart.x + (trueEnd.x - trueStart.x) * t,
                                y: trueStart.y + (trueEnd.y - trueStart.y) * t)
            // Jitter tapers to zero at the very ends so the overshoot tips
            // stay clean rather than fraying.
            let taper = sin(.pi * t)
            let magnitude = (PencilJitter.unit(seed, i) - 0.5) * length * jitterFraction * taper
            path.addLine(to: CGPoint(x: base.x + normal.x * magnitude, y: base.y + normal.y * magnitude))
        }
        return path
    }
}

/// The rendered stroke: three overlaid passes of the same jittered path at
/// different widths/opacities (a soft wide underlayer, a solid core, a
/// faint highlight) — cheap graphite-texture stand-in for a pressure-mapped
/// brush. Animates in via `trim` on appear unless Reduce Motion is on, in
/// which case it's simply drawn complete.
struct DotsAndBoxesPencilStrokeView: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color
    let seed: Int
    var lineWidth: CGFloat = 3.2

    @Environment(\.accessibilityReduceMotion) private var motionReduced
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            PencilStrokeShape(start: start, end: end, seed: seed &* 31 &+ 7)
                .trim(from: 0, to: progress)
                .stroke(color.opacity(0.30), style: StrokeStyle(lineWidth: lineWidth * 1.7, lineCap: .round, lineJoin: .round))
                .blur(radius: 0.7)
            PencilStrokeShape(start: start, end: end, seed: seed)
                .trim(from: 0, to: progress)
                .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            PencilStrokeShape(start: start, end: end, seed: seed &* 17 &+ 3)
                .trim(from: 0, to: progress)
                .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round, lineJoin: .round))
        }
        .onAppear {
            if motionReduced {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 0.30)) { progress = 1 }
            }
        }
    }
}

/// The initial written inside a completed box: a handwritten letterform
/// (system `SnellRoundhand`, no bundled font needed) with a slight tilt for
/// imperfection, revealed by a left-to-right wipe on appear — a cheap but
/// convincing stand-in for an animated stroke-in of real cursive geometry.
struct DotsAndBoxesInitialView: View {
    let initial: String
    let color: Color
    let fontSize: CGFloat
    /// Deterministic per-box jitter seed (pass the box's row/col).
    let seed: Int

    @Environment(\.accessibilityReduceMotion) private var motionReduced
    @State private var revealed: CGFloat = 0

    private var tiltDegrees: Double {
        Double(PencilJitter.unit(seed, 99)) * 8 - 4
    }

    var body: some View {
        Text(initial)
            .font(.custom(DotsAndBoxesTheme.handwritingFont, size: fontSize))
            .foregroundStyle(color)
            .rotationEffect(.degrees(tiltDegrees))
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().frame(width: geo.size.width * revealed)
                }
            }
            .onAppear {
                if motionReduced {
                    revealed = 1
                } else {
                    withAnimation(.easeOut(duration: 0.35)) { revealed = 1 }
                }
            }
    }
}
