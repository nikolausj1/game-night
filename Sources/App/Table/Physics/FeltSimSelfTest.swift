import Foundation

// Headless self-test for FeltSim (no simulator, no SwiftUI views).
//
// Run (from the repo root):
//   swiftc -O -parse-as-library -D FELTSIM_SELFTEST \
//     -o "$TMPDIR/feltsim_selftest" \
//     Sources/App/Table/Physics/FeltSim.swift \
//     Sources/App/Table/Physics/FeltSimSelfTest.swift \
//     Sources/App/Table/FeltPhysics.swift \
//     Sources/App/Table/TableGeometry.swift \
//   && "$TMPDIR/feltsim_selftest"
//
// FeltPhysics/TableGeometry are compiled in so flick parity is checked
// against the REAL legacy solver, not a copy of its formulas. The `#if`
// keeps all of this (and its @main) out of the app target.
#if FELTSIM_SELFTEST
import SwiftUI

@main
struct FeltSimSelfTestMain {
    static func main() {
        let ok = FeltSimSelfTest.run()
        exit(ok ? 0 : 1)
    }
}

enum FeltSimSelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        if !ok { failures += 1 }
    }

    static func makeSim() -> FeltSim {
        FeltSim(FeltSim.Config(width: 1366, height: 1024, cardWidth: 140))
    }

    static func runUntilAsleep(_ sim: FeltSim, limit: Double = 5) -> Double {
        var t = 0.0
        while sim.isActive && t < limit { sim.advance(by: 1.0 / 120); t += 1.0 / 120 }
        return t
    }

    @discardableResult
    static func run() -> Bool {
        failures = 0
        let size = CGSize(width: 1366, height: 1024)

        // 1. Flick parity with the legacy FeltPhysics.toss solver.
        var worst = 0.0
        var worstStop = 0.0
        let seats: [CGPoint?] = [nil, CGPoint(x: 0.5, y: 0.06), CGPoint(x: 0.07, y: 0.5), CGPoint(x: 0.93, y: 0.5)]
        var n = 0
        for (si, seat) in seats.enumerated() {
            for vy in [600.0, 1500, 3000, 4800] {
                let id = "c\(si)-\(Int(vy))"
                let toss = FeltPhysics.toss(cardID: id, seatAnchor: seat,
                                            throwVelocity: CGSize(width: 0, height: vy), tableSize: size)
                let from = FeltVec(x: Double(toss.entry.x * size.width), y: Double(toss.entry.y * size.height))
                let to = FeltVec(x: Double(toss.rest.x * size.width), y: Double(toss.rest.y * size.height))
                let sim = makeSim()
                sim.toss(id: id, from: from, to: to, duration: toss.duration,
                         angleFromDegrees: toss.restRotation - toss.spin, angleToDegrees: toss.restRotation)
                let t = runUntilAsleep(sim)
                let b = sim.body(id)!
                let expected = (to - from).length
                let got = (b.p - from).length
                worst = max(worst, abs(got - expected) / expected)
                worstStop = max(worstStop, abs(b.p.x - to.x) + abs(b.p.y - to.y))
                _ = t
                n += 1
            }
        }
        check("flick distance parity vs FeltPhysics.toss (\(n) tosses)", worst < 0.02,
              String(format: "worst error %.4f%%, worst rest offset %.3f pt", worst * 100, worstStop))

        // Mid-flight shape: quad ease-out says 75% of distance at half time.
        do {
            let sim = makeSim()
            sim.toss(id: "m", from: FeltVec(x: 300, y: 500), to: FeltVec(x: 700, y: 500), duration: 0.5,
                     angleFromDegrees: 0, angleToDegrees: 0)
            var t = 0.0
            while t < 0.25 - 1e-9 { sim.advance(by: 1.0 / 240); t += 1.0 / 240 }
            let frac = (sim.body("m")!.p.x - 300) / 400
            check("slide profile matches quad ease-out (75% at half time)", abs(frac - 0.75) < 0.01,
                  String(format: "%.4f", frac))
        }

        // Legacy release glide: identical distance mapping.
        do {
            let sim = makeSim()
            let v = CGSize(width: 900, height: -300)
            let vMag = hypot(v.width, v.height)
            let glide = min(0.22, vMag / 9000.0)
            let dist = FeltVec(x: Double(v.width * glide), y: Double(v.height * glide))
            let dur = 0.25 + Double(glide) * 1.3
            sim.land(id: "g", at: FeltVec(x: 500, y: 500), angleDegrees: 0,
                     glide: FeltSim.Glide(distance: dist, duration: dur))
            _ = runUntilAsleep(sim)
            let moved = sim.body("g")!.p - FeltVec(x: 500, y: 500)
            check("drag-release glide distance parity", abs(moved.length - dist.length) / dist.length < 0.02,
                  String(format: "%.3f vs %.3f pt", moved.length, dist.length))
        }

        // 2. Collision conservation sanity (frictionless felt).
        do {
            let sim = makeSim()
            sim.land(id: "A", at: FeltVec(x: 500, y: 500), angleDegrees: 0)
            sim.land(id: "B", at: FeltVec(x: 760, y: 515), angleDegrees: 0)
            if let a = sim.slot(for: "A"), let b = sim.slot(for: "B") {
                setFree(sim, a, v: FeltVec(x: 900, y: 0))
                setFree(sim, b, v: FeltVec(x: -300, y: 0))
            }
            let p0 = momentum(sim)
            let e0 = energy(sim)
            for _ in 0..<60 { sim.stepOnce(1.0 / 240) } // before anything reaches a rail
            let p1 = momentum(sim)
            let e1 = energy(sim)
            check("collision conserves linear momentum", abs(p1.x - p0.x) < 1e-6 && abs(p1.y - p0.y) < 1e-6,
                  String(format: "dp = (%.2e, %.2e)", p1.x - p0.x, p1.y - p0.y))
            check("collision never creates energy", e1 <= e0 + 1e-6, String(format: "%.0f -> %.0f", e0, e1))
            check("off-center hit spins the target", abs(sim.body("B")!.w) > 0.01 || abs(sim.body("A")!.w) > 0.01,
                  String(format: "wA=%.3f wB=%.3f", sim.body("A")!.w, sim.body("B")!.w))
        }

        // Nudge: a sliding card shoves a resting one and turns it.
        do {
            let sim = makeSim()
            sim.land(id: "rest", at: FeltVec(x: 700, y: 512), angleDegrees: 0)
            _ = runUntilAsleep(sim)
            sim.toss(id: "slider", from: FeltVec(x: 400, y: 540), to: FeltVec(x: 760, y: 540), duration: 0.5,
                     angleFromDegrees: 0, angleToDegrees: 0)
            _ = runUntilAsleep(sim)
            let r = sim.body("rest")!
            check("sliding card nudges and rotates a resting card",
                  r.p.x > 705 && abs(r.angle) > 0.005,
                  String(format: "rest moved %.1f pt, rotated %.2f deg", r.p.x - 700, r.angle * 180 / .pi))
        }

        // 3. Rail rebound.
        do {
            let sim = makeSim()
            sim.land(id: "w", at: FeltVec(x: 1100, y: 512), angleDegrees: 0)
            setFree(sim, sim.slot(for: "w")!, v: FeltVec(x: 800, y: 0))
            var maxVxAfter = 0.0
            var minX = 1e9, maxX = 0.0
            var bounced = false
            for _ in 0..<720 {
                sim.stepOnce(1.0 / 240)
                let b = sim.body("w")!
                if b.v.x < 0 && !bounced { bounced = true; maxVxAfter = -b.v.x }
                maxX = max(maxX, b.p.x + 70); minX = min(minX, b.p.x)
            }
            let ratio = maxVxAfter / 800
            check("rail rebound damped (~0.25)", bounced && ratio > 0.18 && ratio < 0.32,
                  String(format: "rebound ratio %.3f", ratio))
            check("card never passes the rail", maxX <= 1366 - 18 + 4.5, String(format: "max right edge %.1f", maxX))
        }
        do {
            let sim = makeSim()
            sim.land(id: "s", at: FeltVec(x: 1000, y: 500), angleDegrees: 20)
            setFree(sim, sim.slot(for: "s")!, v: FeltVec(x: 700, y: 900), w: 8)
            var inside = true
            for _ in 0..<1200 {
                sim.stepOnce(1.0 / 240)
                let b = sim.body("s")!
                if b.p.x < 0 || b.p.x > 1366 || b.p.y < 0 || b.p.y > 1024 { inside = false }
            }
            check("corner deflection keeps the card on the felt", inside)
            let w0 = 8.0
            check("spin is shed against the rail", abs(sim.body("s")!.w) < w0)
        }

        // 4. Stack rule.
        do {
            let sim = makeSim()
            let l0 = sim.land(id: "base", at: FeltVec(x: 600, y: 500), angleDegrees: 0)
            let l1 = sim.land(id: "top", at: FeltVec(x: 625, y: 510), angleDegrees: 5)
            let l2 = sim.land(id: "third", at: FeltVec(x: 590, y: 495), angleDegrees: -4)
            sim.land(id: "b2", at: FeltVec(x: 1000, y: 500), angleDegrees: 0)
            let lg = sim.land(id: "glance", at: FeltVec(x: 1000 + 140 - 6, y: 500), angleDegrees: 0)
            check("dropped card rides on top (levels 0,1,2)", l0 == 0 && l1 == 1 && l2 == 2, "\(l0),\(l1),\(l2)")
            _ = runUntilAsleep(sim)
            let gap = sim.body("glance")!.p.x - sim.body("b2")!.p.x
            check("glancing landing stays at felt level and is pushed apart", lg == 0 && gap > 138,
                  String(format: "level %d, center gap %.1f", lg, gap))
            let topBefore = sim.body("top")!.p
            let baseBefore = sim.body("base")!.p
            sim.toss(id: "m", from: FeltVec(x: 300, y: 500), to: FeltVec(x: 520, y: 500), duration: 0.4,
                     angleFromDegrees: 0, angleToDegrees: 0)
            _ = runUntilAsleep(sim)
            let baseAfter = sim.body("base")!.p, topAfter = sim.body("top")!.p
            check("felt-level slider pushes the bottom card", baseAfter.x - baseBefore.x > 5,
                  String(format: "moved %.1f", baseAfter.x - baseBefore.x))
            check("riding cards are carried, not collided with",
                  topAfter.x - topBefore.x > 2 && sim.body("top")!.level >= 1,
                  String(format: "top moved %.1f, level %d", topAfter.x - topBefore.x, sim.body("top")!.level))
        }

        // 5. Determinism.
        func scenario() -> UInt64 {
            let sim = makeSim()
            for i in 0..<8 {
                let a = Double(i) / 8 * 2 * .pi
                let from = FeltVec(x: 683 + cos(a) * 760, y: 512 + sin(a) * 600)
                sim.toss(id: "d\(i)", from: from, to: FeltVec(x: 683 + cos(a + 0.4) * 40, y: 512 + sin(a + 0.4) * 40),
                         duration: 0.5, angleFromDegrees: Double(i) * 10, angleToDegrees: 0)
            }
            _ = runUntilAsleep(sim, limit: 6)
            var h: UInt64 = 1469598103934665603
            for i in 0..<8 {
                let b = sim.body("d\(i)")!
                for d in [b.p.x, b.p.y, b.angle] { h = (h ^ d.bitPattern) &* 1099511628211 }
            }
            return h
        }
        check("deterministic (two identical runs agree bit for bit)", scenario() == scenario())

        // 6. Cost: 40 cards, 8 flung at once, per 1/120 s frame.
        do {
            let sim = makeSim()
            for i in 0..<40 {
                sim.land(id: "p\(i)", at: FeltVec(x: 150 + Double(i % 10) * 105, y: 200 + Double(i / 10) * 190),
                         angleDegrees: Double(i * 7 % 30))
            }
            for i in 0..<40 {
                let a = Double(i) * 0.9
                setFree(sim, sim.slot(for: "p\(i)")!, v: FeltVec(x: cos(a) * 1200, y: sin(a) * 1200), w: 5)
            }
            let t0 = Date()
            var frames = 0
            while sim.isActive && frames < 600 { sim.advance(by: 1.0 / 120); frames += 1 }
            let per = Date().timeIntervalSince(t0) / Double(max(frames, 1)) * 1000
            check("40 cards under 1 ms per 120 Hz frame on this Mac", per < 1.0,
                  String(format: "%.3f ms/frame avg over %d frames", per, frames))
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    // Test helpers: poke a body (frictionless) through the public arrays.
    static func setFree(_ sim: FeltSim, _ s: Int, v: FeltVec, w: Double = 0) {
        sim.debugSet(s, v: v, w: w, decel: 0, spinDecel: 0)
    }
    static func momentum(_ sim: FeltSim) -> FeltVec {
        var m = FeltVec.zero
        for b in sim.bodies where b.alive { m = m + b.v }
        return m
    }
    static func energy(_ sim: FeltSim) -> Double {
        var e = 0.0
        for b in sim.bodies where b.alive { e += 0.5 * b.v.dot(b.v) }
        return e
    }
}
#endif
