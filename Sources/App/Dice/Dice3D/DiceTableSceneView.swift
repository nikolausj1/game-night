import SwiftUI
import SceneKit

/// The table's 3D dice layer: a transparent SCNView floating over the
/// felt. Dice spawn just inside the roller's rail with real velocity and
/// spin, tumble across the table under scaled gravity, clack off the
/// invisible rails and each other, and cast soft shadows onto the felt
/// below. When they stop, physics — not a pre-rolled array — names the
/// result: DieFaceReader reads each up-face and `onResult` reports back.
struct DiceTableSceneView: UIViewRepresentable {
    /// The roll currently requested by the controller (nil between turns).
    let roll: DiceGameController.Roll?
    /// Normalized felt anchor of the rolling seat (spawn edge).
    let anchor: CGPoint
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
        context.coordinator.requestRoll(roll, anchor: anchor)
    }

    func makeCoordinator() -> DiceTableSceneCoordinator { DiceTableSceneCoordinator() }
}

/// SCNView that tells its coordinator when its size is finally known —
/// walls and camera framing depend on the real bounds.
final class DiceSCNView: SCNView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Owns the SceneKit world for the table dice. All scene mutations happen
/// on the main queue; the render delegate only reads physics state and
/// flags settlement.
final class DiceTableSceneCoordinator: NSObject, SCNSceneRendererDelegate,
                                       SCNPhysicsContactDelegate {
    var onResult: ((Int, [LcrFace]) -> Void)?

    private let scene = SCNScene()
    private weak var view: DiceSCNView?
    private let cameraNode = SCNNode()
    private var wallNodes: [SCNNode] = []
    private var dice: [DieNode] = []
    private var shadows: [DieShadowNode] = []

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

    private var contactThrottle: DiceContactThrottle?

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
        for die in dice {
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
        for die in dice {
            die.physicsBody?.applyForce(SCNVector3(
                Float(direction.dx) * Float(strength) * 0.012,
                0,
                Float(direction.dy) * Float(strength) * 0.012), asImpulse: true)
        }
    }

    func attach(to view: DiceSCNView) {
        Self.activeCoordinator = self
        self.view = view
        view.scene = scene
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 60
        view.antialiasingMode =
            UIDevice.current.userInterfaceIdiom == .pad ? .multisampling4X : .multisampling2X
        view.rendersContinuously = false
        view.delegate = self
        view.onLayout = { [weak self] size in self?.rebuildWorld(for: size) }

        scene.background.contents = UIColor.clear
        scene.physicsWorld.gravity = DiceScenePhysics.gravity
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

        contactThrottle = DiceContactThrottle { strength in
            guard strength > 0.08 else { return }
            TableSFX.shared.play(.tableKnock)
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
        let height: CGFloat = 14
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // (boxW, boxL, x, z, _)
            (worldWidth + 8, thickness, 0, -(halfH + thickness / 2), 0),
            (worldWidth + 8, thickness, 0, halfH + thickness / 2, 0),
            (thickness, worldHeight + 8, -(halfW + thickness / 2), 0, 0),
            (thickness, worldHeight + 8, halfW + thickness / 2, 0, 0),
        ]
        for (w, l, x, z, _) in specs {
            let wall = DiceScenePhysics.boundsNode(
                width: w, height: height, length: l,
                position: SCNVector3(x, height / 2, z))
            scene.rootNode.addChildNode(wall)
            wallNodes.append(wall)
        }
    }

    // MARK: rolling

    /// Idempotent per roll id — updateUIView calls this on every SwiftUI
    /// pass, only a NEW id launches dice.
    func requestRoll(_ roll: DiceGameController.Roll?, anchor: CGPoint) {
        guard let roll, roll.id != lastRollID else { return }
        lastRollID = roll.id
        guard let view, view.bounds.width > 10 else {
            pendingRoll = roll
            pendingAnchor = anchor
            return
        }
        launch(roll, anchor: anchor)
    }

    private func launch(_ roll: DiceGameController.Roll, anchor: CGPoint) {
        dice.forEach { $0.removeFromParentNode() }
        dice = []
        shadows.forEach { $0.removeFromParentNode() }
        shadows = []

        // Entry point: the roller's edge of the felt, clamped inside the
        // rails. Heading: toward the middle with a little aim wander.
        let halfW = worldWidth / 2 - wallInset - Dice3D.side
        let halfH = worldHeight / 2 - wallInset - Dice3D.side
        let entryX = max(-halfW, min(halfW, (anchor.x - 0.5) * worldWidth))
        let entryZ = max(-halfH, min(halfH, (anchor.y - 0.5) * worldHeight))
        let heading = atan2(-entryZ, -entryX) // toward world center

        let norm = min(1, max(0, (roll.intensity - 0.3) / 1.2))
        let baseSpeed = 13.0 + 18.0 * norm

        for index in 0..<roll.count {
            let die = DieNode(lcrDie: index)
            // Fan the dice out perpendicular to the throw line.
            let lateral = (CGFloat(index) - CGFloat(roll.count - 1) / 2) * Dice3D.side * 1.4
            die.position = SCNVector3(
                entryX + -sin(heading) * lateral + .random(in: -0.4...0.4),
                Dice3D.side * (1.4 + CGFloat(index) * 0.5),
                entryZ + cos(heading) * lateral + .random(in: -0.4...0.4))
            // Random initial orientation so no two throws start alike.
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))
            scene.rootNode.addChildNode(die)

            let aim = heading + CGFloat.random(in: -0.16...0.16)
                + (CGFloat(index) - CGFloat(roll.count - 1) / 2) * 0.13
            let speed = baseSpeed * CGFloat.random(in: 0.85...1.15)
            die.physicsBody?.velocity = SCNVector3(cos(aim) * speed,
                                                   CGFloat.random(in: -2 ... 1),
                                                   sin(aim) * speed)
            // Strong tumble: faces visibly cycle because the cube really spins.
            let spin = CGFloat.random(in: 14...30)
            let ax = CGFloat.random(in: -1...1)
            let ay = CGFloat.random(in: -1...1)
            let az = CGFloat.random(in: -1...1)
            let length = max(0.001, sqrt(ax * ax + ay * ay + az * az))
            die.physicsBody?.angularVelocity = SCNVector4(ax / length, ay / length,
                                                          az / length, spin)
            dice.append(die)

            let shadow = DieShadowNode()
            scene.rootNode.addChildNode(shadow)
            shadows.append(shadow)
        }

        activeRollID = roll.id
        rollStartTime = nil
        lastFrameTime = nil
        settledSince = nil
        nudged = false
        reported = false
        lastPoses = dice.map { ($0.presentation.simdWorldPosition,
                                $0.presentation.simdWorldOrientation) }
        view?.rendersContinuously = true
    }

    // MARK: settle detection (render delegate — no allocations here)

    /// A die is "settled" when its OBSERVED frame-to-frame motion (from
    /// the presentation transform — the physics-animated pose) stays under
    /// tiny linear/angular rates for 0.3s straight.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard activeRollID != nil, !reported, dice.count == lastPoses.count else { return }
        // Contact shadows ride under the dice every frame.
        if shadows.count == dice.count {
            let floorY = Float(Dice3D.side / 2)
            for index in dice.indices {
                shadows[index].track(dice[index], floorY: floorY)
            }
        }
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
        for index in dice.indices {
            let node = dice[index].presentation
            let position = node.simdWorldPosition
            let orientation = node.simdWorldOrientation
            let previous = lastPoses[index]
            maxLinear = max(maxLinear, simd_distance(position, previous.position) / dt)
            let dot = min(1, abs(simd_dot(orientation.vector, previous.orientation.vector)))
            maxAngular = max(maxAngular, 2 * acos(dot) / dt)
            minFlatness = min(minFlatness, DieFaceReader.flatness(of: dice[index]))
            lastPoses[index] = (position, orientation)
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

        // Time budget: at 4.5s give any die still fidgeting (or cocked
        // against a rail) one tiny settling shove; at 6s read regardless.
        if elapsed > 4.5, !nudged {
            nudged = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reported else { return }
                for die in self.dice where DieFaceReader.flatness(of: die) < 0.94 {
                    die.physicsBody?.velocity = SCNVector3(0, -1.5, 0)
                    die.physicsBody?.angularVelocity = SCNVector4(
                        1, 0, 0, CGFloat.random(in: 0.8...1.6))
                }
            }
        }
        if elapsed > 6.0 {
            finishRoll()
        }
    }

    /// Physics has spoken: read the up-faces and report exactly once. The
    /// bodies are frozen at the same moment so no die can tip to another
    /// face after its value entered the game.
    private func finishRoll() {
        guard !reported, let rollID = activeRollID else { return }
        reported = true
        let faces = dice.map { DieFaceReader.upFace(of: $0) }
        #if DEBUG
        NSLog("Dice3D roll %d settled: %@", rollID,
              faces.map(\.rawValue).joined(separator: ","))
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for die in self.dice {
                die.physicsBody?.velocity = SCNVector3(0, 0, 0)
                die.physicsBody?.angularVelocity = SCNVector4(0, 0, 0, 0)
                die.physicsBody?.clearAllForces()
            }
            self.activeRollID = nil
            self.view?.rendersContinuously = false
            self.onResult?(rollID, faces)
        }
    }

    // MARK: contacts → clacks

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        contactThrottle?.register(contact)
    }
}
