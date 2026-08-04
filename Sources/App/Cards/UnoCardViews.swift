import SwiftUI

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
}

// MARK: - Face

struct UnoCardFaceView: View {
    let color: UnoColor?
    let symbol: UnoSymbol

    private var fieldColor: Color { UnoStyle.field(for: color) }

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
            WildWheel()
                .frame(width: ellipseW, height: ellipseH)
                .overlay(
                    Ellipse()
                        .stroke(.white, lineWidth: max(1.5, w * 0.028))
                        .frame(width: ellipseW, height: ellipseH)
                )
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
        let layout: [(color: Color, dx: CGFloat, dy: CGFloat, angle: Double)] = [
            (UnoStyle.green, 0.85, -0.85, 12),
            (UnoStyle.blue, 0.30, -0.05, 6),
            (UnoStyle.red, -0.30, 0.10, -6),
            (UnoStyle.yellow, -0.85, 0.55, -10)
        ]
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { _, spec in
                RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                    .fill(spec.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                            .strokeBorder(.black, lineWidth: outline)
                    )
                    .frame(width: cardW, height: cardH)
                    .rotationEffect(.degrees(spec.angle))
                    .offset(x: spec.dx * w * 0.16, y: spec.dy * w * 0.16)
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
    var body: some View {
        ZStack {
            PieSlice(startAngle: .degrees(180), endAngle: .degrees(270)).fill(UnoStyle.red)     // top-left
            PieSlice(startAngle: .degrees(270), endAngle: .degrees(360)).fill(UnoStyle.blue)     // top-right
            PieSlice(startAngle: .degrees(90), endAngle: .degrees(180)).fill(UnoStyle.yellow)    // bottom-left
            PieSlice(startAngle: .degrees(0), endAngle: .degrees(90)).fill(UnoStyle.green)       // bottom-right
        }
        .clipShape(Ellipse())
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

/// An L-shaped bent arrow with a triangular head — two of these, rotated
/// 180° from one another, approximate UNO's chasing-arrows reverse glyph.
private struct BentArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let thickness = w * 0.30
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 0, y: 0, width: w * 0.80, height: thickness),
                          cornerSize: CGSize(width: thickness / 2, height: thickness / 2))
        p.addRoundedRect(in: CGRect(x: w * 0.80 - thickness, y: 0, width: thickness, height: h * 0.78),
                          cornerSize: CGSize(width: thickness / 2, height: thickness / 2))
        var head = Path()
        let hx = w * 0.80 - thickness / 2
        let hy = h * 0.78
        head.move(to: CGPoint(x: hx - thickness * 1.15, y: hy - thickness * 0.1))
        head.addLine(to: CGPoint(x: hx + thickness * 1.15, y: hy - thickness * 0.1))
        head.addLine(to: CGPoint(x: hx, y: h))
        head.closeSubpath()
        p.addPath(head)
        return p
    }
}

/// Same three-pass treatment as `SkipGlyph`: black base shadow, black
/// outline, white face — built from `BentArrow`'s solid silhouette so the
/// outline is a true traced stroke rather than an oversized duplicate.
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
/// the whole glyph, matching whatever frame the caller assigns.
private struct ReverseArrowPair: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let arrowW = w * 0.58, arrowH = h * 0.9
        var path = Path()

        var left = BentArrow().path(in: CGRect(x: 0, y: 0, width: arrowW, height: arrowH))
        let leftOrigin = CGPoint(x: w * 0.33 - arrowW / 2, y: h * 0.5 - arrowH / 2)
        left = left.applying(CGAffineTransform(translationX: leftOrigin.x, y: leftOrigin.y))
        path.addPath(left)

        var right = BentArrow().path(in: CGRect(x: 0, y: 0, width: arrowW, height: arrowH))
        // Rotate 180° about the arrow's own center, then translate into place.
        let rotate180 = CGAffineTransform(translationX: arrowW / 2, y: arrowH / 2)
            .rotated(by: .pi)
            .translatedBy(x: -arrowW / 2, y: -arrowH / 2)
        right = right.applying(rotate180)
        let rightOrigin = CGPoint(x: w * 0.67 - arrowW / 2, y: h * 0.5 - arrowH / 2)
        right = right.applying(CGAffineTransform(translationX: rightOrigin.x, y: rightOrigin.y))
        path.addPath(right)

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
            }
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
