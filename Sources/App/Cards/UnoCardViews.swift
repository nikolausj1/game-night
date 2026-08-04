import SwiftUI

/// Programmatic UNO cards — no image assets, drawn to read as the real thing
/// at a glance: saturated color field, white card-stock border, the
/// signature tilted white ellipse, a bold central glyph with an offset
/// drop-shadow, and small rotated corner indices. Personal-use app, never
/// App Store, so this leans hard into faithful recreation over abstraction.

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
            glyph(width: w, big: true)
        }
    }

    @ViewBuilder
    private func ellipseOrWheel(width w: CGFloat) -> some View {
        let ellipseW = w * 0.98
        let ellipseH = w * 0.62
        if case .wild = symbol {
            // "wild = ellipse split into 4 color quadrants" — the ellipse
            // itself becomes the glyph.
            WildWheel()
                .frame(width: ellipseW, height: ellipseH)
                .rotationEffect(.degrees(-28))
                .overlay(
                    Ellipse()
                        .stroke(.white, lineWidth: max(1, w * 0.012))
                        .frame(width: ellipseW, height: ellipseH)
                        .rotationEffect(.degrees(-28))
                )
        } else {
            Ellipse()
                .fill(.white)
                .frame(width: ellipseW, height: ellipseH)
                .rotationEffect(.degrees(-28))
                .shadow(color: .black.opacity(0.20), radius: w * 0.012, y: w * 0.007)
        }
    }

    // MARK: central glyph

    @ViewBuilder
    private func glyph(width w: CGFloat, big: Bool) -> some View {
        switch symbol {
        case .number(let n):
            numberGlyph(n, width: w, big: big)
        case .skip:
            SkipGlyph()
                .frame(width: w * (big ? 0.40 : 0.15), height: w * (big ? 0.40 : 0.15))
                .foregroundStyle(fieldColor)
        case .reverse:
            ReverseGlyph()
                .frame(width: w * (big ? 0.52 : 0.20), height: w * (big ? 0.40 : 0.15))
                .foregroundStyle(fieldColor)
        case .drawTwo:
            drawTwoGlyph(width: w, big: big)
        case .wild:
            EmptyView() // the wheel above IS the glyph
        case .wildDrawFour:
            wildDrawFourGlyph(width: w, big: big)
        }
    }

    private func numberGlyph(_ n: Int, width w: CGFloat, big: Bool) -> some View {
        Group {
            if big {
                ZStack {
                    // Small color-matched oval so the number reads inside
                    // the white ellipse rather than floating on it.
                    Ellipse()
                        .fill(fieldColor)
                        .frame(width: w * 0.60, height: w * 0.38)
                    dropShadowNumber(n, size: w * 0.46)
                }
            } else {
                dropShadowNumber(n, size: w * 0.16, outlineOnly: true)
            }
        }
    }

    private func dropShadowNumber(_ n: Int, size: CGFloat, outlineOnly: Bool = false) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text("\(n)")
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.32))
                    .offset(x: size * 0.05, y: size * 0.06)
                Text("\(n)")
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            if n == 6 || n == 9 {
                Rectangle()
                    .fill(.white)
                    .frame(width: size * 0.44, height: max(1, size * 0.05))
                    .padding(.top, size * 0.02)
            }
        }
    }

    private func drawTwoGlyph(width w: CGFloat, big: Bool) -> some View {
        let cardW = w * (big ? 0.30 : 0.12)
        let cardH = cardW / CardStyle.aspectRatio
        return ZStack {
            miniCardOutline(width: cardW, height: cardH)
                .rotationEffect(.degrees(-10))
                .offset(x: -cardW * 0.30, y: cardH * 0.14)
            miniCardOutline(width: cardW, height: cardH)
                .rotationEffect(.degrees(10))
                .offset(x: cardW * 0.30, y: -cardH * 0.14)
            plusText("+2", size: w * (big ? 0.26 : 0.11))
        }
        .foregroundStyle(fieldColor)
    }

    private func wildDrawFourGlyph(width w: CGFloat, big: Bool) -> some View {
        let cardW = w * (big ? 0.22 : 0.10)
        let cardH = cardW / CardStyle.aspectRatio
        let spread = w * (big ? 0.30 : 0.14)
        let layout: [(dx: CGFloat, dy: CGFloat, angle: Double)] = [
            (-1.5, 0.10, -14), (-0.5, -0.06, -5), (0.5, 0.06, 5), (1.5, -0.10, 14)
        ]
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { i, spec in
                RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                    .fill(UnoStyle.allFour[i])
                    .overlay(RoundedRectangle(cornerRadius: cardW * 0.16, style: .continuous)
                        .strokeBorder(.white, lineWidth: max(0.5, cardW * 0.05)))
                    .frame(width: cardW, height: cardH)
                    .rotationEffect(.degrees(spec.angle))
                    .offset(x: spec.dx * spread / 3, y: spec.dy * spread)
            }
            plusText("+4", size: w * (big ? 0.22 : 0.095))
                .foregroundStyle(.white)
        }
    }

    private func plusText(_ s: String, size: CGFloat) -> some View {
        ZStack {
            Text(s)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(.black.opacity(0.30))
                .offset(x: size * 0.05, y: size * 0.06)
            Text(s)
                .font(.system(size: size, weight: .heavy, design: .rounded))
        }
    }

    private func miniCardOutline(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
            .fill(.white)
            .overlay(
                RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
                    .strokeBorder(lineWidth: max(1, width * 0.10))
            )
            .frame(width: width, height: height)
    }

    // MARK: corner indices

    private func cornerIndex(width w: CGFloat) -> some View {
        cornerContent(width: w)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, w * 0.075)
            .padding(.top, w * 0.05)
    }

    @ViewBuilder
    private func cornerContent(width w: CGFloat) -> some View {
        switch symbol {
        case .number(let n):
            VStack(spacing: 0) {
                Text("\(n)")
                    .font(.system(size: w * 0.16, weight: .heavy, design: .rounded))
                if n == 6 || n == 9 {
                    Rectangle().frame(width: w * 0.07, height: max(1, w * 0.012))
                }
            }
        case .skip:
            SkipGlyph().frame(width: w * 0.13, height: w * 0.13)
        case .reverse:
            ReverseGlyph().frame(width: w * 0.17, height: w * 0.13)
        case .drawTwo:
            Text("+2").font(.system(size: w * 0.135, weight: .heavy, design: .rounded))
        case .wild:
            Circle()
                .strokeBorder(lineWidth: max(1, w * 0.012))
                .frame(width: w * 0.12, height: w * 0.12)
        case .wildDrawFour:
            Text("+4").font(.system(size: w * 0.135, weight: .heavy, design: .rounded))
        }
    }
}

// MARK: - Action glyph shapes

/// A pie wedge of an ellipse's bounding rect — four of these, filled in the
/// four UNO colors and clipped to an ellipse, form the wild-card wheel.
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
            PieSlice(startAngle: .degrees(0), endAngle: .degrees(90)).fill(UnoStyle.allFour[0])
            PieSlice(startAngle: .degrees(90), endAngle: .degrees(180)).fill(UnoStyle.allFour[1])
            PieSlice(startAngle: .degrees(180), endAngle: .degrees(270)).fill(UnoStyle.allFour[2])
            PieSlice(startAngle: .degrees(270), endAngle: .degrees(360)).fill(UnoStyle.allFour[3])
        }
        .clipShape(Ellipse())
    }
}

/// Universal "no" glyph — circle with a diagonal slash.
struct SkipGlyph: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: s * 0.16))
                // Length s places both endpoints exactly on the circle's
                // rim, however the bar is rotated — rotation preserves each
                // point's distance from center.
                Rectangle()
                    .frame(width: s * 0.15, height: s * 0.96)
                    .rotationEffect(.degrees(45))
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

struct ReverseGlyph: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                BentArrow()
                    .frame(width: w * 0.58, height: h * 0.9)
                    .position(x: w * 0.33, y: h * 0.5)
                BentArrow()
                    .rotationEffect(.degrees(180))
                    .frame(width: w * 0.58, height: h * 0.9)
                    .position(x: w * 0.67, y: h * 0.5)
            }
        }
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
                    .fill(UnoStyle.red)
                Ellipse()
                    .fill(.black)
                    .frame(width: w * 0.98, height: w * 0.64)
                    .rotationEffect(.degrees(-28))
                OutlinedText(text: "UNO",
                             font: .system(size: w * 0.30, weight: .heavy, design: .rounded),
                             fillColor: UnoStyle.yellow,
                             outlineColor: .white,
                             outlineWidth: w * 0.012,
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

/// Text with a simulated stroke: eight offset copies in the outline color
/// behind a top copy in the fill color. SwiftUI's Text has no native
/// stroke, so this is the standard trick for a bold outlined logotype.
private struct OutlinedText: View {
    let text: String
    let font: Font
    let fillColor: Color
    let outlineColor: Color
    let outlineWidth: CGFloat
    var kerning: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let rad = Double(i) * .pi / 4
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

#Preview("UNO faces") {
    HStack(spacing: 12) {
        UnoCardFaceView(color: .red, symbol: .number(7))
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
