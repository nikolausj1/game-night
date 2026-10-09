import SwiftUI
import UIKit

/// Programmatic UNO cards — no image assets, drawn to read as the modern
/// printed deck at a glance: saturated color field to a thin white
/// card-stock border, a tilted white OUTLINE ring (not a filled ellipse),
/// and a bold white glyph with a heavy black outline plus a solid black
/// "3D base" shadow offset down-left, like ink printed slightly off-register.
/// Personal-use app, never App Store, so this leans hard into faithful
/// recreation over abstraction.

// MARK: - Palette

enum UnoStyle {
    static let red = Color(red: 0.929, green: 0.110, blue: 0.141)     // ED1C24
    static let yellow = Color(red: 1.000, green: 0.871, blue: 0.000)  // FFDE00
    static let green = Color(red: 0.000, green: 0.651, blue: 0.318)   // 00A651
    static let blue = Color(red: 0.000, green: 0.447, blue: 0.737)    // 0072BC
    static let wildBlack = Color(red: 0.07, green: 0.07, blue: 0.08)

    static func field(for color: UnoColor) -> Color {
        switch color {
        case .red: return red
        case .yellow: return yellow
        case .green: return green
        case .blue: return blue
        }
    }

    /// Field for a card's color; wilds (nil color) print on black.
    static func field(for color: UnoColor?) -> Color {
        guard let color else { return wildBlack }
        return field(for: color)
    }

    static let allFour: [Color] = [red, yellow, green, blue]

    /// `color` mixed toward white by `t` (0...1) — used to punch up the
    /// called-color glow so it reads as a saturated LED bloom rather than
    /// the flat print color it's glowing on top of.
    static func brightened(_ color: Color, by t: CGFloat) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: Double(r + (1 - r) * t),
                     green: Double(g + (1 - g) * t),
                     blue: Double(b + (1 - b) * t))
    }
}

// MARK: - Active color (discard-top glow)

/// Set around the discard pile's top card only, when it's showing an UNO
/// wild/wild-draw-four face, to the color that was called. `nil` (the
/// default) renders every wild face exactly as before — a plain wild in a
/// hand fan, or the table's own discard top before a color is picked, never
/// glows. See `UnoCardFaceView`'s wild/wild-draw-four glyphs for the effect.
private struct UnoActiveColorKey: EnvironmentKey {
    static let defaultValue: UnoColor? = nil
}

extension EnvironmentValues {
    var unoActiveColor: UnoColor? {
        get { self[UnoActiveColorKey.self] }
        set { self[UnoActiveColorKey.self] = newValue }
    }
}

// MARK: - Face

struct UnoCardFaceView: View {
    let color: UnoColor?
    let symbol: UnoSymbol

    /// Only set by the discard pile's own top-card render — see
    /// `unoActiveColor` above.
    @Environment(\.unoActiveColor) private var activeColor
    /// Reduce Motion: the called-color glow stays lit but stops breathing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the called-color glow's slow breathe. Only ever animated when
    /// this face is actually a wild sitting on top with a color called, so
    /// idle hand cards and buried discards never pay for a repeating timer.
    @State private var glowPulse = false

    private var fieldColor: Color { UnoStyle.field(for: color) }
    private var isWildFace: Bool { symbol == .wild || symbol == .wildDrawFour }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = CardStyle.cornerRadius(width: w)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fieldColor)
                centerArt(width: w)
                cornerIndex(width: w)
                    .rotationEffect(.degrees(0))
                cornerIndex(width: w)
                    .rotationEffect(.degrees(180))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white, lineWidth: max(1.5, w * 0.035))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.14), lineWidth: 0.75)
            }
        }
        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
        .onAppear { updateGlow() }
        // The discard top's view instance persists while a wild sits there
        // waiting for its color — `onAppear` alone would miss the moment
        // the color actually gets called, so re-evaluate on that change too.
        .onChange(of: activeColor) { _, _ in updateGlow() }
    }

    /// Starts (or stops) the called-color breathing glow. Gated so the
    /// repeating animation only ever runs on a wild face that's actually
    /// showing a called color — everything else pays nothing. Under Reduce
    /// Motion the glow snaps straight to its lit state and stays there,
    /// steady, with no breathing.
    private func updateGlow() {
        guard isWildFace, activeColor != nil else {
            glowPulse = false
            return
        }
        guard !reduceMotion else {
            glowPulse = true
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
    }

    // MARK: center art

    private func centerArt(width w: CGFloat) -> some View {
        ZStack {
            ellipseOrWheel(width: w)
            glyph(width: w)
        }
    }

    /// The signature tilted ellipse. On colored number/action cards it's a
    /// thick WHITE OUTLINE RING (stroke, not fill) so the field color shows
    /// through the middle. On wilds the ellipse itself becomes the glyph —
    /// four color quadrants inside that same white ring.
    @ViewBuilder
    private func ellipseOrWheel(width w: CGFloat) -> some View {
        let ellipseW = w * 0.98
        let ellipseH = w * 0.62
        if case .wild = symbol {
            ZStack {
                // The called-color bloom: the CALLED QUADRANT'S OWN wedge
                // shape (not a generic halo around the whole wheel) redrawn
                // oversized, blurred, and clipped to progressively larger
                // ellipses — three passes at increasing radius/opacity fake
                // a soft falloff instead of one flat blob. Sitting behind
                // the wheel, outside its clip, so it reads as light
                // bleeding out from under that ONE piece of the pie —
                // exactly the design element the owner wants glowing —
                // never as a wash over the whole card.
                if let activeColor {
                    let glowColor = UnoStyle.field(for: activeColor)
                    let angles = WildWheel.quadrant(for: activeColor)
                    let pulseOpacity: Double = glowPulse ? 1.0 : 0.55
                    ZStack {
                        PieSlice(startAngle: angles.0, endAngle: angles.1)
                            .fill(glowColor)
                            .frame(width: ellipseW * 1.55, height: ellipseH * 1.55)
                            .clipShape(Ellipse())
                            .blur(radius: w * 0.11)
                            .opacity(0.40 * pulseOpacity)
                        PieSlice(startAngle: angles.0, endAngle: angles.1)
                            .fill(glowColor)
                            .frame(width: ellipseW * 1.30, height: ellipseH * 1.30)
                            .clipShape(Ellipse())
                            .blur(radius: w * 0.065)
                            .opacity(0.60 * pulseOpacity)
                        PieSlice(startAngle: angles.0, endAngle: angles.1)
                            .fill(UnoStyle.brightened(glowColor, by: 0.3))
                            .frame(width: ellipseW * 1.12, height: ellipseH * 1.12)
                            .clipShape(Ellipse())
                            .blur(radius: w * 0.03)
                            .opacity(0.80 * pulseOpacity)
                    }
                    // The whole bloom stack breathes outward slightly —
                    // the closest safe stand-in for "enlarging the called
                    // quadrant": the wedge fill itself is already clipped
                    // flush to the card edge with no room to grow, but the
                    // glow around it visibly swells, reading as the same
                    // "popping proud" cue.
                    .scaleEffect(glowPulse ? 1.08 : 1.0)
                }
                WildWheel(activeColor: activeColor, pulse: glowPulse)
                    .frame(width: ellipseW, height: ellipseH)
                    .overlay(
                        Ellipse()
                            .stroke(.white, lineWidth: max(1.5, w * 0.028))
                            .frame(width: ellipseW, height: ellipseH)
                    )
            }
            .rotationEffect(.degrees(-28))
        } else {
            Ellipse()
                .stroke(.white, style: StrokeStyle(lineWidth: max(2, w * 0.045)))
                .frame(width: ellipseW, height: ellipseH)
                .rotationEffect(.degrees(-28))
        }
    }

    // MARK: central glyph

    @ViewBuilder
    private func glyph(width w: CGFloat) -> some View {
        switch symbol {
        case .number(let n):
            BasedOutlinedText(text: "\(n)",
                               font: .system(size: w * 0.46, weight: .heavy, design: .rounded),
                               outlineWidth: max(1.5, w * 0.022),
                               baseOffset: w * 0.035)
        case .skip:
            SkipGlyph(outlineWidth: w * 0.022, baseOffset: w * 0.03)
                .frame(width: w * 0.40, height: w * 0.40)
        case .reverse:
            ReverseGlyph(outlineWidth: w * 0.018, baseOffset: w * 0.03)
                .frame(width: w * 0.56, height: w * 0.42)
        case .drawTwo:
            drawTwoGlyph(width: w)
        case .wild:
            EmptyView() // the wheel above IS the glyph
        case .wildDrawFour:
            wildDrawFourGlyph(width: w)
        }
    }

    private func drawTwoGlyph(width w: CGFloat) -> some View {
        let cardW = w * 0.30
        let cardH = cardW / CardStyle.aspectRatio
        return ZStack {
            miniCardOutline(width: cardW, height: cardH)
                .rotationEffect(.degrees(-10))
                .offset(x: -cardW * 0.30, y: cardH * 0.14)
            miniCardOutline(width: cardW, height: cardH)
                .rotationEffect(.degrees(10))
                .offset(x: cardW * 0.30, y: -cardH * 0.14)
            BasedOutlinedText(text: "+2",
                               font: .system(size: w * 0.24, weight: .heavy, design: .rounded),
                               outlineWidth: max(1.2, w * 0.016),
                               baseOffset: w * 0.02)
        }
    }

    private func wildDrawFourGlyph(width w: CGFloat) -> some View {
        let cardW = w * 0.24
        let cardH = cardW / CardStyle.aspectRatio
        let outline = max(1, cardW * 0.09)
        // Back-to-front z-order matches the reference: green sits furthest
        // back, yellow tumbles out in front, bottom-left.
        var layout: [(color: Color, uno: UnoColor, dx: CGFloat, dy: CGFloat, angle: Double)] = [
            (UnoStyle.green, .green, 0.85, -0.85, 12),
            (UnoStyle.blue, .blue, 0.30, -0.05, 6),
            (UnoStyle.red, .red, -0.30, 0.10, -6),
            (UnoStyle.yellow, .yellow, -0.85, 0.55, -10)
        ]
        // The called color jumps to the end of the array — last drawn in
        // the ForEach below is topmost in the ZStack — so it tumbles out on
        // top of the other three exactly like a card that was just chosen.
        if let activeColor, let called = layout.firstIndex(where: { $0.uno == activeColor }) {
            layout.append(layout.remove(at: called))
        }
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { _, spec in
                let isCalled = activeColor != nil && spec.uno == activeColor
                let dim = activeColor != nil && !isCalled
                RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                    .fill(spec.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                            .strokeBorder(.black, lineWidth: outline)
                    )
                    .overlay(
                        // A bright ring on the called panel itself, IN ITS
                        // OWN COLOR (not gold) — on top of the black print
                        // outline.
                        RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                            .strokeBorder(UnoStyle.brightened(spec.color, by: 0.4),
                                          lineWidth: isCalled ? outline * (glowPulse ? 0.75 : 0.5) : 0)
                    )
                    .frame(width: cardW, height: cardH)
                    // The other three panels dim slightly once a color's
                    // called, so the called one visibly owns the stack.
                    .opacity(dim ? 0.75 : 1)
                    .rotationEffect(.degrees(spec.angle))
                    .offset(x: spec.dx * w * 0.16, y: spec.dy * w * 0.16)
                    // A gentle pop off the stack — the called mini-card
                    // physically stands proud of the others, breathing
                    // with the rest of the glow.
                    .scaleEffect(isCalled ? (glowPulse ? 1.12 : 1.05) : 1.0)
                    // Layered colored bloom — three passes at increasing
                    // radius/opacity, in the panel's OWN color, so the
                    // called card visibly glows rather than just outlines.
                    // Only the called panel casts it; pulses gently, not a
                    // strobe.
                    .shadow(color: isCalled ? spec.color.opacity(glowPulse ? 0.9 : 0.5) : .clear,
                            radius: isCalled ? cardW * (glowPulse ? 0.20 : 0.12) : 0)
                    .shadow(color: isCalled ? spec.color.opacity(glowPulse ? 0.6 : 0.3) : .clear,
                            radius: isCalled ? cardW * (glowPulse ? 0.42 : 0.26) : 0)
                    .shadow(color: isCalled ? spec.color.opacity(glowPulse ? 0.35 : 0.15) : .clear,
                            radius: isCalled ? cardW * (glowPulse ? 0.75 : 0.50) : 0)
            }
        }
    }

    private func miniCardOutline(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
            .fill(.white)
            .overlay(
                RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
                    .strokeBorder(.black, lineWidth: max(1, width * 0.10))
            )
            .frame(width: width, height: height)
    }

    // MARK: corner indices

    private func cornerIndex(width w: CGFloat) -> some View {
        cornerContent(width: w)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, w * 0.075)
            .padding(.top, w * 0.05)
    }

    @ViewBuilder
    private func cornerContent(width w: CGFloat) -> some View {
        switch symbol {
        case .number(let n):
            VStack(spacing: w * 0.012) {
                OutlinedText(text: "\(n)",
                             font: .system(size: w * 0.16, weight: .heavy, design: .rounded),
                             fillColor: .white,
                             outlineColor: .black,
                             outlineWidth: max(0.8, w * 0.013))
                // Every corner index gets a printed "base bar" underline —
                // on 6/9 it also disambiguates the 180°-rotated twin.
                RoundedRectangle(cornerRadius: w * 0.008, style: .continuous)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.008, style: .continuous)
                            .strokeBorder(.black, lineWidth: max(0.8, w * 0.011))
                    )
                    .frame(width: w * 0.10, height: max(2, w * 0.03))
            }
        case .skip:
            SkipGlyph(outlineWidth: w * 0.01, baseOffset: 0)
                .frame(width: w * 0.13, height: w * 0.13)
        case .reverse:
            ReverseGlyph(outlineWidth: w * 0.008, baseOffset: 0)
                .frame(width: w * 0.19, height: w * 0.14)
        case .drawTwo:
            OutlinedText(text: "+2",
                         font: .system(size: w * 0.135, weight: .heavy, design: .rounded),
                         fillColor: .white,
                         outlineColor: .black,
                         outlineWidth: max(0.8, w * 0.011))
        case .wild:
            WildWheel()
                .frame(width: w * 0.17, height: w * 0.11)
                .overlay(
                    Ellipse()
                        .stroke(.white, lineWidth: max(0.8, w * 0.012))
                        .frame(width: w * 0.17, height: w * 0.11)
                )
                .rotationEffect(.degrees(-28))
        case .wildDrawFour:
            OutlinedText(text: "+4",
                         font: .system(size: w * 0.135, weight: .heavy, design: .rounded),
                         fillColor: .white,
                         outlineColor: .black,
                         outlineWidth: max(0.8, w * 0.011))
        }
    }
}

// MARK: - Action glyph shapes

/// A pie wedge of an ellipse's bounding rect — four of these, filled in the
/// four UNO colors and clipped to an ellipse, form the wild-card wheel.
/// Quadrant colors match the real card: red top-left, blue top-right,
/// yellow bottom-left, green bottom-right (before the -28° card tilt).
private struct PieSlice: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height)
        p.move(to: center)
        p.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct WildWheel: View {
    /// The called color, when this wheel is the discard top and a color's
    /// been picked — traces its quadrant in ITS OWN color on top of the
    /// print, and dims the other three so the called one owns the card.
    var activeColor: UnoColor? = nil
    /// Shared breathe state from the face view — keeps the rim's pulse in
    /// lockstep with the bloom halo drawn behind this wheel.
    var pulse: Bool = false

    var body: some View {
        ZStack {
            PieSlice(startAngle: .degrees(180), endAngle: .degrees(270)).fill(quadrantFill(.red))     // top-left
            PieSlice(startAngle: .degrees(270), endAngle: .degrees(360)).fill(quadrantFill(.blue))     // top-right
            PieSlice(startAngle: .degrees(90), endAngle: .degrees(180)).fill(quadrantFill(.yellow))    // bottom-left
            PieSlice(startAngle: .degrees(0), endAngle: .degrees(90)).fill(quadrantFill(.green))       // bottom-right
            if let activeColor {
                // The rim: a thick, bright stroke traced on the called
                // quadrant's own boundary, IN ITS OWN COLOR — the glow
                // comes from the design element itself, not a decoration
                // laid over it. Breathes with the rest of the effect.
                let angles = Self.quadrant(for: activeColor)
                let rimColor = UnoStyle.brightened(UnoStyle.field(for: activeColor), by: 0.45)
                PieSlice(startAngle: angles.0, endAngle: angles.1)
                    .stroke(rimColor, lineWidth: pulse ? 5 : 3.5)
                    .shadow(color: UnoStyle.field(for: activeColor), radius: pulse ? 4 : 2)
            }
        }
        .clipShape(Ellipse())
    }

    /// The called quadrant prints at full strength; once a color's been
    /// called, the other three dim (~80% brightness) so they read as
    /// background instead of competing for attention.
    private func quadrantFill(_ color: UnoColor) -> Color {
        let base = UnoStyle.field(for: color)
        guard let activeColor, activeColor != color else { return base }
        return base.opacity(0.8)
    }

    static func quadrant(for color: UnoColor) -> (Angle, Angle) {
        switch color {
        case .red: return (.degrees(180), .degrees(270))
        case .blue: return (.degrees(270), .degrees(360))
        case .yellow: return (.degrees(90), .degrees(180))
        case .green: return (.degrees(0), .degrees(90))
        }
    }
}

/// Universal "no" glyph — an annulus (ring) crossed by a diagonal bar.
/// Renders in three passes so it reads exactly like the rest of the deck:
/// a solid black base shadow offset down-left, a heavier black silhouette
/// that becomes the outline once the white sits on top, then the white
/// ring + bar itself.
struct SkipGlyph: View {
    var outlineWidth: CGFloat
    var baseOffset: CGFloat

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let ringW = s * 0.16
            let barW = s * 0.15
            let barH = s * 0.96

            ZStack {
                // Base shadow — solid black silhouette, offset down-left.
                Group {
                    Circle().stroke(.black, style: StrokeStyle(lineWidth: ringW))
                    Rectangle().fill(.black).frame(width: barW, height: barH).rotationEffect(.degrees(45))
                }
                .offset(x: -baseOffset, y: baseOffset)

                // Heavy outline — wider black shapes at the true position,
                // peeking out from behind the white on top.
                Group {
                    Circle().stroke(.black, style: StrokeStyle(lineWidth: ringW + outlineWidth * 2))
                    Rectangle().fill(.black).frame(width: barW + outlineWidth * 2, height: barH + outlineWidth * 2)
                        .rotationEffect(.degrees(45))
                }

                // White face on top.
                Group {
                    Circle().stroke(.white, style: StrokeStyle(lineWidth: ringW))
                    Rectangle().fill(.white).frame(width: barW, height: barH).rotationEffect(.degrees(45))
                }
            }
            .frame(width: s, height: s)
        }
    }
}

/// One arrow of UNO's reverse glyph, traced from the owner's reference
/// card (`_inbox/new games/uno reverse.jpg`): NOT a curved ribbon — a
/// STRAIGHT thick shaft with a big triangular head at one end, whose tail
/// makes a tight 180° U-turn and rises in a short stub that runs parallel
/// to (and just clear of) its partner arrow's shaft. Two of these,
/// point-symmetric through the center, interlock into the famous S.
///
/// Built in a unit space with the arrow pointing straight up, then every
/// point is rotated 45° (up-right, like the print) and scaled to fit the
/// unit box before mapping into `rect`.
private struct ReverseArrow: Shape {
    /// 180° point-symmetry flag for the partner arrow.
    var flipped = false

    func path(in rect: CGRect) -> Path {
        // Unit-space layout (y-down screen convention), arrow pointing up:
        // shaft on the right, hook wrapping left under the partner.
        // Proportions verified against the reference by plotting this
        // exact math (see _review/night-reverse-glyph-check.png): the
        // shafts must be LONG relative to the hook — each head has to
        // clear ABOVE the partner's U-turn (whose top sits at
        // -hookTopY - ro), or the hook swallows the head. That was the
        // first attempt's failure mode.
        let w = 0.30            // shaft/stub thickness
        let axis = 0.20         // shaft centerline x
        let headTipY = -1.35
        let headBaseY = -0.95
        let headHalf = 0.32     // head half-span past the tip's centerline
        let hookTopY = 0.35     // where the shaft ends and the U-turn begins
        let stubTopY = -0.10    // stub rises alongside the partner's shaft
        let shaftL = axis - w / 2, shaftR = axis + w / 2
        // U-turn center: chosen so the stub clears the partner shaft
        // (at x ∈ [-shaftR, -shaftL]) by a visible outline gap.
        let hookC = -0.20
        let ro = shaftR - hookC          // outer hook radius
        let ri = shaftL - hookC          // inner hook radius

        var pts: [(Double, Double)] = []
        pts.append((axis, headTipY))                    // tip
        pts.append((axis + headHalf, headBaseY))        // head base, right
        pts.append((shaftR, headBaseY))                 // into the shaft
        pts.append((shaftR, hookTopY))                  // down the right edge
        // Outer U-turn, right → bottom → left.
        let arcN = 18
        for i in 0...arcN {
            let t = Double.pi * Double(i) / Double(arcN)
            pts.append((hookC + cos(t) * ro, hookTopY + sin(t) * ro))
        }
        pts.append((hookC - ro, stubTopY))              // stub outer edge up
        pts.append((hookC - ri, stubTopY))              // stub flat cut
        pts.append((hookC - ri, hookTopY))              // stub inner edge down
        // Inner U-turn, left → bottom → right.
        for i in stride(from: arcN, through: 0, by: -1) {
            let t = Double.pi * Double(i) / Double(arcN)
            pts.append((hookC + cos(t) * ri, hookTopY + sin(t) * ri))
        }
        pts.append((shaftL, headBaseY))                 // up the left edge
        pts.append((axis - headHalf, headBaseY))        // head base, left
        // close back to tip

        // Rotate 45° (up → up-right), flip for the partner, fit, map.
        let c = cos(Double.pi / 4), s = sin(Double.pi / 4)
        let fit = 0.66
        let sign: Double = flipped ? -1 : 1
        let cx = rect.midX, cy = rect.midY
        let ax = rect.width / 2, ay = rect.height / 2
        let screen: [CGPoint] = pts.map { (x, y) in
            let rx = (x * c - y * s) * fit * sign
            let ry = (x * s + y * c) * fit * sign
            return CGPoint(x: cx + rx * ax, y: cy + ry * ay)
        }

        var p = Path()
        p.addLines(screen)
        p.closeSubpath()
        return p
    }
}

/// Same three-pass treatment as `SkipGlyph`: black base shadow, black
/// outline, white face — built from `ReverseArrowPair`'s solid silhouette
/// so the outline is a true traced stroke rather than an oversized
/// duplicate.
struct ReverseGlyph: View {
    var outlineWidth: CGFloat
    var baseOffset: CGFloat

    var body: some View {
        ZStack {
            ReverseArrowPair()
                .foregroundStyle(.black)
                .offset(x: -baseOffset, y: baseOffset)
            ReverseArrowPair()
                .stroke(.black, lineWidth: outlineWidth * 2)
            ReverseArrowPair()
                .fill(.white)
        }
    }
}

/// Both arrows as a single Shape so `.stroke`/`.fill` apply uniformly to
/// the whole glyph. The second arrow is the first rotated 180° about the
/// shared center (point symmetry) — chasing point-to-tail, like the print.
private struct ReverseArrowPair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(ReverseArrow(flipped: false).path(in: rect))
        path.addPath(ReverseArrow(flipped: true).path(in: rect))
        return path
    }
}

// MARK: - Back

struct UnoCardBackView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = CardStyle.cornerRadius(width: w)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(UnoStyle.wildBlack)
                Ellipse()
                    .fill(UnoStyle.red)
                    .frame(width: w * 0.98, height: w * 0.64)
                    .rotationEffect(.degrees(-28))
                DoubleOutlinedText(text: "UNO",
                                    font: .system(size: w * 0.30, weight: .heavy, design: .rounded),
                                    fillColor: UnoStyle.yellow,
                                    innerOutlineColor: .black,
                                    outerOutlineColor: .white,
                                    innerWidth: w * 0.012,
                                    outerWidth: w * 0.028,
                                    kerning: w * 0.008)
                    .rotationEffect(.degrees(-9))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white, lineWidth: max(1.5, w * 0.035))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.14), lineWidth: 0.75)
                CardMaterial(width: w, seed: 0, linen: 0.30, ink: 0, wear: 0.5)
            }
            .compositingGroup()
        }
        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
    }
}

// MARK: - Outlined text helpers

/// Text with a simulated stroke: several offset copies in the outline color
/// behind a top copy in the fill color. SwiftUI's Text has no native
/// stroke, so this is the standard trick for a bold outlined logotype.
private struct OutlinedText: View {
    let text: String
    let font: Font
    let fillColor: Color
    let outlineColor: Color
    let outlineWidth: CGFloat
    var kerning: CGFloat = 0
    var copies: Int = 12

    var body: some View {
        ZStack {
            ForEach(0..<copies, id: \.self) { i in
                let rad = Double(i) / Double(copies) * 2 * .pi
                Text(text)
                    .font(font)
                    .kerning(kerning)
                    .foregroundStyle(outlineColor)
                    .offset(x: cos(rad) * outlineWidth, y: sin(rad) * outlineWidth)
            }
            Text(text)
                .font(font)
                .kerning(kerning)
                .foregroundStyle(fillColor)
        }
    }
}

/// `OutlinedText` plus a solid-black copy offset down-left underneath — the
/// deck's signature "3D base" shadow, as seen on every big center numeral.
private struct BasedOutlinedText: View {
    let text: String
    let font: Font
    var fillColor: Color = .white
    let outlineWidth: CGFloat
    let baseOffset: CGFloat

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .foregroundStyle(.black)
                .offset(x: -baseOffset, y: baseOffset)
            OutlinedText(text: text, font: font, fillColor: fillColor, outlineColor: .black, outlineWidth: outlineWidth)
        }
    }
}

/// Two nested outline passes around a filled copy — used for the "UNO"
/// logotype, which prints with a thin black inner outline and a thicker
/// white outer stroke beyond that.
private struct DoubleOutlinedText: View {
    let text: String
    let font: Font
    let fillColor: Color
    let innerOutlineColor: Color
    let outerOutlineColor: Color
    let innerWidth: CGFloat
    let outerWidth: CGFloat
    var kerning: CGFloat = 0
    var copies: Int = 16

    var body: some View {
        ZStack {
            ForEach(0..<copies, id: \.self) { i in
                let rad = Double(i) / Double(copies) * 2 * .pi
                Text(text)
                    .font(font)
                    .kerning(kerning)
                    .foregroundStyle(outerOutlineColor)
                    .offset(x: cos(rad) * outerWidth, y: sin(rad) * outerWidth)
            }
            ForEach(0..<copies, id: \.self) { i in
                let rad = Double(i) / Double(copies) * 2 * .pi
                Text(text)
                    .font(font)
                    .kerning(kerning)
                    .foregroundStyle(innerOutlineColor)
                    .offset(x: cos(rad) * innerWidth, y: sin(rad) * innerWidth)
            }
            Text(text)
                .font(font)
                .kerning(kerning)
                .foregroundStyle(fillColor)
        }
    }
}

#Preview("UNO faces") {
    HStack(spacing: 12) {
        UnoCardFaceView(color: .red, symbol: .number(7))
        UnoCardFaceView(color: .green, symbol: .number(6))
        UnoCardFaceView(color: .blue, symbol: .skip)
        UnoCardFaceView(color: .green, symbol: .reverse)
        UnoCardFaceView(color: .yellow, symbol: .drawTwo)
        UnoCardFaceView(color: nil, symbol: .wild)
        UnoCardFaceView(color: nil, symbol: .wildDrawFour)
        UnoCardBackView()
    }
    .frame(height: 240)
    .padding()
    .background(CardStyle.feltGreen)
}
