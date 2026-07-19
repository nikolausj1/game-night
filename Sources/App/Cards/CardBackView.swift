import SwiftUI

/// Programmatic card back: felt-green field, parchment margin, gold lattice.
/// May later be swapped for a generated raster back; this must stand on its
/// own regardless (placeholder-first rule).
struct CardBackView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = CardStyle.cornerRadius(width: w)
            let border = w * 0.045 // narrow printed ivory margin, like real stock
            ZStack {
                // The printed back: SAME rectangle as the face, art running
                // full-bleed to a thin margin — not a sheet sitting on top.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [CardStyle.feltGreen,
                                                  CardStyle.feltGreen.opacity(0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if UIImage(named: "CardBackArt") != nil {
                    Image("CardBackArt")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                } else {
                    // Programmatic fallback, also full-bleed.
                    LatticePattern(cell: w * 0.13)
                        .stroke(CardStyle.gold.opacity(0.55), lineWidth: max(0.5, w * 0.006))
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    ZStack {
                        Circle()
                            .fill(CardStyle.feltGreen)
                            .frame(width: w * 0.34)
                            .overlay(Circle().strokeBorder(CardStyle.gold.opacity(0.9),
                                                           lineWidth: max(1, w * 0.010)))
                        StarburstShape(points: 8)
                            .fill(CardStyle.gold.opacity(0.85))
                            .frame(width: w * 0.20, height: w * 0.20)
                    }
                }
                // The ivory printed border frames the art from above.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CardStyle.stockTop, lineWidth: border)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
            }
        }
        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
    }
}

/// Diagonal diamond lattice, drawn once per size.
struct LatticePattern: Shape {
    let cell: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard cell > 0 else { return path }
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            path.move(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += cell
        }
        return path
    }
}

/// One card, either side up, with a physical elevation model: shadow grows
/// and softens as the card lifts off the felt. Every card on every screen
/// goes through this view so depth reads consistently.
struct CardView: View {
    let card: Card
    var faceUp: Bool = true
    /// 0 = resting on felt, 1 = held aloft mid-drag.
    var elevation: CGFloat = 0

    var body: some View {
        ZStack {
            if faceUp {
                CardFaceView(card: card)
            } else {
                CardBackView()
            }
        }
        .compositingGroup()
        // Contact shadow: tight and dark when resting, fades as it lifts.
        .shadow(color: .black.opacity(0.30 - 0.18 * elevation),
                radius: 1.5 + 2 * elevation, y: 1)
        // Ambient shadow: grows and softens with height.
        .shadow(color: .black.opacity(0.18 + 0.12 * elevation),
                radius: 4 + 18 * elevation,
                y: 2 + 10 * elevation)
        .scaleEffect(1 + 0.06 * elevation)
    }
}

#Preview("Back + elevation") {
    HStack(spacing: 24) {
        CardView(card: Card(id: "b1", kind: .standard(suit: .clubs, rank: 2)), faceUp: false)
        CardView(card: Card(id: "h13", kind: .standard(suit: .hearts, rank: 13)), elevation: 0)
        CardView(card: Card(id: "s14", kind: .standard(suit: .spades, rank: 14)), elevation: 1)
    }
    .frame(height: 220)
    .padding(40)
    .background(CardStyle.feltGreen)
}
