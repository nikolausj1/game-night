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
}
