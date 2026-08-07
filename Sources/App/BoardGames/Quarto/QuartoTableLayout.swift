import SwiftUI

/// All table geometry in one place, computed once per `GeometryReader`
/// pass from the available size. Every drag gesture and every static
/// layer (board, trays, wells, labels) in `QuartoView` reads from the SAME
/// instance, so a piece drawn at a slot and a drop point tested against
/// that slot can never drift apart — the alternative (each subview
/// re-deriving its own numbers) is exactly how two layers quietly go
/// out of sync.
struct QuartoTableLayout {
    let size: CGSize

    var boardSize: CGFloat { min(size.width, size.height) * 0.58 }
    var boardCenter: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    private var boardOrigin: CGPoint {
        CGPoint(x: boardCenter.x - boardSize / 2, y: boardCenter.y - boardSize / 2)
    }
    var cellSize: CGFloat { QuartoBoardGeometry.cellSize(boardSize: boardSize) }
    var pieceDiameter: CGFloat { cellSize * 0.58 }
    var trayPieceDiameter: CGFloat { min(boardSize, size.width, size.height) * 0.05 }
    var wellPieceDiameter: CGFloat { pieceDiameter * 1.05 }
    var wellDiameter: CGFloat { wellPieceDiameter * 1.7 }
    var wellCaptureRadius: CGFloat { wellDiameter * 0.9 }

    func boardPoint(forCell cell: Int) -> CGPoint {
        let local = QuartoBoardGeometry.cellCenter(cell, boardSize: boardSize)
        return CGPoint(x: boardOrigin.x + local.x, y: boardOrigin.y + local.y)
    }

    /// Nearest board cell to a point in TABLE-WIDE coordinates (exactly
    /// what a `DragGesture(coordinateSpace: .named("quartoTable"))`
    /// reports), or nil if the point is too far from the board to count
    /// as a drop.
    func cell(nearestTo point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - boardOrigin.x, y: point.y - boardOrigin.y)
        return QuartoBoardGeometry.nearestCell(to: local, boardSize: boardSize)
    }

    // MARK: - Wells

    /// Player 0 sits at the near (bottom) edge, player 1 at the far (top)
    /// edge — a fixed seat, like any physical two-player table, not tied
    /// to whose turn it currently is.
    func wellCenter(forPlayer player: Int) -> CGPoint {
        let margin = size.height * 0.11
        return CGPoint(x: size.width / 2, y: player == 0 ? size.height - margin : margin)
    }

    func labelCenter(forPlayer player: Int) -> CGPoint {
        let center = wellCenter(forPlayer: player)
        let offset = wellDiameter * 0.85
        return CGPoint(x: center.x, y: player == 0 ? center.y + offset : center.y - offset)
    }

    // MARK: - Trays

    enum TraySide { case left, right }

    /// 8 slots per tray, 2 columns x 4 rows, filling the margin between
    /// the screen edge and the board. A piece keeps the SAME slot for as
    /// long as it remains — taking one never reflows the rest.
    func traySlot(side: TraySide, index: Int) -> CGPoint {
        let boardLeft = boardCenter.x - boardSize / 2
        let boardRight = boardCenter.x + boardSize / 2
        let marginWidth = side == .left ? boardLeft : (size.width - boardRight)
        let columnWidth = max(marginWidth * 0.6, trayPieceDiameter * 1.5) / 2
        let rowHeight = boardSize / 4.4
        let col = CGFloat(index % 2)
        let row = CGFloat(index / 2)
        let originX = side == .left ? boardLeft * 0.14 : boardRight + marginWidth * 0.2
        let originY = boardCenter.y - boardSize * 0.42
        return CGPoint(x: originX + columnWidth * (col + 0.5), y: originY + rowHeight * (row + 0.5))
    }

    // MARK: - Piece groupings

    /// Fixed tray membership: light pieces live in the left tray, dark in
    /// the right — a stable visual sort with no gameplay meaning (pieces
    /// aren't owned by either player), matching the "two carved side
    /// trays" of a physical set.
    static let lightPieces = QuartoPiece.all.filter { !$0.isDark }
    static let darkPieces = QuartoPiece.all.filter(\.isDark)
}
