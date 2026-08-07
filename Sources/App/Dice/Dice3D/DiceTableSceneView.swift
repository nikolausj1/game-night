import SwiftUI
import SceneKit

/// The table's 3D dice layer: a transparent SCNView floating over the
/// felt. A persistent POOL of up to 3 real dice lives here for the whole
/// game — the same physical dice a roller throws, the next roller drags
/// (or, in auto-cup mode, watches glide) into their own cup, and so on.
/// Rolls spawn them from wherever they were loaded, gravity and friction
/// settle them across the table, and DieFaceReader reads the result back
/// into the controller. Never intercepts a touch unless it actually lands
/// on a draggable die.
struct DiceTableSceneView: UIViewRepresentable {
    /// The roll currently requested by the controller (nil between turns).
    let roll: DiceGameController.Roll?
    /// Normalized felt anchor of the rolling seat (spawn edge).
    let anchor: CGPoint
    /// Manual/auto cup loading, table-side: which seat (if any) currently
    /// has a cup open and waiting, how many dice it still needs, and the
    /// cup mouth's on-screen drop zone. `mouthScreen` lives in the SAME
    /// coordinate space as this view (both are unpositioned children of
    /// the same GeometryReader-sized ZStack in DiceTableView), so no
    /// conversion is needed at the call site. All default to "no cup" so
    /// call sites that just want the physics toy (Free Play's sandbox
    /// dice in TableGameView) don't need to know cup loading exists.
    var cupSeat: Int? = nil
    var requiredCount: Int = 0
    var loadedCount: Int = 0
    var autoCup: Bool = false
    var mouthScreen: CGPoint? = nil
    /// Fired once per die that lands in the cup (drag-drop OR auto-glide).
    var onDieLoaded: (Int) -> Void = { _ in }
    /// Called exactly once per roll id, on the main queue, with the faces
    /// physics settled on (in die order).
    let onResult: (_ rollID: Int, _ faces: [LcrFace]) -> Void

    func makeUIView(context: Context) -> DiceSCNView {
        let view = DiceSCNView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: DiceSCNView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.onDieLoaded = onDieLoaded
        context.coordinator.updateCupLoading(seat: cupSeat, required: requiredCount,
                                             loaded: loadedCount, autoCup: autoCup,
                                             mouthScreen: mouthScreen)
        context.coordinator.requestRoll(roll, anchor: anchor)
    }

    func makeCoordinator() -> DiceTableSceneCoordinator { DiceTableSceneCoordinator() }
}

/// SCNView that tells its coordinator when its size is finally known —
/// walls and camera framing depend on the real bounds — and gates its own
/// hit-testing so it only ever "claims" a touch that's actually dragging a
/// real die. Every other touch (dead felt, plates, coins) falls straight
/// through to the SwiftUI layers underneath, exactly as when this view
/// was fully non-interactive.
final class DiceSCNView: SCNView {
    var onLayout: ((CGSize) -> Void)?
    /// Returns whether `point` (in this view's own coordinate space)
    /// should be handled here at all. `nil`/false → `hitTest` returns nil,
    /// so UIKit keeps looking at whatever's behind this view. `phase` is
    /// the touch's own phase (when derivable) — passed through so the
    /// coordinator can throttle its expensive SceneKit ray-cast to fresh
    /// touches only (see `DiceTableSceneCoordinator.shouldClaim`).
    var hitTestProbe: ((CGPoint, UITouch.Phase?) -> Bool)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let phase = event?.allTouches?.first?.phase
        guard hitTestProbe?(point, phase) == true else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Owns the SceneKit world for the table dice. All scene mutations happen
/// on the main queue; the render delegate only reads physics state and
/// flags settlement.
final class DiceTableSceneCoordinator: NSObject, SCNSceneRendererDelegate,
                                       SCNPhysicsContactDelegate {
    var onResult: ((Int, [LcrFace]) -> Void)?
    var onDieLoaded: ((Int) -> Void)?

    private let scene = SCNScene()
    private weak var view: DiceSCNView?
    private let cameraNode = SCNNode()
    private var wallNodes: [SCNNode] = []

    /// The persistent pool: up to 3 real dice that live for the entire
    /// game. `poolStates[i]` tracks what die `pool[i]` is doing right now;
    /// `poolShadows[i]` is its tracked contact shadow. Nothing here is
    /// ever destroyed and recreated mid-game — loading, pouring, and
    /// settling all just move the SAME nodes around and flip their state,
    /// which is what makes "the same dice persist across turns" true.
    private enum PoolDieState: Equatable {
        case resting     // free on the felt, dynamic physics, draggable
        case dragging    // a finger (or the auto-glide) has it, kinematic
        case loaded(seat: Int) // hidden inside a seat's cup, waiting to be thrown
        case flying      // mid-roll, dynamic physics, being read for a result
    }
    private var pool: [DieNode] = []
    private var poolStates: [PoolDieState] = []
    private var poolShadows: [DieShadowNode] = []
    /// Per-pool-index last world position `trackAllShadows` actually
    /// re-solved a shadow transform for — lets it detect "this die hasn't
    /// moved since last frame" (a table nudge/jolt can set a `.resting` die
    /// drifting again without changing its `PoolDieState`, so this checks
    /// real motion rather than trusting the category). See
    /// `trackAllShadows`'s perf doc. `.greatestFiniteMagnitude` sentinel so
    /// a freshly spawned die's first frame always tracks.
    private var lastShadowPosition: [simd_float3] = []

    /// The subset of `pool` actually in flight for the CURRENT roll (by
    /// pool index) — settle detection, resistance tiers, and face-reading
    /// all operate on just these, same as the old per-roll `dice` array.
    private var activeIndices: [Int] = []
    private var activeDice: [DieNode] { activeIndices.map { pool[$0] } }

    // World framing (recomputed from the view size).
    private var worldWidth: CGFloat = 50
    private var worldHeight: CGFloat = 38
    private var wallInset: CGFloat = 2
    /// On-screen size of one die, points. The world is scaled so a die
    /// always renders about this big regardless of device.
    private let dieScreenPoints: CGFloat = 54
    /// Felt inset in points (matches TableSurface's rail).
    private let feltInsetPoints: CGFloat = 52
    private let cameraTilt: CGFloat = 12 * .pi / 180

    // Roll lifecycle. `pending*` handles a roll that arrives pre-layout.
    private var lastRollID = 0
    private var activeRollID: Int?
    private var rollStartTime: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var settledSince: TimeInterval?
    private var nudged = false
    private var reported = false
    private var pendingRoll: DiceGameController.Roll?
    private var pendingAnchor = CGPoint(x: 0.5, y: 0.94)
    /// Last frame's presentation pose per die — settle detection measures
    /// OBSERVED motion (SCNPhysicsBody's velocity getters don't track the
    /// live simulation, they just echo whatever was last assigned).
    private var lastPoses: [(position: simd_float3, orientation: simd_quatf)] = []
    /// Per-die rolling-resistance tier (0 fast/airborne, 1 slowing,
    /// 2 dying). Felt's rolling resistance RISES as a die slows — that's
    /// why real dice tumble-stop instead of gliding — and Bullet's constant
    /// coefficients can't express it, so the render loop ramps them.
    private var resistanceTiers: [Int] = []

    private var contactThrottle: DiceContactThrottle?

    /// Reduce Motion: captured per-roll (non-View code, so we read the
    /// system flag directly rather than threading an environment value
    /// through UIViewRepresentable). Physics still fully decides the
    /// result — only the visible tumble is hidden and the reveal shortened.
    private var rollMotionReduced = false

    // MARK: cup loading (drag-drop + auto-glide)

    private var dragSeat: Int?
    private var mouthScreen: CGPoint?
    private var draggingIndex: Int?
    /// Guards the auto-cup glide sequence to firing exactly once per human
    /// turn (reset whenever `cupSeat` goes back to nil).
    private var autoLoadedForTurnSeat: Int?
    private var autoGlideActive = false
    private static let dropCaptureRadius: CGFloat = 64

    // MARK: setup

    /// The one live table scene, reachable by TableMotion wiring.
    static weak var activeCoordinator: DiceTableSceneCoordinator?

    /// A real thump on the physical table. Mid-roll: full re-tumble — the
    /// slam legitimately changes the outcome (physics reports faces only
    /// after settling, so chaos stays fair). Settled: a vertical hop with
    /// a whisper of spin — dice jump but land showing the same faces,
    /// because those faces are already the recorded result.
    func jolt(intensity: Double) {
        let midRoll = activeRollID != nil && !reported
        let targets = liveDice()
        if midRoll {
            // A slam re-loosens the felt grip: back to tier 0 so the
            // re-tumble carries like a fresh throw.
            resistanceTiers = Array(repeating: 0, count: activeIndices.count)
            for die in targets {
                die.physicsBody?.damping = 0.1
                die.physicsBody?.angularDamping = Dice3D.angularDamping
                die.physicsBody?.rollingFriction = Dice3D.rollingFriction
            }
        }
        for die in targets {
            guard let body = die.physicsBody else { continue }
            body.isAffectedByGravity = true
            if midRoll {
                body.applyForce(SCNVector3(
                    Float.random(in: -1...1) * Float(intensity) * 0.06,
                    Float(0.05 + 0.05 * intensity),
                    Float.random(in: -1...1) * Float(intensity) * 0.06), asImpulse: true)
                body.applyTorque(SCNVector4(
                    Float.random(in: -1...1), Float.random(in: -1...1),
                    Float.random(in: -1...1), Float(0.02 + 0.02 * intensity)), asImpulse: true)
                settledSince = nil
            } else {
                body.applyForce(SCNVector3(0, Float(0.03 + 0.025 * intensity), 0),
                                asImpulse: true)
                body.applyTorque(SCNVector4(0, 1, 0, Float(0.004 * intensity)),
                                 asImpulse: true)
            }
        }
    }

    /// Gentle handling: dice slide a touch with the iPad's motion.
    func nudge(direction: CGVector, strength: Double) {
        for die in liveDice() {
            die.physicsBody?.applyForce(SCNVector3(
                Float(direction.dx) * Float(strength) * 0.012,
                0,
                Float(direction.dy) * Float(strength) * 0.012), asImpulse: true)
        }
    }

    /// Dice a table jolt/nudge should actually touch: not hidden inside a
    /// cup, and not mid-drag under someone's finger.
    private func liveDice() -> [DieNode] {
        pool.indices.compactMap { index in
            switch poolStates[index] {
            case .loaded, .dragging: return nil
            case .resting, .flying: return pool[index]
            }
        }
    }

    func attach(to view: DiceSCNView) {
        Self.activeCoordinator = self
        self.view = view
        view.scene = scene
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode =
            UIDevice.current.userInterfaceIdiom == .pad ? .multisampling4X : .multisampling2X
        view.rendersContinuously = false
        view.delegate = self
        view.onLayout = { [weak self] size in self?.rebuildWorld(for: size) }
        view.hitTestProbe = { [weak self] point, phase in self?.shouldClaim(point, phase: phase) ?? false }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        scene.background.contents = UIColor.clear
        scene.physicsWorld.gravity = DiceScenePhysics.gravity
        // Dice are tiny fast bodies: a 120Hz solver step keeps corner
        // impacts crisp (60Hz visibly tunnels energy on chamfered edges).
        scene.physicsWorld.timeStep = 1.0 / 120.0
        scene.physicsWorld.contactDelegate = self

        scene.rootNode.addChildNode(DiceScenePhysics.physicsFloor())
        DiceScenePhysics.addLights(to: scene, shadowScale: 40)

        cameraNode.camera = {
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.zNear = 1
            camera.zFar = 200
            return camera
        }()
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        contactThrottle = DiceContactThrottle { strength, contactClass in
            guard strength > 0.08 else { return }
            TableSFX.shared.playDiceContact(contactClass, strength: strength)
        }
    }

    /// Size the world so one die is ~54pt on screen, aim the camera nearly
    /// top-down with a 12° tilt (cube depth reads), and rebuild the rails.
    private func rebuildWorld(for size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let newHeight = size.height * Dice3D.side / dieScreenPoints
        let newWidth = newHeight * size.width / size.height
        // Avoid churn on sub-point layout wiggles.
        if abs(newHeight - worldHeight) > 0.5 || abs(newWidth - worldWidth) > 0.5 || wallNodes.isEmpty {
            worldHeight = newHeight
            worldWidth = newWidth
            wallInset = feltInsetPoints * newHeight / size.height
            rebuildWalls()
        }

        let distance: CGFloat = 60
        cameraNode.position = SCNVector3(0,
                                         distance * cos(cameraTilt),
                                         distance * sin(cameraTilt))
        cameraNode.eulerAngles = SCNVector3(-(CGFloat.pi / 2 - cameraTilt), 0, 0)
        cameraNode.camera?.orthographicScale = Double(worldHeight / 2 * cos(cameraTilt))

        ensurePool()

        if let pending = pendingRoll {
            pendingRoll = nil
            launch(pending, anchor: pendingAnchor)
        }
    }

    private func rebuildWalls() {
        wallNodes.forEach { $0.removeFromParentNode() }
        wallNodes = []
        let halfW = worldWidth / 2 - wallInset
        let halfH = worldHeight / 2 - wallInset
        let thickness: CGFloat = 3
        let height: CGFloat = 22 // tall enough that arced throws can't hop the rail
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // (boxW, boxL, x, z, _)
            (worldWidth + 8, thickness, 0, -(halfH + thickness / 2), 0),
            (worldWidth + 8, thickness, 0, halfH + thickness / 2, 0),
            (thickness, worldHeight + 8, -(halfW + thickness / 2), 0, 0),
            (thickness, worldHeight + 8, halfW + thickness / 2, 0, 0),
        ]
        for (w, l, x, z, _) in specs {
            // Named so DiceContactThrottle can tell a rail knock from a
            // felt landing by node identity alone.
            let wall = DiceScenePhysics.boundsNode(
                width: w, height: height, length: l,
                position: SCNVector3(x, height / 2, z), name: "rail-wall")
            scene.rootNode.addChildNode(wall)
            wallNodes.append(wall)
        }
    }

    /// Builds the 3-die pool the first time the world is sized, resting at
    /// the table center — the "fresh set of dice sitting at the pot,
    /// waiting to be loaded" a brand-new game starts with. Every later
    /// roll/load/pour just moves these SAME three nodes; nothing here ever
    /// gets destroyed and recreated again.
    private func ensurePool() {
        guard pool.isEmpty else { return }
        for index in 0..<3 {
            let die = DieNode(lcrDie: index)
            let lateral = (CGFloat(index) - 1) * Dice3D.side * 1.3
            die.position = SCNVector3(lateral, Dice3D.side * 3 + CGFloat(index) * 0.5,
                                      CGFloat.random(in: -0.8...0.8))
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))
            scene.rootNode.addChildNode(die)
            pool.append(die)
            poolStates.append(.resting)
            let shadow = DieShadowNode()
            scene.rootNode.addChildNode(shadow)
            poolShadows.append(shadow)
            lastShadowPosition.append(simd_float3(repeating: .greatestFiniteMagnitude))
        }
        // Freshly spawned above the floor — needs a moment of real physics
        // ticks to actually fall and settle (see beginSettleWindow's doc).
        beginSettleWindow()
    }

    // MARK: cup loading — drag-drop

    /// Called from `updateUIView` every SwiftUI pass with the current cup
    /// state. Cheap and idempotent; the actual work (starting an auto
    /// glide) only fires on a genuine turn change.
    func updateCupLoading(seat: Int?, required: Int, loaded: Int, autoCup: Bool, mouthScreen: CGPoint?) {
        self.mouthScreen = mouthScreen
        if autoCup {
            dragSeat = nil
            if seat == nil {
                autoLoadedForTurnSeat = nil
            } else if let seat, loaded < required, autoLoadedForTurnSeat != seat, mouthScreen != nil {
                autoLoadedForTurnSeat = seat
                autoGlideSequence(seat: seat, count: required)
            }
        } else {
            dragSeat = (seat != nil && loaded < required) ? seat : nil
            autoLoadedForTurnSeat = nil
        }
        updateRenderingContinuity()
    }

    /// Cache for `shouldClaim`'s throttle: the last touch's verdict, and
    /// whether it was actually computed from a real ray-cast (vs. just
    /// carried over). See `shouldClaim`'s perf doc.
    private var lastProbeComputed = false
    private var lastProbeResult = false

    /// Whether `point` (view-local) should be handled by this view at all:
    /// either a drag is already underway (keep routing it here through
    /// `.changed`/`.ended`) or it's landing fresh on a currently-draggable
    /// resting die. Anything else — dead felt, a plate, a coin — is
    /// waved through to whatever's behind this view.
    ///
    /// While a cup is open (`dragSeat != nil`) this transparent view covers
    /// the ENTIRE felt, so UIKit/SwiftUI's own hit-test probing — which can
    /// fire more than once per touch while gesture recognizers compete,
    /// not just once at touch-down — ran a full `SCNView.hitTest` (a
    /// ray-cast against the whole scene graph: walls, floor, every pool
    /// die) on EVERY probe, for every touch anywhere on the table: a dead-
    /// felt tap, a plate tap, another seat's coin drag. That's the
    /// intermittent cup-loading stutter reported ("not all the time, but
    /// sometimes" — exactly what you'd expect from a cost that scales with
    /// how much else is happening on screen at once, not with the cup
    /// itself). Fix: only run the real ray-cast on a fresh `.began` touch;
    /// every other phase of that SAME touch reuses its cached verdict, and
    /// `.ended`/`.cancelled` clears the cache so the NEXT touch is fresh.
    private func shouldClaim(_ point: CGPoint, phase: UITouch.Phase?) -> Bool {
        if draggingIndex != nil { return true }
        guard dragSeat != nil, let view else { return false }
        switch phase {
        case .ended, .cancelled:
            lastProbeComputed = false
        case .began, .none:
            break // always recompute — a fresh (or unidentifiable) touch needs the real test
        default:
            if lastProbeComputed { return lastProbeResult }
        }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        let result = hits.first
            .flatMap { hit in pool.firstIndex(where: { $0 === hit.node }) }
            .map { poolStates[$0] == .resting } ?? false
        lastProbeComputed = true
        lastProbeResult = result
        return result
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        let point = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            beginDrag(at: point)
        case .changed:
            updateDrag(at: point)
        case .ended, .cancelled, .failed:
            endDrag(at: point)
        default:
            break
        }
    }

    private func beginDrag(at point: CGPoint) {
        guard let view, draggingIndex == nil, dragSeat != nil else { return }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first, let index = pool.firstIndex(where: { $0 === hit.node }),
              poolStates[index] == .resting else { return }
        draggingIndex = index
        poolStates[index] = .dragging
        pool[index].physicsBody?.type = .kinematic
        Haptics.tick()
        updateRenderingContinuity()
    }

    private func updateDrag(at point: CGPoint) {
        guard let index = draggingIndex, let view,
              let target = feltPoint(forScreen: point, in: view, liftedY: 1.6) else { return }
        pool[index].position = target
    }

    private func endDrag(at point: CGPoint) {
        guard let index = draggingIndex else { return }
        draggingIndex = nil
        guard let seat = dragSeat,
              let mouthScreen,
              hypot(point.x - mouthScreen.x, point.y - mouthScreen.y) <= Self.dropCaptureRadius else {
            // Missed the mouth (or the cup closed mid-drag) — the die just
            // falls back to the felt from wherever it was released.
            poolStates[index] = .resting
            pool[index].physicsBody?.type = .dynamic
            beginSettleWindow(0.6)
            return
        }
        // Not physics-driven (the die is kinematic through the whole drop-
        // in animation), but a short forced-continuous window guarantees
        // SceneKit actually renders the animated frames even though
        // nothing else currently demands continuous rendering.
        beginSettleWindow(0.4)
        loadDie(index: index, seat: seat)
    }

    /// The auto-cup visual: dice already resting on the felt glide into
    /// the cup by themselves, one at a time, at turn start — same drop-in
    /// animation a manual drag ends with, just triggered by code instead
    /// of a finger. Purely cosmetic (DiceGameController.canRoll already
    /// waives the load requirement in auto-cup mode) but keeps the two
    /// modes visually consistent, per owner feedback.
    private func autoGlideSequence(seat: Int, count: Int) {
        let indices = Array(poolStates.indices.filter { poolStates[$0] == .resting }.prefix(count))
        guard !indices.isEmpty else { return }
        autoGlideActive = true
        updateRenderingContinuity()
        for (step, index) in indices.enumerated() {
            let delay = 0.35 + Double(step) * 0.32
            let isLast = step == indices.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.poolStates.indices.contains(index),
                      self.poolStates[index] == .resting else { return }
                self.poolStates[index] = .dragging
                self.pool[index].physicsBody?.type = .kinematic
                self.loadDie(index: index, seat: seat, isLastInAutoSequence: isLast)
            }
        }
    }

    /// Animates `pool[index]` sliding down into the cup mouth and hides it
    /// there (state → `.loaded`) — the die "leaves the scene" exactly as
    /// the owner asked for, rather than a synthetic icon standing in for
    /// it. `launch(_:anchor:)` is what brings it back.
    private func loadDie(index: Int, seat: Int, isLastInAutoSequence: Bool = false) {
        guard pool.indices.contains(index) else { return }
        let die = pool[index]
        poolStates[index] = .loaded(seat: seat)
        die.physicsBody?.type = .kinematic
        guard let view, let mouthScreen,
              let target = feltPoint(forScreen: mouthScreen, in: view, liftedY: 0.5) else {
            // No mouth to aim at (shouldn't happen while a cup is showing)
            // — hide it in place rather than leaving a half-dragged die
            // stranded mid-air.
            die.isHidden = true
            DispatchQueue.main.async { [weak self] in self?.onDieLoaded?(seat) }
            return
        }
        TableSFX.shared.playDiceContact(.die, strength: 0.45)
        Haptics.arm()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.22
        SCNTransaction.completionBlock = { [weak self] in
            DispatchQueue.main.async {
                die.isHidden = true
                die.position = SCNVector3(0, -400, 0) // tucked well out of the way
                die.scale = SCNVector3(1, 1, 1)
                die.opacity = 1
                self?.onDieLoaded?(seat)
                if isLastInAutoSequence {
                    self?.autoGlideActive = false
                    self?.updateRenderingContinuity()
                }
            }
        }
        die.position = target
        die.scale = SCNVector3(0.22, 0.22, 0.22)
        die.opacity = 0
        SCNTransaction.commit()
    }

    /// Projects a view-local screen point onto the felt-height plane
    /// (`liftedY` above the physics floor) using the camera's own
    /// projection — works for the table's orthographic camera the same
    /// way it would for a perspective one.
    private func feltPoint(forScreen point: CGPoint, in view: SCNView, liftedY: CGFloat) -> SCNVector3? {
        let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let dx = far.x - near.x, dy = far.y - near.y, dz = far.z - near.z
        guard abs(dy) > 0.0001 else { return nil }
        let targetY = Float(liftedY)
        let t = (targetY - near.y) / dy
        return SCNVector3(near.x + dx * t, targetY, near.z + dz * t)
    }

    /// Rendering is normally OFF between rolls (perf) — but SceneKit's
    /// physics only steps forward when a frame actually renders, so any
    /// die that needs to FALL (freshly spawned into the pool, or dropped
    /// back after a drag misses the cup) needs a brief forced-continuous
    /// window or it just hangs frozen mid-air until the next unrelated
    /// render happens to fire.
    private var settleWindowUntil: Date?

    private func beginSettleWindow(_ duration: TimeInterval = 1.4) {
        let deadline = Date().addingTimeInterval(duration)
        if settleWindowUntil.map({ deadline > $0 }) ?? true {
            settleWindowUntil = deadline
        }
        updateRenderingContinuity()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.updateRenderingContinuity()
        }
    }

    private func updateRenderingContinuity() {
        let settling = settleWindowUntil.map { $0 > Date() } ?? false
        view?.rendersContinuously = activeRollID != nil || draggingIndex != nil
            || autoGlideActive || settling
    }

    // MARK: rolling

    /// Idempotent per roll id — updateUIView calls this on every SwiftUI
    /// pass, only a NEW id launches dice.
    func requestRoll(_ roll: DiceGameController.Roll?, anchor: CGPoint) {
        guard let roll, roll.id != lastRollID else { return }
        lastRollID = roll.id
        guard let view, view.bounds.width > 10, !pool.isEmpty else {
            pendingRoll = roll
            pendingAnchor = anchor
            return
        }
        launch(roll, anchor: anchor)
    }

    private func launch(_ roll: DiceGameController.Roll, anchor: CGPoint) {
        ensurePool()
        guard !pool.isEmpty else {
            pendingRoll = roll
            pendingAnchor = anchor
            return
        }

        // Pick which pool dice actually throw: the ones this seat loaded
        // into its cup, first — that's "the same dice the roller just
        // dragged in" pouring back out. If manual loading never happened
        // (a bot, a watchdog fallback, or auto-cup's cosmetic glide still
        // catching up), top up from whatever's simply resting on the felt
        // so a roll can never soft-lock waiting on a drag that isn't
        // coming.
        var chosen = poolStates.indices.filter {
            if case .loaded(let seat) = poolStates[$0] { return seat == roll.seat }
            return false
        }
        if chosen.count < roll.count {
            let extra = poolStates.indices.filter { idx in
                !chosen.contains(idx) && poolStates[idx] == .resting
            }
            chosen.append(contentsOf: extra.prefix(roll.count - chosen.count))
        }
        if chosen.count < roll.count {
            // Still short (e.g. a die is mid-drag elsewhere) — grab
            // whatever's left rather than leave the roll stuck.
            let leftover = poolStates.indices.filter { !chosen.contains($0) }
            chosen.append(contentsOf: leftover.prefix(roll.count - chosen.count))
        }
        chosen = Array(chosen.prefix(roll.count).sorted())

        activeIndices = chosen
        for index in activeIndices { poolStates[index] = .flying }
        let dice = activeDice

        // Reduce Motion: physics still runs the tumble (it's what decides
        // the result), but nobody has to watch it — dice stay invisible
        // until settled, and the simulation clock runs fast so the wait is
        // short. finishRoll() below fades them straight in on the result.
        rollMotionReduced = UIAccessibility.isReduceMotionEnabled
        scene.physicsWorld.speed = rollMotionReduced ? 3.0 : 1.0

        // Entry point: ABOVE the roller's edge of the felt, clamped inside
        // the rails. Real dice arrive from a cup held over the table: they
        // spawn high near the roller, travel toward the middle AND down,
        // and their first contact with the felt is a BOUNCE mid-tumble —
        // never a flat puck-slide in from the rail. Since these are the
        // SAME dice that were just sitting hidden in that roller's cup,
        // this entry point IS the cup's position — pouring them back out.
        let halfW = worldWidth / 2 - wallInset - Dice3D.side
        let halfH = worldHeight / 2 - wallInset - Dice3D.side
        // The cup is tipped out OVER the felt, not at the rim: pull the
        // entry point ~25% toward center so first contact lands on open
        // felt instead of against the roller's own plate.
        let entryX = max(-halfW, min(halfW, (anchor.x - 0.5) * worldWidth * 0.75))
        let entryZ = max(-halfH, min(halfH, (anchor.y - 0.5) * worldHeight * 0.75))
        let heading = atan2(-entryZ, -entryX) // toward world center

        let norm = min(1, max(0, (roll.intensity - 0.3) / 1.2))
        // A harder pour = flatter, faster arc from a little higher up.
        let baseSpeed = 10.0 + 12.0 * norm         // horizontal carry
        let dropHeight = 26.0 + 10.0 * norm        // cup height above the felt
        let plungeSpeed = 22.0 + 10.0 * norm       // downward launch (cup tips out)

        for (i, die) in dice.enumerated() {
            let poolIndex = activeIndices[i]
            die.physicsBody?.type = .dynamic
            die.isHidden = false
            die.scale = SCNVector3(1, 1, 1)
            die.opacity = rollMotionReduced ? 0 : 1
            // Fan the dice out perpendicular to the throw line, and stagger
            // their heights slightly — a cupful never leaves as one layer.
            let lateral = (CGFloat(i) - CGFloat(dice.count - 1) / 2) * Dice3D.side * 1.4
            die.position = SCNVector3(
                entryX + -sin(heading) * lateral + .random(in: -0.5...0.5),
                dropHeight + CGFloat(i) * Dice3D.side * 0.8 + .random(in: -1.5...1.5),
                entryZ + cos(heading) * lateral + .random(in: -0.5...0.5))
            // Random initial orientation so no two throws start alike.
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))

            let aim = heading + CGFloat.random(in: -0.16...0.16)
                + (CGFloat(i) - CGFloat(dice.count - 1) / 2) * 0.13
            let speed = baseSpeed * CGFloat.random(in: 0.85...1.15)
            die.physicsBody?.velocity = SCNVector3(
                cos(aim) * speed,
                -plungeSpeed * CGFloat.random(in: 0.85...1.15),
                sin(aim) * speed)
            // Strong tumble: faces visibly cycle because the cube really spins.
            let spin = CGFloat.random(in: 18...34)
            let ax = CGFloat.random(in: -1...1)
            let ay = CGFloat.random(in: -1...1)
            let az = CGFloat.random(in: -1...1)
            let length = max(0.001, sqrt(ax * ax + ay * ay + az * az))
            die.physicsBody?.angularVelocity = SCNVector4(ax / length, ay / length,
                                                          az / length, spin)
            die.physicsBody?.damping = 0.1
            die.physicsBody?.angularDamping = Dice3D.angularDamping
            die.physicsBody?.rollingFriction = Dice3D.rollingFriction

            let shadow = poolShadows[poolIndex]
            shadow.isHidden = rollMotionReduced
            shadow.opacity = rollMotionReduced ? 0 : shadow.opacity
        }

        activeRollID = roll.id
        rollStartTime = nil
        lastFrameTime = nil
        settledSince = nil
        nudged = false
        reported = false
        lastPoses = dice.map { ($0.presentation.simdWorldPosition,
                                $0.presentation.simdWorldOrientation) }
        resistanceTiers = Array(repeating: 0, count: dice.count)
        updateRenderingContinuity()
    }

    // MARK: settle detection (render delegate — no allocations here)

    /// A die is "settled" when its OBSERVED frame-to-frame motion (from
    /// the presentation transform — the physics-animated pose) stays under
    /// tiny linear/angular rates for 0.3s straight.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        trackAllShadows()
        guard activeRollID != nil, !reported, activeIndices.count == lastPoses.count else { return }
        let dice = activeDice
        if rollStartTime == nil { rollStartTime = time }
        let elapsed = time - (rollStartTime ?? time)
        guard let last = lastFrameTime, time > last else {
            lastFrameTime = time
            return
        }
        let dt = Float(time - last)
        lastFrameTime = time

        var maxLinear: Float = 0   // units/s
        var maxAngular: Float = 0  // rad/s
        var minFlatness: Float = 1
        var tierChanges: [(index: Int, tier: Int)] = []
        let groundedY = Float(Dice3D.side) * 0.9
        for index in dice.indices {
            let node = dice[index].presentation
            let position = node.simdWorldPosition
            let orientation = node.simdWorldOrientation
            let previous = lastPoses[index]
            let linear = simd_distance(position, previous.position) / dt
            maxLinear = max(maxLinear, linear)
            let dot = min(1, abs(simd_dot(orientation.vector, previous.orientation.vector)))
            maxAngular = max(maxAngular, 2 * acos(dot) / dt)
            minFlatness = min(minFlatness, DieFaceReader.flatness(of: dice[index]))
            lastPoses[index] = (position, orientation)

            // Speed-staged rolling resistance: airborne/fast dice carry,
            // grounded slowing dice bite, near-stopped dice die on the spot.
            // Tiers only ever escalate within a roll (no flicker back to
            // "loose" from a bounce wobble).
            let tier: Int
            if position.y > groundedY || linear > 4.5 {
                tier = 0
            } else if linear > 1.8 {
                tier = 1
            } else {
                tier = 2
            }
            if index < resistanceTiers.count, tier > resistanceTiers[index] {
                resistanceTiers[index] = tier
                tierChanges.append((index, tier))
            }
        }
        if !tierChanges.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reported else { return }
                let dice = self.activeDice
                for change in tierChanges where dice.indices.contains(change.index) {
                    guard let body = dice[change.index].physicsBody else { continue }
                    switch change.tier {
                    case 1:
                        body.damping = 0.22
                        body.angularDamping = 0.30
                        body.rollingFriction = 0.22
                    default:
                        // Tier 2 is "this die is done" — the settle tick
                        // hooks right off that existing detection instead
                        // of adding a second one. Ties only ever escalate
                        // once per die per roll, so this fires exactly
                        // once as each die individually comes to rest —
                        // real dice don't all stop on the same frame, and
                        // now neither does the sound.
                        body.damping = 0.60
                        body.angularDamping = 0.75
                        body.rollingFriction = 0.80
                        TableSFX.shared.playDiceContact(.settle, strength: 0.3)
                    }
                }
            }
        }

        // Settled = barely moving AND every die lying flat on a face. The
        // flatness gate matters: a die creep-rolling just under the rate
        // thresholds could otherwise be read one face too early — and the
        // read IS the game result. (Ignore the first beat — freshly
        // spawned dice register no delta until the physics world picks
        // them up.)
        let calm = elapsed > 0.4 && maxLinear < 0.45 && maxAngular < 0.45
            && minFlatness > 0.94
        if calm {
            if settledSince == nil { settledSince = time }
        } else {
            settledSince = nil
        }

        let settledFor = settledSince.map { time - $0 } ?? 0
        if settledFor >= 0.3 {
            finishRoll()
            return
        }

        // Time budget: at 3.2s give any die still fidgeting (or cocked
        // against a rail) one tiny settling shove; at 5s read regardless.
        // Real dice are done ~1.5s after first contact — anything past
        // this budget is physics noise, not drama.
        if elapsed > 3.2, !nudged {
            nudged = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reported else { return }
                for die in self.activeDice where DieFaceReader.flatness(of: die) < 0.94 {
                    die.physicsBody?.velocity = SCNVector3(0, -1.5, 0)
                    die.physicsBody?.angularVelocity = SCNVector4(
                        1, 0, 0, CGFloat.random(in: 0.8...1.6))
                }
            }
        }
        if elapsed > 5.0 {
            finishRoll()
        }
    }

    /// Every pool die's contact shadow, tracked while it's visible —
    /// resting dice sit on the felt permanently now (not just mid-roll),
    /// and a dragged/flying die's shadow needs to follow it every frame.
    /// A STILL die, though, isn't moving — `renderer(_:updateAtTime:)`
    /// (which calls this) runs on every rendered frame, and during a cup
    /// load (`rendersContinuously` forced on for the load animation, see
    /// `updateRenderingContinuity`) that's a real frame rate, not an
    /// occasional one — so re-solving a shadow's transform for dice that
    /// haven't budged was pure waste stacking up with everything else
    /// competing for that frame (see `shouldClaim`'s perf doc for the
    /// other half of the same "sometimes slow" report). Fix: skip the
    /// `track()` call (position/scale/opacity writes) for any die that
    /// hasn't actually moved since the last frame — driven by real
    /// position deltas rather than `PoolDieState`, so a table nudge/jolt
    /// waking a `.resting` die back up (its state never changes) still
    /// gets its shadow updated correctly.
    private func trackAllShadows() {
        let floorY = Float(Dice3D.side / 2)
        for index in pool.indices where poolShadows.indices.contains(index) {
            let die = pool[index]
            let shadow = poolShadows[index]
            shadow.isHidden = die.isHidden
            guard !die.isHidden else { continue }
            let position = die.presentation.simdWorldPosition
            if index < lastShadowPosition.count {
                guard simd_distance(position, lastShadowPosition[index]) > 0.006 else { continue }
                lastShadowPosition[index] = position
            }
            shadow.track(die, floorY: floorY)
        }
    }

    /// Physics has spoken: read the up-faces and report exactly once. The
    /// bodies are frozen at the same moment so no die can tip to another
    /// face after its value entered the game.
    private func finishRoll() {
        guard !reported, let rollID = activeRollID else { return }
        reported = true
        let dice = activeDice
        let faces = dice.map { DieFaceReader.upFace(of: $0) }
        #if DEBUG
        let elapsed = (lastFrameTime ?? 0) - (rollStartTime ?? 0)
        NSLog("Dice3D roll %d settled in %.2fs: %@", rollID, elapsed,
              faces.map(\.rawValue).joined(separator: ","))
        #endif
        let settledIndices = activeIndices
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (i, die) in dice.enumerated() {
                die.physicsBody?.velocity = SCNVector3(0, 0, 0)
                die.physicsBody?.angularVelocity = SCNVector4(0, 0, 0, 0)
                die.physicsBody?.clearAllForces()
                // Reduce Motion: the tumble was never shown — reveal the
                // already-settled result with a quick fade instead.
                if self.rollMotionReduced {
                    die.runAction(.fadeIn(duration: 0.2))
                    if i < settledIndices.count, self.poolShadows.indices.contains(settledIndices[i]) {
                        self.poolShadows[settledIndices[i]].runAction(.fadeIn(duration: 0.2))
                    }
                }
            }
            for index in settledIndices where self.poolStates.indices.contains(index) {
                self.poolStates[index] = .resting
            }
            self.activeRollID = nil
            self.activeIndices = []
            self.updateRenderingContinuity()
            self.onResult?(rollID, faces)
        }
    }

    // MARK: contacts → clacks

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        contactThrottle?.register(contact)
    }
}
