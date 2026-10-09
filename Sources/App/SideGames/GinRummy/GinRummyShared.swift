import SwiftUI

// Shared building blocks for the Gin Rummy phone hand and table: card text,
// the public-move ledger phrasing, the auto-grouping of a hand into melds vs
// deadwood, the hand-drawn deadwood circle, and the flip card.

// MARK: - Seat identity

enum GinSeat {
    /// Same colour a bot always wears on the table plates; humans get their seat colour.
    static func colorIndex(name: String, seat: Int) -> Int {
        BotRoster.identity(named: name)?.colorIndex ?? seat
    }

    static func fallbackName(_ seat: Int) -> String { "Seat \(seat + 1)" }
}

// MARK: - Card text

extension Card {
    /// "7♠", "K♦", "A♥" (aces print as A, they play low).
    var ginShort: String {
        guard case .standard(let suit, let rank) = kind else { return "?" }
        return GinText.rankLabel(rank) + suit.symbol
    }
}

enum GinText {
    static func rankLabel(_ rank: Int) -> String {
        switch rank {
        case 14, 1: return "A"
        case 13: return "K"
        case 12: return "Q"
        case 11: return "J"
        default: return String(rank)
        }
    }

    /// Ink for a card glyph in running text. `onDark` is for text sitting on felt.
    static func suitColor(_ card: Card, onDark: Bool) -> Color {
        let red = card.suit?.isRed ?? false
        if onDark { return red ? Color(red: 0.98, green: 0.52, blue: 0.46) : CardStyle.stockTop }
        return red ? CardStyle.crimson : CardStyle.ink
    }

    /// "Sarah took the 7♠" with the card glyph in its suit colour.
    static func ledgerLine(_ move: GinMove, name: String, onDark: Bool) -> AttributedString {
        var line: AttributedString
        switch move.kind {
        case .passedUpcard:
            return AttributedString("\(name) passed")
        case .drewStock:
            return AttributedString("\(name) drew from the stock")
        case .tookUpcard(let card):
            line = AttributedString("\(name) took the ")
            line.append(cardGlyph(card, onDark: onDark))
        case .discarded(let card):
            line = AttributedString("\(name) discarded the ")
            line.append(cardGlyph(card, onDark: onDark))
        }
        return line
    }

    static func cardGlyph(_ card: Card, onDark: Bool, weight: Font.Weight = .bold) -> AttributedString {
        var a = AttributedString(card.ginShort)
        a.foregroundColor = suitColor(card, onDark: onDark)
        a.font = .system(.body, design: .serif).weight(weight)
        return a
    }
}

// MARK: - Auto-grouping

/// One cluster of the displayed hand: a meld (tight sub-fan, gold underline)
/// or the deadwood (everything else, looser).
struct GinDisplayGroup: Identifiable, Equatable {
    let id: String
    let cards: [Card]
    let isMeld: Bool
}

enum GinArrange {
    /// The hand as melds + deadwood, using the engine's own minimum-deadwood
    /// arrangement. Melds are ordered low rank first; deadwood by rank.
    static func groups(for hand: [Card]) -> (groups: [GinDisplayGroup], deadwoodPoints: Int) {
        guard !hand.isEmpty else { return ([], 0) }
        let arrangement = GinMelds.bestArrangement(hand)
        let melds = arrangement.melds.sorted {
            let a = $0.cards.map(GinRummyCards.rank).min() ?? 0
            let b = $1.cards.map(GinRummyCards.rank).min() ?? 0
            return a != b ? a < b : ($0.cards.first?.id ?? "") < ($1.cards.first?.id ?? "")
        }
        var out: [GinDisplayGroup] = melds.map { meld in
            let cards = meld.kind == .run
                ? meld.cards.sorted { GinRummyCards.rank($0) < GinRummyCards.rank($1) }
                : meld.cards
            return GinDisplayGroup(id: "m-" + cards.map(\.id).joined(separator: "."), cards: cards, isMeld: true)
        }
        let dead = arrangement.deadwood.sorted {
            let a = GinRummyCards.rank($0), b = GinRummyCards.rank($1)
            return a != b ? a < b : $0.id < $1.id
        }
        if !dead.isEmpty {
            out.append(GinDisplayGroup(id: "dead", cards: dead, isMeld: false))
        }
        return (out, arrangement.deadwoodPoints)
    }

    /// Lowest deadwood reachable by discarding any one legal card from an 11-card hand.
    static func bestAfterDiscard(hand: [Card], excluding id: String?) -> Int {
        guard hand.count == GinRummyRules.handSize + 1 else { return GinMelds.minDeadwood(hand) }
        return hand.filter { $0.id != id }.map { c in GinMelds.minDeadwood(hand.filter { $0 != c }) }.min() ?? 0
    }
}

/// Memoises the grouping so a drag (60 redraws a second) doesn't re-solve it.
final class GinGroupMemo {
    private var key: [String] = []
    private var cached: (groups: [GinDisplayGroup], deadwoodPoints: Int) = ([], 0)

    func groups(for hand: [Card]) -> (groups: [GinDisplayGroup], deadwoodPoints: Int) {
        let k = hand.map(\.id)
        if k != key {
            key = k
            cached = GinArrange.groups(for: hand)
        }
        return cached
    }
}

// MARK: - Flip card

/// A card that turns over: `angle` 0 = face up, 180 = back showing. Animatable,
/// so the face swaps at the edge-on moment of the turn.
struct GinFlipCard: View, Animatable {
    let card: Card
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                CardView(card: card, faceUp: true)
            } else {
                CardView(card: card, faceUp: false)
                    .scaleEffect(x: -1, y: 1)
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

// MARK: - Pencil circle

/// A slightly wobbly, hand-drawn ring (the way you circle deadwood on a score
/// pad). Deterministic wobble per seed; `trim` it from 0 to 1 to draw it.
struct GinPencilCircle: Shape {
    var seed: Int = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 48
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        // Start slightly before the top and overshoot the join, like a real pencil loop.
        let startAngle = -Double.pi / 2 - 0.25
        let sweep = Double.pi * 2 + 0.45
        let phase = Double(seed % 7) * 0.9
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let a = startAngle + sweep * t
            let wobble = 1 + 0.035 * sin(a * 3 + phase) - 0.02 * t // closes slightly inside where it began
            let p = CGPoint(x: cx + CGFloat(cos(a) * wobble) * rx, y: cy + CGFloat(sin(a) * wobble) * ry)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

// MARK: - Revealed hand (melds + circled deadwood)

/// A face-up hand laid out the way it's shown down: each meld a tight cluster
/// under a thin gold rule, the deadwood circled in pencil. Cards laid off by
/// the defender sit slightly proud with a gold edge. Used on the table at the
/// knock / showdown.
struct GinRevealedHand: View {
    let melds: [GinMeld]
    let deadwood: [Card]
    var laidOffIDs: Set<String> = []
    let cardWidth: CGFloat
    /// false = every card shows its back; flipping animates a staggered turn.
    var flipped: Bool = true
    var showDeadwoodCircle: Bool = false
    var deadwoodPoints: Int? = nil
    var reduceMotion: Bool = false

    private var cardHeight: CGFloat { cardWidth * 1.4 }

    var body: some View {
        HStack(alignment: .bottom, spacing: cardWidth * 0.30) {
            ForEach(Array(melds.enumerated()), id: \.offset) { _, meld in
                cluster(meld.cards, overlap: 0.64)
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(CardStyle.gold)
                            .frame(height: max(2, cardWidth * 0.03))
                            .padding(.horizontal, cardWidth * 0.06)
                            .offset(y: cardWidth * 0.11)
                            .shadow(color: CardStyle.gold.opacity(0.5), radius: 3)
                    }
            }
            if !deadwood.isEmpty {
                cluster(deadwood, overlap: 0.52)
                    .padding(.horizontal, cardWidth * 0.14)
                    .padding(.vertical, cardWidth * 0.14)
                    .overlay {
                        GinPencilCircle(seed: deadwood.count)
                            .trim(from: 0, to: showDeadwoodCircle ? 1 : 0)
                            .stroke(Color(red: 0.86, green: 0.30, blue: 0.26),
                                    style: StrokeStyle(lineWidth: max(2, cardWidth * 0.034), lineCap: .round, lineJoin: .round))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: showDeadwoodCircle)
                    }
                    .overlay(alignment: .topTrailing) {
                        if showDeadwoodCircle, let deadwoodPoints {
                            Text("\(deadwoodPoints)")
                                .font(.system(size: max(13, cardWidth * 0.22), weight: .heavy, design: .serif))
                                .monospacedDigit()
                                .foregroundStyle(CardStyle.stockTop)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 0.62, green: 0.20, blue: 0.18)))
                                .offset(x: cardWidth * 0.12, y: -cardWidth * 0.20)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: melds)
    }

    private func cluster(_ cards: [Card], overlap: CGFloat) -> some View {
        HStack(spacing: -cardWidth * overlap) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let proud = laidOffIDs.contains(card.id)
                GinFlipCard(card: card, angle: flipped ? 0 : 180)
                    .frame(width: cardWidth, height: cardHeight)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).delay(Double(index) * 0.06), value: flipped)
                    .overlay {
                        if proud && flipped {
                            RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cardWidth), style: .continuous)
                                .strokeBorder(CardStyle.gold, lineWidth: 2)
                                .shadow(color: CardStyle.gold.opacity(0.8), radius: 5)
                        }
                    }
                    .offset(y: proud ? -cardWidth * 0.10 : 0)
                    .zIndex(Double(index))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}
