import SwiftUI

/// Where everything sits on the Solitaire table. Landscape-first (iPad on a
/// stand or flat): stock top-left, waste beside it, foundations top-right,
/// seven tableau columns filling the row below — the classic Klondike
/// layout, sized off the board's own geometry the same way `TableGeometry`
/// sizes the trick-taking felt.
enum SolitaireLayout {
    static let columnCount = 7

    /// The one card size every pile on this board renders at.
    static func cardSize(for boardSize: CGSize) -> CGSize {
        let usableWidth = boardSize.width - 48
        let width = min(usableWidth / CGFloat(columnCount) * 0.80, 122)
        return CGSize(width: width, height: width / CardStyle.aspectRatio)
    }

    /// Vertical center of the stock/waste/foundation row.
    static func topRowY(for boardSize: CGSize) -> CGFloat {
        24 + cardSize(for: boardSize).height / 2
    }

    /// Vertical center of the first (topmost, face-down) card in every
    /// tableau column.
    static func tableauBaseY(for boardSize: CGSize) -> CGFloat {
        topRowY(for: boardSize) + cardSize(for: boardSize).height * 0.95
    }

    /// Column centers, evenly spaced across the board with a margin on
    /// each side so the leftmost/rightmost columns don't hug the rail.
    static func columnX(_ index: Int, boardSize: CGSize) -> CGFloat {
        let margin: CGFloat = 24
        let usable = boardSize.width - margin * 2
        let step = usable / CGFloat(columnCount)
        return margin + step * (CGFloat(index) + 0.5)
    }

    static func stockCenter(for boardSize: CGSize) -> CGPoint {
        CGPoint(x: columnX(0, boardSize: boardSize), y: topRowY(for: boardSize))
    }

    static func wasteCenter(for boardSize: CGSize) -> CGPoint {
        CGPoint(x: columnX(1, boardSize: boardSize), y: topRowY(for: boardSize))
    }

    /// Foundations sit in suit order (clubs, diamonds, hearts, spades) over
    /// the rightmost four columns, so they land directly above the columns
    /// a card is most often walking home from.
    static func foundationCenter(_ suit: Suit, boardSize: CGSize) -> CGPoint {
        let index = Suit.allCases.firstIndex(of: suit) ?? 0
        return CGPoint(x: columnX(columnCount - 4 + index, boardSize: boardSize), y: topRowY(for: boardSize))
    }

    /// A face-down card in a column shows only a sliver of its neighbor
    /// below it; a face-up card shows much more (it might carry a rank
    /// index another card needs to read). Real Klondike apps stagger
    /// exactly this way so a seven-card column doesn't run off the felt.
    static func rowStagger(faceUp: Bool, cardHeight: CGFloat) -> CGFloat {
        faceUp ? cardHeight * 0.30 : cardHeight * 0.11
    }

    /// The vertical offset of card `index` within `pile`, measured from the
    /// column's base position — purely a function of the pile's OWN
    /// face-up states up to (not including) `index`, so a card's landing
    /// slot never shifts as siblings above or below it arrive/depart
    /// visually (important for the staggered opening deal — see
    /// `SolitaireView.runOpeningDeal`).
    static func rowOffsetY(in pile: [SolitaireCard], index: Int, cardHeight: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        var y: CGFloat = 0
        for i in 0..<index { y += rowStagger(faceUp: pile[i].faceUp, cardHeight: cardHeight) }
        return y
    }

    /// Where card `index` in tableau column `column` renders, in board
    /// coordinates.
    static func tableauCardCenter(column: Int, index: Int, pile: [SolitaireCard], boardSize: CGSize) -> CGPoint {
        let height = cardSize(for: boardSize).height
        let x = columnX(column, boardSize: boardSize)
        let y = tableauBaseY(for: boardSize) + rowOffsetY(in: pile, index: index, cardHeight: height)
        return CGPoint(x: x, y: y)
    }

    /// The empty-column landing point (no cards yet) — same as index 0.
    static func tableauEmptyCenter(column: Int, boardSize: CGSize) -> CGPoint {
        CGPoint(x: columnX(column, boardSize: boardSize), y: tableauBaseY(for: boardSize))
    }

    /// The felt real estate a whole column occupies, tallest possible
    /// (used for its own hit-testing during drag/drop — generous on
    /// purpose, a well-filled column runs long).
    static func columnHitRadius(for boardSize: CGSize) -> CGFloat {
        cardSize(for: boardSize).width * 0.62
    }
}
