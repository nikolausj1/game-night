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
                case .uno(let color, let symbol):
                    UnoCardFaceView(color: color, symbol: symbol)
                }
            }
        }
        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
        // The printed pips/corner indices are a pile of individually
        // swipeable Text glyphs with nothing useful to say on their own —
        // CardView (the shared wrapper) supplies one real accessibility
        // label for the whole card instead.
        .accessibilityHidden(true)
    }

    // MARK: stock

    /// Deterministic per-card "wear" in 0..<1000, from the card's own stable
    /// `id` — same djb2-style hash `TableGeometry.jitterDegrees` uses for
    /// per-card table jitter, kept local here so card-stock rendering stays
    /// self-contained. One hash of a short string per render, never
    /// per-frame randomness, so it costs nothing and never flickers.
    private func wearSeed(_ id: String) -> Int {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(hash % 1000)
    }

    private func cardStock(width w: CGFloat) -> some View {
        let radius = CardStyle.cornerRadius(width: w)
        // A few degrees of ivory-tone variation and barely-there corner/edge
        // softening, so a fan of cards reads as individual well-handled
        // stock rather than identical clones — aged, not dirty: warmth only
        // ever adds a whisper of sepia, never grays a card down.
        let wear = wearSeed(card.id)
        let warmth = Double(wear % 45) / 1000.0                 // 0...0.044
        let edgeSoften = CGFloat(wear % 7) / 7.0 * 0.6           // 0...0.6pt
        let radiusJitter: CGFloat = 1 + (CGFloat(wear % 5) - 2) / 260.0 // ~0.992...1.008
        let cornerRadius = radius * radiusJitter

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [CardStyle.stockTop, CardStyle.stockBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 0.62, green: 0.47, blue: 0.26).opacity(warmth))
            )
            .overlay(
                // Printed inner frame — the hallmark of real card stock.
                RoundedRectangle(cornerRadius: cornerRadius * 0.62, style: .continuous)
                    .strokeBorder(CardStyle.ink.opacity(0.10), lineWidth: max(0.5, w * 0.006))
                    .padding(w * 0.045)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                    .blur(radius: edgeSoften)
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

    /// Ornate scanned-art center for the ace of spades when the asset is
    /// bundled; otherwise the plain typographic pip.
    private func aceCenter(suit: Suit, width w: CGFloat) -> some View {
        Group {
            if suit == .spades, UIImage(named: "AceOfSpadesArt") != nil {
                Image("AceOfSpadesArt")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: w * 0.6)
            } else {
                Text(suit.symbol)
                    .font(.system(size: w * 0.52))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: w * 0.008, y: w * 0.006)
    }

    /// Maps a court rank/suit to its bundled art asset name, e.g. "Court_KS"
    /// for the king of spades. Returns nil for non-court ranks.
    private func courtAssetName(suit: Suit, rank: Int) -> String? {
        let rankLetter: String
        switch rank {
        case 11: rankLetter = "J"
        case 12: rankLetter = "Q"
        case 13: rankLetter = "K"
        default: return nil
        }
        let suitLetter: String
        switch suit {
        case .spades: suitLetter = "S"
        case .hearts: suitLetter = "H"
        case .diamonds: suitLetter = "D"
        case .clubs: suitLetter = "C"
        }
        return "Court_\(rankLetter)\(suitLetter)"
    }

    /// Court cards: ornate gold frame stays constant; inside it renders the
    /// bundled traditional court-figure art when available, falling back to
    /// the typographic letter/pips design when the asset is missing.
    private func courtCenter(suit: Suit, rank: Int, width w: CGFloat) -> some View {
        let color = CardStyle.inkColor(for: suit)
        let frameW = w * 0.52
        let frameH = w * 0.78
        let assetName = courtAssetName(suit: suit, rank: rank)
        return ZStack {
            RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.85), lineWidth: max(1, w * 0.010))
                .background(
                    RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                        .fill(color.opacity(0.055))
                )
                .frame(width: frameW, height: frameH)
            if let assetName, UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: frameW * 0.92, height: frameH * 0.92)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.03, style: .continuous))
            } else {
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

/// VoiceOver-friendly spoken name for a card — "Ace of Spades", "Red 7",
/// "Wild Draw Four", "Wizard" — used wherever a card needs an accessibility
/// label instead of relying on its printed pips/glyphs. Mirrors the same
/// rank/suit vocabulary `CardFaceView.indexLabel` and `Suit.symbol` draw on,
/// just spelled out in full words instead of single letters.
extension Card {
    var accessibleName: String {
        switch kind {
        case .standard(let suit, let rank):
            return "\(Card.rankWord(rank)) of \(suit.rawValue.capitalized)"
        case .wizard:
            return "Wizard"
        case .jester:
            return "Jester"
        case .uno(let color, let symbol):
            return Card.unoAccessibleName(color: color, symbol: symbol)
        }
    }

    private static func rankWord(_ rank: Int) -> String {
        switch rank {
        case 14: return "Ace"
        case 13: return "King"
        case 12: return "Queen"
        case 11: return "Jack"
        default: return String(rank)
        }
    }

    private static func unoAccessibleName(color: UnoColor?, symbol: UnoSymbol) -> String {
        let colorWord = color?.rawValue.capitalized
        switch symbol {
        case .number(let n): return [colorWord, "\(n)"].compactMap { $0 }.joined(separator: " ")
        case .skip: return [colorWord, "Skip"].compactMap { $0 }.joined(separator: " ")
        case .reverse: return [colorWord, "Reverse"].compactMap { $0 }.joined(separator: " ")
        case .drawTwo: return [colorWord, "Draw Two"].compactMap { $0 }.joined(separator: " ")
        case .wild: return "Wild"
        case .wildDrawFour: return "Wild Draw Four"
        }
    }
}

#Preview("Faces") {
    HStack(spacing: 12) {
        CardFaceView(card: Card(id: "h14", kind: .standard(suit: .hearts, rank: 14)))
        CardFaceView(card: Card(id: "s12", kind: .standard(suit: .spades, rank: 12)))
        CardFaceView(card: Card(id: "d7", kind: .standard(suit: .diamonds, rank: 7)))
        CardFaceView(card: Card(id: "W0", kind: .wizard))
        CardFaceView(card: Card(id: "J0", kind: .jester))
        CardFaceView(card: Card(id: "u-r7", kind: .uno(color: .red, symbol: .number(7))))
        CardFaceView(card: Card(id: "u-yskip", kind: .uno(color: .yellow, symbol: .skip)))
        CardFaceView(card: Card(id: "u-wild", kind: .uno(color: nil, symbol: .wild)))
    }
    .frame(height: 240)
    .padding()
    .background(CardStyle.feltGreen)
}
