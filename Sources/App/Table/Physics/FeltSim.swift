import Foundation

// FeltSim: cards lying on felt as small rigid bodies.
//
// PURE core: Foundation only, no SwiftUI, no clocks, no randomness. Same
// inputs -> same outputs, bit for bit (fixed 1/240 s substeps), which is
// what lets FeltSimSelfTest run headless under plain `swiftc`.
//
// Design in one paragraph. Every loose card is a body (position, angle,
// velocity, spin) with a rectangle collider. Felt friction is CONSTANT
// deceleration, integrated exactly: that is the physics FeltPhysics already
// documents (p = p0 + v0 t - 1/2 a t^2, the quad ease-out), so a toss
// solved as "travel d in T seconds" (v0 = 2d/T, a = 2d/T^2) stops at
// exactly d at exactly T when nothing is in its way. Cards only collide
// with cards on the SAME LEVEL. A card that lands (drop, drag release,
// deck flip) on top of what it overlaps takes level = 1 + highest level
// beneath and rides there; a card that slides in along the felt stays at
// level 0 and shoves what it meets from the side. A riding card loses its
// level the moment it is no longer supported (it slid off), and is carried
// along when its support is pushed.

struct FeltVec: Equatable {
    var x: Double
    var y: Double
    static let zero = FeltVec(x: 0, y: 0)
    @inline(__always) init(x: Double, y: Double) { self.x = x; self.y = y }
    @inline(__always) static func + (a: FeltVec, b: FeltVec) -> FeltVec { FeltVec(x: a.x + b.x, y: a.y + b.y) }
    @inline(__always) static func - (a: FeltVec, b: FeltVec) -> FeltVec { FeltVec(x: a.x - b.x, y: a.y - b.y) }
    @inline(__always) static func * (a: FeltVec, s: Double) -> FeltVec { FeltVec(x: a.x * s, y: a.y * s) }
    @inline(__always) func dot(_ b: FeltVec) -> Double { x * b.x + y * b.y }
    /// 2D cross product (z component).
    @inline(__always) func cross(_ b: FeltVec) -> Double { x * b.y - y * b.x }
    @inline(__always) var length: Double { (x * x + y * y).squareRoot() }
}

/// One card. Plain-old-data on purpose (the id strings live in a parallel
/// array) so copying a body never touches reference counts.
struct FeltBody {
    var alive = false
    var p = FeltVec.zero
    var v = FeltVec.zero
    var angle = 0.0          // radians
    var w = 0.0              // rad/s
    var decel = 0.0          // sliding friction, pt/s^2
    var spinDecel = 0.0      // rad/s^2
    var level = 0            // 0 = on the felt; k = lying on k cards
    var seq = 0              // landing order (older cards are "beneath")
    var held = false         // under a finger: kinematic, collides with nothing
    var awake = false
    var entered = true       // false while a toss is still coming in over the rail
    var restTime = 0.0
    var grab = FeltVec.zero  // finger -> center offset while held
    var seed: UInt32 = 0     // per-card stable jitter for shocks
    var dirty = false        // pose changed since the last publish
}

final class FeltSim {
    struct Config {
        var width = 1366.0
        var height = 1024.0
        var cardWidth = 140.0
        var cardAspect = 2.5 / 3.5
        /// The rail: a rounded rectangle inset from the table edge.
        var wallInset = 18.0
        var wallRadius = 30.0
        var railRestitution = 0.25
        var railSpinKeep = 0.55
        var railFriction = 0.25
        var cardRestitution = 0.30
        var cardFriction = 0.35
        /// Felt deceleration for cards that were never given their own
        /// (a card that was hit while resting).
        var baseDecel = 3200.0
        var baseSpinDecel = 30.0
        /// Overlap (fraction of card width) at which a landing card rides on
        /// top rather than shoving; the lower threshold keeps it supported.
        var rideDepth = 0.12
        var supportDepth = 0.04
        var carryRate = 14.0
        var step = 1.0 / 240.0
        var maxWallCorrection = 4.0
        var maxPairCorrection = 3.0
    }

    /// A slide the felt will bring to rest: travel `distance` in `duration`.
    struct Glide {
        var distance: FeltVec
        var duration: Double
        /// Degrees turned during the slide (spin damps on the same curve).
        var spinDegrees = 0.0
    }

    private(set) var config: Config
    private(set) var bodies: [FeltBody] = []
    private(set) var ids: [String] = []
    private var slotByID: [String: Int] = [:]
    private var freeSlots: [Int] = []
    private var accumulator = 0.0
    private var landingCounter = 0
    private(set) var stepCount = 0

    private var halfW = 0.0, halfH = 0.0, invI = 0.0
    private var cell = 1.0
    private var cols = 1, rows = 1
    private var cellHead: [Int32] = []
    private var nextInCell: [Int32] = []

    init(_ config: Config = Config()) {
        self.config = config
        bodies.reserveCapacity(64)
        ids.reserveCapacity(64)
        derive()
    }

    func reconfigure(_ config: Config) {
        self.config = config
        derive()
    }

    private func derive() {
        halfW = config.cardWidth / 2
        halfH = config.cardWidth / config.cardAspect / 2
        let m = 1.0
        invI = 12.0 / (m * (4 * halfW * halfW + 4 * halfH * halfH))
        cell = (4 * halfW * halfW + 4 * halfH * halfH).squareRoot() + 1
        cols = max(1, Int((config.width / cell).rounded(.up)))
        rows = max(1, Int((config.height / cell).rounded(.up)))
        cellHead = [Int32](repeating: -1, count: cols * rows)
    }

    var cardHeight: Double { halfH * 2 }

    // MARK: lookup

    func slot(for id: String) -> Int? { slotByID[id] }
    func contains(_ id: String) -> Bool { slotByID[id] != nil }
    var aliveCount: Int { slotByID.count }
    var slotCount: Int { bodies.count }

    /// True while anything needs stepping (a held card needs no stepping).
    var isActive: Bool {
        for b in bodies where b.alive && b.awake && !b.held { return true }
        return false
    }

    // MARK: lifecycle

    private func allocate(_ id: String) -> Int {
        if let s = slotByID[id] { return s }
        let s: Int
        if let free = freeSlots.popLast() {
            s = free
            ids[s] = id
        } else {
            s = bodies.count
            bodies.append(FeltBody())
            ids.append(id)
            nextInCell.append(-1)
        }
        var b = FeltBody()
        b.alive = true
        b.decel = config.baseDecel
        b.spinDecel = config.baseSpinDecel
        var h: UInt32 = 2166136261
        for byte in id.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        b.seed = h
        bodies[s] = b
        slotByID[id] = s
        return s
    }

    func remove(_ id: String) {
        guard let s = slotByID.removeValue(forKey: id) else { return }
        bodies[s].alive = false
        bodies[s].awake = false
        freeSlots.append(s)
    }

    func retain(only keep: Set<String>) {
        for id in Array(slotByID.keys) where !keep.contains(id) { remove(id) }
    }

    func reset() {
        for id in Array(slotByID.keys) { remove(id) }
        accumulator = 0
    }

    // MARK: spawning

    /// A card sliding in along the felt (the thrown-card path). Starts at
    /// level 0, may begin outside the rail, and collides with whatever it
    /// meets. With nothing in the way it travels exactly `to - from` and
    /// stops exactly at `duration`.
    func toss(id: String, from: FeltVec, to: FeltVec, duration: Double,
              angleFromDegrees: Double, angleToDegrees: Double) {
        let s = allocate(id)
        landingCounter += 1
        bodies[s].seq = landingCounter
        bodies[s].level = 0
        bodies[s].p = from
        bodies[s].angle = angleFromDegrees * .pi / 180
        bodies[s].held = false
        bodies[s].entered = insideWall(s)
        applyGlide(s, Glide(distance: to - from, duration: duration,
                            spinDegrees: angleToDegrees - angleFromDegrees))
        bodies[s].dirty = true
    }

    /// Put a card down on the felt. Rides on whatever it covers (stack
    /// rule), else lies at felt level. `glide` is an optional last skid.
    @discardableResult
    func land(id: String, at p: FeltVec, angleDegrees: Double, glide: Glide? = nil) -> Int {
        let s = allocate(id)
        bodies[s].held = false
        bodies[s].p = p
        bodies[s].angle = angleDegrees * .pi / 180
        bodies[s].v = .zero
        bodies[s].w = 0
        bodies[s].entered = true
        landingCounter += 1
        bodies[s].seq = landingCounter
        bodies[s].level = landingLevel(s)
        bodies[s].awake = true
        bodies[s].restTime = 0
        bodies[s].dirty = true
        if let g = glide { applyGlide(s, g) }
        return bodies[s].level
    }

    private func applyGlide(_ s: Int, _ g: Glide) {
        let T = max(0.001, g.duration)
        let d = g.distance.length
        bodies[s].v = g.distance * (2 / T)
        bodies[s].decel = d > 0.0001 ? 2 * d / (T * T) : config.baseDecel
        let spin = g.spinDegrees * .pi / 180
        bodies[s].w = 2 * spin / T
        bodies[s].spinDecel = abs(spin) > 0.00001 ? abs(2 * spin / T) / T : config.baseSpinDecel
        bodies[s].awake = true
        bodies[s].restTime = 0
    }

    /// Finger-driven: the first call lifts the card (captures the grab
    /// offset so it doesn't jump), later calls move it.
    func hold(id: String, finger: FeltVec) {
        guard let s = slotByID[id] else { return }
        if !bodies[s].held {
            bodies[s].held = true
            bodies[s].grab = bodies[s].p - finger
            bodies[s].v = .zero
            bodies[s].w = 0
        }
        bodies[s].p = finger + bodies[s].grab
        bodies[s].dirty = true
    }

    func isHeld(_ id: String) -> Bool {
        slotByID[id].map { bodies[$0].held } ?? false
    }

    /// Let go. With a glide the card keeps sliding; either way it lands by
    /// the stack rule where it is.
    func release(id: String, glide: Glide?) {
        guard let s = slotByID[id] else { return }
        land(id: id, at: bodies[s].p, angleDegrees: bodies[s].angle * 180 / .pi, glide: glide)
    }

    // MARK: table motion

    /// Gentle drift: every level-0 card gets a kick that would carry it
    /// `distance` points along `direction` (grip 0.5...1.5 per card).
    func nudge(direction: FeltVec, distance: Double) {
        for s in 0..<bodies.count where bodies[s].alive && !bodies[s].held && bodies[s].level == 0 {
            let grip = 0.5 + Double(bodies[s].seed % 1000) / 1000.0
            let speed = (2 * bodies[s].decel * distance * grip).squareRoot()
            bodies[s].v = bodies[s].v + direction * speed
            wake(s)
        }
    }

    /// A thump: kick every level-0 card, harder near the struck edge (the
    /// edge on `direction`'s side), with a per-card scatter and a little
    /// spin. `strength` is in pt/s at the struck edge.
    func shock(direction: FeltVec, strength: Double) {
        let len = max(0.0001, direction.length)
        let d = direction * (1 / len)
        let cx = config.width / 2, cy = config.height / 2
        for s in 0..<bodies.count where bodies[s].alive && !bodies[s].held && bodies[s].level == 0 {
            let rel = FeltVec(x: (bodies[s].p.x - cx) / cx, y: (bodies[s].p.y - cy) / cy)
            let proj = max(-1, min(1, rel.dot(d)))
            let weight = 0.35 + 0.65 * max(0, proj)
            let a = Double(bodies[s].seed & 0xFFFF) / 65535.0 * 2 * .pi
            let jitter = FeltVec(x: cos(a), y: sin(a))
            bodies[s].v = bodies[s].v + (d + jitter * 0.6) * (strength * weight)
            bodies[s].w += (Double((bodies[s].seed >> 16) & 0xFF) / 255.0 - 0.5) * 0.004 * strength * weight
            wake(s)
        }
    }

    private func wake(_ s: Int) {
        bodies[s].awake = true
        bodies[s].restTime = 0
    }

    // MARK: stepping

    /// Advance by wall time; internally fixed substeps (deterministic).
    func advance(by dt: Double) {
        accumulator += min(dt, 0.1)
        var guardCount = 0
        while accumulator >= config.step && guardCount < 40 {
            stepOnce(config.step)
            accumulator -= config.step
            guardCount += 1
        }
        if guardCount == 40 { accumulator = 0 }
    }

    func stepOnce(_ dt: Double) {
        stepCount += 1
        integrate(dt)
        buildGrid()
        for _ in 0..<2 {
            collideWalls()
            collidePairs()
        }
        collideWalls()
        updateSupports(dt)
        updateSleep(dt)
    }

    private func integrate(_ dt: Double) {
        for s in 0..<bodies.count {
            guard bodies[s].alive, bodies[s].awake, !bodies[s].held else { continue }
            var b = bodies[s]
            let speed = b.v.length
            if speed > 0 {
                let dir = b.v * (1 / speed)
                if speed <= b.decel * dt {
                    b.p = b.p + dir * (speed * speed / (2 * b.decel))
                    b.v = .zero
                } else {
                    b.p = b.p + dir * (speed * dt - 0.5 * b.decel * dt * dt)
                    b.v = dir * (speed - b.decel * dt)
                }
            }
            let aw = abs(b.w)
            if aw > 0 {
                let sign: Double = b.w > 0 ? 1 : -1
                if aw <= b.spinDecel * dt {
                    b.angle += sign * aw * aw / (2 * b.spinDecel)
                    b.w = 0
                } else {
                    b.angle += sign * (aw * dt - 0.5 * b.spinDecel * dt * dt)
                    b.w = sign * (aw - b.spinDecel * dt)
                }
            }
            if speed > 0 || aw > 0 { b.dirty = true }
            bodies[s] = b
        }
    }

    private func buildGrid() {
        for i in 0..<cellHead.count { cellHead[i] = -1 }
        for s in 0..<bodies.count where bodies[s].alive && !bodies[s].held {
            let c = cellIndex(bodies[s].p)
            nextInCell[s] = cellHead[c]
            cellHead[c] = Int32(s)
        }
    }

    @inline(__always) private func cellCoords(_ p: FeltVec) -> (Int, Int) {
        (min(cols - 1, max(0, Int(p.x / cell))), min(rows - 1, max(0, Int(p.y / cell))))
    }
    @inline(__always) private func cellIndex(_ p: FeltVec) -> Int {
        let (cx, cy) = cellCoords(p)
        return cy * cols + cx
    }

    // MARK: walls (the rail)

    private var wallCX: Double { config.width / 2 }
    private var wallCY: Double { config.height / 2 }
    private var wallBX: Double { config.width / 2 - config.wallInset }
    private var wallBY: Double { config.height / 2 - config.wallInset }

    /// Signed distance to the rail (positive = outside) and the OUTWARD
    /// gradient there.
    @inline(__always)
    private func wallSD(_ q: FeltVec) -> (Double, FeltVec) {
        let r = config.wallRadius
        let dx = q.x - wallCX, dy = q.y - wallCY
        let ax = abs(dx), ay = abs(dy)
        let sx: Double = dx < 0 ? -1 : 1, sy: Double = dy < 0 ? -1 : 1
        let qx = ax - (wallBX - r), qy = ay - (wallBY - r)
        if qx > 0 && qy > 0 {
            let l = max(0.0001, (qx * qx + qy * qy).squareRoot())
            return (l - r, FeltVec(x: sx * qx / l, y: sy * qy / l))
        }
        if qx > qy { return (qx - r, FeltVec(x: sx, y: 0)) }
        return (qy - r, FeltVec(x: 0, y: sy))
    }

    @inline(__always)
    private func corner(_ b: FeltBody, _ k: Int) -> FeltVec {
        let ca = cos(b.angle), sa = sin(b.angle)
        let lx = (k & 1) == 0 ? -halfW : halfW
        let ly = (k & 2) == 0 ? -halfH : halfH
        return FeltVec(x: b.p.x + lx * ca - ly * sa, y: b.p.y + lx * sa + ly * ca)
    }

    private func insideWall(_ s: Int) -> Bool {
        for k in 0..<4 where wallSD(corner(bodies[s], k)).0 > 0 { return false }
        return true
    }

    private func collideWalls() {
        for s in 0..<bodies.count {
            guard bodies[s].alive, !bodies[s].held else { continue }
            if !bodies[s].entered {
                if insideWall(s) { bodies[s].entered = true } else { continue }
            }
            var depth = 0.0
            var count = 0.0
            var cp = FeltVec.zero
            var n = FeltVec.zero
            for k in 0..<4 {
                let c = corner(bodies[s], k)
                let (sd, grad) = wallSD(c)
                if sd > 0 {
                    depth = max(depth, sd)
                    cp = cp + c
                    n = n - grad
                    count += 1
                }
            }
            guard count > 0 else { continue }
            cp = cp * (1 / count)
            let nl = max(0.0001, n.length)
            n = n * (1 / nl)
            // Positional: slide back in, rate-limited so a card dropped
            // half over the rail glides in instead of teleporting.
            bodies[s].p = bodies[s].p + n * min(depth, config.maxWallCorrection)
            // Velocity: reflect with damped restitution, shed spin.
            let r = cp - bodies[s].p
            let vc = bodies[s].v + FeltVec(x: -bodies[s].w * r.y, y: bodies[s].w * r.x)
            let vn = vc.dot(n)
            if vn < 0 {
                let e = -vn > 40 ? config.railRestitution : 0
                let rn = r.cross(n)
                let jn = -(1 + e) * vn / (1 + rn * rn * invI)
                bodies[s].v = bodies[s].v + n * jn
                bodies[s].w += rn * jn * invI
                // Tangential friction against the wall.
                let t = FeltVec(x: -n.y, y: n.x)
                let vt = vc.dot(t)
                let rt = r.cross(t)
                var jt = -vt / (1 + rt * rt * invI)
                let cap = config.railFriction * jn
                jt = max(-cap, min(cap, jt))
                bodies[s].v = bodies[s].v + t * jt
                bodies[s].w += rt * jt * invI
                if -vn > 50 { bodies[s].w *= config.railSpinKeep }
                bodies[s].awake = true
                bodies[s].restTime = 0
            }
            bodies[s].dirty = true
        }
    }

    // MARK: card-card

    /// SAT overlap of two cards. Returns false if separated; otherwise the
    /// minimum-translation axis (pointing a -> b) and depth.
    private func sat(_ a: Int, _ b: Int, normal: inout FeltVec, depth: inout Double) -> Bool {
        let A = bodies[a], B = bodies[b]
        let ca = cos(A.angle), sa = sin(A.angle), cb = cos(B.angle), sb = sin(B.angle)
        let au = FeltVec(x: ca, y: sa), av = FeltVec(x: -sa, y: ca)
        let bu = FeltVec(x: cb, y: sb), bv = FeltVec(x: -sb, y: cb)
        let d = B.p - A.p
        var best = Double.greatestFiniteMagnitude
        var bestAxis = au
        for k in 0..<4 {
            let L: FeltVec = k == 0 ? au : (k == 1 ? av : (k == 2 ? bu : bv))
            let ra = halfW * abs(L.dot(au)) + halfH * abs(L.dot(av))
            let rb = halfW * abs(L.dot(bu)) + halfH * abs(L.dot(bv))
            let dist = L.dot(d)
            let overlap = ra + rb - abs(dist)
            if overlap <= 0 { return false }
            if overlap < best {
                best = overlap
                bestAxis = dist < 0 ? L * -1 : L
            }
        }
        normal = bestAxis
        depth = best
        return true
    }

    private func pointInside(_ q: FeltVec, _ s: Int) -> Bool {
        let b = bodies[s]
        let ca = cos(b.angle), sa = sin(b.angle)
        let r = q - b.p
        let lx = r.x * ca + r.y * sa
        let ly = -r.x * sa + r.y * ca
        return abs(lx) <= halfW + 0.5 && abs(ly) <= halfH + 0.5
    }

    /// Contact point: average of the corners of each card that sit inside
    /// the other (off-center hits therefore produce torque).
    private func contactPoint(_ a: Int, _ b: Int) -> FeltVec {
        var sum = FeltVec.zero
        var n = 0.0
        for k in 0..<4 {
            let ca = corner(bodies[a], k)
            if pointInside(ca, b) { sum = sum + ca; n += 1 }
            let cb = corner(bodies[b], k)
            if pointInside(cb, a) { sum = sum + cb; n += 1 }
        }
        if n == 0 { return (bodies[a].p + bodies[b].p) * 0.5 }
        return sum * (1 / n)
    }

    private func collidePairs() {
        for a in 0..<bodies.count {
            guard bodies[a].alive, !bodies[a].held else { continue }
            let (cx, cy) = cellCoords(bodies[a].p)
            for ny in max(0, cy - 1)...min(rows - 1, cy + 1) {
                for nx in max(0, cx - 1)...min(cols - 1, cx + 1) {
                    var j = cellHead[ny * cols + nx]
                    while j >= 0 {
                        let b = Int(j)
                        j = nextInCell[b]
                        if b <= a { continue }
                        if bodies[a].level != bodies[b].level { continue }
                        if !bodies[a].awake && !bodies[b].awake { continue }
                        resolve(a, b)
                    }
                }
            }
        }
    }

    private func resolve(_ a: Int, _ b: Int) {
        var n = FeltVec.zero
        var depth = 0.0
        guard sat(a, b, normal: &n, depth: &depth) else { return }
        let c = contactPoint(a, b)
        let ra = c - bodies[a].p, rb = c - bodies[b].p
        let va = bodies[a].v + FeltVec(x: -bodies[a].w * ra.y, y: bodies[a].w * ra.x)
        let vb = bodies[b].v + FeltVec(x: -bodies[b].w * rb.y, y: bodies[b].w * rb.x)
        let rv = vb - va
        let vn = rv.dot(n)
        if vn < 0 {
            let e = -vn > 40 ? config.cardRestitution : 0
            let ran = ra.cross(n), rbn = rb.cross(n)
            let denom = 2 + ran * ran * invI + rbn * rbn * invI
            let jn = -(1 + e) * vn / denom
            bodies[a].v = bodies[a].v - n * jn
            bodies[b].v = bodies[b].v + n * jn
            bodies[a].w -= ran * jn * invI
            bodies[b].w += rbn * jn * invI
            // Coulomb friction between the card stocks.
            let t = FeltVec(x: -n.y, y: n.x)
            let vt = rv.dot(t)
            let rat = ra.cross(t), rbt = rb.cross(t)
            let denomT = 2 + rat * rat * invI + rbt * rbt * invI
            var jt = -vt / denomT
            let cap = config.cardFriction * jn
            jt = max(-cap, min(cap, jt))
            bodies[a].v = bodies[a].v - t * jt
            bodies[b].v = bodies[b].v + t * jt
            bodies[a].w -= rat * jt * invI
            bodies[b].w += rbt * jt * invI
        }
        // Positional correction, split evenly, rate-limited.
        let slop = 0.5
        let corr = min(max(depth - slop, 0) * 0.6, config.maxPairCorrection)
        if corr > 0 {
            bodies[a].p = bodies[a].p - n * (corr * 0.5)
            bodies[b].p = bodies[b].p + n * (corr * 0.5)
        }
        wake(a); wake(b)
        bodies[a].dirty = true; bodies[b].dirty = true
    }

    // MARK: stack rule

    /// Level a card would take if set down where it is: on top of anything
    /// it covers by more than `rideDepth`.
    private func landingLevel(_ s: Int) -> Int {
        var level = 0
        var n = FeltVec.zero
        var depth = 0.0
        for o in 0..<bodies.count where o != s && bodies[o].alive && !bodies[o].held {
            if sat(s, o, normal: &n, depth: &depth), depth > config.rideDepth * config.cardWidth {
                level = max(level, bodies[o].level + 1)
            }
        }
        return level
    }

    /// Riding cards: find the support beneath; no support -> drop to the
    /// level below; support moving -> get carried with it.
    private func updateSupports(_ dt: Double) {
        let minDepth = config.supportDepth * config.cardWidth
        for s in 0..<bodies.count where bodies[s].alive && !bodies[s].held && bodies[s].level > 0 {
            var newLevel = 0
            var bestDepth = 0.0
            var support = -1
            var n = FeltVec.zero
            var depth = 0.0
            for o in 0..<bodies.count where o != s && bodies[o].alive && !bodies[o].held
                && bodies[o].seq < bodies[s].seq && bodies[o].level < bodies[s].level {
                if sat(s, o, normal: &n, depth: &depth), depth > minDepth {
                    newLevel = max(newLevel, bodies[o].level + 1)
                    if depth > bestDepth { bestDepth = depth; support = o }
                }
            }
            if newLevel != bodies[s].level {
                bodies[s].level = newLevel
                bodies[s].dirty = true
                wake(s)
            }
            if support >= 0 {
                let sv = bodies[support].v
                let dv = sv - bodies[s].v
                if sv.length > 3 || dv.length > 3 {
                    let k = min(1, config.carryRate * dt)
                    bodies[s].v = bodies[s].v + dv * k
                    wake(s)
                }
            }
        }
    }

    private func updateSleep(_ dt: Double) {
        for s in 0..<bodies.count where bodies[s].alive && bodies[s].awake && !bodies[s].held {
            if bodies[s].v.length < 3 && abs(bodies[s].w) < 0.02 {
                bodies[s].restTime += dt
                if bodies[s].restTime > 0.15 {
                    bodies[s].awake = false
                    bodies[s].v = .zero
                    bodies[s].w = 0
                    bodies[s].dirty = true
                }
            } else {
                bodies[s].restTime = 0
            }
        }
    }

    // MARK: publish

    /// Visit every body whose pose changed since the last publish.
    func publishDirty(_ visit: (_ slot: Int, _ id: String, _ body: FeltBody) -> Void) {
        for s in 0..<bodies.count where bodies[s].alive && bodies[s].dirty {
            bodies[s].dirty = false
            visit(s, ids[s], bodies[s])
        }
    }

    /// Test hook: set a body's motion directly.
    func debugSet(_ s: Int, v: FeltVec, w: Double, decel: Double, spinDecel: Double) {
        bodies[s].v = v; bodies[s].w = w
        bodies[s].decel = decel; bodies[s].spinDecel = spinDecel
        bodies[s].awake = true; bodies[s].restTime = 0
    }

    func body(_ id: String) -> FeltBody? { slotByID[id].map { bodies[$0] } }

    /// Sort key for painting: higher level paints later; landing order
    /// breaks ties.
    static func zOrder(level: Int, seq: Int) -> Double {
        Double(level) + Double(seq % 1000) / 1100.0
    }
}
