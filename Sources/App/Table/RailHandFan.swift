import SwiftUI

/// A realistic mini fan of overlapping card backs beside a rail nameplate:
/// at a glance, how many cards that player is holding. Backs render through
/// `CardView(faceUp: false)`, so deck themes (UNO back, Bicycle scans) flow
/// through automatically via the environment.
///
/// API: `RailHandFan(count: Int, cardWidth: CGFloat = 26)`.
/// - `count` — the seat's hand size (table side: `state.hands[seat]?.count
///   ?? 0`; remote side the same number lives in `snapshot.handCounts`).
/// - `cardWidth` — width of one mini back; height follows the card aspect
///   (~1.45×), so the default 26pt gives a fan about 40pt tall.
///
/// Placement convention for the integrator (the lead mounts this):
/// - Mount the fan BETWEEN the plate and the screen edge, so the plate stays
///   the primary read and the fan sits "behind" the player like a held hand.
///   In plate-local coordinates (before the outward rotation is applied)
///   that is BELOW the plate: offset `y: +(plateHeight / 2 + 24)` from the
///   plate's center, x centered.
/// - Apply the SAME `outwardAngle` rotation as the plate (rotate a container
///   holding plate + fan together, or give the fan its own matching
///   `.rotationEffect`). The fan is drawn for "down = rim", exactly like
///   `SeatPlateView`.
/// - `count` changes animate internally (one back slides in/out); the caller
///   does not need its own `withAnimation`.
///
/// Visual cap: at most 12 backs are drawn; beyond that a small gold count
/// capsule joins the fan so a 20-card Wizard endgame hand doesn't sprawl.
struct RailHandFan: View {
    let count: Int
    var cardWidth: CGFloat = 26

    /// Never draw more than this many backs; label the true count instead.
    private let visualCap = 12
    /// Horizontal advance per card — tight overlap, like a squeezed hand.
    private var step: CGFloat { cardWidth * 0.34 }
    /// Degrees of splay per card away from the fan's center.
    private let anglePerCard: Double = 3.4

    private var shown: Int { min(count, visualCap) }
    private var fanWidth: CGFloat {
        shown == 0 ? 0 : cardWidth + CGFloat(shown - 1) * step + 8
    }
    private var cardHeight: CGFloat { cardWidth * 1.45 }

    var body: some View {
        HStack(spacing: 5) {
            if shown > 0 {
                fan
            }
            if count > visualCap {
                countBadge
            }
        }
        .frame(height: cardHeight + 8)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: count)
    }

    /// The backs, oldest at the left, each rotated around a pivot below the
    /// card so the spread reads as one hand holding them. New cards slide in
    /// from the fan's trailing side; removed cards slide back out the same
    /// way — one back moving, never a repaint of the whole fan.
    private var fan: some View {
        ZStack {
            ForEach(0..<shown, id: \.self) { index in
                let centered = Double(index) - Double(shown - 1) / 2
                CardView(card: Card(id: "railfan", kind: .standard(suit: .spades, rank: 2)),
                         faceUp: false, elevation: 0)
                    .frame(width: cardWidth)
                    // Pivot below the bottom edge: the fan arcs like cards
                    // pinched at their base, tips spreading.
                    .rotationEffect(.degrees(centered * anglePerCard),
                                    anchor: UnitPoint(x: 0.5, y: 1.6))
                    .offset(x: CGFloat(centered) * step)
                    .zIndex(Double(index))
                    .transition(.asymmetric(
                        insertion: .offset(x: cardWidth * 0.9, y: -6)
                            .combined(with: .opacity),
                        removal: .offset(x: cardWidth * 0.9, y: -6)
                            .combined(with: .opacity)))
            }
        }
        .frame(width: fanWidth, height: cardHeight + 8)
    }

    /// Overflow label: the felt's serif-and-gold voice, small enough to
    /// read as a tally chip, not a scoreboard.
    private var countBadge: some View {
        Text("\(count)")
            .font(.system(.caption, design: .serif).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(CardStyle.gold)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(.black.opacity(0.45))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1))
            )
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

#Preview("Rail hand fans") {
    VStack(spacing: 28) {
        RailHandFan(count: 1)
        RailHandFan(count: 5)
        RailHandFan(count: 12)
        RailHandFan(count: 17)
    }
    .padding(40)
    .background(CardStyle.feltGreen)
}
