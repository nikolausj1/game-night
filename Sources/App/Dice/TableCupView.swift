import SwiftUI

/// Manual cup loading's table-side hardware: a realistic open dice cup
/// sitting at the current roller's rail edge, PLUS the loose dice waiting
/// to be dragged into it. `gn.autoCup` off (the default) means a human
/// roller must load every required die before `DiceGameController.roll`
/// will do anything — see `DiceGameController.canRoll`/`loadDie`.
///
/// The cup itself is presentation-only (`allowsHitTesting(false)`): the
/// interaction lives entirely on `LoadableDieToken`, which knows where the
/// cup's mouth is via `TableCupView.mouthOffset(for:)` and reports back
/// through `onLoaded` when a drag lands there. `DiceTableView` owns
/// placement (seat anchor → edge, plate position → die homes) since that
/// geometry is shared with the rest of the felt; this file only knows how
/// to draw a cup and animate one die falling into it.
struct TableCupView: View {
    /// Which rail this cup sits against — the same four-way convention
    /// TableGameView's plate rotation uses (bottom 0°, top 180°, left 90°,
    /// right -90°), so a cup always tilts its mouth toward the table
    /// center and lets its body bleed off the correct screen edge.
    enum RailEdge {
        case bottom, top, left, right

        var rotation: Angle {
            switch self {
            case .bottom: return .degrees(0)
            case .top: return .degrees(180)
            case .left: return .degrees(90)
            case .right: return .degrees(-90)
            }
        }
    }

    var edge: RailEdge
    /// How many of the required dice are already loaded — purely cosmetic
    /// here (a fuller-looking mouth as dice go in); the gate itself lives
    /// in the controller.
    var loadedCount: Int
    var requiredCount: Int

    /// Canonical (unrotated, "bottom seat") footprint: mouth near the top
    /// (toward the table), tapered leather body bleeding downward (toward
    /// the seat, past the rail).
    private let bodyWidth: CGFloat = 128
    private let bodyHeight: CGFloat = 132
    private let mouthWidth: CGFloat = 118
    private let mouthHeight: CGFloat = 50

    /// Where the mouth sits relative to wherever the caller `.position()`s
    /// this view, ALREADY rotated for `edge` — callers aim drops here
    /// without needing to know the cup's internal layout.
    static func mouthOffset(for edge: RailEdge) -> CGVector {
        let distance: CGFloat = 56
        switch edge {
        case .bottom: return CGVector(dx: 0, dy: -distance)
        case .top: return CGVector(dx: 0, dy: distance)
        case .left: return CGVector(dx: distance, dy: 0)
        case .right: return CGVector(dx: -distance, dy: 0)
        }
    }

    var body: some View {
        ZStack {
            leatherBody
            mouthInterior
            brassBand
            if loadedCount > 0 {
                loadedGlints
            }
        }
        .frame(width: bodyWidth + 20, height: bodyHeight + mouthHeight)
        .rotationEffect(edge.rotation)
        .allowsHitTesting(false) // LoadableDieToken owns the interaction
        .animation(.easeInOut(duration: 0.25), value: loadedCount)
    }

    // MARK: - Body

    /// A tapered rounded trapezoid: wide at the mouth, pinched toward a
    /// stable base — leather-toned with a soft vertical material sweep and
    /// a couple of tooled seam lines so it doesn't read as flat plastic.
    private var leatherBody: some View {
        CupBodyShape(taper: 0.68, corner: 16)
            .fill(LinearGradient(
                colors: [
                    Color(red: 0.46, green: 0.29, blue: 0.15),
                    Color(red: 0.30, green: 0.18, blue: 0.09),
                    Color(red: 0.20, green: 0.12, blue: 0.06),
                ],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                CupBodyShape(taper: 0.68, corner: 16)
                    .stroke(Color(red: 0.12, green: 0.07, blue: 0.03), lineWidth: 1.5)
            )
            .overlay(seams)
            .overlay(
                // Material sheen: a soft diagonal highlight, the kind of
                // thing worn leather always catches under an overhead lamp.
                CupBodyShape(taper: 0.68, corner: 16)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.16), .clear, .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .frame(width: bodyWidth, height: bodyHeight)
            .offset(y: mouthHeight * 0.32) // body hangs below the mouth ellipse
            .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
    }

    private var seams: some View {
        VStack(spacing: bodyHeight * 0.30) {
            Capsule()
                .stroke(Color.black.opacity(0.22), lineWidth: 1)
                .frame(width: bodyWidth * 0.86, height: 1)
            Capsule()
                .stroke(Color.black.opacity(0.18), lineWidth: 1)
                .frame(width: bodyWidth * 0.70, height: 1)
        }
        .padding(.top, mouthHeight * 0.5)
    }

    // MARK: - Mouth

    /// Looking down into the cup: a dark felt-red interior gradient (deep
    /// crimson at the rim easing to near-black in the throat) so the mouth
    /// reads as a real opening, not a painted circle.
    private var mouthInterior: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [
                    Color(red: 0.05, green: 0.02, blue: 0.02),
                    Color(red: 0.30, green: 0.05, blue: 0.05),
                    Color(red: 0.46, green: 0.09, blue: 0.08),
                ],
                center: .center, startRadius: 2, endRadius: mouthWidth * 0.55))
            .frame(width: mouthWidth, height: mouthHeight)
            .offset(y: -bodyHeight * 0.34)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
    }

    /// The rim: a raised brass band with a milled inner ring, matching the
    /// coin/chip material language elsewhere on the table.
    private var brassBand: some View {
        ZStack {
            Ellipse()
                .strokeBorder(LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.90, blue: 0.60),
                        Color(red: 0.72, green: 0.52, blue: 0.20),
                        Color(red: 0.95, green: 0.80, blue: 0.42),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: mouthHeight * 0.11)
                .frame(width: mouthWidth + mouthHeight * 0.11, height: mouthHeight + mouthHeight * 0.11)
            Ellipse()
                .stroke(Color(red: 0.45, green: 0.30, blue: 0.10).opacity(0.6),
                       style: StrokeStyle(lineWidth: mouthHeight * 0.045,
                                          dash: [mouthHeight * 0.09, mouthHeight * 0.08]))
                .frame(width: mouthWidth * 0.90, height: mouthHeight * 0.90)
        }
        .offset(y: -bodyHeight * 0.34)
    }

    /// A hint of loaded dice sitting in the throat — small pale glints,
    /// more of them as `loadedCount` climbs toward `requiredCount`.
    private var loadedGlints: some View {
        HStack(spacing: mouthWidth * 0.10) {
            ForEach(0..<max(0, loadedCount), id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(white: 0.92))
                    .frame(width: mouthWidth * 0.14, height: mouthWidth * 0.14)
                    .rotationEffect(.degrees(TableGeometry.jitterDegrees(cardID: "cup\(index)") * 2))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
        }
        .offset(y: -bodyHeight * 0.30)
        .opacity(0.85)
    }
}

/// Tapered rounded-trapezoid silhouette shared by the cup body.
private struct CupBodyShape: Shape {
    var taper: CGFloat = 0.68
    var corner: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let topW = rect.width
        let botW = rect.width * taper
        let topL = CGPoint(x: rect.midX - topW / 2, y: rect.minY)
        let topR = CGPoint(x: rect.midX + topW / 2, y: rect.minY)
        let botR = CGPoint(x: rect.midX + botW / 2, y: rect.maxY)
        let botL = CGPoint(x: rect.midX - botW / 2, y: rect.maxY)
        let c = min(corner, rect.height / 2, topW / 4)

        var path = Path()
        path.move(to: CGPoint(x: topL.x + c, y: topL.y))
        path.addLine(to: CGPoint(x: topR.x - c, y: topR.y))
        path.addQuadCurve(to: CGPoint(x: topR.x, y: topR.y + c), control: topR)
        path.addLine(to: CGPoint(x: botR.x, y: botR.y - c))
        path.addQuadCurve(to: CGPoint(x: botR.x - c, y: botR.y), control: botR)
        path.addLine(to: CGPoint(x: botL.x + c, y: botL.y))
        path.addQuadCurve(to: CGPoint(x: botL.x, y: botL.y - c), control: botL)
        path.addLine(to: CGPoint(x: topL.x, y: topL.y + c))
        path.addQuadCurve(to: CGPoint(x: topL.x + c, y: topL.y), control: topL)
        path.closeSubpath()
        return path
    }
}

/// One 2D die waiting by the roller's plate, draggable into the cup's
/// mouth. A drop within `captureRadius` of `cupMouth` plays the "falls in"
/// beat — shrink, drop, soft rattle — then reports `onLoaded`; anywhere
/// else it springs back home. Tracks its OWN loaded state (rather than
/// being removed from a shrinking list by its caller) so a batch of these
/// can sit at STABLE indices/identities for an entire loading phase — no
/// reindex-on-remove jump for the dice the player didn't touch yet.
struct LoadableDieToken: View {
    let home: CGPoint
    let cupMouth: CGPoint
    /// Flavor only — which face shows at rest. Physics decides the real
    /// result once the roll actually happens.
    let face: LcrFace
    let onLoaded: () -> Void

    static let captureRadius: CGFloat = 60

    @State private var offset: CGSize = .zero
    @State private var dragging = false
    @State private var loaded = false
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 1

    var body: some View {
        dieFace
            .frame(width: 42, height: 42)
            .scaleEffect(scale)
            .opacity(opacity)
            .shadow(color: .black.opacity(dragging ? 0.45 : 0.22),
                    radius: dragging ? 11 : 4, y: dragging ? 7 : 2)
            .position(x: home.x + offset.width, y: home.y + offset.height)
            .allowsHitTesting(!loaded)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !loaded else { return }
                        if !dragging { dragging = true; Haptics.tick() }
                        offset = value.translation
                    }
                    .onEnded { value in
                        guard !loaded else { return }
                        dragging = false
                        let at = CGPoint(x: home.x + value.translation.width,
                                         y: home.y + value.translation.height)
                        if hypot(at.x - cupMouth.x, at.y - cupMouth.y) <= Self.captureRadius {
                            loaded = true
                            Haptics.arm()
                            TableSFX.shared.playDiceContact(.die, strength: 0.45)
                            withAnimation(.easeIn(duration: 0.22)) {
                                offset = CGSize(width: cupMouth.x - home.x,
                                                height: cupMouth.y - home.y)
                                scale = 0.22
                                opacity = 0
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                                onLoaded()
                            }
                        } else {
                            withAnimation(.interpolatingSpring(stiffness: 300, damping: 14)) {
                                offset = .zero
                            }
                        }
                    }
            )
    }

    private var dieFace: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.88)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
            )
            .overlay(faceGlyph)
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
    }

    @ViewBuilder
    private var faceGlyph: some View {
        let crimson = Color(red: 0.72, green: 0.09, blue: 0.09)
        switch face {
        case .dot:
            Circle().fill(crimson).frame(width: 11, height: 11)
        case .left:
            Text("L").font(.system(size: 21, weight: .black, design: .serif)).foregroundStyle(crimson)
        case .right:
            Text("R").font(.system(size: 21, weight: .black, design: .serif)).foregroundStyle(crimson)
        case .center:
            Text("C").font(.system(size: 21, weight: .black, design: .serif)).foregroundStyle(crimson)
        }
    }
}
