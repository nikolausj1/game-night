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
    /// motion, never a fly-in-then-drop.
    ///
    /// The previous two attempts both decomposed the throw into a ground
    /// track (x/y) plus a separate lift (height), each driven by its OWN
    /// `withAnimation` call against its own `@State` dictionary. SwiftUI
    /// gives no lockstep guarantee between independent animations — they
    /// can start on different commits and visibly desync under real-device
    /// frame pressure — so the eye reads "slide, then drop" no matter how
    /// the individual curves are tuned. Curve tweaks can't fix a
    /// synchronization problem.
    ///
    /// The fix: `PileToss` is solved ONCE (pure geometry, no timing state),
    /// and `evaluate(_:progress:tableSize:)` is a pure function of a SINGLE
    /// scalar `progress` — position, height, scale, rotation, and the
    /// separated ground shadow all come out of that one input. The caller
    /// drives `progress` with exactly one `withAnimation` call on exactly
    /// one `@State` value, rendered through a custom `Animatable` view
    /// (`PileTossCardView` in TableGameView) whose `animatableData` IS that
    /// progress — SwiftUI re-invokes its `body` at every intermediate tick
    /// of the SAME transaction, so every quantity is always read at the
    /// same instant. Desync is structurally impossible: there's only one
    /// thing being animated.
    struct PileToss {
        let entry: CGPoint        // normalized, just outside the felt: where the card leaves the hand
        let control: CGPoint      // normalized bezier control point: bows the path like a real toss
        let touchdown: CGPoint    // normalized, where the card first contacts the pile
        let rest: CGPoint         // normalized, touchdown + the tiny landing skid
        let entryRotation: Double // degrees, spin at launch
        let restRotation: Double  // degrees, final settle angle
        let settleTwist: Double   // degrees of rotational overshoot right at touchdown, eased out during the skid
        let apex: CGFloat         // peak lift in points, mid-flight
        let duration: Double      // the WHOLE throw, launch through settle — one span, one animation
        /// Fraction of `duration` spent airborne before the card is
        /// grounded; the remainder is the landing skid (see `evaluate`).
        let touchdownFraction: CGFloat
    }

    /// Every visual quantity of a pile toss, at one instant, in points.
    struct PileTossFrame {
        let position: CGPoint    // ground track, in points — the shadow lives here
        let heightPoints: CGFloat
        let rotation: Double     // degrees
        let scale: CGFloat
        let shadowAlpha: Double
        let shadowScale: CGFloat
        let shadowBlur: CGFloat
    }

    /// Solve a pile toss for a card entering from a seat's edge (or the
    /// table's own edge when the seat is unknown, e.g. a deck-sourced card)
    /// and landing on the pile at `restPoint`. Pure geometry — no `Date`,
    /// no timers, safe to recompute every render.
    static func pileToss(cardID: String, seatAnchor: CGPoint?,
                         restPoint: CGPoint, tableSize: CGSize) -> PileToss {
        let hash = TableGeometry.jitterDegrees(cardID: cardID)
        let anchor = seatAnchor ?? CGPoint(x: 0.5, y: 1.0)
        let entry = CGPoint(x: 0.5 + (anchor.x - 0.5) * 1.22,
                            y: 0.47 + (anchor.y - 0.47) * 1.22)
        let entryPt = CGPoint(x: entry.x * tableSize.width, y: entry.y * tableSize.height)
        let restPt = CGPoint(x: restPoint.x * tableSize.width, y: restPoint.y * tableSize.height)
        let travel = hypot(restPt.x - entryPt.x, restPt.y - entryPt.y)
        let flightDuration = 0.30 + Double(travel / tableSize.width) * 0.24
        let settleDuration = 0.06
        let apex = min(96, 52 + travel * 0.10)

        // The landing skid: a tiny 2–4pt continuation past touchdown, along
        // the same heading, so contact reads as a landing, not a
        // teleport-stop. `touchdown` is where the card actually meets the
        // felt; `rest` (the caller's target) is a hair past it.
        let dx = restPt.x - entryPt.x, dy = restPt.y - entryPt.y
        let dirLen = max(0.0001, hypot(dx, dy))
        let settleDist: CGFloat = 3
        let settle = CGPoint(x: dx / dirLen * settleDist / tableSize.width,
                             y: dy / dirLen * settleDist / tableSize.height)
        let touchdown = CGPoint(x: restPoint.x - settle.x, y: restPoint.y - settle.y)

        // Control point: pulled toward the table's center and "up" along
        // the throw direction, so the entry→touchdown line bows into a real
        // arc instead of a ruler-straight glide.
        let midX = (entry.x + touchdown.x) / 2
        let midY = (entry.y + touchdown.y) / 2
        let bow = CGPoint(x: (0.5 - midX) * 0.5, y: (0.47 - midY) * 0.35)
        let control = CGPoint(x: midX + bow.x, y: midY + bow.y)

        let restRotation = hash * 1.8
        let entryRotation = restRotation - hash * 3.0
        let settleTwist: Double = hash >= 0 ? 2.4 : -2.4
        let duration = flightDuration + settleDuration

        return PileToss(entry: entry, control: control, touchdown: touchdown, rest: restPoint,
                        entryRotation: entryRotation, restRotation: restRotation,
                        settleTwist: settleTwist, apex: apex, duration: duration,
                        touchdownFraction: CGFloat(flightDuration / duration))
    }

    /// Reduce Motion: the same card, flattened to a short, low, straight
    /// slide — no rising arc — matching the rest of the felt's short/no-op
    /// a11y treatment. Still driven through the identical single-progress
    /// path, just with the physics dialed to (almost) nothing.
    static func flatSlide(_ toss: PileToss) -> PileToss {
        let straight = CGPoint(x: (toss.entry.x + toss.touchdown.x) / 2,
                               y: (toss.entry.y + toss.touchdown.y) / 2)
        return PileToss(entry: toss.entry, control: straight, touchdown: toss.touchdown,
                        rest: toss.rest, entryRotation: toss.restRotation,
                        restRotation: toss.restRotation, settleTwist: 0, apex: 0,
                        duration: 0.15, touchdownFraction: 0.85)
    }

    /// Pure function: every visual quantity of a pile toss, at ONE instant,
    /// derived from a single `progress` scalar (0…1). No other state feeds
    /// this — position is a quadratic bezier entry→control→touchdown for
    /// the airborne fraction of `progress`, then a straight lerp
    /// touchdown→rest for the trailing landing skid; height follows a
    /// ballistic 4·p·(1−p) profile over the airborne fraction (naturally
    /// zero at both liftoff and touchdown, peaking at `apex` mid-flight);
    /// rotation interpolates entry→(rest∓settleTwist)→rest to match.
    static func evaluate(_ toss: PileToss, progress: CGFloat, tableSize: CGSize) -> PileTossFrame {
        let p = min(1, max(0, progress))
        let touchdownRotation = toss.restRotation - toss.settleTwist

        let normPosition: CGPoint
        let heightFrac: CGFloat
        let rotation: Double
        if p <= toss.touchdownFraction {
            let t = toss.touchdownFraction > 0 ? p / toss.touchdownFraction : 1
            normPosition = quadraticBezier(toss.entry, toss.control, toss.touchdown, t)
            heightFrac = 4 * t * (1 - t)
            rotation = toss.entryRotation + (touchdownRotation - toss.entryRotation) * Double(t)
        } else {
            let remaining = 1 - toss.touchdownFraction
            let t = remaining > 0 ? (p - toss.touchdownFraction) / remaining : 1
            normPosition = CGPoint(x: toss.touchdown.x + (toss.rest.x - toss.touchdown.x) * t,
                                   y: toss.touchdown.y + (toss.rest.y - toss.touchdown.y) * t)
            heightFrac = 0
            rotation = touchdownRotation + (toss.restRotation - touchdownRotation) * Double(t)
        }

        let position = CGPoint(x: normPosition.x * tableSize.width, y: normPosition.y * tableSize.height)
        let heightPoints = heightFrac * toss.apex

        return PileTossFrame(
            position: position, heightPoints: heightPoints, rotation: rotation,
            scale: 1 + heightPoints * 0.0032,
            shadowAlpha: 0.30 - Double(heightPoints) * 0.0016,
            shadowScale: 0.92 - heightPoints * 0.0022,
            shadowBlur: 3 + heightPoints * 0.16)
    }

    private static func quadraticBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                       y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y)
    }
}
