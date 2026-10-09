import SwiftUI
import SceneKit
import Observation
import simd
import UIKit

// The SwiftUI side of CoinSim: one shared coin world per felt (LCR's seat
// piles + pot in DiceTableView, free play's toy coins). The model owns a
// `CoinSim`, steps it from a display link ONLY while something is moving or
// waiting to tidy, mirrors awake bodies into observable nodes (so only
// moving coins re-render) and turns sim events into sound. Nothing here is
// game state: LCR's chip counts still come from the controller; groups are
// just "N coins live around this home point".

// MARK: - Specs

struct CoinPayTarget: Equatable {
    let id: Int
    let point: CGPoint
}

/// One cluster of coins: a seat's pile, the pot, or the free-play toy pile.
struct CoinGroupSpec: Equatable, Identifiable {
    var key: String
    var count: Int
    var diameter: CGFloat
    var maxVisible: Int = 8
    var seedKey: String
    var spreadScale: CGFloat = 0.40
    /// Absolute felt position of the cluster's home.
    var center: CGPoint
    /// Coins can be picked up and flicked. The pot isn't.
    var draggable = true
    /// Live pending-transfer destinations THIS group currently owes coins
    /// to. A coin the player FLICKS or drops that comes to rest within the
    /// snap radius pays; coins knocked by collisions never do.
    var payTargets: [CoinPayTarget] = []
    var id: String { key }
    var visible: Int { min(count, maxVisible) }
}

enum CoinWorldSpace {
    static let name = "coinWorld"
    /// Snap radius for a flicked/dropped coin onto an owed target (same
    /// generous ~110 pt the old drag-to-pay used).
    static let paySnapRadius: CGFloat = 110
}

// MARK: - Observable node

@Observable
final class CoinNode: Identifiable {
    let id: Int
    let groupKey: String
    let index: Int
    let diameter: CGFloat
    let jitterScale: CGFloat
    var draggable: Bool
    var x: CGFloat
    var y: CGFloat
    var angle: Double
    var tilt: Double = 0
    var heading: Double = 0
    var z: CGFloat = 0
    var held = false
    var paying = false
    var order: Double

    init(id: Int, groupKey: String, index: Int, diameter: CGFloat, jitterScale: CGFloat,
         draggable: Bool, position: CGPoint, angle: Double, order: Double) {
        self.id = id; self.groupKey = groupKey; self.index = index
        self.diameter = diameter; self.jitterScale = jitterScale
        self.draggable = draggable
        self.x = position.x; self.y = position.y
        self.angle = angle; self.order = order
    }
}

// MARK: - Model

@Observable
final class CoinWorldModel {
    private(set) var nodes: [CoinNode] = []

    @ObservationIgnored private var sim: CoinSim
    @ObservationIgnored private var specs: [String: CoinGroupSpec] = [:]
    @ObservationIgnored private var groupIndex: [String: Int] = [:]
    @ObservationIgnored private var slots: [String: CoinNode] = [:]   // "group#index"
    @ObservationIgnored private var nodeByID: [Int: CoinNode] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var topOrder = 1000.0
    @ObservationIgnored private var grabOffset: [Int: CGSize] = [:]
    @ObservationIgnored private var lastDragTime: [Int: CFTimeInterval] = [:]
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var proxy: LinkProxy?
    @ObservationIgnored private var lastStamp: CFTimeInterval = 0
    @ObservationIgnored private var lastClink: CFTimeInterval = 0
    @ObservationIgnored var onPay: ((String, Int) -> Void)?

    init(tidyDelay: Double? = 1.0) {
        var c = CoinSimConfig()
        c.tidyDelay = tidyDelay
        sim = CoinSim(config: c)
    }

    // MARK: Configure

    func configure(groups: [CoinGroupSpec], bounds: CGRect, reduceMotion: Bool) {
        sim.config.reduceMotion = reduceMotion
        sim.config.bounds = (Double(bounds.minX), Double(bounds.minY),
                             Double(bounds.maxX), Double(bounds.maxY))
        var added: [CoinNode] = []
        var removed: [CoinNode] = []
        let liveKeys = Set(groups.map(\.key))
        for (i, spec) in groups.enumerated() {
            specs[spec.key] = spec
            groupIndex[spec.key] = i
            let r = Double(spec.diameter) / 2
            for index in 0..<spec.visible {
                let slotKey = "\(spec.key)#\(index)"
                let rest = Self.rest(spec: spec, index: index)
                let home = CoinVec(Double(spec.center.x + rest.width), Double(spec.center.y + rest.height))
                let homeAngle = Self.homeAngle(spec: spec, index: index)
                if let node = slots[slotKey] {
                    node.draggable = spec.draggable
                    sim.setHome(id: node.id, home: home, homeAngle: homeAngle)
                    if let b = sim.body(node.id), !b.awake, b.mode == .flat {
                        node.x = CGFloat(b.pos.x); node.y = CGFloat(b.pos.y)
                    }
                } else {
                    let id = nextID; nextID += 1
                    let jitter = CoinCluster.pileJitter(index: index, seedKey: spec.seedKey, diameter: spec.diameter)
                    let node = CoinNode(id: id, groupKey: spec.key, index: index, diameter: spec.diameter,
                                        jitterScale: jitter.scale, draggable: spec.draggable,
                                        position: CGPoint(x: home.x, y: home.y), angle: homeAngle,
                                        order: Double(i) * 100 + Double(index))
                    sim.addCoin(id: id, group: i, radius: r, home: home, homeAngle: homeAngle)
                    slots[slotKey] = node
                    nodeByID[id] = node
                    added.append(node)
                }
            }
            // Coins above the new count leave (top of the pile first).
            for (slotKey, node) in slots where node.groupKey == spec.key && node.index >= spec.visible {
                removed.append(node)
                slots[slotKey] = nil
            }
        }
        for (slotKey, node) in slots where !liveKeys.contains(node.groupKey) {
            removed.append(node)
            slots[slotKey] = nil
        }
        for node in removed {
            sim.removeCoin(id: node.id)
            nodeByID[node.id] = nil
        }
        specs = specs.filter { liveKeys.contains($0.key) }
        if !added.isEmpty || !removed.isEmpty {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                let gone = Set(removed.map(\.id))
                nodes.removeAll { gone.contains($0.id) }
                nodes.append(contentsOf: added)
            }
        }
        if sim.needsStepping { startLink() }
    }

    private static func rest(spec: CoinGroupSpec, index: Int) -> CGSize {
        let slot = CoinCluster.slot(index: index, seedKey: spec.seedKey,
                                    diameter: spec.diameter, spreadScale: spec.spreadScale)
        let jitter = CoinCluster.pileJitter(index: index, seedKey: spec.seedKey, diameter: spec.diameter)
        return CGSize(width: slot.width + jitter.offset.width,
                      height: slot.height + jitter.offset.height - jitter.lift)
    }

    private static func homeAngle(spec: CoinGroupSpec, index: Int) -> Double {
        TableGeometry.jitterDegrees(cardID: "\(spec.seedKey)r\(index)") * 4 * .pi / 180
    }

    func nodes(inGroup key: String) -> [CoinNode] { nodes.filter { $0.groupKey == key } }

    // MARK: Finger

    func dragChanged(_ node: CoinNode, location: CGPoint, start: CGPoint) {
        guard !node.paying, node.draggable else { return }
        let now = CACurrentMediaTime()
        if !node.held {
            node.held = true
            Haptics.tick()
            grabOffset[node.id] = CGSize(width: node.x - start.x, height: node.y - start.y)
            topOrder += 1
            node.order = topOrder
            sim.grab(id: node.id, at: CoinVec(Double(node.x), Double(node.y)))
            lastDragTime[node.id] = now
            startLink()
        }
        let off = grabOffset[node.id] ?? .zero
        let dt = now - (lastDragTime[node.id] ?? now)
        lastDragTime[node.id] = now
        sim.drag(id: node.id, to: CoinVec(Double(location.x + off.width), Double(location.y + off.height)), dt: dt)
        startLink()
    }

    func dragEnded(_ node: CoinNode, velocity: CGSize) {
        guard node.held else { return }
        node.held = false
        sim.release(id: node.id, velocity: CoinVec(Double(velocity.width), Double(velocity.height)))
        startLink()
    }

    // MARK: Dice impact

    /// A dice settle/landing at `point` (this world's coordinate space).
    func dicePing(at point: CGPoint, strength: Double) {
        sim.impulse(at: CoinVec(Double(point.x), Double(point.y)), strength: strength)
        for b in sim.bodies where b.awake {
            if let node = nodeByID[b.id], node.order < 1000 {
                topOrder += 1
                node.order = topOrder
            }
        }
        startLink()
    }

    // MARK: Demo hooks (sim-verify)

    /// `-demoCoinScatter`: flick one coin into the biggest other cluster.
    /// `edge` forces the edge-roll (`-demoCoinEdge`).
    func demoScatter(edge: Bool) {
        let live = specs.values.filter { $0.visible > 0 }
        guard let src = live.filter({ $0.draggable }).sorted(by: { $0.key < $1.key }).first,
              let dst = live.filter({ $0.key != src.key }).max(by: { $0.visible < $1.visible }),
              let node = slots["\(src.key)#\(src.visible - 1)"] else { return }
        let dx = dst.center.x - src.center.x, dy = dst.center.y - src.center.y
        let len = max(1, hypot(dx, dy))
        let dir = CGPoint(x: dx / len, y: dy / len)
        let start = CoinVec(Double(dst.center.x - dir.x * 200), Double(dst.center.y - dir.y * 200))
        sim.place(id: node.id, at: start)
        node.x = CGFloat(start.x); node.y = CGFloat(start.y)
        topOrder += 1; node.order = topOrder
        sim.grab(id: node.id, at: start)
        sim.release(id: node.id, velocity: CoinVec(Double(dir.x), Double(dir.y)) * (edge ? 3300 : 2500),
                    forceEdgeRoll: edge)
        startLink()
    }

    // MARK: Display link

    private final class LinkProxy: NSObject {
        weak var model: CoinWorldModel?
        @objc func tick(_ link: CADisplayLink) { model?.tick(link) }
    }

    private func startLink() {
        guard link == nil else { return }
        let p = LinkProxy()
        p.model = self
        let l = CADisplayLink(target: p, selector: #selector(LinkProxy.tick(_:)))
        l.add(to: .main, forMode: .common)
        proxy = p
        link = l
        lastStamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
    }

    private func tick(_ l: CADisplayLink) {
        let stamp = l.timestamp
        let dt = lastStamp == 0 ? 1.0 / 60.0 : stamp - lastStamp
        lastStamp = stamp
        sim.step(dt)
        publish()
        handle(sim.drainEvents())
        if !sim.needsStepping { stop() }
    }

    private func publish() {
        for b in sim.bodies {
            guard let node = nodeByID[b.id], b.mode != .scripted else { continue }
            let x = CGFloat(b.pos.x + b.wobble.x), y = CGFloat(b.pos.y + b.wobble.y)
            if node.x != x { node.x = x }
            if node.y != y { node.y = y }
            if node.angle != b.angle { node.angle = b.angle }
            if node.tilt != b.tilt { node.tilt = b.tilt }
            if node.heading != b.heading { node.heading = b.heading }
            let z = CGFloat(b.z)
            if node.z != z { node.z = z }
            // A coin that has gone home drops back to its pile order.
            if !b.awake, b.mode == .flat, node.order >= 1000,
               simd_length(b.pos - b.home) < 1 {
                node.order = Double(groupIndex[node.groupKey] ?? 0) * 100 + Double(node.index)
            }
        }
    }

    private func handle(_ events: [CoinEvent]) {
        let now = CACurrentMediaTime()
        var clinks = 0
        for event in events {
            switch event {
            case .clink(let s, _):
                guard s > 0.07, clinks < 3, now - lastClink > 0.03 else { continue }
                clinks += 1
                lastClink = now
                TableSFX.shared.playCoinClink(strength: s)
            case .land(let s, _):
                guard s > 0.12, clinks < 3, now - lastClink > 0.03 else { continue }
                clinks += 1
                lastClink = now
                TableSFX.shared.playCoinClink(strength: s * 0.6)
            case .rail(let s, _):
                guard s > 0.08 else { continue }
                TableSFX.shared.playCoinRail(strength: s)
            case .edgeStart:
                break
            case .spinDown:
                TableSFX.shared.playCoinSpinDown()
            case .rested(let id, let at, let thrown):
                if thrown { resolveThrow(id: id, at: CGPoint(x: at.x, y: at.y)) }
            }
        }
    }

    /// A coin the player released has come to rest. If its group owes a
    /// debt and it stopped within snap range of a target, it pays. Only the
    /// released coin is ever `thrown`, so collision-knocked bystanders can
    /// never pay.
    private func resolveThrow(id: Int, at point: CGPoint) {
        guard let node = nodeByID[id], !node.paying,
              let spec = specs[node.groupKey], !spec.payTargets.isEmpty else { return }
        guard let target = spec.payTargets
            .map({ ($0, hypot(point.x - $0.point.x, point.y - $0.point.y)) })
            .filter({ $0.1 <= CoinWorldSpace.paySnapRadius })
            .min(by: { $0.1 < $1.1 })?.0 else { return }
        node.paying = true
        sim.setScripted(id: id, true)
        Haptics.arm()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            node.x = target.point.x
            node.y = target.point.y
        }
        let groupKey = node.groupKey
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            self.onPay?(groupKey, target.id)
            if let body = self.sim.body(id) {
                self.sim.place(id: id, at: body.home, angle: body.homeAngle)
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) {
                    node.x = CGFloat(body.home.x); node.y = CGFloat(body.home.y)
                    node.angle = body.homeAngle
                    node.paying = false
                    node.order = Double(self.groupIndex[groupKey] ?? 0) * 100 + Double(node.index)
                }
            } else {
                node.paying = false
            }
        }
    }
}

// MARK: - Impact bus (dice -> coins)

/// The hook between the 3D dice scene and the coin layers. Every
/// `CoinWorldView` registers its model; the dice scene posts a ping with
/// the contact's SCREEN position (table coordinates) and a 0...1 strength,
/// and coins within range hop and scatter in proportion.
///
/// ONE-LINE INTEGRATION for `DiceTableSceneCoordinator`
/// (`Sources/App/Dice/Dice3D/DiceTableSceneView.swift`), in
/// `physicsWorld(_:didBegin:)` next to `contactThrottle?.register(contact)`:
///
///     CoinImpactBus.shared.dicePing(contact: contact, in: view)
///
/// (`view` is the coordinator's `private weak var view: DiceSCNView?`.)
/// Safe from the physics thread; gated and rate-limited internally.
final class CoinImpactBus {
    static let shared = CoinImpactBus()

    private final class Weak { weak var model: CoinWorldModel?; init(_ m: CoinWorldModel) { model = m } }
    private var models: [Weak] = []
    private var lastPing = Date.distantPast
    private let lock = NSLock()

    func register(_ model: CoinWorldModel) {
        lock.lock(); defer { lock.unlock() }
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(Weak(model))
    }

    func unregister(_ model: CoinWorldModel) {
        lock.lock(); defer { lock.unlock() }
        models.removeAll { $0.model == nil || $0.model === model }
    }

    /// Any thread. `point` is in the same space as the coin layers (the
    /// full-screen table), `strength` 0...1.
    func dicePing(at point: CGPoint, strength: Double) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let live = models.compactMap(\.model)
            lock.unlock()
            for model in live { model.dicePing(at: point, strength: strength) }
        }
    }

    /// Convenience for the SceneKit contact delegate (physics thread).
    func dicePing(contact: SCNPhysicsContact, in view: SCNView?) {
        let impulse = Double(contact.collisionImpulse)
        guard impulse > 0.03, let view else { return }
        let now = Date()
        lock.lock()
        let allowed = now.timeIntervalSince(lastPing) > 0.045
        if allowed { lastPing = now }
        lock.unlock()
        guard allowed else { return }
        let world = contact.contactPoint
        let strength = min(1, impulse / 0.17)
        guard strength > 0.12 else { return }
        DispatchQueue.main.async {
            let p = view.projectPoint(world)
            CoinImpactBus.shared.dicePing(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), strength: strength)
        }
    }
}

// MARK: - View

/// The coin layer: place it full-size in the table ZStack at the depth
/// coins should sit (above the plates, below the dice scene).
struct CoinWorldView: View {
    let size: CGSize
    let groups: [CoinGroupSpec]
    let bounds: CGRect
    var onPay: ((String, Int) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: CoinWorldModel

    init(size: CGSize, groups: [CoinGroupSpec], bounds: CGRect, tidyDelay: Double? = 1.0,
         onPay: ((String, Int) -> Void)? = nil) {
        self.size = size
        self.groups = groups
        self.bounds = bounds
        self.onPay = onPay
        _model = State(initialValue: CoinWorldModel(tidyDelay: tidyDelay))
    }

    var body: some View {
        ZStack {
            ForEach(groups) { spec in
                CoinGroupBackdrop(model: model, spec: spec)
            }
            ForEach(model.nodes) { node in
                CoinSpriteView(node: node, model: model)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: CoinWorldSpace.name)
        .onAppear {
            model.onPay = onPay
            model.configure(groups: groups, bounds: bounds, reduceMotion: reduceMotion)
            CoinImpactBus.shared.register(model)
            runDemosIfRequested()
        }
        .onDisappear {
            CoinImpactBus.shared.unregister(model)
            model.stop()
        }
        .onChange(of: groups) { _, new in
            model.onPay = onPay
            model.configure(groups: new, bounds: bounds, reduceMotion: reduceMotion)
        }
        .onChange(of: bounds) { _, new in
            model.configure(groups: groups, bounds: new, reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, new in
            model.configure(groups: groups, bounds: bounds, reduceMotion: new)
        }
    }

    /// Sim-verify launch args (only meaningful in DiceTableView; harmless elsewhere).
    private func runDemosIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("-demoCoinScatter") || args.contains("-demoCoinEdge")
                || args.contains("-demoCoinDicePing") else { return }
        let edge = args.contains("-demoCoinEdge")
        let ping = args.contains("-demoCoinDicePing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if ping {
                if let g = groups.filter({ $0.visible > 0 }).max(by: { $0.visible < $1.visible }) {
                    model.dicePing(at: CGPoint(x: g.center.x + 18, y: g.center.y - 10), strength: 0.85)
                }
            } else {
                model.demoScatter(edge: edge)
            }
        }
    }
}

/// The soft pooled shadow under a whole cluster plus its "xN" overflow
/// tag. The shadow fades as coins scatter away from home.
private struct CoinGroupBackdrop: View {
    let model: CoinWorldModel
    let spec: CoinGroupSpec

    var body: some View {
        let d = spec.diameter
        let visible = spec.visible
        let members = model.nodes(inGroup: spec.key)
        let spread = members.isEmpty ? 0 : members.reduce(0.0) {
            $0 + Double(hypot($1.x - spec.center.x, $1.y - spec.center.y))
        } / Double(members.count)
        let homeSpread = Double(d) * Double(spec.spreadScale) * Double(max(1, visible)).squareRoot()
        let scatter = max(0, min(1, (spread - homeSpread) / 60))
        ZStack {
            if visible > 0 {
                Ellipse()
                    .fill(.black.opacity(0.30 * (1 - scatter)))
                    .frame(width: d * (1.1 + spec.spreadScale * CGFloat(visible) * 0.5),
                           height: d * (0.8 + spec.spreadScale * CGFloat(visible) * 0.35))
                    .blur(radius: 5)
                    .offset(y: d * 0.10)
                    .position(spec.center)
            }
            if spec.count > spec.maxVisible {
                Text("\u{00D7}\(spec.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .position(x: spec.center.x + d * 1.1, y: spec.center.y + d * 0.55)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.count == 1 ? "1 coin" : "\(spec.count) coins")
        .accessibilityHint(spec.payTargets.isEmpty ? ""
                           : "You owe a coin. Drag or flick any coin to the glowing spot to pay")
    }
}

/// One coin: contact shadow + metal token, positioned by its node.
private struct CoinSpriteView: View {
    let node: CoinNode
    let model: CoinWorldModel

    var body: some View {
        let d = node.diameter
        let lift = node.z
        let standing = node.tilt > 0.03
        let rim = max(0, min(1, (node.tilt - 0.95) / 0.45))
        ZStack {
            CoinContactShadow(diameter: d)
                .scaleEffect(x: 1 - 0.55 * min(1, node.tilt / 1.3), y: 1)
                .rotationEffect(.radians(standing ? node.heading : 0))
                .scaleEffect(1 + lift * 0.003)
                .opacity((node.paying ? 0 : 1) * Double(max(0.35, 1 - lift * 0.006)))
                .offset(y: lift * 0.25)
            ChipToken(diameter: d, animatesSheen: node.index < 3)
                .rotation3DEffect(.radians(node.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .rotationEffect(.radians(standing ? node.heading : node.angle))
                .overlay {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.93, blue: 0.62),
                                     Color(red: 0.55, green: 0.38, blue: 0.10)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: d * 0.97, height: d * 0.12)
                        .rotationEffect(.radians(node.heading))
                        .opacity(rim)
                }
                .scaleEffect(node.jitterScale * (node.held ? 1.18 : 1 + lift * 0.004))
                .opacity(node.paying ? 0 : 1)
                .shadow(color: .black.opacity(node.held ? 0.45 : 0), radius: 8, y: 5)
                .offset(y: -lift * 0.5)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(CoinWorldSpace.name))
                        .onChanged { model.dragChanged(node, location: $0.location, start: $0.startLocation) }
                        .onEnded { model.dragEnded(node, velocity: $0.velocity) },
                    including: node.draggable && !node.paying ? .all : .none)
        }
        .position(x: node.x, y: node.y)
        .zIndex(node.order)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
        .accessibilityHidden(true)
    }
}
