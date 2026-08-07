import SwiftUI

/// Solitaire's own single-progress flight geometry, the same structural
/// idea as `FeltPhysics.PileToss`/`PileTossCardView` in `Sources/App/Table`
/// (read there for the full rationale): every quantity of a flying card —
/// position, lift, rotation, scale — comes out of ONE scalar `progress`
/// via a pure function, rendered through an `Animatable` view whose
/// `animatableData` IS that scalar. SwiftUI then re-invokes `body` at every
/// intermediate tick of a SINGLE `withAnimation` transaction, so nothing
/// here can desync into the "slide, then pop" bug two independent x/y
/// animations are prone to. Kept local to Solitaire rather than reusing
/// `FeltPhysics` directly: this file has zero dependency on `TableGeometry`
/// or seat anchors, which don't mean anything on a single-player board.
enum SolitaireMotion {
    /// One flight, solved once (pure geometry, no timers).
    struct Flight {
        let entry: CGPoint         // board points: where the card starts
        let control: CGPoint       // bezier control point: bows the arc
        let rest: CGPoint          // board points: where it lands
        let entryRotation: Double  // degrees
        let restRotation: Double   // degrees
        let apex: CGFloat          // peak lift in points; 0 = a flat slide
        let duration: Double
    }

    /// Every visual quantity of a flight, at one instant.
    struct Frame {
        let position: CGPoint
        let heightPoints: CGFloat
        let rotation: Double
        let scale: CGFloat
    }

    /// A gentle arced toss — used for the opening deal and the double-tap
    /// foundation fly-up. `liftFraction` scales how high the arc rises
    /// relative to the travel distance (bigger for the foundation fly-up,
    /// which should read as a decisive little flourish; smaller for the
    /// opening deal, which is quick and businesslike).
    static func arc(from entry: CGPoint, to rest: CGPoint, entryRotation: Double,
                    restRotation: Double, liftFraction: CGFloat, duration: Double) -> Flight {
        let dx = rest.x - entry.x, dy = rest.y - entry.y
        let travel = max(1, hypot(dx, dy))
        let mid = CGPoint(x: (entry.x + rest.x) / 2, y: (entry.y + rest.y) / 2)
        // Bow the control point perpendicular to the travel line so the
        // path reads as a real toss/throw arc, not a straight ruled line
        // with a vertical bounce glued on top.
        let perpendicular = CGPoint(x: -dy / travel, y: dx / travel)
        let bow = travel * 0.12
        let control = CGPoint(x: mid.x + perpendicular.x * bow, y: mid.y + perpendicular.y * bow)
        let apex = min(140, travel * liftFraction)
        return Flight(entry: entry, control: control, rest: rest, entryRotation: entryRotation,
                     restRotation: restRotation, apex: apex, duration: duration)
    }

    /// Reduce Motion: the same start/end points, flattened to a short,
    /// low, straight slide — no rising arc — matching the rest of the
    /// app's Reduce Motion treatment (see `FeltPhysics.flatSlide`).
    static func flattened(_ flight: Flight) -> Flight {
        Flight(entry: flight.entry, control: flight.entry, rest: flight.rest,
              entryRotation: flight.restRotation, restRotation: flight.restRotation,
              apex: 0, duration: min(flight.duration, 0.16))
    }

    /// Pure function: derive every visual quantity from `progress` (0...1)
    /// alone. Position rides a quadratic bezier entry→control→rest; height
    /// follows a ballistic 4·p·(1−p) profile (zero at both ends, peaking
    /// at `apex` mid-flight); rotation eases entry→rest in step.
    static func evaluate(_ flight: Flight, progress: CGFloat) -> Frame {
        let p = min(1, max(0, progress))
        let position = quadraticBezier(flight.entry, flight.control, flight.rest, p)
        let heightPoints = 4 * p * (1 - p) * flight.apex
        let rotation = flight.entryRotation + (flight.restRotation - flight.entryRotation) * Double(p)
        return Frame(position: position, heightPoints: heightPoints, rotation: rotation,
                    scale: 1 + heightPoints * 0.0035)
    }

    private static func quadraticBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                       y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y)
    }
}

/// One card riding a `SolitaireMotion.Flight`. `progress` IS
/// `animatableData` — see the rationale on `SolitaireMotion` above and on
/// `FeltPhysics.PileToss`/`PileTossCardView`, which this mirrors.
struct SolitaireFlightCardView: View, Animatable {
    var progress: CGFloat
    let card: Card
    let faceUp: Bool
    let flight: SolitaireMotion.Flight
    let cardWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = SolitaireMotion.evaluate(flight, progress: progress)
        let airborne = frame.heightPoints > 0.5
        ZStack {
            if airborne {
                Ellipse()
                    .fill(.black.opacity(0.28 - Double(frame.heightPoints) * 0.0014))
                    .frame(width: cardWidth * 0.9, height: cardWidth * 0.56)
                    .blur(radius: 3 + frame.heightPoints * 0.14)
                    .position(frame.position)
            }
            CardView(card: card, faceUp: faceUp, elevation: 0)
                .frame(width: cardWidth)
                .rotationEffect(.degrees(frame.rotation))
                .scaleEffect(frame.scale)
                .position(x: frame.position.x, y: frame.position.y - frame.heightPoints)
                .shadow(color: .black.opacity(airborne ? 0 : 0.28), radius: 2, y: 1)
        }
        .allowsHitTesting(false)
        .zIndex(600)
    }
}
