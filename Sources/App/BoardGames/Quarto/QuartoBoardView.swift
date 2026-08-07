import SwiftUI

/// Shared board math: where the 16 cells sit within a square board of a
/// given side length, and the cell diameter that follows from it. Both the
/// board's own recess rendering and the interactive drag/drop overlay in
/// `QuartoView` read from here, so a recess drawn at cell (r, c) is always
/// exactly where a dropped piece will land.
enum QuartoBoardGeometry {
    /// Fraction of the board's side eaten by the inset (the flat rim
    /// outside the routed circle) on each edge. Measured directly off the
    /// real `QuartoBoard` photo asset (connected-component centroid
    /// analysis of its 16 recesses — see the session report) so a placed
    /// piece lands dead-center in its recess, not just approximately.
    /// The procedural fallback reuses the same constant for visual
    /// consistency between the two.
    static let insetFraction: CGFloat = 0.194

    static func cellSize(boardSize: CGFloat) -> CGFloat {
        (boardSize - boardSize * insetFraction * 2) / 4
    }

    /// Center point of cell `index` (row-major, 0...15) in the board's own
    /// local coordinate space (origin top-left, matching `.position(...)`).
    static func cellCenter(_ index: Int, boardSize: CGFloat) -> CGPoint {
        let inset = boardSize * insetFraction
        let cell = cellSize(boardSize: boardSize)
        let row = index / 4, col = index % 4
        return CGPoint(x: inset + cell * (CGFloat(col) + 0.5), y: inset + cell * (CGFloat(row) + 0.5))
    }

    /// Nearest cell to a point in board-local coordinates, honoring a
    /// generous drop radius (a real fingertip is not a precise pointer) —
    /// nil if the point isn't close enough to any cell to count as a drop.
    static func nearestCell(to point: CGPoint, boardSize: CGFloat) -> Int? {
        let cell = cellSize(boardSize: boardSize)
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<16 {
            let center = cellCenter(index, boardSize: boardSize)
            let distance = hypot(point.x - center.x, point.y - center.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best, best.distance < cell * 0.85 else { return nil }
        return best.index
    }
}

/// The wooden board itself. Checks for a photoreal `QuartoBoard` imageset
/// first (an asset worker was generating a top-down photograph of a real
/// board separately, same drop-in convention `DotsAndBoxesPaperView` uses
/// for `PaperGraph` and `CardBackView` uses for its art assets —
/// `UIImage(named:) != nil`); at build time no such asset existed, so the
/// procedural fallback below is what actually ships today. Built to match
/// the owner's reference photo (`_inbox/new games/quarto.jpg`): a square
/// board with a dark slate-like top surface, a single inscribed circle
/// routed through that surface exposing warm wood beneath, 16 round
/// recesses likewise exposing wood, and a natural-wood outer border.
struct QuartoBoardView: View {
    let size: CGFloat

    private var cornerRadius: CGFloat { size * 0.045 }

    var body: some View {
        Group {
            if let photoreal = UIImage(named: "QuartoBoard") {
                Image(uiImage: photoreal)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                proceduralBoard
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.55), radius: size * 0.045, y: size * 0.025)
    }

    // MARK: - Procedural fallback

    private var proceduralBoard: some View {
        ZStack {
            // Natural wood base/border — the frame the slate top sits in.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [BoardPalette.borderLight, BoardPalette.borderDark],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image("WalnutTexture")
                .resizable(resizingMode: .tile)
                .opacity(0.45)
                .blendMode(.overlay)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Dark slate top surface, inset from the wood border.
            RoundedRectangle(cornerRadius: cornerRadius * 0.8, style: .continuous)
                .fill(RadialGradient(colors: [BoardPalette.slateHighlight, BoardPalette.slateBase, BoardPalette.slateShadow],
                                     center: UnitPoint(x: 0.4, y: 0.35), startRadius: size * 0.05, endRadius: size * 0.62))
                .padding(size * 0.045)

            // The inscribed circle: a routed channel through the slate,
            // exposing the warm wood underneath.
            Circle()
                .strokeBorder(BoardPalette.routedWood, lineWidth: size * 0.014)
                .overlay(
                    Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1)
                )
                .padding(size * (insetGap + QuartoBoardGeometry.insetFraction * 0.55))

            recessGrid
        }
    }

    /// Extra breathing room between the routed circle and the recess grid
    /// (the circle reads as an inscribed ring OUTSIDE the piece area, same
    /// as the reference photo).
    private let insetGap: CGFloat = 0.045

    private var recessGrid: some View {
        ForEach(0..<16, id: \.self) { index in
            let center = QuartoBoardGeometry.cellCenter(index, boardSize: size)
            let diameter = QuartoBoardGeometry.cellSize(boardSize: size) * 0.6
            recess(diameter: diameter)
                .position(center)
        }
    }

    /// One recess: a wood-toned disc let into the slate, with an inner
    /// shadow ring so it reads as CUT INTO the surface rather than painted
    /// on top of it.
    private func recess(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [BoardPalette.routedWood, BoardPalette.routedWoodShadow],
                                     center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: diameter * 0.6))
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: diameter * 0.12)
                .blur(radius: diameter * 0.05)
                .clipShape(Circle())
            Circle()
                .strokeBorder(.black.opacity(0.3), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
    }
}

private enum BoardPalette {
    static let borderLight = Color(red: 0.60, green: 0.41, blue: 0.22)
    static let borderDark = Color(red: 0.36, green: 0.23, blue: 0.12)
    static let slateHighlight = Color(red: 0.22, green: 0.25, blue: 0.245)
    static let slateBase = Color(red: 0.115, green: 0.135, blue: 0.13)
    static let slateShadow = Color(red: 0.045, green: 0.055, blue: 0.055)
    static let routedWood = Color(red: 0.72, green: 0.55, blue: 0.34)
    static let routedWoodShadow = Color(red: 0.52, green: 0.38, blue: 0.22)
}

#Preview("Quarto board") {
    ZStack {
        Color(red: 0.05, green: 0.10, blue: 0.08).ignoresSafeArea()
        QuartoBoardView(size: 520)
    }
}
