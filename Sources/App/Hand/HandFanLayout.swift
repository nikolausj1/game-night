import SwiftUI

/// Geometry of a hand of cards held in a fan: positions along a shallow arc,
/// like cards pivoting around a point below the wrist. Pure math, no views.
struct HandFanLayout {
    let cardCount: Int
    let containerWidth: CGFloat
    let cardWidth: CGFloat

    /// Hands bigger than this spread wider than the screen and become
    /// horizontally scrollable (see HandView's browse gesture) instead of
    /// crushing every card into a fixed arc width. ~10 is roughly where a
    /// standard-width phone can no longer show every card at a legible size.
    static let wideThreshold = 10

    private var isWide: Bool { cardCount > Self.wideThreshold }

    /// Total angular spread grows with hand size but saturates so a 15-card
    /// Wizard endgame hand still fits a thumb's reach. Wide (>10-card) hands
    /// don't saturate — they keep a steady per-card angular step so the fan
    /// spreads naturally past the screen edge; `fanScroll` (HandView) brings
    /// the off-screen ends to center instead.
    private var totalSpreadDegrees: CGFloat {
        guard cardCount > 1 else { return 0 }
        if isWide { return CGFloat(cardCount - 1) * 6.5 }
        return min(46, CGFloat(cardCount - 1) * 6.5)
    }

    /// The virtual pivot sits well below the screen: shallow, natural arc.
    private var pivotRadius: CGFloat { containerWidth * 1.55 }

    struct Slot {
        let angle: Angle          // card's own tilt
        let offset: CGSize        // from the fan's center anchor
        let zIndex: Double
    }

    /// The card's natural (unscrolled) x position on the arc, before the
    /// container clamp or `scrollOffset` are applied. This is the reference
    /// frame browsing scrolls against and what the fisheye/focus math in
    /// HandView compares finger position to.
    func rawX(for index: Int) -> CGFloat {
        guard cardCount > 1 else { return 0 }
        let t = CGFloat(index) / CGFloat(cardCount - 1)
        let degrees = (t - 0.5) * totalSpreadDegrees
        let radians = degrees * .pi / 180
        return sin(radians) * pivotRadius
    }

    func slot(for index: Int, selected: Bool = false, scrollOffset: CGFloat = 0) -> Slot {
        guard cardCount > 0 else { return Slot(angle: .zero, offset: .zero, zIndex: 0) }
        let t = cardCount == 1 ? 0.5 : CGFloat(index) / CGFloat(cardCount - 1)
        let degrees = (t - 0.5) * totalSpreadDegrees
        let radians = degrees * .pi / 180

        // Position on the arc around the below-screen pivot, shifted by
        // however far the hand has been browse-scrolled.
        var x = rawX(for: index) + scrollOffset
        var y = (1 - cos(radians)) * pivotRadius

        // A touched card slides up out of the fan to say "I'm yours".
        if selected { y -= cardWidth * 0.55 }

        // Small hands already fit — keep them pinned inside the container,
        // same as before. Wide hands are deliberately allowed to overflow;
        // that's what makes them scrollable.
        if !isWide {
            let maxX = (containerWidth - cardWidth) / 2
            x = max(-maxX, min(maxX, x))
        }

        return Slot(angle: .degrees(Double(degrees)),
                    offset: CGSize(width: x, height: y),
                    zIndex: Double(index))
    }

    /// How far `fanScroll` may travel before the first/last card would
    /// overshoot past center — lets browsing always bring either end of the
    /// hand to the middle, but no further. Narrow hands don't scroll at all.
    func scrollBounds() -> ClosedRange<CGFloat> {
        guard isWide, cardCount > 1 else { return 0...0 }
        let halfWidth = abs(rawX(for: cardCount - 1))
        guard halfWidth > 0 else { return 0...0 }
        return -halfWidth...halfWidth
    }

    /// The card nearest the fan's center once `scroll` is applied — used to
    /// drive the browse-focus haptic as a momentum glide settles past cards
    /// with no finger left to track.
    func nearestIndex(toScroll scroll: CGFloat) -> Int {
        guard cardCount > 1 else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<cardCount {
            let distance = abs(rawX(for: i) + scroll)
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }

    /// The card nearest a given displayed x (e.g. the browsing finger) —
    /// used to drive the focus haptic while the finger is still down. Uses
    /// actual displayed positions (via `slot`), so it's correct for both
    /// scrolling wide hands and static narrow ones.
    func nearestIndex(toDisplayedX x: CGFloat, scrollOffset: CGFloat) -> Int {
        guard cardCount > 1 else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<cardCount {
            let distance = abs(slot(for: i, scrollOffset: scrollOffset).offset.width - x)
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }

    /// 0 at the fan's center card, 1 at the wings. Used to scale
    /// depth-dependent effects (like gyroscope parallax) so cards farther
    /// from center move more than ones dead center — a fanned hand isn't a
    /// rigid plane, so a uniform shift alone reads flat.
    func normalizedDistanceFromCenter(for index: Int) -> CGFloat {
        guard cardCount > 1 else { return 0 }
        let t = CGFloat(index) / CGFloat(cardCount - 1)
        return abs(t - 0.5) * 2
    }
}

/// Interactive state for one card being dragged out of the fan.
/// Owned by HandView; separated so the maths stay testable.
struct CardDragState {
    var translation: CGSize = .zero
    var isDragging = false

    /// How far along the "this is a play" gesture we are, 0…1.
    /// Crossing 1 and releasing = play the card. (Fast flicks can also
    /// play via predicted momentum — see HandView's gesture.)
    func playProgress(handHeight: CGFloat) -> CGFloat {
        let liftDistance = -translation.height
        let threshold = handHeight * 0.26
        return max(0, min(1, liftDistance / threshold))
    }

    /// Elevation for CardView shadows: rises quickly at drag start, then eases.
    func elevation(handHeight: CGFloat) -> CGFloat {
        guard isDragging else { return 0 }
        return 0.4 + 0.6 * playProgress(handHeight: handHeight)
    }
}

/// How the hand is displayed. Purely a presentation reorder — never touches
/// the underlying snapshot, so it's safe to flip anytime, including mid-turn.
/// Persisted via @AppStorage("gn.handSort") by whichever view last set it;
/// every reader of that key sees the same value.
enum HandSortMode: String, CaseIterable {
    case asDealt, bySuitColor, byRank

    var icon: String {
        switch self {
        case .asDealt: return "hand.raised.fill"
        case .bySuitColor: return "square.grid.2x2.fill"
        case .byRank: return "arrow.up.arrow.down"
        }
    }

    var next: HandSortMode {
        switch self {
        case .asDealt: return .bySuitColor
        case .bySuitColor: return .byRank
        case .byRank: return .asDealt
        }
    }

    func sorted(_ cards: [Card]) -> [Card] {
        switch self {
        case .asDealt:
            return cards
        case .bySuitColor:
            return cards.sorted { Self.groupKey($0) < Self.groupKey($1) }
        case .byRank:
            return cards.sorted { Self.rankKey($0) < Self.rankKey($1) }
        }
    }

    /// Suit/color grouping: standard cards by suit, UNO cards by color
    /// (wilds sort last within their group), Wizards/Jesters trail.
    private static func groupKey(_ card: Card) -> (Int, Int) {
        switch card.kind {
        case .standard(let suit, let rank):
            return (suitOrder(suit), rank)
        case .uno(let color, let symbol):
            return (10 + unoColorOrder(color), symbolOrder(symbol))
        case .wizard:
            return (100, 0)
        case .jester:
            return (101, 0)
        }
    }

    /// Rank/value: low to high within a kind; Jesters (always-low) first,
    /// Wizards (always-high) last.
    private static func rankKey(_ card: Card) -> (Int, Int) {
        switch card.kind {
        case .jester:
            return (-1, 0)
        case .standard(_, let rank):
            return (0, rank)
        case .uno(_, let symbol):
            return (0, symbolOrder(symbol))
        case .wizard:
            return (2, 0)
        }
    }

    private static func suitOrder(_ suit: Suit) -> Int {
        switch suit {
        case .clubs: return 0
        case .diamonds: return 1
        case .hearts: return 2
        case .spades: return 3
        }
    }

    /// Wilds (no color) sort after all four colors.
    private static func unoColorOrder(_ color: UnoColor?) -> Int {
        guard let color else { return 4 }
        switch color {
        case .red: return 0
        case .yellow: return 1
        case .green: return 2
        case .blue: return 3
        }
    }

    private static func symbolOrder(_ symbol: UnoSymbol) -> Int {
        switch symbol {
        case .number(let n): return n
        case .skip: return 20
        case .reverse: return 21
        case .drawTwo: return 22
        case .wild: return 23
        case .wildDrawFour: return 24
        }
    }
}
