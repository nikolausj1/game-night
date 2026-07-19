import SwiftUI

/// A playing-card face drawn entirely in SwiftUI — no raster assets.
/// Sized by its container; keep the CardStyle.aspectRatio when placing it.
struct CardFaceView: View {
    let card: Card

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                cardStock(width: w)
                switch card.kind {
                case .standard(let suit, let rank):
                    standardFace(suit: suit, rank: rank, width: w)
                case .wizard:
                    specialFace(letter: "W", title: "WIZARD", color: CardStyle.wizardIndigo, width: w)
                case .jester:
                    specialFace(letter: "J", title: "JESTER", color: CardStyle.jesterPlum, width: w)
                }
            }
        }
        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
    }

    // MARK: stock

    private func cardStock(width w: CGFloat) -> some View {
        let radius = CardStyle.cornerRadius(width: w)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [CardStyle.stockTop, CardStyle.stockBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                // Printed inner frame — the hallmark of real card stock.
                RoundedRectangle(cornerRadius: radius * 0.62, style: .continuous)
                    .strokeBorder(CardStyle.ink.opacity(0.10), lineWidth: max(0.5, w * 0.006))
                    .padding(w * 0.045)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: standard faces

    private func standardFace(suit: Suit, rank: Int, width w: CGFloat) -> some View {
        let color = CardStyle.inkColor(for: suit)
        return ZStack {
            cornerIndex(suit: suit, rank: rank, width: w)
            cornerIndex(suit: suit, rank: rank, width: w)
                .rotationEffect(.degrees(180))
            Group {
                if rank == 14 {
                    aceCenter(suit: suit, width: w)
                } else if rank >= 11 {
                    courtCenter(suit: suit, rank: rank, width: w)
                } else {
                    pipGrid(suit: suit, rank: rank, width: w)
                }
            }
            .foregroundStyle(color)
        }
    }

    private func cornerIndex(suit: Suit, rank: Int, width w: CGFloat) -> some View {
        VStack(spacing: -w * 0.012) {
            Text(indexLabel(rank))
                .font(.system(size: w * 0.155, weight: .semibold, design: .serif))
                .kerning(-w * 0.004)
            Text(suit.symbol)
                .font(.system(size: w * 0.125))
        }
        .foregroundStyle(CardStyle.inkColor(for: suit))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, w * 0.065)
        .padding(.top, w * 0.055)
    }

    private func indexLabel(_ rank: Int) -> String {
        switch rank {
        case 14: return "A"
        case 13: return "K"
        case 12: return "Q"
        case 11: return "J"
        default: return String(rank)
        }
    }

    private func aceCenter(suit: Suit, width w: CGFloat) -> some View {
        Text(suit.symbol)
            .font(.system(size: w * 0.52))
            .shadow(color: .black.opacity(0.12), radius: w * 0.008, y: w * 0.006)
    }

    /// Typographic court cards: ornate frame, large serif letter, mirrored
    /// pips. Deliberate art direction — richer than clip-art royals.
    private func courtCenter(suit: Suit, rank: Int, width w: CGFloat) -> some View {
        let color = CardStyle.inkColor(for: suit)
        return ZStack {
            RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.85), lineWidth: max(1, w * 0.010))
                .background(
                    RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                        .fill(color.opacity(0.055))
                )
                .frame(width: w * 0.52, height: w * 0.78)
            VStack(spacing: w * 0.015) {
                Text(suit.symbol).font(.system(size: w * 0.11))
                Text(indexLabel(rank))
                    .font(.system(size: w * 0.34, weight: .bold, design: .serif))
                Text(suit.symbol).font(.system(size: w * 0.11))
                    .rotationEffect(.degrees(180))
            }
            .foregroundStyle(color)
        }
    }

    // MARK: pips

    /// Classic pip arrangements for ranks 2–10, in unit coordinates
    /// (x: 0-left…1-right, y: 0-top…1-bottom of the pip area). `flip` pips
    /// render upside-down like a printed card's lower half.
    private func pipPositions(_ rank: Int) -> [(x: CGFloat, y: CGFloat, flip: Bool)] {
        let L: CGFloat = 0.22, C: CGFloat = 0.5, R: CGFloat = 0.78
        switch rank {
        case 2: return [(C, 0.08, false), (C, 0.92, true)]
        case 3: return [(C, 0.08, false), (C, 0.5, false), (C, 0.92, true)]
        case 4: return [(L, 0.08, false), (R, 0.08, false), (L, 0.92, true), (R, 0.92, true)]
        case 5: return [(L, 0.08, false), (R, 0.08, false), (C, 0.5, false), (L, 0.92, true), (R, 0.92, true)]
        case 6: return [(L, 0.08, false), (R, 0.08, false), (L, 0.5, false), (R, 0.5, false), (L, 0.92, true), (R, 0.92, true)]
        case 7: return [(L, 0.08, false), (R, 0.08, false), (C, 0.29, false), (L, 0.5, false), (R, 0.5, false), (L, 0.92, true), (R, 0.92, true)]
        case 8: return [(L, 0.08, false), (R, 0.08, false), (C, 0.29, false), (L, 0.5, false), (R, 0.5, false), (C, 0.71, true), (L, 0.92, true), (R, 0.92, true)]
        case 9: return [(L, 0.08, false), (R, 0.08, false), (L, 0.36, false), (R, 0.36, false), (C, 0.5, false), (L, 0.64, true), (R, 0.64, true), (L, 0.92, true), (R, 0.92, true)]
        case 10: return [(L, 0.08, false), (R, 0.08, false), (C, 0.22, false), (L, 0.36, false), (R, 0.36, false), (L, 0.64, true), (R, 0.64, true), (C, 0.78, true), (L, 0.92, true), (R, 0.92, true)]
        default: return []
        }
    }

    private func pipGrid(suit: Suit, rank: Int, width w: CGFloat) -> some View {
        let pipSize = w * (rank <= 3 ? 0.20 : 0.165)
        let areaW = w * 0.56
        let areaH = w * 0.56 / CardStyle.aspectRatio * 0.82
        return ZStack {
            ForEach(Array(pipPositions(rank).enumerated()), id: \.offset) { _, pip in
                Text(suit.symbol)
                    .font(.system(size: pipSize))
                    .rotationEffect(.degrees(pip.flip ? 180 : 0))
                    .position(x: pip.x * areaW, y: pip.y * areaH)
            }
        }
        .frame(width: areaW, height: areaH)
    }

    // MARK: wizard & jester

    private func specialFace(letter: String, title: String, color: Color, width w: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: w) * 0.62, style: .continuous)
                .fill(
                    RadialGradient(colors: [color.opacity(0.92), color],
                                   center: .center, startRadius: 0, endRadius: w * 0.75)
                )
                .padding(w * 0.045)
            // Starburst behind the letter.
            StarburstShape(points: 8)
                .fill(.white.opacity(0.10))
                .frame(width: w * 0.85, height: w * 0.85)
            VStack(spacing: w * 0.02) {
                Text(letter)
                    .font(.system(size: w * 0.44, weight: .black, design: .serif))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: w * 0.015, y: w * 0.01)
                Text(title)
                    .font(.system(size: w * 0.085, weight: .semibold, design: .serif))
                    .kerning(w * 0.02)
                    .foregroundStyle(CardStyle.gold)
            }
            // Corner letters so it reads in a fan.
            VStack {
                HStack {
                    Text(letter).padding([.top, .leading], w * 0.06)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(letter).rotationEffect(.degrees(180)).padding([.bottom, .trailing], w * 0.06)
                }
            }
            .font(.system(size: w * 0.14, weight: .bold, design: .serif))
            .foregroundStyle(.white.opacity(0.92))
        }
    }
}

/// Simple N-point starburst used on special cards.
struct StarburstShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.42
        for i in 0..<(points * 2) {
            let angle = (CGFloat(i) / CGFloat(points * 2)) * 2 * .pi - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

#Preview("Faces") {
    HStack(spacing: 12) {
        CardFaceView(card: Card(id: "h14", kind: .standard(suit: .hearts, rank: 14)))
        CardFaceView(card: Card(id: "s12", kind: .standard(suit: .spades, rank: 12)))
        CardFaceView(card: Card(id: "d7", kind: .standard(suit: .diamonds, rank: 7)))
        CardFaceView(card: Card(id: "W0", kind: .wizard))
        CardFaceView(card: Card(id: "J0", kind: .jester))
    }
    .frame(height: 240)
    .padding()
    .background(CardStyle.feltGreen)
}
