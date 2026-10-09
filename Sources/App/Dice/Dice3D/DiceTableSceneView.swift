import SwiftUI
import SceneKit
import Observation

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
    /// How many dice live in the persistent pool this whole game — LCR's
    /// always-3 default keeps every existing call site unchanged; Yahtzee/
    /// Zilch/Shut the Box pass their own `DiceGameConfig.diceCount` (2-6).
    /// Only takes effect the FIRST time the pool is built (see
    /// `DiceTableSceneCoordinator.ensurePool`) — it's a whole-game setting,
    /// not something that changes turn to turn.
    var diceCount: Int = 3
    /// Which face art the pool's dice are built with — LCR's letters/dot
    /// by default, or `.pips` for a standard 1-6 die (see `DieNode`,
    /// `DieFaceReader`). Same "only matters before the pool exists" rule
    /// as `diceCount`.
    var faceStyle: DieFaceStyle = .lcr
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
    /// POUR (night 2): where the roller's cup MOUTH is on screen (same
    /// coordinate space as `mouthScreen`) when a roll launches — dice now
    /// emerge from there instead of from a seat anchor. Optional: when nil
    /// the coordinator uses the last `mouthScreen` it saw for that seat
    /// (it's non-nil all through the loading phase, which always precedes
    /// the roll) and, failing that (bots have no cup), derives it from
    /// `anchor` with the same plate -> cup -> mouth geometry DiceTableView
    /// uses. So existing call sites keep working untouched.
    var pourMouthScreen: CGPoint? = nil
    /// POUR (night 2): how the phone was tilted when it poured, seat-
    /// relative and unit-ish: `dx` -1...1 (+ = the roller's right) steers
    /// the fan left/right (up to ~26 degrees), `dy` -1...1 (+ = away from the
    /// roller, toward the table center) scales the carry (+-15%). nil = no
    /// tilt info on the wire (today's `.dicePour(intensity:)` carries only
    /// intensity): the pour fans straight at the table center and spread
    /// comes from intensity alone. See the report for the wire addition.
    var pourTilt: CGVector? = nil
    /// Fired once per die that lands in the cup (drag-drop OR auto-glide).
    var onDieLoaded: (Int) -> Void = { _ in }
    /// Pool indices a game controller has marked HELD right now (Yahtzee-
    /// style hold, Zilch-style set-aside) — see
    /// `DiceTableSceneCoordinator.setHeld` for the full contract. Empty
    /// default costs LCR nothing: it never sets this.
    var heldIndices: Set<Int> = []
    /// Fired when a RESTING or HELD die is tapped (not dragged) — the
    /// table-side half of the hold/set-aside primitive. `nil` (the
    /// default) means "no game wants taps," which also keeps this view's
    /// hit-testing exactly as expensive as it's always been for LCR and
    /// free play (see `DiceTableSceneCoordinator.shouldClaim`).
    var onDieTapped: ((Int) -> Void)? = nil
    /// Called exactly once per roll id, on the main queue, with each die's
    /// settled result — `.lcr(LcrFace)` for an LCR pool, `.pip(1...6)` for
    /// a pip pool (see `DieResult`), in die order.
    let onResult: (_ rollID: Int, _ results: [DieResult]) -> Void

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
        context.coordinator.onDieTapped = onDieTapped
        context.coordinator.configurePool(diceCount: diceCount, faceStyle: faceStyle)
        context.coordinator.updateCupLoading(seat: cupSeat, required: requiredCount,
                                             loaded: loadedCount, autoCup: autoCup,
                                             mouthScreen: mouthScreen)
        context.coordinator.setHeld(heldIndices)
        context.coordinator.requestRoll(roll, anchor: anchor,
                                        mouth: pourMouthScreen, tilt: pourTilt)
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
    var onResult: ((Int, [DieResult]) -> Void)?
    var onDieLoaded: ((Int) -> Void)?
    /// Table-side half of the hold/set-aside primitive — see `setHeld`.
    /// `nil` (LCR, free play) keeps `shouldClaim`'s hit-testing exactly as
    /// narrow as it's always been.
    var onDieTapped: ((Int) -> Void)?

    private let scene = SCNScene()
    private weak var view: DiceSCNView?
    private let cameraNode = SCNNode()
    private var wallNodes: [SCNNode] = []

    /// Whole-game pool settings, latched in by `configurePool` (called
    /// every SwiftUI pass) and only actually consumed once, by
    /// `ensurePool` the first time the pool is built. LCR's defaults (3,
    /// `.lcr`) reproduce the pool this coordinator has always built.
    private var poolDiceCount = 3
    private var poolFaceStyle: DieFaceStyle = .lcr

    /// The persistent pool: 2-6 real dice (game-dependent — see
    /// `poolDiceCount`) that live for the entire game. `poolStates[i]`
    /// tracks what die `pool[i]` is doing right now; `poolShadows[i]` is
    /// its tracked contact shadow. Nothing here is ever destroyed and
    /// recreated mid-game — loading, pouring, holding, and settling all
    /// just move the SAME nodes around and flip their state, which is what
    /// makes "the same dice persist across turns" true.
    private enum PoolDieState: Equatable {
        case resting     // free on the felt, dynamic physics, draggable
        case dragging    // a finger (or the auto-glide) has it, kinematic
        case loaded(seat: Int) // hidden inside a seat's cup, waiting to be thrown
        case flying      // mid-roll, dynamic physics, being read for a result
        case held        // marked by a game controller — sits in the hold tray, kinematic, excluded from the next launch (see `setHeld`)
    }
    private var pool: [DieNode] = []
    private var poolStates: [PoolDieState] = []
    private var poolShadows: [DieShadowNode] = []
    /// One gold underglow ring per pool die, shown only while that die is
    /// `.held` — see `setHeld`.
    private var poolHoldRings: [DieHoldRingNode] = []
    /// Pool indices currently `.held`, mirroring the last `setHeld(_:)`
    /// call — kept so that call can diff against "what's already true"
    /// instead of re-animating dice that haven't actually changed state.
    private var heldIndices: Set<Int> = []
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
    /// The most recent `anchor` passed to `requestRoll`, kept even when
    /// that particular call didn't launch anything — `heldTraySlot` reuses
    /// it so the hold tray always sits near the CURRENT roller's edge, not
    /// just wherever the last actual throw came from.
    private var lastAnchor = CGPoint(x: 0.5, y: 0.94)
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

    /// Pour (night 2). Last cup-mouth screen point seen per seat while its
    /// cup was open (`updateCupLoading`), reused when that seat's roll
    /// launches — the cup layer is gone by then (rollInFlight hides it).
    private var lastMouthBySeat: [Int: CGPoint] = [:]
    private var pendingMouth: CGPoint?
    private var pendingTilt: CGVector?
    /// Indices (into `activeIndices`) of dice whose staged release from
    /// the cup mouth hasn't fired yet. While non-empty the settle logic
    /// stays out of the way: a die parked hidden at y = -400 is perfectly
    /// "still" and would otherwise read as settled/tier-2.
    private var pendingRelease: Set<Int> = []

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
    /// cup, not mid-drag under someone's finger, and not sitting HELD in
    /// the tray (a real player wouldn't expect a table thump to jostle a
    /// die they've deliberately set aside).
    private func liveDice() -> [DieNode] {
        pool.indices.compactMap { index in
            switch poolStates[index] {
            case .loaded, .dragging, .held: return nil
            case .resting, .flying: return pool[index]
            }
        }
    }

    /// Latches this whole-game pool config in — see the properties' own
    /// doc. Called every SwiftUI pass; cheap (two Int/enum writes) and
    /// only actually consumed the first time `ensurePool` runs, so calling
    /// it repeatedly (or with the same values, as every LCR pass does) is
    /// a no-op in effect.
    func configurePool(diceCount: Int, faceStyle: DieFaceStyle) {
        poolDiceCount = max(1, min(6, diceCount))
        poolFaceStyle = faceStyle
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

        // Hold/set-aside primitive: a TAP (not a drag) on a resting or
        // held die reports back via `onDieTapped`. Harmless to add
        // unconditionally — `shouldClaim` only ever lets a touch reach
        // this view AT ALL when `onDieTapped` is actually wired (or a cup
        // is open), so for LCR/free play (which never set it) this
        // recognizer simply never receives a touch, exactly today's
        // behavior.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)

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
            lastMouthBySeat.removeAll() // screen geometry changed
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
            launch(pending, anchor: pendingAnchor, mouth: pendingMouth, tilt: pendingTilt)
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

    /// Builds the pool (`poolDiceCount` dice, LCR's default 3) the first
    /// time the world is sized, resting at the table center — the "fresh
    /// set of dice sitting at the pot, waiting to be loaded" a brand-new
    /// game starts with. Every later roll/load/pour/hold just moves these
    /// SAME nodes; nothing here ever gets destroyed and recreated again.
    private func ensurePool() {
        guard pool.isEmpty else { return }
        let count = poolDiceCount
        for index in 0..<count {
            let die = poolFaceStyle == .pips ? DieNode(pipDie: index) : DieNode(lcrDie: index)
            let lateral = (CGFloat(index) - CGFloat(count - 1) / 2) * Dice3D.side * 1.3
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
            let ring = DieHoldRingNode()
            scene.rootNode.addChildNode(ring)
            poolHoldRings.append(ring)
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
        if let seat, let mouthScreen { lastMouthBySeat[seat] = mouthScreen }
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
        guard let view else { return false }
        // Same "nothing here wants this touch" short-circuit the cup-
        // loading doc above describes, just widened by one more reason to
        // stay interested: a game controller wired `onDieTapped` (the
        // hold/set-aside primitive). Costs LCR/free play nothing — neither
        // ever sets it, so this reduces to the original `dragSeat != nil`
        // gate for them.
        let tapCapable = onDieTapped != nil
        guard dragSeat != nil || tapCapable else { return false }
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
            .map { index -> Bool in
                if dragSeat != nil, poolStates[index] == .resting { return true }
                if tapCapable, poolStates[index] == .resting || poolStates[index] == .held { return true }
                return false
            } ?? false
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

    /// The tap half of the hold/set-aside primitive: a resting OR held die
    /// tapped (not dragged) reports its pool index to `onDieTapped`.
    /// `onDieTapped == nil` (LCR, free play) short-circuits before doing
    /// any work, and `shouldClaim` already refuses the touch in that case
    /// anyway, so this recognizer never even fires for them.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view, let onDieTapped else { return }
        let point = recognizer.location(in: view)
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first, let index = pool.firstIndex(where: { $0 === hit.node }),
              poolStates[index] == .resting || poolStates[index] == .held else { return }
        Haptics.tick()
        onDieTapped(index)
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
    func requestRoll(_ roll: DiceGameController.Roll?, anchor: CGPoint,
                     mouth: CGPoint? = nil, tilt: CGVector? = nil) {
        // Captured on EVERY pass, not just a launching one — `heldTraySlot`
        // wants the current roller's edge even between rolls (e.g. while a
        // Yahtzee player is still deciding what to hold).
        lastAnchor = anchor
        guard let roll, roll.id != lastRollID else { return }
        lastRollID = roll.id
        guard let view, view.bounds.width > 10, !pool.isEmpty else {
            pendingRoll = roll
            pendingAnchor = anchor
            pendingMouth = mouth
            pendingTilt = tilt
            return
        }
        launch(roll, anchor: anchor, mouth: mouth, tilt: tilt)
    }

    // MARK: pour geometry

    /// The roller's cup mouth, in this view's screen space: explicit
    /// override, else the last mouth seen for that seat, else derived from
    /// the seat anchor with the exact plate -> cup -> mouth math
    /// DiceTableView uses (`cupCenter` + `TableCupView.mouthOffset`).
    private func resolvedMouthScreen(seat: Int, anchor: CGPoint, explicit: CGPoint?,
                                     size: CGSize) -> CGPoint {
        if let explicit { return explicit }
        if let cached = lastMouthBySeat[seat] { return cached }
        let plate = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.47)
        let ox = plate.x - center.x, oy = plate.y - center.y
        let len = max(1, hypot(ox, oy))
        let cup = CGPoint(x: plate.x + ox / len * 92, y: plate.y + oy / len * 92)
        let dLeft = anchor.x, dRight = 1 - anchor.x, dTop = anchor.y, dBottom = 1 - anchor.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        let edge: TableCupView.RailEdge =
            nearest == dBottom ? .bottom : nearest == dTop ? .top : nearest == dLeft ? .left : .right
        let off = TableCupView.mouthOffset(for: edge)
        return CGPoint(x: cup.x + off.dx, y: cup.y + off.dy)
    }

    /// Height of the cup mouth above the felt while pouring, world units
    /// (a die is 2; the cup sprite stands ~3.5 dice tall and tips toward
    /// the table, so the mouth hangs about 3 dice up).
    private static let mouthHeight: CGFloat = 6.0

    private func launch(_ roll: DiceGameController.Roll, anchor: CGPoint,
                        mouth: CGPoint?, tilt: CGVector?) {
        ensurePool()
        guard !pool.isEmpty else {
            pendingRoll = roll
            pendingAnchor = anchor
            pendingMouth = mouth
            pendingTilt = tilt
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
            // whatever's left rather than leave the roll stuck. `.held`
            // dice are excluded even here: "excluded from the next
            // launch" is a hard guarantee for `setHeld`, not a best-effort
            // one, so a Yahtzee reroll can never accidentally scoop up a
            // die the player just locked in.
            let leftover = poolStates.indices.filter { !chosen.contains($0) && poolStates[$0] != .held }
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

        // POUR: dice EMERGE from the roller's cup mouth. Where the mouth is
        // on screen (explicit > remembered from the loading phase > derived
        // from the seat anchor) is unprojected onto the felt at mouth
        // height, then clamped inside the rails — the cup sprite bleeds
        // past the rail, but the invisible walls would shove a die spawned
        // inside them (the clamp moves a spawn at most ~1 die width).
        let halfW = worldWidth / 2 - wallInset - Dice3D.side
        let halfH = worldHeight / 2 - wallInset - Dice3D.side
        let size = view?.bounds.size ?? CGSize(width: 1024, height: 768)
        let mouthScreen = resolvedMouthScreen(seat: roll.seat, anchor: anchor,
                                              explicit: mouth, size: size)
        var mouthWorld = view.flatMap { feltPoint(forScreen: mouthScreen, in: $0,
                                                  liftedY: Self.mouthHeight) }
            ?? SCNVector3(0, Self.mouthHeight, 0)
        mouthWorld.x = Float(max(-halfW, min(halfW, CGFloat(mouthWorld.x))))
        mouthWorld.z = Float(max(-halfH, min(halfH, CGFloat(mouthWorld.z))))
        let mouthX = CGFloat(mouthWorld.x), mouthZ = CGFloat(mouthWorld.z)
        // Toward the table center; the phone's tilt (when the wire carries
        // it) steers the fan up to ~26 degrees to the roller's right/left.
        var heading = atan2(-mouthZ, -mouthX)
        var carry: CGFloat = 1
        if let tilt {
            heading += max(-1, min(1, tilt.dx)) * 0.45
            carry += max(-1, min(1, tilt.dy)) * 0.15
        }

        let norm = min(1, max(0, (roll.intensity - 0.3) / 1.2))
        // Hard pour = faster carry and a wider fan. The dice leave the mouth
        // nearly level (a slight downward tip), NOT plunging from above.
        let baseSpeed = (11.0 + 13.0 * norm) * carry
        let tipSpeed = 2.5 + 3.5 * norm
        let fanStep = 0.09 + 0.07 * norm
        // Staged release: tilt first, then one die at a time, ~75ms apart.
        let firstRelease: TimeInterval = rollMotionReduced ? 0 : 0.22
        let stagger: TimeInterval = rollMotionReduced ? 0 : 0.075

        pendingRelease = Set(dice.indices)
        for (i, die) in dice.enumerated() {
            // Park hidden and inert until its turn out of the mouth.
            die.physicsBody?.type = .kinematic
            die.isHidden = true
            die.position = SCNVector3(0, -400, 0)
            die.scale = SCNVector3(1, 1, 1)
            die.opacity = rollMotionReduced ? 0 : 1
            let poolIndex = activeIndices[i]
            let shadow = poolShadows[poolIndex]
            shadow.isHidden = rollMotionReduced
            shadow.opacity = rollMotionReduced ? 0 : shadow.opacity

            let delay = firstRelease + Double(i) * stagger + Double.random(in: 0...0.02)
            let release = { [weak self] in
                guard let self, self.activeRollID == roll.id, !self.reported,
                      self.pendingRelease.contains(i) else { return }
                if i == 0, norm > 0.55, !self.rollMotionReduced, TableMotion.isEnabled {
                    // A hard pour jolts the table: the same hook a real
                    // knock on the iPad uses (knock SFX + dice re-tumble).
                    TableMotion.shared.onBump?(1.0 + 1.3 * norm)
                }
                self.release(die: die, order: i, of: dice.count, mouthX: mouthX, mouthZ: mouthZ,
                             heading: heading, baseSpeed: baseSpeed, tipSpeed: tipSpeed,
                             fanStep: fanStep)
            }
            if delay <= 0 {
                DispatchQueue.main.async(execute: release) // after activeRollID is set below
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: release)
            }
        }
        if !rollMotionReduced {
            TablePourState.shared.begin(seat: roll.seat, intensity: roll.intensity,
                                        releaseSpan: firstRelease + Double(dice.count) * stagger)
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

    /// One die leaves the cup mouth: placed at the mouth (a hair of
    /// scatter, a slight stagger along the throw line so a cupful isn't one
    /// layer), launched along its own fan angle with a nearly level carry
    /// and a strong random tumble, then handed to physics like any thrown
    /// die. `order`/`of` place it in the fan (centered on `heading`).
    private func release(die: DieNode, order: Int, of count: Int, mouthX: CGFloat, mouthZ: CGFloat,
                         heading: CGFloat, baseSpeed: CGFloat, tipSpeed: CGFloat, fanStep: CGFloat) {
        guard let activeIndex = activeDice.firstIndex(where: { $0 === die }) else { return }
        let aim = heading + (CGFloat(order) - CGFloat(count - 1) / 2) * fanStep
            + CGFloat.random(in: -0.06...0.06)
        let speed = baseSpeed * CGFloat.random(in: 0.88...1.12)
        // A short line out of the mouth: each later die starts a touch
        // further back along the throw line, so they leave in a stream.
        let back = CGFloat(order) * 0.35
        die.physicsBody?.type = .dynamic
        die.isHidden = false
        die.position = SCNVector3(
            mouthX - cos(aim) * back + .random(in: -0.45...0.45),
            Self.mouthHeight + .random(in: -0.4...0.6),
            mouthZ - sin(aim) * back + .random(in: -0.45...0.45))
        die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                     CGFloat.random(in: 0..<(2 * .pi)),
                                     CGFloat.random(in: 0..<(2 * .pi)))
        die.physicsBody?.velocity = SCNVector3(
            cos(aim) * speed,
            -tipSpeed * CGFloat.random(in: 0.8...1.2) + CGFloat.random(in: 0...1.5),
            sin(aim) * speed)
        // Strong tumble: faces visibly cycle because the cube really spins.
        let spin = CGFloat.random(in: 18...34)
        let ax = CGFloat.random(in: -1...1), ay = CGFloat.random(in: -1...1)
        let az = CGFloat.random(in: -1...1)
        let length = max(0.001, sqrt(ax * ax + ay * ay + az * az))
        die.physicsBody?.angularVelocity = SCNVector4(ax / length, ay / length, az / length, spin)
        die.physicsBody?.damping = 0.1
        die.physicsBody?.angularDamping = Dice3D.angularDamping
        die.physicsBody?.rollingFriction = Dice3D.rollingFriction
        if lastPoses.indices.contains(activeIndex) {
            lastPoses[activeIndex] = (die.simdWorldPosition, die.simdWorldOrientation)
        }
        if resistanceTiers.indices.contains(activeIndex) { resistanceTiers[activeIndex] = 0 }
        pendingRelease.remove(order)
        TableSFX.shared.playDiceContact(.die, strength: 0.25)
        beginSettleWindow(0.2)
    }

    // MARK: hold / set-aside primitive

    /// Called every SwiftUI pass with the CURRENT full held set — same
    /// "diff against what's already true" idiom `updateCupLoading` uses
    /// for the cup. Only indices whose membership actually CHANGED this
    /// pass do any work; a repeat call with the same set (every LCR/free-
    /// play pass, since they never populate this) is a cheap no-op.
    ///
    /// A newly-held die goes kinematic and slides into a small tray row
    /// near the current roller's own felt edge (`lastAnchor` — the same
    /// edge the throw entry point and cup mouth already use), with a gold
    /// underglow ring (`DieHoldRingNode`) fading in underneath. A newly-
    /// released index slides back to `.resting` on the open felt with the
    /// ring fading out. Held dice are excluded from the next `launch()`
    /// (see the `.held` guard there) and from jolts/nudges (`liveDice()`);
    /// only ever transitions a die that's actually `.resting` right now —
    /// a game controller marking an in-flight/loaded/dragging index held
    /// is a no-op until that die settles back to `.resting` on its own.
    func setHeld(_ indices: Set<Int>) {
        let clamped = indices.filter { pool.indices.contains($0) }
        guard clamped != heldIndices else { return }
        let newlyHeld = clamped.subtracting(heldIndices)
        let newlyReleased = heldIndices.subtracting(clamped)
        heldIndices = clamped

        for index in newlyHeld where poolStates[index] == .resting {
            poolStates[index] = .held
            pool[index].physicsBody?.type = .kinematic
        }
        for index in newlyReleased where poolStates[index] == .held {
            poolStates[index] = .resting
            pool[index].physicsBody?.type = .dynamic
            if poolHoldRings.indices.contains(index) {
                poolHoldRings[index].opacity = 0
            }
        }
        // Re-lay the WHOLE tray row in stable sorted order on every change
        // (not just the newly-held ones) so held dice never end up
        // overlapping regardless of which order they were held/released in.
        let order = heldIndices.sorted()
        for (slot, index) in order.enumerated() where pool.indices.contains(index) {
            let target = heldTraySlot(order: slot)
            animateHeldDie(pool[index], ring: poolHoldRings.indices.contains(index) ? poolHoldRings[index] : nil,
                          to: target)
        }
        if !newlyHeld.isEmpty || !newlyReleased.isEmpty {
            beginSettleWindow(0.5)
            updateRenderingContinuity()
        }
    }

    /// Where held/set-aside die #`order` (0-based, stable sort of the
    /// currently held pool indices) sits: a short row just inside the felt
    /// from the roller's own edge — the same entry-point math `launch`
    /// uses for `anchor`, just parked at rest height instead of thrown.
    private func heldTraySlot(order: Int) -> SCNVector3 {
        let halfW = worldWidth / 2 - wallInset - Dice3D.side
        let halfH = worldHeight / 2 - wallInset - Dice3D.side
        let baseX = max(-halfW, min(halfW, (lastAnchor.x - 0.5) * worldWidth * 0.6))
        let baseZ = max(-halfH, min(halfH, (lastAnchor.y - 0.5) * worldHeight * 0.6))
        let heading = atan2(-baseZ, -baseX) // toward world center, same convention as launch()
        // Room for up to 6 in a row (Zilch's whole pool), centered on the
        // anchor point.
        let lateral = (CGFloat(order) - 2.5) * Dice3D.side * 1.3
        return SCNVector3(
            baseX + -sin(heading) * lateral,
            Dice3D.side / 2,
            baseZ + cos(heading) * lateral)
    }

    /// Slides a held die (and its ring) to its tray slot over a short
    /// animation — not physics-driven (the die is kinematic through the
    /// whole move), matching `loadDie`'s own cup drop-in animation.
    private func animateHeldDie(_ die: DieNode, ring: DieHoldRingNode?, to position: SCNVector3) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.28
        die.position = position
        ring?.position = SCNVector3(position.x, 0.03, position.z)
        ring?.opacity = 1
        SCNTransaction.commit()
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

        // Still pouring dice out of the cup mouth: keep poses fresh, keep
        // the settle clock at zero, and skip the settle/tier logic (a die
        // parked at y = -400 is "still" and would read as settled).
        if !pendingRelease.isEmpty {
            for index in dice.indices {
                let node = dice[index].presentation
                lastPoses[index] = (node.simdWorldPosition, node.simdWorldOrientation)
            }
            rollStartTime = nil
            settledSince = nil
            return
        }

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
        pendingRelease.removeAll()
        let dice = activeDice
        // Style-tagged so an LCR pool and a pip pool can ride the exact
        // same `onResult` callback — see `DieResult`. The whole pool is
        // built to ONE style (`poolFaceStyle`, latched by `configurePool`
        // before `ensurePool` ever runs), so every die here reads the same
        // way.
        let results: [DieResult] = dice.map { die in
            switch poolFaceStyle {
            case .lcr: return .lcr(DieFaceReader.upFace(of: die))
            case .pips: return .pip(DieFaceReader.upPipValue(of: die))
            }
        }
        #if DEBUG
        let elapsed = (lastFrameTime ?? 0) - (rollStartTime ?? 0)
        let debugFaces = results.map { result -> String in
            switch result {
            case .lcr(let face): return face.rawValue
            case .pip(let value): return "\(value)"
            }
        }
        NSLog("Dice3D roll %d settled in %.2fs: %@", rollID, elapsed,
              debugFaces.joined(separator: ","))
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
            self.onResult?(rollID, results)
        }
    }

    // MARK: contacts → clacks

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        contactThrottle?.register(contact)
        CoinImpactBus.shared.dicePing(contact: contact, in: view)
    }
}

/// A soft gold ring glowing under a HELD die — the visual telling a
/// player "this one's locked in, it won't roll again until you tap it
/// loose." Same tracked-plane trick as `DieShadowNode` (a flat, constant-
/// lit plane repositioned in world space, not a real light), just gold and
/// ring-shaped instead of a dark shadow disc. Table-only: the hold/set-
/// aside primitive is a table-side mechanism (see `DiceTableSceneCoordinator.
/// setHeld`), so this lives here rather than in `DiceScenePhysics` (shared
/// with the cup, which has no hold concept).
final class DieHoldRingNode: SCNNode {
    private static let texture: UIImage = {
        let size: CGFloat = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size),
                                       format: format).image { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let gold = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0.9)
            let clear = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0)
            // A RING, not a filled disc: transparent core, a bright gold
            // band, transparent again past the edge.
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [clear.cgColor, clear.cgColor, gold.cgColor, gold.cgColor, clear.cgColor] as CFArray,
                locations: [0, 0.56, 0.70, 0.82, 1]) {
                ctx.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                    endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size / 2,
                    options: [])
            }
        }
    }()

    override init() {
        super.init()
        let plane = SCNPlane(width: Dice3D.side * 2.2, height: Dice3D.side * 2.2)
        let material = SCNMaterial()
        material.diffuse.contents = Self.texture
        material.emission.contents = Self.texture
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        plane.materials = [material]
        geometry = plane
        eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // lie flat
        castsShadow = false
        opacity = 0 // hidden until `setHeld` shows it
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
}


// MARK: - Pour state (the cup tips toward the table)

/// Published by `DiceTableSceneCoordinator.launch` for the duration of a
/// pour, so the cup SPRITE (TableCupView — not owned by the scene) can tip
/// toward the table while the dice leave its mouth. Read-only for views.
///
/// Timeline for one pour (seconds from launch): `progress` eases 0 -> 1
/// over 0.26s (cup tips), holds while the dice leave the mouth (first at
/// 0.22s, one more every ~75ms), then eases back to 0 over 0.45s once the
/// last die is out (cup rights itself); `seat` returns to nil when done.
///
/// CONTRACT for the cup layer (DiceTableView.cupLayer / TableCupView):
/// 1. Keep drawing the roller's cup while `TablePourState.shared.seat`
///    is non-nil — `activeCupSeat` goes nil the instant a roll is in flight,
///    which would otherwise drop the cup the moment it should tip.
///    e.g. `if let seat = activeCupSeat ?? TablePourState.shared.seat { ... }`
/// 2. Apply `.tablePourTilt(seat:edge:)` (below) to the TableCupView — it
///    reads `progress` and does the foreshortened tip.
@Observable
final class TablePourState {
    static let shared = TablePourState()

    /// The seat whose cup is mid-pour; nil when idle.
    private(set) var seat: Int?
    /// 0 (upright) ... 1 (fully tipped), eased.
    private(set) var progress: Double = 0
    /// The roll intensity (0.3...1.5) — harder pours tip further.
    private(set) var intensity: Double = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt = CACurrentMediaTime()
    @ObservationIgnored private var holdUntil: TimeInterval = 0.5
    private static let tipIn: TimeInterval = 0.26
    private static let recover: TimeInterval = 0.45

    func begin(seat: Int, intensity: Double, releaseSpan: TimeInterval) {
        self.seat = seat
        self.intensity = intensity
        startedAt = CACurrentMediaTime()
        holdUntil = max(Self.tipIn, releaseSpan + 0.15)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let t = CACurrentMediaTime() - startedAt
        if t < Self.tipIn {
            let x = t / Self.tipIn
            progress = 1 - pow(1 - x, 3) // easeOutCubic: snaps down, settles
        } else if t < holdUntil {
            progress = 1
        } else if t < holdUntil + Self.recover {
            let x = (t - holdUntil) / Self.recover
            progress = 1 - (x * x * (3 - 2 * x)) // smoothstep back up
        } else {
            progress = 0
            seat = nil
            timer?.invalidate()
            timer = nil
        }
    }
}

/// The reference tip for a TableCupView: foreshortens the sprite along the
/// pour axis (mouth end recedes, base end rises toward the eye), grows it a
/// touch, and slides it a few points toward the table center — all scaled by
/// `TablePourState.progress` for this seat. Apply OUTSIDE the cup's own
/// rail rotation (it works in screen space, using `edge` for the axis).
struct TablePourTiltModifier: ViewModifier {
    let seat: Int
    let edge: TableCupView.RailEdge

    func body(content: Content) -> some View {
        let state = TablePourState.shared
        let p = state.seat == seat ? state.progress : 0
        let hard = min(1, max(0, (state.intensity - 0.3) / 1.2))
        let degrees = p * (42 + 20 * hard)
        // Unit vector from the cup toward the table center, screen space.
        let d: CGVector
        switch edge {
        case .bottom: d = CGVector(dx: 0, dy: -1)
        case .top: d = CGVector(dx: 0, dy: 1)
        case .left: d = CGVector(dx: 1, dy: 0)
        case .right: d = CGVector(dx: -1, dy: 0)
        }
        // Horizontal pour axis (cup on the top/bottom rail) rotates about
        // the screen X axis; vertical (left/right rail) about Y. The sign
        // makes the MOUTH end recede for every edge.
        let axis: (x: CGFloat, y: CGFloat, z: CGFloat) = d.dy != 0 ? (1, 0, 0) : (0, 1, 0)
        let sign: Double = (d.dy != 0 ? d.dy : -d.dx) > 0 ? -1 : 1
        return content
            .rotation3DEffect(.degrees(sign * degrees), axis: axis, anchor: .center, perspective: 0.45)
            .scaleEffect(1 + 0.08 * p)
            .offset(x: d.dx * 10 * p, y: d.dy * 10 * p)
    }
}

extension View {
    /// See `TablePourState` for the full contract.
    func tablePourTilt(seat: Int, edge: TableCupView.RailEdge) -> some View {
        modifier(TablePourTiltModifier(seat: seat, edge: edge))
    }
}
