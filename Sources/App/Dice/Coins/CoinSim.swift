import Foundation
import simd

/// CoinSim: the shared 2D coin physics for LCR's seat piles, the pot and
/// free play's toy coins. Pure value-type simulation: Foundation only, no
/// UIKit/SwiftUI, deterministic (a seeded xorshift RNG and a fixed 240 Hz
/// substep), so it compiles and self-tests headless:
///
///   swiftc -O -D COINSIM_SELFTEST -parse-as-library \
///     Sources/App/Dice/Coins/CoinSim.swift \
///     Sources/App/Dice/Coins/CoinSimSelfTest.swift -o /tmp/coinsim_selftest \
///     && /tmp/coinsim_selftest
///
/// The model (see `CoinWorld.swift`) steps it from a display link ONLY
/// while `needsStepping` is true, copies awake bodies into observable
/// nodes, and turns `events` into sound.
///
/// What it models:
/// - Felt friction (Coulomb + viscous) so a flick slides and stops.
/// - Coin-coin collisions: restitution ~0.6, equal-ish masses, tangential
///   friction that transfers spin; penetration is resolved to a "contact
///   radius" slightly smaller than the visual diameter so piles keep
///   their natural slight overlaps.
/// - Stacks: coins that rest overlapped (the deterministic pile look) are
///   "ghost" pairs that ignore each other until they genuinely separate,
///   so a pile never explodes at rest but topples when hit.
/// - Rail: damped rebound off the felt boundary.
/// - Edge-roll: a hard flick (above `edgeRollSpeed`) can tip a coin onto
///   its edge. It rolls a curving path whose lean grows as it slows, then
///   falls into a chirping wobble-settle (Euler's disk) and lies flat.
/// - Hops: dice impacts kick nearby coins radially and into a small hop.
/// - Tidy: after `tidyDelay` at rest, coins drift back to their home slot
///   (the existing deterministic cluster look). `tidyDelay == nil` leaves
///   coins where they landed (free play).
typealias CoinVec = SIMD2<Double>

struct CoinRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    /// xorshift64*; uniform in 0..<1.
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let v = state &* 2685821657736338717
        return Double(v >> 11) / Double(1 << 53)
    }
    mutating func signed() -> Double { next() * 2 - 1 }
}

struct CoinSimConfig {
    var restitution = 0.6
    var railRestitution = 0.5
    var railTangentKeep = 0.9
    /// Felt: constant deceleration (pt/s^2) plus a viscous term (1/s).
    var coulomb = 900.0
    var viscous = 1.6
    var angularDamping = 2.6
    /// Tangential friction coefficient at a coin-coin contact (spin transfer).
    var contactFriction = 0.25
    /// Collision radius as a fraction of (r1 + r2). < 1 allows the slight
    /// overlaps a real pile has.
    var contactScale = 0.84
    var sleepSpeed = 14.0
    var maxSpeed = 1700.0
    /// Finger px/s -> sim pt/s. A finger overstates a coin's real speed.
    var releaseScale = 0.5
    /// Below this release speed the coin is simply set down.
    var minFlickSpeed = 60.0
    var edgeRollSpeed = 1050.0
    var edgeRollMinChance = 0.18
    var edgeRollMaxChance = 0.7
    /// Rolling speed as a fraction of the flat release speed.
    var edgeSpeedFactor = 0.55
    var allowEdgeRoll = true
    var hopGravity = 1500.0
    var allowHop = true
    var tidyDelay: Double? = 1.0
    var tidyStiffness = 55.0
    var tidyDamping = 13.0
    /// Felt rect (minX, minY, maxX, maxY); coins stay inside by radius.
    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? = nil
    var seed: UInt64 = 0xC0FFEE
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if reduceMotion {
                coulomb *= 2.4; allowEdgeRoll = false; allowHop = false
                if let t = tidyDelay { tidyDelay = t * 0.6 }
            } else {
                coulomb /= 2.4; allowEdgeRoll = true; allowHop = true
                if let t = tidyDelay { tidyDelay = t / 0.6 }
            }
        }
    }
}

enum CoinMode: Equatable {
    case flat       // lying on the felt (awake = sliding, else asleep)
    case held       // in a finger: kinematic, collides with nothing
    case edge       // rolling on its edge
    case falling    // wobble-settle after the roll
    case tidy       // drifting home
    case scripted   // owned by the UI (pay flight)
}

struct CoinEdgeState {
    var t = 0.0
    var duration = 1.6
    var speed0 = 600.0
    var moveDir = CoinVec(1, 0)
    var heading = 0.0
    var turnSign = 1.0
    var lean0 = 0.22
    var wobblePhase = 0.0
    var fallT = 0.0
    var fallSpeed = 0.0
    var tilt0 = 0.3
    static let fallDuration = 0.95
}

struct CoinBody {
    var id: Int
    var group: Int
    var radius: Double
    var pos: CoinVec
    var vel = CoinVec(0, 0)
    var angle = 0.0
    var angVel = 0.0
    var home: CoinVec
    var homeAngle = 0.0
    var mode: CoinMode = .flat
    var awake = false
    var restTime = 0.0
    var thrown = false
    /// Hop height (pt) and vertical speed; purely visual + landing sound.
    var z = 0.0
    var vz = 0.0
    /// Radians from lying flat (0) toward standing on edge (pi/2).
    var tilt = 0.0
    /// Direction the tilt axis points, radians (edge-roll / wobble).
    var heading = 0.0
    /// Visual-only wobble offset applied by the renderer.
    var wobble = CoinVec(0, 0)
    var edge = CoinEdgeState()
    var mass: Double { radius * radius / 625.0 }
    var invMass: Double { mode == .held ? 0 : 1 / mass }
    var momentOfInertia: Double { 0.5 * mass * radius * radius }
}

enum CoinEvent: Equatable {
    case clink(strength: Double, at: CoinVec)
    case rail(strength: Double, at: CoinVec)
    case land(strength: Double, at: CoinVec)
    case edgeStart(id: Int, speed: Double)
    case spinDown(id: Int, duration: Double)
    /// A coin the user released came to rest (flat, not moving).
    case rested(id: Int, at: CoinVec, thrown: Bool)
}

struct CoinSim {
    var config: CoinSimConfig
    private(set) var bodies: [CoinBody] = []
    private(set) var events: [CoinEvent] = []
    private var ghosts: Set<UInt64> = []
    private var rng: CoinRNG
    private var accumulator = 0.0
    private(set) var time = 0.0
    static let substep = 1.0 / 240.0

    init(config: CoinSimConfig = CoinSimConfig()) {
        self.config = config
        self.rng = CoinRNG(seed: config.seed)
    }

    // MARK: - Lookup / membership

    func index(of id: Int) -> Int? { bodies.firstIndex { $0.id == id } }
    func body(_ id: Int) -> CoinBody? { index(of: id).map { bodies[$0] } }

    mutating func drainEvents() -> [CoinEvent] {
        let out = events
        events.removeAll(keepingCapacity: true)
        return out
    }

    /// True while anything is moving OR a resting coin is waiting out its
    /// tidy delay: the display link must keep ticking.
    var needsStepping: Bool {
        for b in bodies {
            if b.awake || b.mode == .held { return true }
            if config.tidyDelay != nil, b.mode == .flat,
               simd_length(b.pos - b.home) > 0.75 { return true }
        }
        return false
    }

    var awakeCount: Int { bodies.reduce(0) { $0 + ($1.awake ? 1 : 0) } }

    mutating func addCoin(id: Int, group: Int, radius: Double, home: CoinVec,
                          homeAngle: Double = 0, position: CoinVec? = nil) {
        guard index(of: id) == nil else { return }
        var b = CoinBody(id: id, group: group, radius: radius,
                         pos: position ?? home, home: home)
        b.angle = homeAngle
        b.homeAngle = homeAngle
        bodies.append(b)
        // A new coin dropped onto a pile overlaps it by design.
        ghostOverlaps(of: bodies.count - 1)
    }

    mutating func removeCoin(id: Int) {
        guard let i = index(of: id) else { return }
        bodies.remove(at: i)
        ghosts = ghosts.filter { Self.pairInvolves($0, id: id) == false }
    }

    mutating func setHome(id: Int, home: CoinVec, homeAngle: Double) {
        guard let i = index(of: id) else { return }
        let old = bodies[i].home
        bodies[i].home = home
        bodies[i].homeAngle = homeAngle
        if !bodies[i].awake, bodies[i].mode == .flat, simd_length(bodies[i].pos - old) < 1.0 {
            bodies[i].pos = home
            bodies[i].angle = homeAngle
        }
    }

    mutating func place(id: Int, at point: CoinVec, angle: Double? = nil) {
        guard let i = index(of: id) else { return }
        bodies[i].pos = point
        bodies[i].vel = .zero
        bodies[i].angVel = 0
        bodies[i].mode = .flat
        bodies[i].awake = false
        bodies[i].restTime = 0
        bodies[i].z = 0; bodies[i].vz = 0; bodies[i].tilt = 0; bodies[i].wobble = .zero
        bodies[i].thrown = false
        if let angle { bodies[i].angle = angle }
        ghostOverlaps(of: i)
    }

    mutating func setScripted(id: Int, _ on: Bool) {
        guard let i = index(of: id) else { return }
        bodies[i].mode = on ? .scripted : .flat
        bodies[i].vel = .zero
        bodies[i].awake = false
        if on { bodies[i].thrown = false }
    }

    // MARK: - Finger interaction

    /// Pick a coin up. A held coin is lifted: kinematic and collides with
    /// nothing, so dragging through a pile never bulldozes it.
    mutating func grab(id: Int, at point: CoinVec) {
        guard let i = index(of: id) else { return }
        bodies[i].mode = .held
        bodies[i].awake = true
        bodies[i].vel = .zero
        bodies[i].angVel = 0
        bodies[i].tilt = 0; bodies[i].wobble = .zero
        bodies[i].z = 0; bodies[i].vz = 0
        bodies[i].thrown = false
        bodies[i].restTime = 0
        bodies[i].pos = clampToBounds(point, radius: bodies[i].radius)
    }

    mutating func drag(id: Int, to point: CoinVec, dt: Double) {
        guard let i = index(of: id), bodies[i].mode == .held else { return }
        let target = clampToBounds(point, radius: bodies[i].radius)
        let step = max(dt, 1.0 / 240.0)
        bodies[i].vel = (bodies[i].vel + (target - bodies[i].pos) / step) * 0.5
        bodies[i].pos = target
    }

    /// Let go with a finger velocity (px/s). Returns true when the coin
    /// tipped onto its edge.
    @discardableResult
    mutating func release(id: Int, velocity: CoinVec, forceEdgeRoll: Bool = false) -> Bool {
        guard let i = index(of: id) else { return false }
        bodies[i].mode = .flat
        bodies[i].thrown = true
        bodies[i].awake = true
        bodies[i].restTime = 0
        // Whatever it was dropped onto is a stack, not a collision.
        ghostOverlaps(of: i)
        var v = velocity * config.releaseScale
        let speed = simd_length(v)
        if speed < config.minFlickSpeed {
            bodies[i].vel = .zero
            return false
        }
        if speed > config.maxSpeed { v *= config.maxSpeed / speed }
        bodies[i].vel = v
        let s = simd_length(v)
        var tipped = false
        if config.allowEdgeRoll {
            let chance = Self.edgeRollChance(speed: s, config: config)
            let roll = rng.next()
            tipped = forceEdgeRoll || (chance > 0 && roll < chance)
        }
        if tipped { beginEdgeRoll(i, speed: s) }
        return tipped
    }

    /// Probability a release at `speed` (sim pt/s) tips onto its edge:
    /// zero below the threshold, rising to `edgeRollMaxChance` at top speed.
    static func edgeRollChance(speed: Double, config: CoinSimConfig) -> Double {
        guard config.allowEdgeRoll, speed >= config.edgeRollSpeed else { return 0 }
        let span = max(1, config.maxSpeed - config.edgeRollSpeed)
        let f = min(1, (speed - config.edgeRollSpeed) / span)
        return config.edgeRollMinChance + (config.edgeRollMaxChance - config.edgeRollMinChance) * f
    }

    // MARK: - Dice impact

    /// A dice settle/landing at `point` (same coordinate space as the
    /// coins), `strength` 0...1. Coins within the blast radius are kicked
    /// radially away and hop; stacked neighbours topple.
    mutating func impulse(at point: CoinVec, strength: Double, baseRadius: Double = 70) {
        let s = max(0, min(1, strength))
        guard s > 0.02 else { return }
        let blast = baseRadius + 150 * s
        var woken: [Int] = []
        for i in bodies.indices {
            let m = bodies[i].mode
            if m == .held || m == .scripted { continue }
            let d = bodies[i].pos - point
            let dist = simd_length(d)
            guard dist < blast + bodies[i].radius else { continue }
            let f = pow(max(0, 1 - dist / (blast + bodies[i].radius)), 1.5)
            guard f > 0.02 else { continue }
            let dir: CoinVec
            if dist > 0.5 { dir = d / dist } else {
                let a = rng.next() * 2 * Double.pi
                dir = CoinVec(cos(a), sin(a))
            }
            // Slight deterministic scatter so a pile doesn't fan out like a ruler.
            let jitter = rng.signed() * 0.35
            let c = cos(jitter), sn = sin(jitter)
            let rd = CoinVec(dir.x * c - dir.y * sn, dir.x * sn + dir.y * c)
            let kick = f * (260 + 900 * s)
            if bodies[i].mode == .edge || bodies[i].mode == .falling {
                bodies[i].mode = .flat; bodies[i].tilt = 0; bodies[i].wobble = .zero
            }
            bodies[i].vel += rd * kick
            let sp = simd_length(bodies[i].vel)
            if sp > config.maxSpeed { bodies[i].vel *= config.maxSpeed / sp }
            bodies[i].angVel += rng.signed() * 9 * f * (0.4 + s)
            if config.allowHop { bodies[i].vz = max(bodies[i].vz, (120 + 380 * s) * f) }
            bodies[i].awake = true
            bodies[i].restTime = 0
            woken.append(i)
        }
        for i in woken { ghostOverlaps(of: i) }
        if !woken.isEmpty {
            events.append(.clink(strength: min(1, 0.25 + s * 0.6), at: point))
        }
    }

    // MARK: - Stepping

    mutating func step(_ dt: Double) {
        accumulator += min(max(dt, 0), 0.05)
        var n = 0
        while accumulator >= Self.substep && n < 14 {
            substep(Self.substep)
            accumulator -= Self.substep
            n += 1
        }
        if n == 14 { accumulator = 0 }
    }

    private mutating func substep(_ h: Double) {
        time += h
        for i in bodies.indices { integrate(i, h) }
        resolveRails()
        resolvePairs()
    }

    private mutating func integrate(_ i: Int, _ h: Double) {
        switch bodies[i].mode {
        case .scripted:
            return
        case .held:
            bodies[i].vel *= exp(-14 * h)
            return
        case .edge:
            stepEdge(i, h)
        case .falling:
            stepFall(i, h)
        case .tidy:
            stepTidy(i, h)
        case .flat:
            if !bodies[i].awake {
                bodies[i].restTime += h
                if let delay = config.tidyDelay, bodies[i].restTime >= delay,
                   simd_length(bodies[i].pos - bodies[i].home) > 0.75 {
                    bodies[i].mode = .tidy
                    bodies[i].awake = true
                    bodies[i].thrown = false
                }
                return
            }
            stepFlat(i, h)
        }
    }

    private mutating func stepFlat(_ i: Int, _ h: Double) {
        // Hop (vertical): gravity, soft bounce, landing sound.
        if bodies[i].z > 0 || bodies[i].vz > 0 {
            bodies[i].z += bodies[i].vz * h
            bodies[i].vz -= config.hopGravity * h
            if bodies[i].z <= 0 {
                let impact = -bodies[i].vz
                bodies[i].z = 0
                if impact > 70 {
                    events.append(.land(strength: min(1, impact / 520), at: bodies[i].pos))
                    bodies[i].vz = impact * 0.28
                    if bodies[i].vz < 40 { bodies[i].vz = 0 }
                } else {
                    bodies[i].vz = 0
                }
            }
        }
        let airborne = bodies[i].z > 0
        var v = bodies[i].vel
        var speed = simd_length(v)
        if speed > 0 {
            let drop = (airborne ? 0.15 : 1.0) * config.coulomb * h
            let newSpeed = max(0, speed - drop) * exp(-config.viscous * (airborne ? 0.3 : 1.0) * h)
            v *= newSpeed / speed
            speed = newSpeed
        }
        bodies[i].vel = v
        bodies[i].pos += v * h
        bodies[i].angle += bodies[i].angVel * h
        bodies[i].angVel *= exp(-config.angularDamping * h)
        if speed < config.sleepSpeed, !airborne, bodies[i].vz == 0 {
            bodies[i].vel = .zero
            if abs(bodies[i].angVel) < 0.6 {
                bodies[i].angVel = 0
                bodies[i].awake = false
                bodies[i].restTime = 0
                events.append(.rested(id: bodies[i].id, at: bodies[i].pos, thrown: bodies[i].thrown))
                bodies[i].thrown = false
            }
        }
    }

    private mutating func stepTidy(_ i: Int, _ h: Double) {
        let toHome = bodies[i].home - bodies[i].pos
        let acc = toHome * config.tidyStiffness - bodies[i].vel * config.tidyDamping
        bodies[i].vel += acc * h
        bodies[i].pos += bodies[i].vel * h
        let da = Self.wrap(bodies[i].homeAngle - bodies[i].angle)
        bodies[i].angle += da * (1 - exp(-8 * h))
        bodies[i].angVel = 0
        if simd_length(toHome) < 0.35, simd_length(bodies[i].vel) < 6, abs(da) < 0.01 {
            bodies[i].pos = bodies[i].home
            bodies[i].angle = bodies[i].homeAngle
            bodies[i].vel = .zero
            bodies[i].mode = .flat
            bodies[i].awake = false
            bodies[i].restTime = 0
        }
    }

    // MARK: Edge-roll

    private mutating func beginEdgeRoll(_ i: Int, speed: Double) {
        let dir = bodies[i].vel / max(1e-6, simd_length(bodies[i].vel))
        var e = CoinEdgeState()
        e.speed0 = speed * config.edgeSpeedFactor
        e.moveDir = dir
        e.heading = atan2(dir.y, dir.x)
        e.turnSign = rng.next() < 0.5 ? -1 : 1
        e.lean0 = 0.16 + rng.next() * 0.12
        e.duration = min(2.1, max(1.15, 1.0 + e.speed0 / 900))
        e.wobblePhase = rng.next() * 2 * Double.pi
        bodies[i].edge = e
        bodies[i].mode = .edge
        bodies[i].tilt = Double.pi / 2 - e.lean0
        bodies[i].heading = e.heading
        bodies[i].vel = dir * e.speed0
        events.append(.edgeStart(id: bodies[i].id, speed: e.speed0))
    }

    /// Rolling on edge: a rolling disc turns at roughly g*tan(lean)/speed,
    /// and as it slows it leans further, so the path tightens into a
    /// spiral until it can no longer stand.
    private mutating func stepEdge(_ i: Int, _ h: Double) {
        var e = bodies[i].edge
        e.t += h
        let p = min(1, e.t / e.duration)
        let speed = e.speed0 * (0.12 + 0.88 * pow(1 - p, 1.1))
        let lean = e.lean0 + (1.28 - e.lean0) * pow(p, 2.6)
        let gScaled = 1400.0
        let omega = min(6.5, gScaled * tan(lean) / max(speed, 140)) * e.turnSign
        let wobble = 0.35 * sin(2 * Double.pi * 5.5 * e.t + e.wobblePhase) * (0.5 + p)
        e.heading += (omega + wobble) * h
        let dir = CoinVec(cos(e.heading), sin(e.heading))
        e.moveDir = dir
        bodies[i].vel = dir * speed
        bodies[i].pos += bodies[i].vel * h
        bodies[i].heading = e.heading
        bodies[i].tilt = Double.pi / 2 - lean
        bodies[i].angle = e.heading
        e.fallSpeed = speed
        bodies[i].edge = e
        if p >= 1 { beginFall(i) }
    }

    private mutating func beginFall(_ i: Int) {
        guard bodies[i].mode == .edge else { return }
        var e = bodies[i].edge
        e.fallT = 0
        e.tilt0 = max(0.12, bodies[i].tilt)
        e.fallSpeed = max(e.fallSpeed, simd_length(bodies[i].vel))
        bodies[i].edge = e
        bodies[i].mode = .falling
        events.append(.spinDown(id: bodies[i].id, duration: CoinEdgeState.fallDuration))
    }

    /// Euler's-disk settle: the tilt axis precesses faster and faster
    /// while the tilt itself dies away, then the coin lies flat.
    private mutating func stepFall(_ i: Int, _ h: Double) {
        var e = bodies[i].edge
        e.fallT += h
        let q = min(1, e.fallT / CoinEdgeState.fallDuration)
        let f0 = 3.0, f1 = 20.0
        // Phase of a chirp whose frequency rises f0 -> f1 (q^2 ramp).
        let theta = 2 * Double.pi * (f0 * e.fallT
            + (f1 - f0) * CoinEdgeState.fallDuration * pow(q, 3) / 3)
        let env = pow(1 - q, 1.4)
        bodies[i].tilt = e.tilt0 * env
        bodies[i].heading = theta
        bodies[i].wobble = CoinVec(cos(theta), sin(theta)) * (bodies[i].radius * 0.07 * env)
        let sp = e.fallSpeed * exp(-6 * e.fallT)
        bodies[i].vel = e.moveDir * sp
        bodies[i].pos += bodies[i].vel * h
        bodies[i].edge = e
        if q >= 1 {
            bodies[i].mode = .flat
            bodies[i].tilt = 0
            bodies[i].wobble = .zero
            bodies[i].vel = .zero
            bodies[i].angle = atan2(e.moveDir.y, e.moveDir.x)
            bodies[i].angVel = 0
            bodies[i].awake = false
            bodies[i].restTime = 0
            events.append(.rested(id: bodies[i].id, at: bodies[i].pos, thrown: bodies[i].thrown))
            bodies[i].thrown = false
        }
    }

    // MARK: Rails

    private mutating func resolveRails() {
        guard let b = config.bounds else { return }
        for i in bodies.indices {
            let m = bodies[i].mode
            guard m == .flat || m == .edge || m == .falling, bodies[i].awake else { continue }
            let r = bodies[i].radius
            var hit = 0.0
            if bodies[i].pos.x < b.minX + r {
                bodies[i].pos.x = b.minX + r
                if bodies[i].vel.x < 0 {
                    hit = max(hit, -bodies[i].vel.x)
                    bodies[i].vel.x = -bodies[i].vel.x * config.railRestitution
                    bodies[i].vel.y *= config.railTangentKeep
                    bodies[i].angVel += bodies[i].vel.y * 0.004
                }
            } else if bodies[i].pos.x > b.maxX - r {
                bodies[i].pos.x = b.maxX - r
                if bodies[i].vel.x > 0 {
                    hit = max(hit, bodies[i].vel.x)
                    bodies[i].vel.x = -bodies[i].vel.x * config.railRestitution
                    bodies[i].vel.y *= config.railTangentKeep
                    bodies[i].angVel -= bodies[i].vel.y * 0.004
                }
            }
            if bodies[i].pos.y < b.minY + r {
                bodies[i].pos.y = b.minY + r
                if bodies[i].vel.y < 0 {
                    hit = max(hit, -bodies[i].vel.y)
                    bodies[i].vel.y = -bodies[i].vel.y * config.railRestitution
                    bodies[i].vel.x *= config.railTangentKeep
                    bodies[i].angVel -= bodies[i].vel.x * 0.004
                }
            } else if bodies[i].pos.y > b.maxY - r {
                bodies[i].pos.y = b.maxY - r
                if bodies[i].vel.y > 0 {
                    hit = max(hit, bodies[i].vel.y)
                    bodies[i].vel.y = -bodies[i].vel.y * config.railRestitution
                    bodies[i].vel.x *= config.railTangentKeep
                    bodies[i].angVel += bodies[i].vel.x * 0.004
                }
            }
            if hit > 0 {
                if hit > 50 { events.append(.rail(strength: min(1, hit / 900), at: bodies[i].pos)) }
                if m == .edge {
                    // A standing coin that meets the rail topples.
                    bodies[i].edge.fallSpeed = simd_length(bodies[i].vel)
                    bodies[i].edge.moveDir = bodies[i].vel / max(1e-6, simd_length(bodies[i].vel))
                    beginFall(i)
                }
            }
        }
    }

    // MARK: Pairs

    private static func key(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(UInt32(truncatingIfNeeded: min(a, b)))
        let hi = UInt64(UInt32(truncatingIfNeeded: max(a, b)))
        return (lo << 32) | hi
    }

    private static func pairInvolves(_ key: UInt64, id: Int) -> Bool {
        let u = UInt64(UInt32(truncatingIfNeeded: id))
        return (key >> 32) == u || (key & 0xFFFF_FFFF) == u
    }

    private func contactDistance(_ a: Int, _ b: Int) -> Double {
        (bodies[a].radius + bodies[b].radius) * config.contactScale
    }

    /// Ghost every pair body `i` currently overlaps with, so a coin that
    /// wakes (or is dropped) inside a stack separates from it instead of
    /// being fired out of it.
    private mutating func ghostOverlaps(of i: Int, onlyAsleepOthers: Bool = false,
                                        excluding: Int? = nil) {
        for j in bodies.indices where j != i && j != excluding {
            if onlyAsleepOthers && bodies[j].awake { continue }
            if bodies[j].mode == .scripted { continue }
            if simd_length(bodies[j].pos - bodies[i].pos) < contactDistance(i, j) {
                ghosts.insert(Self.key(bodies[i].id, bodies[j].id))
            }
        }
    }

    private mutating func wake(_ i: Int, excluding other: Int) {
        guard !bodies[i].awake else { return }
        // Neighbours it is stacked with stay stacked until they separate.
        ghostOverlaps(of: i, onlyAsleepOthers: true, excluding: other)
        bodies[i].awake = true
        bodies[i].restTime = 0
        if bodies[i].mode == .tidy { bodies[i].mode = .flat }
    }

    private mutating func resolvePairs() {
        let n = bodies.count
        guard n > 1 else { return }
        for a in 0..<(n - 1) {
            for b in (a + 1)..<n {
                let ma = bodies[a].mode, mb = bodies[b].mode
                if ma == .scripted || mb == .scripted || ma == .held || mb == .held { continue }
                if !bodies[a].awake && !bodies[b].awake { continue }
                let d = bodies[b].pos - bodies[a].pos
                let contact = contactDistance(a, b)
                let dist2 = d.x * d.x + d.y * d.y
                let key = Self.key(bodies[a].id, bodies[b].id)
                if dist2 >= contact * contact {
                    if !ghosts.isEmpty, dist2 >= contact * contact * 1.0404 { ghosts.remove(key) }
                    continue
                }
                if ghosts.contains(key) { continue }
                // Homing coins ignore each other and sleepers (they converge on overlap by design).
                if (ma == .tidy && (mb == .tidy || !bodies[b].awake))
                    || (mb == .tidy && !bodies[a].awake) {
                    ghosts.insert(key)
                    continue
                }
                collide(a, b, d: d, dist: dist2.squareRoot(), contact: contact)
            }
        }
    }

    private mutating func collide(_ a: Int, _ b: Int, d: CoinVec, dist: Double, contact: Double) {
        let n = dist > 1e-6 ? d / dist : CoinVec(1, 0)
        let va = bodies[a].vel, vb = bodies[b].vel
        let vrel = va - vb
        let vn = simd_dot(vrel, n)   // > 0: closing
        let aAwake = bodies[a].awake, bAwake = bodies[b].awake
        let invA = bodies[a].invMass, invB = bodies[b].invMass
        let sumInv = invA + invB
        if vn > 0 {
            if !aAwake { wake(a, excluding: b) }
            if !bAwake { wake(b, excluding: a) }
            let e = vn < 90 ? 0.2 : config.restitution
            let j = (1 + e) * vn / sumInv
            bodies[a].vel -= n * (j * invA)
            bodies[b].vel += n * (j * invB)
            // Tangential friction: spin transfer.
            let t = CoinVec(-n.y, n.x)
            let slip = simd_dot(vrel, t)
            let jtMax = config.contactFriction * j
            let jt = max(-jtMax, min(jtMax, -slip * 0.5 / sumInv))
            bodies[a].vel += t * (jt * invA)
            bodies[b].vel -= t * (jt * invB)
            bodies[a].angVel += bodies[a].radius * jt / bodies[a].momentOfInertia
            bodies[b].angVel += bodies[b].radius * jt / bodies[b].momentOfInertia
            // Anything standing on its edge that gets hit falls over.
            if bodies[a].mode == .edge { bodies[a].edge.moveDir = Self.unit(bodies[a].vel); bodies[a].edge.fallSpeed = simd_length(bodies[a].vel); beginFall(a) }
            if bodies[b].mode == .edge { bodies[b].edge.moveDir = Self.unit(bodies[b].vel); bodies[b].edge.fallSpeed = simd_length(bodies[b].vel); beginFall(b) }
            if vn > 40 {
                events.append(.clink(strength: min(1, vn / 800), at: bodies[a].pos + d * 0.5))
            }
        }
        // Positional correction up to the contact radius.
        let pen = contact - dist
        if pen > 0 {
            let aMoves = bodies[a].awake && bodies[a].invMass > 0
            let bMoves = bodies[b].awake && bodies[b].invMass > 0
            let share = 0.85 * pen
            if aMoves && bMoves {
                let wa = invA / sumInv, wb = invB / sumInv
                bodies[a].pos -= n * (share * wa)
                bodies[b].pos += n * (share * wb)
            } else if aMoves {
                bodies[a].pos -= n * share
            } else if bMoves {
                bodies[b].pos += n * share
            }
        }
    }

    private static func unit(_ v: CoinVec) -> CoinVec {
        let l = simd_length(v)
        return l > 1e-6 ? v / l : CoinVec(1, 0)
    }

    private static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * Double.pi)
        if x > Double.pi { x -= 2 * Double.pi }
        if x < -Double.pi { x += 2 * Double.pi }
        return x
    }

    private func clampToBounds(_ p: CoinVec, radius: Double) -> CoinVec {
        guard let b = config.bounds else { return p }
        return CoinVec(min(max(p.x, b.minX + radius), b.maxX - radius),
                       min(max(p.y, b.minY + radius), b.maxY - radius))
    }
}
