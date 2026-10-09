#if COINSIM_SELFTEST
import Foundation
import simd

/// Headless self-test for CoinSim. Build and run:
///
///   swiftc -O -D COINSIM_SELFTEST -parse-as-library \
///     Sources/App/Dice/Coins/CoinSim.swift \
///     Sources/App/Dice/Coins/CoinSimSelfTest.swift -o /tmp/coinsim_selftest \
///     && /tmp/coinsim_selftest
///
/// Compiled out of the app (the flag is never set there).
@main
struct CoinSimSelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }
    static let bounds = (minX: 0.0, minY: 0.0, maxX: 1000.0, maxY: 700.0)

    static func run(_ sim: inout CoinSim, seconds: Double) {
        var t = 0.0
        while t < seconds { sim.step(1.0 / 60.0); t += 1.0 / 60.0 }
    }

    static func main() {
        // 1. Head-on collision: momentum conserved, separation speed = e * closing speed.
        do {
            var c = CoinSimConfig()
            c.coulomb = 0; c.viscous = 0; c.angularDamping = 0; c.tidyDelay = nil
            c.contactScale = 1.0; c.contactFriction = 0
            var sim = CoinSim(config: c)
            sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(200, 300))
            sim.addCoin(id: 2, group: 0, radius: 25, home: CoinVec(400, 300))
            sim.grab(id: 1, at: CoinVec(200, 300))
            sim.release(id: 1, velocity: CoinVec(1600, 0))   // 800 sim pt/s
            let v0 = sim.body(1)!.vel.x
            let pBefore = v0 * sim.body(1)!.mass
            run(&sim, seconds: 0.8)
            let a = sim.body(1)!, b = sim.body(2)!
            let pAfter = a.vel.x * a.mass + b.vel.x * b.mass
            check(abs(pAfter - pBefore) / abs(pBefore) < 0.01, "head-on momentum conserved (\(pBefore) -> \(pAfter))")
            let sep = b.vel.x - a.vel.x
            check(abs(sep / v0 - 0.6) < 0.03, "head-on restitution ~0.6 (got \(sep / v0))")
            check(abs(a.vel.x) < abs(v0) && b.vel.x > 0, "equal masses: target takes most of the speed")
        }
        // 2. Glancing hit transfers spin.
        do {
            var c = CoinSimConfig(); c.tidyDelay = nil
            var sim = CoinSim(config: c)
            sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(200, 330))
            sim.addCoin(id: 2, group: 0, radius: 25, home: CoinVec(300, 300))
            sim.grab(id: 1, at: CoinVec(200, 330))
            sim.release(id: 1, velocity: CoinVec(1400, 0))
            var maxSpin = 0.0
            for _ in 0..<120 { sim.step(1.0 / 60.0); maxSpin = max(maxSpin, abs(sim.body(2)!.angVel)) }
            check(maxSpin > 0.5, "glancing hit spins the target (peak \(maxSpin) rad/s)")
        }
        // 3. Rail rebound is damped.
        do {
            var c = CoinSimConfig(); c.bounds = bounds; c.tidyDelay = nil; c.allowEdgeRoll = false
            var sim = CoinSim(config: c)
            sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(60, 300))
            sim.grab(id: 1, at: CoinVec(60, 300))
            sim.release(id: 1, velocity: CoinVec(-1600, 0))
            var minX = 1e9, reboundSpeed = 0.0, railEvents = 0
            for _ in 0..<60 {
                sim.step(1.0 / 60.0)
                minX = min(minX, sim.body(1)!.pos.x)
                reboundSpeed = max(reboundSpeed, sim.body(1)!.vel.x)
                railEvents += sim.drainEvents().filter { if case .rail = $0 { return true }; return false }.count
            }
            check(minX >= 25 - 1e-9, "coin never crosses the rail (min x \(minX))")
            check(reboundSpeed > 200 && reboundSpeed < 800 * 0.55, "rebound damped (e~0.5): \(reboundSpeed)")
            check(railEvents >= 1, "rail event emitted")
        }
        // 4. Travel distances (informational + sanity).
        do {
            for speed in [400.0, 800.0, 1200.0, 1800.0] {
                var c = CoinSimConfig(); c.tidyDelay = nil; c.allowEdgeRoll = false
                var sim = CoinSim(config: c)
                sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(100, 300))
                sim.grab(id: 1, at: CoinVec(100, 300))
                sim.release(id: 1, velocity: CoinVec(speed, 0))
                run(&sim, seconds: 3)
                let d = sim.body(1)!.pos.x - 100
                print(String(format: "INFO finger %4.0f px/s slides %.0f pt", speed, d))
                if speed == 400 { check(d > 5 && d < 60, "gentle flick slides a short way (\(d))") }
                if speed == 1800 { check(d > 150 && d < 450, "hard flick slides far but finite (\(d))") }
            }
        }
        // 5. Edge-roll trigger threshold and behaviour.
        do {
            var below = 0, above = 0
            for seed in 1...200 {
                var c = CoinSimConfig(); c.seed = UInt64(seed); c.tidyDelay = nil
                var sim = CoinSim(config: c)
                sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(100, 300))
                sim.grab(id: 1, at: CoinVec(100, 300))
                if sim.release(id: 1, velocity: CoinVec(2000, 0)) { below += 1 }   // 1000 sim < 1050
                var sim2 = CoinSim(config: c)
                sim2.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(100, 300))
                sim2.grab(id: 1, at: CoinVec(100, 300))
                if sim2.release(id: 1, velocity: CoinVec(3200, 0)) { above += 1 }  // 1600 sim
            }
            check(below == 0, "no edge-roll below threshold (0/200, got \(below))")
            check(above > 40 && above < 190, "edge-roll is rare-but-real above threshold (\(above)/200)")
            var rm = CoinSimConfig(); rm.reduceMotion = true
            var sim3 = CoinSim(config: rm)
            sim3.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(100, 300))
            sim3.grab(id: 1, at: CoinVec(100, 300))
            check(!sim3.release(id: 1, velocity: CoinVec(3400, 0), forceEdgeRoll: true), "Reduce Motion: never edge-rolls")
            var d = sim3.body(1)!.pos.x
            _ = d; d = 0
            // Full edge-roll lifecycle.
            var c = CoinSimConfig(); c.tidyDelay = nil; c.bounds = (0, 0, 3000, 3000)
            var sim = CoinSim(config: c)
            sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(500, 500))
            sim.grab(id: 1, at: CoinVec(500, 500))
            let tipped = sim.release(id: 1, velocity: CoinVec(3000, 0), forceEdgeRoll: true)
            check(tipped, "forced edge-roll starts")
            var sawEdge = false, sawFall = false, headingMin = 9.0, headingMax = -9.0
            var maxTilt = 0.0, spinDown = false, rested = false, t = 0.0
            while t < 6 {
                sim.step(1.0 / 60.0); t += 1.0 / 60.0
                let b = sim.body(1)!
                if b.mode == .edge { sawEdge = true; headingMin = min(headingMin, b.heading); headingMax = max(headingMax, b.heading); maxTilt = max(maxTilt, b.tilt) }
                if b.mode == .falling { sawFall = true }
                for e in sim.drainEvents() {
                    if case .spinDown = e { spinDown = true }
                    if case .rested(_, _, let th) = e, th { rested = true }
                }
            }
            check(sawEdge && sawFall && spinDown && rested, "edge -> fall -> spinDown event -> rested flat")
            check(headingMax - headingMin > 0.5, "edge path is curved (heading swept \(headingMax - headingMin) rad)")
            check(maxTilt > 1.0, "coin stands near vertical (tilt \(maxTilt) rad)")
            check(sim.body(1)!.mode == .flat && sim.body(1)!.tilt == 0, "ends lying flat")
        }
        // 6. Resting piles stay put; a hit topples them; they tidy home.
        do {
            func pile() -> CoinSim {
                var c = CoinSimConfig(); c.bounds = bounds; c.tidyDelay = 1.0; c.allowEdgeRoll = false
                var sim = CoinSim(config: c)
                for i in 0..<8 {
                    let a = Double(i) * 2.39996
                    let r = 50 * 0.4 * Double(i).squareRoot()
                    sim.addCoin(id: i, group: 0, radius: 25, home: CoinVec(500 + cos(a) * r, 350 + sin(a) * r * 0.86))
                }
                sim.addCoin(id: 100, group: 1, radius: 25, home: CoinVec(250, 350))
                return sim
            }
            var sim = pile()
            run(&sim, seconds: 2)
            let drift = (0..<8).map { simd_length(sim.body($0)!.pos - sim.body($0)!.home) }.max()!
            check(drift < 1e-9 && sim.awakeCount == 0, "stacked pile at rest does not move (drift \(drift))")
            sim.grab(id: 100, at: CoinVec(250, 350))
            sim.release(id: 100, velocity: CoinVec(2400, 0))
            var maxSpeed = 0.0, finite = true
            var t = 0.0
            var displaced = 0.0
            while t < 1.5 {
                sim.step(1.0 / 60.0); t += 1.0 / 60.0
                for b in sim.bodies {
                    maxSpeed = max(maxSpeed, simd_length(b.vel))
                    if !b.pos.x.isFinite || !b.pos.y.isFinite { finite = false }
                }
                displaced = max(displaced, (0..<8).map { simd_length(sim.body($0)!.pos - sim.body($0)!.home) }.max()!)
            }
            check(finite, "no NaN/inf during scatter")
            check(maxSpeed <= 1700 * 1.05, "no energy explosion (peak \(maxSpeed) pt/s)")
            check(displaced > 25, "flicked coin scatters the pile (peak displacement \(displaced) pt)")
            run(&sim, seconds: 5)
            let back = (0..<8).map { simd_length(sim.body($0)!.pos - sim.body($0)!.home) }.max()!
            check(back < 0.5 && sim.awakeCount == 0, "pile tidies back to its deterministic layout (\(back))")
        }
        // 7. Only the coin the user released reports thrown=true.
        do {
            var c = CoinSimConfig(); c.tidyDelay = nil
            var sim = CoinSim(config: c)
            sim.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(200, 300))
            sim.addCoin(id: 2, group: 0, radius: 25, home: CoinVec(300, 300))
            sim.grab(id: 1, at: CoinVec(200, 300))
            sim.release(id: 1, velocity: CoinVec(1400, 0))
            var thrownIDs = Set<Int>(), restedIDs = Set<Int>()
            for _ in 0..<300 {
                sim.step(1.0 / 60.0)
                for e in sim.drainEvents() {
                    if case .rested(let id, _, let th) = e { restedIDs.insert(id); if th { thrownIDs.insert(id) } }
                }
            }
            check(restedIDs == [1, 2] && thrownIDs == [1], "bystander knocked by a collision never reports thrown (rested \(restedIDs), thrown \(thrownIDs))")
        }
        // 8. Dice impact: proportional, radial, hop.
        do {
            func total(_ s: Double) -> Double {
                var c = CoinSimConfig(); c.tidyDelay = nil
                var sim = CoinSim(config: c)
                for i in 0..<6 { sim.addCoin(id: i, group: 0, radius: 25, home: CoinVec(500 + Double(i % 3) * 60, 400 + Double(i / 3) * 60)) }
                sim.impulse(at: CoinVec(480, 380), strength: s)
                let hop = sim.bodies.map { $0.vz }.max()!
                _ = hop
                run(&sim, seconds: 2)
                return sim.bodies.map { simd_length($0.pos - $0.home) }.reduce(0, +)
            }
            let soft = total(0.2), hard = total(0.9)
            check(hard > soft * 1.5, "stronger dice impact scatters farther (\(soft) -> \(hard))")
            var c = CoinSimConfig(); c.tidyDelay = nil
            var far = CoinSim(config: c)
            far.addCoin(id: 1, group: 0, radius: 25, home: CoinVec(900, 600))
            far.impulse(at: CoinVec(100, 100), strength: 1)
            check(far.awakeCount == 0, "coins far from the impact are untouched")
        }
        // 9. Determinism.
        do {
            func scenario() -> [CoinBody] {
                var c = CoinSimConfig(); c.bounds = bounds
                var sim = CoinSim(config: c)
                for i in 0..<10 { sim.addCoin(id: i, group: 0, radius: 25, home: CoinVec(400 + Double(i % 5) * 30, 300 + Double(i / 5) * 30)) }
                sim.grab(id: 3, at: sim.body(3)!.pos)
                sim.release(id: 3, velocity: CoinVec(2600, 400))
                run(&sim, seconds: 1)
                sim.impulse(at: CoinVec(430, 320), strength: 0.7)
                run(&sim, seconds: 4)
                return sim.bodies
            }
            let a = scenario(), b = scenario()
            let same = zip(a, b).allSatisfy { $0.pos == $1.pos && $0.vel == $1.vel && $0.angle == $1.angle }
            check(same, "two runs from the same seed are bit-identical")
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
