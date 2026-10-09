import SwiftUI
import QuartzCore

/// One card's pose as the views read it. Its own @Observable object so a
/// moving card invalidates ONLY the small wrapper view that reads it
/// (`SimPlacedCard`), never TableGameView's big body.
@Observable
final class CardPoseBox {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var angle: Double = 0   // degrees
    var z: Double = 0
}

/// SwiftUI-side owner of the FeltSim: a display link that runs ONLY while
/// something is moving (idle table = zero work), publishing poses into
/// `CardPoseBox`es. Fixed 1/240 s substeps inside FeltSim keep it
/// deterministic whatever the display's refresh rate.
@Observable
final class FeltSimStore {
    @ObservationIgnored let sim = FeltSim()
    @ObservationIgnored private var boxes: [String: CardPoseBox] = [:]
    /// Bumps only when a card gains/loses a body (rare), so the parent
    /// re-renders to swap placeholder <-> placed card, not per frame.
    private(set) var version = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var target: LinkTarget?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    /// A body fell asleep: (id, normalized center, angle degrees). Used to
    /// mirror the resting pose into the host's freePlayLayout.
    @ObservationIgnored var onSettled: ((String, CGPoint, Double) -> Void)?

    private final class LinkTarget: NSObject {
        weak var store: FeltSimStore?
        @objc func tick(_ link: CADisplayLink) { store?.tick(link) }
    }

    // MARK: setup

    func configure(size: CGSize, cardWidth: CGFloat) {
        var c = sim.config
        let w = Double(size.width), h = Double(size.height), cw = Double(cardWidth)
        guard c.width != w || c.height != h || c.cardWidth != cw else { return }
        c.width = w; c.height = h; c.cardWidth = cw
        // Felt is inset 14 pt inside the walnut (TableSurface), 38 pt radius.
        c.wallInset = 16
        c.wallRadius = 34
        sim.reconfigure(c)
    }

    var size: CGSize { CGSize(width: sim.config.width, height: sim.config.height) }

    func box(for id: String) -> CardPoseBox? {
        _ = version // register the dependency: appearing/vanishing bodies re-render the parent
        return boxes[id]
    }

    // MARK: mutations (each publishes immediately and wakes the clock)

    func toss(id: String, from: CGPoint, to: CGPoint, duration: Double,
              angleFrom: Double, angleTo: Double) {
        sim.toss(id: id, from: vec(from), to: vec(to), duration: duration,
                 angleFromDegrees: angleFrom, angleToDegrees: angleTo)
        afterMutation()
    }

    func land(id: String, at p: CGPoint, angle: Double, glide: FeltSim.Glide? = nil) {
        sim.land(id: id, at: vec(p), angleDegrees: angle, glide: glide)
        afterMutation()
    }

    func hold(id: String, finger: CGPoint) {
        sim.hold(id: id, finger: vec(finger))
        afterMutation()
    }

    func isHeld(_ id: String) -> Bool { sim.isHeld(id) }

    func release(id: String, glide: FeltSim.Glide?) {
        sim.release(id: id, glide: glide)
        afterMutation()
    }

    func remove(_ id: String) {
        sim.remove(id)
        if boxes.removeValue(forKey: id) != nil { version += 1 }
    }

    func retain(only keep: Set<String>) {
        sim.retain(only: keep)
        let gone = boxes.keys.filter { !keep.contains($0) }
        for id in gone { boxes.removeValue(forKey: id) }
        if !gone.isEmpty { version += 1 }
    }

    func nudge(direction: CGVector, distance: Double) {
        sim.nudge(direction: FeltVec(x: Double(direction.dx), y: Double(direction.dy)), distance: distance)
        afterMutation()
    }

    func shock(direction: CGVector, strength: Double) {
        sim.shock(direction: FeltVec(x: Double(direction.dx), y: Double(direction.dy)), strength: strength)
        afterMutation()
    }

    @inline(__always) private func vec(_ p: CGPoint) -> FeltVec { FeltVec(x: Double(p.x), y: Double(p.y)) }

    private func afterMutation() {
        publish()
        if sim.isActive { startClock() }
    }

    // MARK: clock

    private func startClock() {
        guard link == nil else { return }
        let t = LinkTarget()
        t.store = self
        let l = CADisplayLink(target: t, selector: #selector(LinkTarget.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        target = t
        link = l
        lastTimestamp = 0
    }

    private func stopClock() {
        link?.invalidate()
        link = nil
        target = nil
    }

    private func tick(_ l: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0 / 120.0 : l.timestamp - lastTimestamp
        lastTimestamp = l.timestamp
        sim.advance(by: dt)
        publish()
        if !sim.isActive { stopClock() }
    }

    private func publish() {
        let width = sim.config.width, height = sim.config.height
        sim.publishDirty { _, id, body in
            let box: CardPoseBox
            if let existing = boxes[id] {
                box = existing
            } else {
                box = CardPoseBox()
                boxes[id] = box
                version += 1
            }
            let x = CGFloat(body.p.x), y = CGFloat(body.p.y)
            let a = body.angle * 180 / .pi
            let z = FeltSim.zOrder(level: body.level, seq: body.seq)
            if box.x != x { box.x = x }
            if box.y != y { box.y = y }
            if box.angle != a { box.angle = a }
            if box.z != z { box.z = z }
            if !body.awake && !body.held {
                onSettled?(id, CGPoint(x: body.p.x / width, y: body.p.y / height), a)
            }
        }
    }

    deinit { link?.invalidate() }
}

/// Solve the x (time) at which a CSS-style cubic bezier timing curve
/// reaches a given progress y. Lets a handoff land at the EXACT instant a
/// SwiftUI `.timingCurve` animation touches down, instead of the linear
/// `duration * fraction` guess (the curve is front-loaded, so touchdown
/// comes earlier than that).
enum FeltTiming {
    static func time(atProgress target: Double,
                     _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bez(mid, y1, y2) < target { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, x1, x2)
    }
}

/// The one shadow treatment for a card that is NOT lying flat: a soft,
/// offset ground ellipse that separates and fades with height. Resting
/// cards get no ellipse, only CardView's own tight contact shadow at
/// elevation 0, so every card on the felt (free play, shed pile, flipped,
/// tossed, held) shares exactly two looks: resting and airborne.
enum FeltShadow {
    static func alpha(lift: CGFloat) -> Double { 0.30 - Double(lift) * 0.0016 }
    static func scale(lift: CGFloat) -> CGFloat { 0.92 - lift * 0.0022 }
    static func blur(lift: CGFloat) -> CGFloat { 3 + lift * 0.16 }
    /// CardView's own attached shadow softens a little with height; the
    /// separated ground shadow does the rest of the work.
    static func cardElevation(lift: CGFloat) -> CGFloat { min(0.4, lift / 70) }
}

struct FeltGroundShadow: View {
    let lift: CGFloat
    let cardWidth: CGFloat
    var body: some View {
        Ellipse()
            .fill(.black.opacity(FeltShadow.alpha(lift: lift)))
            .frame(width: cardWidth * FeltShadow.scale(lift: lift),
                   height: cardWidth * 0.62 * FeltShadow.scale(lift: lift))
            .blur(radius: FeltShadow.blur(lift: lift))
    }
}

/// A card placed by the sim. Reads its pose from the box (the only thing
/// that changes per frame); `content` is built once by the parent.
struct SimPlacedCard<Content: View>: View {
    let box: CardPoseBox
    let lift: CGFloat
    let cardWidth: CGFloat
    /// Paint order override (held / lifting cards float above the rest).
    var zOverride: Double?
    let content: Content

    init(box: CardPoseBox, lift: CGFloat, cardWidth: CGFloat, zOverride: Double? = nil,
         @ViewBuilder content: () -> Content) {
        self.box = box
        self.lift = lift
        self.cardWidth = cardWidth
        self.zOverride = zOverride
        self.content = content()
    }

    var body: some View {
        ZStack {
            if lift > 0.5 {
                FeltGroundShadow(lift: lift, cardWidth: cardWidth)
                    .position(x: box.x, y: box.y)
            }
            content
                .rotationEffect(.degrees(box.angle))
                .offset(y: -lift)
                .position(x: box.x, y: box.y)
        }
        .zIndex(zOverride ?? box.z)
    }
}
