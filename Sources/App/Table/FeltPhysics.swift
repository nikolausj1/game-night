import SwiftUI

/// The physics of a card tossed onto felt.
///
/// A sliding card decelerates under (nearly constant) friction:
///   p(t) = p₀ + v₀t − ½at²,  stopping at t = v₀/a.
/// Normalized, that trajectory is exactly the quadratic ease-out curve
/// 1−(1−τ)², so we solve the physics for distance, duration, and spin,
/// then let one bezier that matches quad-out render it. Spin damps on the
/// same curve — a real card stops sliding and stops turning together.
enum FeltPhysics {
    /// The friction curve (canonical easeOutQuad as a cubic bezier).
    static func slide(duration: Double) -> Animation {
        .timingCurve(0.25, 0.46, 0.45, 0.94, duration: duration)
    }

    struct Toss {
        let entry: CGPoint       // normalized, just outside the felt
        let rest: CGPoint        // normalized, where friction wins
        let restRotation: Double // degrees, final settle angle
        let spin: Double         // degrees turned during the slide
        let duration: Double
    }

    /// Solve a toss for a card entering from a seat's edge.
    /// - throwVelocity: the flick in points/sec on the thrower's phone;
    ///   nil (table-dealt or unknown) gets a natural medium toss.
    static func toss(cardID: String,
                     seatAnchor: CGPoint?,
                     throwVelocity: CGSize?,
                     tableSize: CGSize) -> Toss {
        let hash = TableGeometry.jitterDegrees(cardID: cardID)          // −9…9, stable
        let lateralJitter = TableGeometry.jitterDegrees(cardID: cardID + "lat") / 90.0 // −0.1…0.1

        // Where the card enters: just past the felt edge on the thrower's
        // side (or the bottom edge when we don't know the seat).
        let anchor = seatAnchor ?? CGPoint(x: 0.5, y: 1.0)
        let entry = CGPoint(x: 0.5 + (anchor.x - 0.5) * 1.22,
                            y: 0.47 + (anchor.y - 0.47) * 1.22)

        // Flick strength → how far it slides. |vy| ≈ 800 (gentle flip)
        // to 4500+ (hard snap) on a phone; map to 0…1 with a soft knee.
        let speed: Double
        if let v = throwVelocity {
            let magnitude = abs(Double(v.height)) + abs(Double(v.width)) * 0.3
            speed = min(1.0, max(0.15, (magnitude - 500) / 3500))
        } else {
            speed = 0.35 + abs(hash) / 30.0 // 0.35…0.65, varied per card
        }

        // Direction: toward the center zone, bent by the lateral jitter
        // (nobody throws perfectly straight).
        let target = CGPoint(x: 0.52 + lateralJitter, y: 0.47 + lateralJitter * 0.5)
        let dx = target.x - entry.x
        let dy = target.y - entry.y
        let norm = max(0.001, sqrt(dx * dx + dy * dy))

        // Travel: a gentle flip stops a third of the way in; a hard snap
        // sails to (or just past) the middle of the felt.
        let travel = 0.34 + 0.78 * speed // fraction of entry→target distance
        var rest = CGPoint(x: entry.x + dx * travel, y: entry.y + dy * travel)
        rest.x = min(0.90, max(0.10, rest.x))
        rest.y = min(0.86, max(0.12, rest.y))

        // Friction timing: harder throws travel farther AND stop later,
        // but only by a bit — felt is grippy.
        let duration = 0.34 + 0.26 * speed

        // Spin: a real toss turns the card 10–45° while it slides; keep
        // the stable hash angle as the settle so re-renders don't twitch.
        let restRotation = hash * 2.2
        let spinDirection: Double = hash >= 0 ? 1 : -1
        let spin = spinDirection * (10 + 35 * speed)

        _ = norm
        return Toss(entry: entry, rest: rest, restRotation: restRotation,
                    spin: spin, duration: duration)
    }

    /// A thrown card landing on a neat pile: "as if you threw the card from
    /// your hand and it lands perfectly on the discard stack" — ONE smooth
    /// descending arc, never a fly-in-then-drop. The previous version drove
    /// the ground track and the lift as separate `withAnimation` calls
    /// keyed to a hand-rolled bezier (`.timingCurve(0.30, 0.0, 0.18, 1.0,
    /// …)`) whose control points aren't x-monotonic — SwiftUI's easing
    /// solver stalls the horizontal motion early and holds near the target
    /// while the (correctly-timed) vertical fall keeps going, which reads
    /// exactly as "flies in, hangs above the pile, then drops."
    ///
    /// The fix: the ground track uses a plain, guaranteed-monotonic
    /// deceleration (`.easeOut`) that keeps advancing all the way to the
    /// full animation duration — it never finishes early — while the lift
    /// still rises and falls in two C1-continuous halves (easeOut up,
    /// easeIn down, meeting at zero velocity at the apex, matching the
    /// shed pile's proven "trick-slide" landing). Because both now span
    /// the identical `duration`, they touch down on the same frame:
    /// decelerating horizontally right up to contact, never hovering.
    struct PileDropArc {
        let entry: CGPoint        // normalized, just outside the felt
        let touchdown: CGPoint    // normalized, where the arc actually lands
        let rest: CGPoint         // normalized, touchdown + the tiny contact settle
        let restRotation: Double  // degrees, final settle angle
        let entryRotation: Double // degrees, spin at launch
        let apex: CGFloat         // peak lift in points
        let duration: Double      // the arc itself (excludes the settle)
        /// The settle: a real card doesn't stop dead on contact — it skids
        /// a couple points and finishes its spin as it grips the felt.
        static let settleDuration = 0.06
    }

    /// Solve a pile-drop arc for a card entering from a seat's edge (or the
    /// table's own edge when the seat is unknown, e.g. a deck-sourced card)
    /// and landing on the pile at `restPoint`.
    static func pileDropArc(cardID: String, seatAnchor: CGPoint?,
                            restPoint: CGPoint, tableSize: CGSize) -> PileDropArc {
        let hash = TableGeometry.jitterDegrees(cardID: cardID)
        let anchor = seatAnchor ?? CGPoint(x: 0.5, y: 1.0)
        let entry = CGPoint(x: 0.5 + (anchor.x - 0.5) * 1.22,
                            y: 0.47 + (anchor.y - 0.47) * 1.22)
        let entryPt = CGPoint(x: entry.x * tableSize.width, y: entry.y * tableSize.height)
        let restPt = CGPoint(x: restPoint.x * tableSize.width, y: restPoint.y * tableSize.height)
        let travel = hypot(restPt.x - entryPt.x, restPt.y - entryPt.y)
        let duration = 0.30 + Double(travel / tableSize.width) * 0.24
        let apex = min(96, 52 + travel * 0.10)

        // The settle: a tiny 2–4pt skid past touchdown, along the same
        // heading, so contact reads as a landing, not a teleport-stop.
        let dx = restPt.x - entryPt.x, dy = restPt.y - entryPt.y
        let dirLen = max(0.0001, hypot(dx, dy))
        let settleDist: CGFloat = 3
        let settle = CGPoint(x: dx / dirLen * settleDist / tableSize.width,
                             y: dy / dirLen * settleDist / tableSize.height)
        let touchdown = CGPoint(x: restPoint.x - settle.x, y: restPoint.y - settle.y)

        return PileDropArc(entry: entry, touchdown: touchdown, rest: restPoint,
                           restRotation: hash * 1.8, entryRotation: hash * 1.8 - hash * 3.0,
                           apex: apex, duration: duration)
    }
}
