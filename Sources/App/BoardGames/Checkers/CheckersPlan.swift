import SwiftUI

/// Pose of one token at one instant (board units; `lift` = height above the
/// wood; `flip` = horizontal squash for the tumble, 1 == face-on).
struct CheckersPose {
    var position: CGPoint
    var lift: CGFloat
    var flip: CGFloat = 1
    var alpha: CGFloat = 1
    var scale: CGFloat = 1
}

/// A time-indexed script for one move (or one hop of a human's step-by-step
/// multi-jump). Pure function of `t`, exactly like `MancalaPlan`.
struct CheckersPlan {
    struct Hop {
        var t0: Double
        var t1: Double
        var from: Int
        var to: Int
        var jump: Bool
    }

    struct Capture {
        var tokenID: Int
        var seat: Int           // who captured it (whose pile it joins)
        var t0: Double
        var t1: Double
        var from: Int
        var pileIndex: Int
    }

    enum Cue {
        case landing
        case captureStart
        case captureLand
        case crown
    }

    var moverID: Int?
    var hops: [Hop] = []
    var captures: [Capture] = []
    var crownTime: Double?
    var cues: [(t: Double, cue: Cue)] = []
    var duration: Double = 0
    var finalTokens: [CheckersToken] = []
    var finalPile: [Int] = [0, 0]

    private static func smooth(_ u: Double) -> Double { let c = min(max(u, 0), 1); return c * c * (3 - 2 * c) }

    /// Mover's pose, or nil if there's no mover / no hops.
    func moverPose(at t: Double) -> CheckersPose? {
        guard let first = hops.first else { return nil }
        if t <= first.t0 { return CheckersPose(position: CheckersGeometry.center(of: first.from), lift: 0) }
        var rest = CheckersGeometry.center(of: first.from)
        for hop in hops {
            let a = CheckersGeometry.center(of: hop.from), b = CheckersGeometry.center(of: hop.to)
            if t < hop.t0 { return CheckersPose(position: rest, lift: 0) }
            if t <= hop.t1 {
                let u = (t - hop.t0) / max(hop.t1 - hop.t0, 0.0001)
                let e = CGFloat(Self.smooth(u))
                let arc = CGFloat(sin(Double.pi * u))
                let height = hop.jump ? CheckersGeometry.liftHeight * 1.15 * arc : CheckersGeometry.liftHeight * 0.30 * arc
                return CheckersPose(position: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), lift: height)
            }
            rest = b
        }
        return CheckersPose(position: rest, lift: 0)
    }

    /// Capture pose given where the pile slot is (board units, may lie off
    /// the board). nil once the piece has landed in the pile.
    func capturePose(_ capture: Capture, at t: Double, pileSlot: CGPoint) -> CheckersPose? {
        if t >= capture.t1 { return nil }
        let a = CheckersGeometry.center(of: capture.from)
        if t <= capture.t0 { return CheckersPose(position: a, lift: 0) }
        let u = (t - capture.t0) / max(capture.t1 - capture.t0, 0.0001)
        let e = CGFloat(Self.smooth(u))
        let arc = CGFloat(sin(Double.pi * u))
        // The tumble: a coin-flip about the vertical axis, 1.5 turns, while
        // the piece rises and sails to its pile.
        let flip = CGFloat(cos(u * Double.pi * 3))
        return CheckersPose(position: CGPoint(x: a.x + (pileSlot.x - a.x) * e, y: a.y + (pileSlot.y - a.y) * e),
                            lift: CheckersGeometry.liftHeight * 2.2 * arc,
                            flip: flip == 0 ? 0.02 : flip,
                            alpha: 1,
                            scale: 1 - 0.38 * CGFloat(u))
    }

    /// Captured count per seat as the pile should show it at `t`.
    func pileCount(seat: Int, at t: Double, base: [Int]) -> Int {
        var n = base[seat]
        for c in captures where c.seat == seat && t >= c.t1 { n += 1 }
        return n
    }

    /// 0...1 progress of the crown flourish, or nil if not crowning / not yet.
    func crownProgress(at t: Double) -> Double? {
        guard let ct = crownTime, t >= ct else { return nil }
        return (t - ct) / 0.75
    }
}

enum CheckersChoreographer {
    static let jumpDuration = 0.40
    static let stepDuration = 0.30

    /// Builds the plan for `move` as played by `seat`. `doneHops` hops were
    /// already played visually (human step-by-step jumping), so the mover
    /// currently stands on `move.path[doneHops]`.
    static func plan(move: CheckersMove, crowned: Bool, seat: Int, tokens: [CheckersToken], pile: [Int],
                     doneHops: Int, animated: Bool) -> CheckersPlan {
        var plan = CheckersPlan()
        var final = tokens
        var finalPile = pile
        let start = min(doneHops, move.path.count - 1)
        guard let moverIndex = tokens.firstIndex(where: { $0.square == move.path[start] }) else {
            plan.finalTokens = tokens
            plan.finalPile = pile
            return plan
        }
        let mover = tokens[moverIndex]
        plan.moverID = mover.id

        // Captured tokens still on the board, in hop order.
        var capturedTokens: [(hop: Int, token: CheckersToken)] = []
        for (k, sq) in move.captured.enumerated() where k >= start {
            if let t = tokens.first(where: { $0.square == sq }) { capturedTokens.append((k, t)) }
        }

        var t = 0.06
        var end = 0.0
        var pileIndex = pile[seat]
        if animated {
            for k in start..<max(start, move.path.count - 1) {
                let jump = move.isJump
                let dur = jump ? CheckersChoreographer.jumpDuration : CheckersChoreographer.stepDuration
                plan.hops.append(.init(t0: t, t1: t + dur, from: move.path[k], to: move.path[k + 1], jump: jump))
                plan.cues.append((t + dur * 0.92, .landing))
                if let cap = capturedTokens.first(where: { $0.hop == k }) {
                    let c0 = t + dur * 0.62
                    let c1 = c0 + 0.62
                    plan.captures.append(.init(tokenID: cap.token.id, seat: seat, t0: c0, t1: c1,
                                               from: cap.token.square, pileIndex: pileIndex))
                    plan.cues.append((c0, .captureStart))
                    plan.cues.append((c1 - 0.04, .captureLand))
                    pileIndex += 1
                    end = max(end, c1)
                }
                end = max(end, t + dur)
                t += dur + 0.05
            }
            if crowned {
                plan.crownTime = end + 0.04
                plan.cues.append((end + 0.04, .crown))
                end += 0.80
            }
        } else {
            end = 0.25
            if crowned { plan.cues.append((0.05, .crown)) }
        }

        // Final positions.
        final[moverIndex].square = move.path[move.path.count - 1]
        if crowned { final[moverIndex].isKing = true }
        let removed = Set(capturedTokens.map(\.token.id))
        final.removeAll { removed.contains($0.id) }
        finalPile[seat] += capturedTokens.count
        plan.finalTokens = final
        plan.finalPile = finalPile
        plan.duration = end + 0.12
        plan.cues.sort { $0.t < $1.t }
        return plan
    }
}
