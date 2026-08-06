import SwiftUI

/// How many cards a player is holding, read at a glance: real-scale card
/// backs fanned out and bled off the screen's edge, as if someone sitting
/// just past the rail is holding their hand up to the table and all we can
/// see is the top of their cards. No hand graphic, no arm, just the cards
/// themselves — the OWNER'S call after the old miniature version ("tiny
/// little icons that don't bleed off the edge... ridiculous"): real cards,
/// real size, mostly off past the bezel. Backs render through
/// `CardView(faceUp: false)` (→ `CardBackView`), so deck themes (UNO back,
/// Bicycle scans) flow through automatically via the environment.
///
/// API: `RailHandFan(count: Int, cardWidth: CGFloat = TableGeometry.tableCardWidth(for:))`.
/// - `count` — the seat's hand size (table side: `state.hands[seat]?.count
///   ?? 0`; remote side the same number lives in `snapshot.handCounts`).
/// - `cardWidth` — width of one card at (near) real table-card scale; the
///   caller passes `TableGeometry.tableCardWidth(for: size)` so the rail
///   hand reads as the SAME object class as everything else on the felt,
///   not a separate miniature deck.
///
/// Placement convention for the integrator (the lead mounts this):
/// - Mount the fan BELOW the plate, same as before: in plate-local
///   coordinates (before the outward rotation is applied) that is BELOW
///   the plate — a plain `VStack { plate; fan }` reads correctly with no
///   extra offset math needed.
/// - Apply the SAME `outwardAngle` rotation as the plate (rotate a
///   container holding plate + fan together). The fan is drawn for "down
///   = rim, and past the bottom edge is offscreen", exactly like
///   `SeatPlateView`'s "down = rim" convention.
/// - Critically, this view does NOT clip its own overflow. Its outer
///   `.frame(height:)` is only the peek strip (for layout — it's what
///   keeps the plate snug against the fan instead of the VStack ballooning
///   to full card height), but each card itself renders at FULL card
///   height and is free to paint past that frame. Because the mount sits
///   near the physical screen edge, the ~3/4 of each card below the peek
///   strip lands past the device bezel and simply isn't there to see —
///   that's the "someone is holding cards just past the edge" illusion.
///   Do NOT wrap this view (or an ancestor) in `.clipped()`／a clipShape —
///   that would crop the bleed back into the old miniature look.
/// - `count` changes animate internally (one back rises in / sinks out);
///   the caller does not need its own `withAnimation`.
///
/// Visual cap: at most 14 backs are drawn; beyond that a small gold count
/// capsule joins the fan so a 20-card Wizard endgame hand doesn't sprawl.
struct RailHandFan: View {
    let count: Int
    var cardWidth: CGFloat = 48

    /// Never draw more than this many backs; label the true count instead.
    private let visualCap = 14
    /// Degrees of splay per card away from the fan's center.
    private let anglePerCard: Double = 4.0

    private var shown: Int { min(count, visualCap) }
    /// Horizontal advance per card — real cards laid this tight (~70%
    /// overlap) still read as a full hand, not a card show. Tightens
    /// further as the hand grows so a big hand doesn't outrun the rail.
    private var step: CGFloat {
        switch shown {
        case 0...5: cardWidth * 0.32
        case 6...9: cardWidth * 0.26
        default: cardWidth * 0.20
        }
    }
    private var fanWidth: CGFloat {
        shown == 0 ? 0 : cardWidth + CGFloat(shown - 1) * step + 10
    }
    private var cardHeight: CGFloat { cardWidth * 1.45 }
    /// Only the near-table quarter of each card reads as "in view" — the
    /// rest is real, full-size card, just physically past the table's edge
    /// (see the file-level note: nothing clips it, the bezel does).
    private var peekHeight: CGFloat { cardHeight * 0.25 }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if shown > 0 {
                fan
            }
            if count > visualCap {
                countBadge
            }
        }
        .frame(height: peekHeight, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: count)
    }

    /// The backs, oldest at the left, each rotated around a pivot well
    /// below the visible strip — the unseen hand's grip point — so the
    /// spread reads as one fan held by someone off past the edge, not a
    /// row of flat cards. New cards rise up into the peek from below (out
    /// of the offscreen hand); removed cards sink back down the same way —
    /// one back moving, never a repaint of the whole fan. Full card height
    /// intentionally overflows this view's own (peek-height) frame; see
    /// the type doc for why that's the point, not a bug.
    private var fan: some View {
        ZStack(alignment: .top) {
            ForEach(0..<shown, id: \.self) { index in
                let centered = Double(index) - Double(shown - 1) / 2
                CardView(card: Card(id: "railfan", kind: .standard(suit: .spades, rank: 2)),
                         faceUp: false, elevation: 0)
                    // FIXED width AND height: CardBackView is
                    // `.aspectRatio(_, contentMode: .fit)`, which sizes
                    // itself to whatever height its ancestor PROPOSES —
                    // and the enclosing ZStack only proposes `peekHeight`
                    // (see below). Without an explicit height here, the
                    // whole card would shrink to fit that sliver instead
                    // of rendering full-size and overflowing it, silently
                    // turning this back into the old miniature. A fixed
                    // frame makes the card report (and paint at) its real
                    // size regardless of what the parent offers.
                    .frame(width: cardWidth, height: cardHeight)
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
        // No `.clipped()` here — see the type doc. The frame above is for
        // LAYOUT (keeps the plate snug against the peek strip); the actual
        // card art is full height and bleeds past it toward the rail.
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
        RailHandFan(count: 1, cardWidth: 110)
        RailHandFan(count: 5, cardWidth: 110)
        RailHandFan(count: 12, cardWidth: 110)
        RailHandFan(count: 17, cardWidth: 110)
    }
    .padding(40)
    .background(CardStyle.feltGreen)
}
