import SwiftUI

/// One stone's pose at one instant, in board units. `height` is how far the
/// stone is above the wood (0 == resting); the renderer turns it into a lift,
/// a scale and a softer, wider shadow.
struct MancalaPose {
    var position: CGPoint
    var height: CGFloat
    /// Stacking index inside its resting slot (for painter's order), or -1
    /// to mean "unchanged from before the move".
    var order: Int = -1
}

/// A complete, time-indexed script for ONE move's animation. The engine has
/// already applied the move; the plan replays it for the eye. Everything the
/// renderer needs is a pure function of `t` (seconds since the plan began),
/// so a frame can be drawn for any instant, there is no per-stone animation
/// state to drift out of sync, and Reduce Motion simply plays no plan.
struct MancalaPlan {
    struct Segment {
        enum Kind {
            /// Rise from the pit into the hovering hand.
            case lift
            /// Ride along with the hand (`from` is the offset from the hand).
            case held
            /// Fall from the hand into a pit with a tiny settle bounce.
            case drop
            /// Slide from one resting place to another on a low arc
            /// (captures, the end-of-game sweep).
            case glide
        }
        var kind: Kind
        var t0: Double
        var t1: Double
        var from: CGPoint
        var to: CGPoint
        /// Stacking index in the destination slot once this segment lands.
        var endIndex: Int = 0
    }

    struct Glow {
        var slots: [Int]
        var t0: Double
        var t1: Double
    }

    enum Cue {
        case pitTick
        case storeTick
        case lift
        case goAgain(seat: Int)
        case clearGoAgain
        case captureFlash
        case chime
    }

    var segments: [Int: [Segment]] = [:]
    /// The hovering hand: piecewise-smooth path through (time, point).
    var hand: [(t: Double, p: CGPoint)] = []
    var glows: [Glow] = []
    var cues: [(t: Double, cue: Cue)] = []
    var duration: Double = 0
    /// Stone ids per absolute slot once the whole move has played out.
    var finalSlots: [[Int]] = []

    // MARK: - Evaluation

    private static func smooth(_ u: Double) -> Double { let c = min(max(u, 0), 1); return c * c * (3 - 2 * c) }
    private static func easeOut(_ u: Double) -> Double { let c = min(max(u, 0), 1); return 1 - (1 - c) * (1 - c) }

    func handPosition(at t: Double) -> CGPoint {
        guard let first = hand.first else { return .zero }
        if t <= first.t { return first.p }
        for i in 1..<hand.count where t <= hand[i].t {
            let a = hand[i - 1], b = hand[i]
            let span = max(b.t - a.t, 0.0001)
            let u = Self.smooth((t - a.t) / span)
            return CGPoint(x: a.p.x + (b.p.x - a.p.x) * u, y: a.p.y + (b.p.y - a.p.y) * u)
        }
        return hand[hand.count - 1].p
    }

    /// Pose of stone `id` at time `t`, or nil if this plan doesn't move it.
    func pose(of id: Int, at t: Double) -> MancalaPose? {
        guard let list = segments[id], let first = list.first else { return nil }
        let hh = MancalaGeometry.handHeight
        if t < first.t0 { return MancalaPose(position: first.from, height: 0) }
        var previousEnd = first.from
        var previousOrder = -1
        for seg in list {
            if t < seg.t0 { return MancalaPose(position: previousEnd, height: 0, order: previousOrder) }
            if t <= seg.t1 {
                let u = (t - seg.t0) / max(seg.t1 - seg.t0, 0.0001)
                switch seg.kind {
                case .lift:
                    let e = Self.easeOut(u)
                    return MancalaPose(position: lerp(seg.from, seg.to, e), height: hh * CGFloat(e))
                case .held:
                    let h = handPosition(at: t)
                    return MancalaPose(position: CGPoint(x: h.x + seg.from.x, y: h.y + seg.from.y), height: hh)
                case .drop:
                    // Lateral settle is quick; the fall itself is gravity
                    // (height shrinks like 1 - u^2), then a small bounce.
                    let fall = 0.78
                    let lateral = Self.easeOut(u / fall)
                    let height: CGFloat
                    if u < fall {
                        let x = u / fall
                        height = hh * CGFloat(1 - x * x)
                    } else {
                        height = 0.0075 * CGFloat(sin(Double.pi * (u - fall) / (1 - fall)))
                    }
                    return MancalaPose(position: lerp(seg.from, seg.to, lateral), height: height)
                case .glide:
                    let e = Self.smooth(u)
                    return MancalaPose(position: lerp(seg.from, seg.to, e), height: 0.020 * CGFloat(sin(Double.pi * u)))
                }
            }
            previousEnd = seg.to
            previousOrder = seg.endIndex
        }
        return MancalaPose(position: previousEnd, height: 0, order: previousOrder)
    }

    /// 0...1 brightness of the glow on `slot` at `t`.
    func glowStrength(slot: Int, at t: Double) -> Double {
        var best = 0.0
        for g in glows where g.slots.contains(slot) && t >= g.t0 && t <= g.t1 {
            let u = (t - g.t0) / max(g.t1 - g.t0, 0.0001)
            best = max(best, sin(Double.pi * u))
        }
        return best
    }

    /// How many of the stones that END UP in `slot` (a store) have landed by
    /// `t`. Stores only ever gain stones, so this is the live count a badge
    /// should show while a pour is mid-flight.
    func landedCount(in slot: Int, at t: Double) -> Int {
        guard finalSlots.indices.contains(slot) else { return 0 }
        var n = 0
        for id in finalSlots[slot] {
            if let last = segments[id]?.last { if t >= last.t1 { n += 1 } } else { n += 1 }
        }
        return n
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ e: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * CGFloat(e), y: a.y + (b.y - a.y) * CGFloat(e))
    }
}
