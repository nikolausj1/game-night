import SwiftUI

/// The craft crux of the whole feature: a Quarto piece rendered as
/// convincing turned wood, seen from a natural slightly-elevated angle
/// (never flat top-down) — dark walnut vs pale maple, a genuine height
/// difference between tall and short (not just a label), round vs square
/// silhouettes, and hollow pieces with a visible bore drilled into the
/// top. Matches the owner-supplied reference photo
/// (`_inbox/new games/quarto.jpg`): every real piece there has a
/// horizontal groove ring turned into its middle, hollow pieces show a
/// round bore even when the piece itself is square, and tall pieces run
/// roughly 2x short height.
///
/// Built the same way `ChipToken` (DiceTableView.swift) sells "real metal
/// coin, not clip-art": a body gradient for the lit-from-above material,
/// a raised/lit cap face for the top surface, and a carved band for
/// texture. No image asset backs this — no sprite sheet was present at
/// `_review/assets/quarto/` when this shipped (see the check in
/// `QuartoView.swift`), so this programmatic rendering IS the piece, not
/// a placeholder for one.
struct QuartoPieceView: View {
    let piece: QuartoPiece
    /// Footprint width — cylinder diameter (round) or post side (square).
    var diameter: CGFloat = 54
    var isHighlighted: Bool = false

    private var palette: WoodPalette { piece.isDark ? .walnut : .maple }
    /// Tall pieces run ~2x short height, per the reference photo.
    private var totalHeight: CGFloat { diameter * (piece.isTall ? 2.05 : 1.05) }
    private var capHeight: CGFloat { diameter * 0.36 }
    private var bodyHeight: CGFloat { totalHeight - capHeight * 0.5 }

    var body: some View {
        ZStack {
            if piece.isRound {
                roundBody
            } else {
                squareBody
            }
        }
        .frame(width: diameter * 1.1, height: totalHeight)
        .scaleEffect(isHighlighted ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isHighlighted ? 0.5 : 0.32),
               radius: isHighlighted ? 11 : 6, y: diameter * 0.10)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        "\(piece.isTall ? "Tall" : "Short") \(piece.isDark ? "dark" : "light") "
            + "\(piece.isRound ? "round" : "square") \(piece.isHollow ? "hollow" : "solid") piece"
    }

    // MARK: - Round (cylindrical post)

    private var roundBody: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [palette.rimLight, palette.mid, palette.shadow],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    // A soft angular sheen sweeping around the curve — the
                    // "turned on a lathe" catch-light, not a flat fill.
                    Capsule()
                        .fill(AngularGradient(colors: [.clear, .white.opacity(0.16), .clear,
                                                       .black.opacity(0.20), .clear],
                                              center: .center))
                        .blendMode(.overlay)
                )
                .frame(width: diameter, height: bodyHeight)
                .offset(y: capHeight * 0.28)

            grooveRing.offset(y: capHeight * 0.28 + bodyHeight * 0.13)

            Ellipse()
                .fill(RadialGradient(colors: [palette.capHighlight, palette.capMid, palette.rimLight],
                                     center: UnitPoint(x: 0.36, y: 0.32), startRadius: 0, endRadius: diameter * 0.6))
                .overlay(bore)
                .overlay(Ellipse().strokeBorder(palette.shadow.opacity(0.55), lineWidth: 1))
                .frame(width: diameter, height: capHeight)
                .offset(y: -bodyHeight / 2 + capHeight * 0.12)
        }
    }

    // MARK: - Square (post with chamfered corners)

    private var squareBody: some View {
        let corner = diameter * 0.14
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [palette.rimLight, palette.mid, palette.shadow],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    // Narrow shaded/lit strips at the edges so the post
                    // reads as a square COLUMN, not a flat card.
                    HStack(spacing: 0) {
                        Rectangle().fill(palette.shadow.opacity(0.30)).frame(width: diameter * 0.16)
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.white.opacity(0.10)).frame(width: diameter * 0.11)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                )
                .frame(width: diameter, height: bodyHeight)
                .offset(y: capHeight * 0.28)

            grooveRing.offset(y: capHeight * 0.28 + bodyHeight * 0.13)

            RoundedRectangle(cornerRadius: corner * 0.85, style: .continuous)
                .fill(RadialGradient(colors: [palette.capHighlight, palette.capMid, palette.rimLight],
                                     center: UnitPoint(x: 0.36, y: 0.32), startRadius: 0, endRadius: diameter * 0.6))
                .overlay(bore)
                .overlay(RoundedRectangle(cornerRadius: corner * 0.85, style: .continuous)
                    .strokeBorder(palette.shadow.opacity(0.55), lineWidth: 1))
                .frame(width: diameter * 0.92, height: capHeight * 0.82)
                .offset(y: -bodyHeight / 2 + capHeight * 0.12)
        }
    }

    // MARK: - Shared detail: groove ring + bore

    /// A carved band roughly 60% down the piece, matching every piece in
    /// the reference photo — a dark stroke directly above a light stroke
    /// fakes a lathe-cut indentation on the material's own curve/face.
    private var grooveRing: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.shadow.opacity(0.6)).frame(height: max(1, diameter * 0.026))
            Rectangle().fill(palette.rimLight.opacity(0.4)).frame(height: max(1, diameter * 0.018))
        }
        .frame(width: diameter * (piece.isRound ? 0.98 : 0.90))
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    /// Hollow pieces (round OR square) get a round bore drilled into the
    /// top — matches the reference photo exactly (square pieces there
    /// still show a circular hole, not a square one).
    @ViewBuilder private var bore: some View {
        if piece.isHollow {
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.88), palette.shadow.opacity(0.65), .clear],
                                     center: .center, startRadius: 0, endRadius: diameter * 0.22))
                .frame(width: diameter * 0.42, height: capHeight * 0.58)
        }
    }
}

/// The two wood tones every piece is turned from.
private struct WoodPalette {
    let capHighlight: Color
    let capMid: Color
    let rimLight: Color
    let mid: Color
    let shadow: Color

    /// Pale maple — light, warm, low-saturation tan.
    static let maple = WoodPalette(
        capHighlight: Color(red: 0.97, green: 0.90, blue: 0.72),
        capMid: Color(red: 0.90, green: 0.79, blue: 0.56),
        rimLight: Color(red: 0.86, green: 0.73, blue: 0.48),
        mid: Color(red: 0.78, green: 0.63, blue: 0.38),
        shadow: Color(red: 0.55, green: 0.42, blue: 0.24))

    /// Dark walnut — deep warm brown, still readable as wood (never
    /// crosses into near-black plastic).
    static let walnut = WoodPalette(
        capHighlight: Color(red: 0.50, green: 0.34, blue: 0.20),
        capMid: Color(red: 0.37, green: 0.24, blue: 0.14),
        rimLight: Color(red: 0.31, green: 0.20, blue: 0.12),
        mid: Color(red: 0.23, green: 0.15, blue: 0.09),
        shadow: Color(red: 0.12, green: 0.08, blue: 0.05))
}

#Preview("Quarto pieces — all 16") {
    let columns = Array(repeating: GridItem(.flexible()), count: 4)
    return ScrollView {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(QuartoPiece.all) { piece in
                QuartoPieceView(piece: piece, diameter: 46)
                    .frame(height: 110, alignment: .bottom)
            }
        }
        .padding(30)
    }
    .background(Color(red: 0.10, green: 0.12, blue: 0.11))
}
