import SwiftUI

/// How many cards a player is holding, read at a glance: the TOP sliver of
/// a fan of card BACKS poking in from past the table's edge — as if someone
/// standing beyond the screen is holding their hand up to the felt and all
/// we can see is the tips of their cards. No hand graphic, no arm, just the
/// cards themselves, mostly bled offscreen. Backs render through
/// `CardView(faceUp: false)` (→ `CardBackView`), so deck themes (UNO back,
/// Bicycle scans) flow through automatically via the environment.
///
/// API: `RailHandFan(count: Int, cardWidth: CGFloat = 48)`.
/// - `count` — the seat's hand size (table side: `state.hands[seat]?.count
///   ?? 0`; remote side the same number lives in `snapshot.handCounts`).
/// - `cardWidth` — width of one card AT FULL SCALE (only its top ~1/4
///   actually shows — see `peekHeight`); height follows the card aspect.
///
/// Placement convention for the integrator (the lead mounts this):
/// - Mount the fan BETWEEN the plate and the screen edge, same as before:
///   in plate-local coordinates (before the outward rotation is applied)
///   that is BELOW the plate. The view's own frame is already just the
///   peek strip's height, so a plain `VStack { plate; fan }` reads
///   correctly with no extra offset math needed.
/// - Apply the SAME `outwardAngle` rotation as the plate (rotate a
///   container holding plate + fan together). The fan is drawn for "down
///   = rim, and past the bottom edge is offscreen", exactly like
///   `SeatPlateView`'s "down = rim" convention — the peek always faces the
///   table center and the (clipped) rest of each card points off the edge
///   toward the player who's holding it.
/// - `count` changes animate internally (one back rises in / sinks out);
///   the caller does not need its own `withAnimation`.
///
/// Visual cap: at most 12 backs are drawn; beyond that a small gold count
/// capsule joins the fan so a 20-card Wizard endgame hand doesn't sprawl.
struct RailHandFan: View {
    let count: Int
    var cardWidth: CGFloat = 48

    /// Never draw more than this many backs; label the true count instead.
    private let visualCap = 12
    /// Horizontal advance per card — tight overlap, like a squeezed hand.
    private var step: CGFloat { cardWidth * 0.26 }
    /// Degrees of splay per card away from the fan's center.
    private let anglePerCard: Double = 3.0

    private var shown: Int { min(count, visualCap) }
    private var fanWidth: CGFloat {
        shown == 0 ? 0 : cardWidth + CGFloat(shown - 1) * step + 6
    }
    private var cardHeight: CGFloat { cardWidth * 1.45 }
    /// Only the near-table quarter of each card is visible; the rest is
    /// clipped away — the part an onscreen player would never see anyway,
    /// since it belongs to a hand held past the table's edge.
    private var peekHeight: CGFloat { cardHeight * 0.25 }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if shown > 0 {
                fan
            }
            if count > visualCap {
                countBadge
            }
        }
        .frame(height: peekHeight)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: count)
    }

    /// The backs, oldest at the left, each rotated around a pivot well
    /// below the visible strip — the unseen hand's grip point — so the
    /// spread reads as one fan held by someone off past the edge, not a
    /// row of flat cards. New cards rise up into the peek from below (out
    /// of the offscreen hand); removed cards sink back down the same way —
    /// one back moving, never a repaint of the whole fan.
    private var fan: some View {
        ZStack(alignment: .top) {
            ForEach(0..<shown, id: \.self) { index in
                let centered = Double(index) - Double(shown - 1) / 2
                CardView(card: Card(id: "railfan", kind: .standard(suit: .spades, rank: 2)),
                         faceUp: false, elevation: 0)
                    .frame(width: cardWidth)
                    // Pivot far below the peek strip: the fan arcs like
                    // cards pinched at a base we never see, tips spreading
                    // as they poke up into view.
                    .rotationEffect(.degrees(centered * anglePerCard),
                                    anchor: UnitPoint(x: 0.5, y: 1.6))
                    .offset(x: CGFloat(centered) * step)
                    .zIndex(Double(index))
                    .transition(.asymmetric(
                        insertion: .offset(y: peekHeight * 1.4).combined(with: .opacity),
                        removal: .offset(y: peekHeight * 1.4).combined(with: .opacity)))
            }
        }
        .frame(width: fanWidth, height: peekHeight, alignment: .top)
        // The crop that sells the whole illusion: only the top sliver of
        // each full-size card back survives — the rest bleeds offscreen.
        .clipped()
    }

    /// Overflow label: the felt's serif-and-gold voice, small enough to
    /// read as a tally chip, not a scoreboard.
    private var countBadge: some View {
        Text("\(count)")
            .font(.system(.caption2, design: .serif).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(CardStyle.gold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
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
