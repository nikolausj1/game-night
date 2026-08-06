import SwiftUI
import SceneKit
import CoreMotion

/// The three looks for the phone-as-dice-cup. All three share one physics
/// world, one motion pipeline, and one pour gesture — only the camera,
/// lighting, and what the floor is made of change. Persisted via
/// @AppStorage("gn.cupConcept"); toggling is instant (the scene is
/// rebuilt fresh, dice re-seeded).
enum CupConcept: Int, CaseIterable {
    /// C1 — the phone is a CROSS-SECTION of the cup: oblique interior,
    /// opening at the top of the device, leather walls sweeping past.
    case crossSection = 0
    /// C2 — LOOK-IN: straight down into the cup from just under the rim,
    /// the whole floor and wall circle in frame (the original view).
    case lookIn = 1
    /// C3 — GLASS BOTTOM: you're under the cup looking up through its
    /// glass base. Dice tumble against the glass inches from your eye,
    /// silhouetted by warm light pouring down the tube from the mouth.
    /// Pouring reads as the dice falling up-and-away THROUGH the phone.
    case glassBottom = 2

    var label: String {
        switch self {
        case .crossSection: return "Cross-section"
        case .lookIn: return "Look-in"
        case .glassBottom: return "Glass bottom"
        }
    }

    var next: CupConcept {
        CupConcept(rawValue: (rawValue + 1) % CupConcept.allCases.count) ?? .crossSection
    }
}

/// The inside of the dice cup, first person: the PHONE IS THE CUP.
/// CoreMotion drives the physics continuously — tilting the phone tilts
/// gravity so the dice slide and roll around the interior; shakes become
/// real impulses, so a gentle shake skitters them and a hard one launches
/// them tumbling. Every clack you hear (and feel) is an actual physics
/// contact, rate-limited — the sound matches what the eyes see.
///
/// The `concept` decides the viewpoint (see CupConcept). Callers apply
/// `.id(concept)` so switching concepts rebuilds the scene instantly.
struct DiceCupSceneView: UIViewRepresentable {
    /// How many dice are in the cup (min(chips, 3)).
    let diceCount: Int
    /// Motion source: the coordinator subscribes to the model's sample
    /// stream (single CMMotionManager for pour detection AND physics).
    let model: DiceCupModel
    /// Which of the three cup looks to build.
    var concept: CupConcept = .crossSection

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        context.coordinator.attach(to: view, model: model, concept: concept)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.setDiceCount(diceCount)
    }

    func makeCoordinator() -> DiceCupSceneCoordinator { DiceCupSceneCoordinator() }
}

final class DiceCupSceneCoordinator: NSObject, SCNPhysicsContactDelegate {
    // Cup geometry, scene units (a die is 2). Deep tumbler: the depth is
    // the phone's long axis, the mouth is at +Y.
    private let cupInnerRadius: CGFloat = 5.2
    private let cupWall: CGFloat = 0.55
    private let cupHeight: CGFloat = 15.0

    private let scene = SCNScene()
    private weak var view: SCNView?
    private var concept: CupConcept = .crossSection
    private var dice: [DieNode] = []
    private var audio = CupAudio()
    private var contactThrottle: DiceContactThrottle?
    private let clackHaptic = UIImpactFeedbackGenerator(style: .light)
    private let thumpHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastImpulse = Date.distantPast

    func attach(to view: SCNView, model: DiceCupModel, concept: CupConcept) {
        self.view = view
        self.concept = concept
        view.scene = scene
        view.backgroundColor = .black // interior fills the frame; no felt behind
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false // SwiftUI keeps the pour swipe
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true // motion drives physics nonstop

        scene.background.contents = UIColor.black
        // Until the first real motion sample lands (and always in the
        // simulator), assume the natural hold: phone reclined ~25° from
        // flat, the way a seated player actually looks at a screen.
        scene.physicsWorld.gravity = restingGravity()
        scene.physicsWorld.timeStep = 1.0 / 120.0
        scene.physicsWorld.contactDelegate = self

        buildCup()
        buildLights()
        buildCamera()
        setDiceCount(3)

        clackHaptic.prepare()
        contactThrottle = DiceContactThrottle(minInterval: 0.08, minImpulse: 0.010) {
            [weak self] strength in
            guard let self else { return }
            self.audio.playRattle(volume: Float(0.25 + 0.65 * strength))
            if strength > 0.5 {
                self.thumpHaptic.impactOccurred(intensity: min(1.0, 0.4 + strength * 0.6))
            } else {
                self.clackHaptic.impactOccurred(intensity: min(1.0, 0.3 + strength))
            }
        }

        // One CMMotionManager for the whole cup: the model detects the
        // pour and banks energy; we turn the same samples into physics.
        model.onMotionSample = { [weak self] deviceMotion in
            self?.apply(deviceMotion)
        }
    }

    // MARK: device frame → cup frame

    /// Maps a device-frame vector (gravity or acceleration) into cup
    /// space for the active concept.
    ///
    /// - crossSection: the cup's depth runs the phone's long axis
    ///   (screen right = +X, toward the mouth/top of screen = +Y, out of
    ///   the screen = +Z) — the device frame exactly, so 1:1.
    /// - lookIn: the camera looks DOWN the cup axis from the mouth;
    ///   screen right = +X, screen up = −Z, out of the screen = cup-up
    ///   (+Y). Face-up phone → dice pressed onto the floor.
    /// - glassBottom: the camera looks UP the cup axis through the glass
    ///   base; screen right = +X, screen up = +Z, out of the screen
    ///   (toward the viewer) = base-down (−Y). Face-up phone → dice
    ///   pressed onto the glass, right in front of the lens.
    private func mapToCup(x: Double, y: Double, z: Double) -> SCNVector3 {
        switch concept {
        case .crossSection:
            return SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
        case .lookIn:
            return SCNVector3(CGFloat(x), CGFloat(z), CGFloat(-y))
        case .glassBottom:
            return SCNVector3(CGFloat(x), CGFloat(z), CGFloat(y))
        }
    }

    /// The "natural hold" gravity (phone reclined ~25° from flat) for
    /// scene setup before real samples arrive — and forever in the sim.
    private func restingGravity() -> SCNVector3 {
        let s = DiceScenePhysics.cupGravityStrength
        let g = mapToCup(x: 0, y: -0.55, z: -0.84)
        return SCNVector3(g.x * Float(s), g.y * Float(s), g.z * Float(s))
    }

    // MARK: cup construction

    private func buildCup() {
        // Interior wall: open-top tube, leather inside, stitched near the rim.
        let tube = SCNTube(innerRadius: cupInnerRadius,
                           outerRadius: cupInnerRadius + cupWall,
                           height: cupHeight)
        tube.radialSegmentCount = 64
        let leather = SCNMaterial()
        leather.diffuse.contents = CupTextures.wallLeather()
        leather.diffuse.wrapS = .repeat
        leather.lightingModel = .blinn
        leather.specular.contents = UIColor(white: 0.25, alpha: 1)
        leather.shininess = 0.15
        leather.isDoubleSided = true
        tube.materials = [leather]
        let wallNode = SCNNode(geometry: tube)
        wallNode.position = SCNVector3(0, cupHeight / 2, 0)
        wallNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: tube,
                                       options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]))
            body.friction = 0.55
            // Leather over wood: dead. A die hitting the wall thuds and
            // drops instead of pinging around the tube.
            body.restitution = 0.28
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(wallNode)

        // Floor: leather for C1/C2, polished glass for C3.
        let floor = SCNCylinder(radius: cupInnerRadius + cupWall, height: 0.6)
        if concept == .glassBottom {
            let glass = SCNMaterial()
            // Nearly invisible: the pane must read as a whisper of tint
            // and a polish streak, never a fog bank between eye and dice.
            glass.diffuse.contents = UIColor(red: 0.30, green: 0.38, blue: 0.35, alpha: 1)
            glass.lightingModel = .blinn
            glass.specular.contents = UIColor.white
            glass.shininess = 0.95
            glass.transparency = 0.07 // you're looking THROUGH it
            glass.fresnelExponent = 1.6
            glass.isDoubleSided = true
            floor.materials = [glass]
        } else {
            let floorLeather = SCNMaterial()
            floorLeather.diffuse.contents = CupTextures.floorLeather()
            floorLeather.lightingModel = .blinn
            floorLeather.specular.contents = UIColor(white: 0.18, alpha: 1)
            floor.materials = [floorLeather]
        }
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.3, 0) // top surface at y = 0
        floorNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: floor, options: nil))
            // Felt-lined base (or glass): grippy enough to bite a rolling
            // die, restitution low so landings THUD and die fast.
            body.friction = 0.62
            body.restitution = concept == .glassBottom ? 0.34 : 0.26
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(floorNode)

        if concept == .glassBottom {
            // The base seam: a dark leather ring where glass meets wall,
            // framing the view from below.
            let seam = SCNTorus(ringRadius: cupInnerRadius + cupWall / 2, pipeRadius: 0.5)
            seam.ringSegmentCount = 64
            let seamLeather = SCNMaterial()
            seamLeather.diffuse.contents = UIColor(red: 0.22, green: 0.13, blue: 0.07, alpha: 1)
            seamLeather.lightingModel = .blinn
            seamLeather.specular.contents = UIColor(white: 0.35, alpha: 1)
            seam.materials = [seamLeather]
            let seamNode = SCNNode(geometry: seam)
            seamNode.position = SCNVector3(0, 0.1, 0)
            scene.rootNode.addChildNode(seamNode)

            // A faint polish streak ON the glass: a constant-lit arc so the
            // base reads as a real reflective surface, not a missing floor.
            let streak = SCNPlane(width: cupInnerRadius * 1.7, height: cupInnerRadius * 0.8)
            let streakMaterial = SCNMaterial()
            streakMaterial.diffuse.contents = CupTextures.glassStreak()
            streakMaterial.emission.contents = CupTextures.glassStreak()
            streakMaterial.lightingModel = .constant
            streakMaterial.blendMode = .add
            streakMaterial.writesToDepthBuffer = false
            streak.materials = [streakMaterial]
            let streakNode = SCNNode(geometry: streak)
            streakNode.position = SCNVector3(-1.1, 0.32, 1.0)
            streakNode.eulerAngles = SCNVector3(Float.pi / 2, 0, Float.pi * 0.13)
            streakNode.opacity = 0.5
            scene.rootNode.addChildNode(streakNode)
        }

        // Rolled rim at the mouth.
        let rim = SCNTorus(ringRadius: cupInnerRadius + cupWall / 2, pipeRadius: 0.45)
        rim.ringSegmentCount = 64
        let rimLeather = SCNMaterial()
        rimLeather.diffuse.contents = UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1)
        rimLeather.lightingModel = .blinn
        rimLeather.specular.contents = UIColor(white: 0.5, alpha: 1)
        rimLeather.shininess = 0.3
        rim.materials = [rimLeather]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, cupHeight, 0)
        scene.rootNode.addChildNode(rimNode)

        // The world beyond the mouth: a big warm glow disc — the "room
        // light" the cup is open to. Constant-lit so it just burns bright.
        let sky = SCNPlane(width: 40, height: 40)
        let skyMaterial = SCNMaterial()
        skyMaterial.diffuse.contents = CupTextures.openingGlow()
        skyMaterial.emission.contents = CupTextures.openingGlow()
        skyMaterial.lightingModel = .constant
        skyMaterial.isDoubleSided = true
        sky.materials = [skyMaterial]
        let skyNode = SCNNode(geometry: sky)
        skyNode.position = SCNVector3(0, cupHeight + 7, 0)
        skyNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0) // face down the cup
        scene.rootNode.addChildNode(skyNode)

        // Invisible lid just above the rim: hard shakes launch the dice
        // toward the mouth, but never out of the cup.
        scene.rootNode.addChildNode(DiceScenePhysics.boundsNode(
            width: 30, height: 1, length: 30,
            position: SCNVector3(0, cupHeight + 1.6, 0)))
    }

    private func buildLights() {
        // Dim warm ambient so the cup shades darker away from the mouth.
        let ambient = SCNNode()
        ambient.light = {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = concept == .glassBottom ? 230 : 260
            light.color = UIColor(red: 1.0, green: 0.90, blue: 0.78, alpha: 1)
            return light
        }()
        scene.rootNode.addChildNode(ambient)

        // The room lamp beyond the mouth: warm light entering from the
        // opening, falling off down the cup.
        let lamp = SCNNode()
        lamp.light = {
            let light = SCNLight()
            light.type = .omni
            light.intensity = concept == .glassBottom ? 2400 : 1600
            light.color = UIColor(red: 1.0, green: 0.93, blue: 0.80, alpha: 1)
            light.attenuationStartDistance = 6
            light.attenuationEndDistance = 46
            return light
        }()
        lamp.position = SCNVector3(2.0, cupHeight + 9, -2.0)
        scene.rootNode.addChildNode(lamp)

        switch concept {
        case .crossSection:
            // Key shining DOWN the cup axis so dice faces read and throw
            // shadows deeper into the cup.
            let key = SCNNode()
            key.light = {
                let light = SCNLight()
                light.type = .directional
                light.intensity = 620
                light.castsShadow = true
                light.shadowMode = .forward
                light.shadowColor = UIColor.black.withAlphaComponent(0.55)
                light.shadowRadius = 7
                light.shadowSampleCount = 8
                light.orthographicScale = 10
                return light
            }()
            key.eulerAngles = SCNVector3(-Float.pi * 0.42, 0.25, 0)
            scene.rootNode.addChildNode(key)

            // Rim light: a low warm slash across the near rim/wall so the
            // cross-section edge catches the room, killing the flat band
            // the old build had at the bottom of the frame.
            let rimLight = SCNNode()
            rimLight.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 340
                light.color = UIColor(red: 1.0, green: 0.82, blue: 0.58, alpha: 1)
                light.attenuationStartDistance = 3
                light.attenuationEndDistance = 22
                return light
            }()
            rimLight.position = SCNVector3(0, cupHeight * 0.72, cupInnerRadius + 3.5)
            scene.rootNode.addChildNode(rimLight)

        case .lookIn:
            // Straight-down key: the floor is the stage, dice pips must
            // read crisply from above.
            let key = SCNNode()
            key.light = {
                let light = SCNLight()
                light.type = .directional
                light.intensity = 700
                light.castsShadow = true
                light.shadowMode = .forward
                light.shadowColor = UIColor.black.withAlphaComponent(0.5)
                light.shadowRadius = 6
                light.shadowSampleCount = 8
                light.orthographicScale = 9
                return light
            }()
            key.eulerAngles = SCNVector3(-Float.pi * 0.46, -0.3, 0)
            scene.rootNode.addChildNode(key)

        case .glassBottom:
            // Soft warm-neutral fill from BELOW the glass (the viewer's
            // side) so the faces pressed against it stay readable inside
            // the warm silhouette from above.
            let fill = SCNNode()
            fill.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 240
                light.color = UIColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 1)
                light.attenuationStartDistance = 2
                light.attenuationEndDistance = 18
                return light
            }()
            fill.position = SCNVector3(0, -4.5, 0)
            scene.rootNode.addChildNode(fill)
        }
    }

    private func buildCamera() {
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.zNear = 0.3
        camera.zFar = 90
        cameraNode.camera = camera

        switch concept {
        case .crossSection:
            // Oblique interior: sitting inside near the closed end, offset
            // toward the near (+Z) wall, looking up the axis at the far
            // wall just below the rim. Near wall sweeps past the bottom of
            // the frame; wide FOV converges the walls toward the mouth.
            camera.fieldOfView = 82
            cameraNode.position = SCNVector3(0, 6.2, 4.4)
            cameraNode.look(at: SCNVector3(0, cupHeight * 0.45, -cupInnerRadius),
                            up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        case .lookIn:
            // Hovering just inside the mouth, looking straight down: the
            // full floor circle with the wall wrapping every edge — no
            // dead space anywhere in the frame.
            camera.fieldOfView = 76
            cameraNode.position = SCNVector3(0, cupHeight - 1.2, 0)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        case .glassBottom:
            // Under the cup, an eye's width below the glass, looking
            // straight up the tube at the glowing mouth. Dice land ON the
            // lens, effectively.
            camera.fieldOfView = 80
            cameraNode.position = SCNVector3(0, -6.0, 0)
            cameraNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        }
        scene.rootNode.addChildNode(cameraNode)
        view?.pointOfView = cameraNode
    }

    // MARK: dice

    func setDiceCount(_ count: Int) {
        let clamped = max(0, min(3, count))
        guard clamped != dice.count else { return }
        dice.forEach { $0.removeFromParentNode() }
        dice = []
        for index in 0..<clamped {
            let die = DieNode(lcrDie: index)
            // Cup dice sit HEAVY: much higher rolling resistance and
            // damping than a table throw (they live in a hand-sized world
            // — any drift reads as floating). They still fly on a shake;
            // they just land dead and stay planted.
            die.physicsBody?.damping = 0.30
            die.physicsBody?.angularDamping = 0.45
            die.physicsBody?.rollingFriction = 0.55
            let spread = CGFloat(index) - CGFloat(clamped - 1) / 2
            die.position = SCNVector3(spread * Dice3D.side * 1.6 + .random(in: -0.5...0.5),
                                      5.0 + CGFloat(index) * Dice3D.side * 0.8,
                                      CGFloat.random(in: -2.6 ... -1.2))
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))
            scene.rootNode.addChildNode(die)
            dice.append(die)
        }
    }

    // MARK: motion → physics

    /// Called ~60Hz on the main queue while it's this player's turn.
    /// Attitude tilts gravity (dice roll around as the phone tilts);
    /// acceleration spikes become impulses (gentle shake = skitter, hard
    /// shake = airborne dice).
    private func apply(_ dm: CMDeviceMotion) {
        let g = dm.gravity
        let strength = DiceScenePhysics.cupGravityStrength
        let mapped = mapToCup(x: g.x, y: g.y, z: g.z)
        scene.physicsWorld.gravity = SCNVector3(mapped.x * Float(strength),
                                                mapped.y * Float(strength),
                                                mapped.z * Float(strength))

        // Shake impulses. The cup jerks, the dice lag: push them opposite
        // the hand's acceleration (mapped into cup space), plus lift
        // toward the mouth when it's a real jolt. Scaled ~2× from the old
        // 2.6× -gravity tune — a rattle has to fight real weight now.
        let a = dm.userAcceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        let now = Date()
        guard magnitude > 0.55, now.timeIntervalSince(lastImpulse) > 0.09 else { return }
        lastImpulse = now

        let hard = magnitude > 1.5
        let lateralScale = Dice3D.mass * min(30, magnitude * 14)
        let lift = Dice3D.mass * (hard ? CGFloat.random(in: 26...36)
                                       : min(17, CGFloat(magnitude) * 8.5))
        let push = mapToCup(x: -a.x, y: -a.y, z: -a.z)
        for die in dice {
            let jitter: (CGFloat) -> CGFloat = { CGFloat.random(in: -$0...$0) }
            let impulse = SCNVector3(
                CGFloat(push.x) * lateralScale + jitter(0.04),
                CGFloat(push.y) * lateralScale * 0.6 + lift * CGFloat.random(in: 0.8...1.15),
                CGFloat(push.z) * lateralScale + jitter(0.04))
            die.physicsBody?.applyForce(impulse, asImpulse: true)
            // A twist of spin so airborne dice tumble, faces cycling.
            die.physicsBody?.applyTorque(
                SCNVector4(jitter(1), jitter(1), jitter(1),
                           Dice3D.mass * CGFloat.random(in: 8...16)),
                asImpulse: true)
        }
    }

    // MARK: contacts → rattle + haptic

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        contactThrottle?.register(contact)
    }
}

/// Programmatic leather for the cup interior — warm brown with tonal
/// mottling and a stitched band near the rim. Generated once, cached.
enum CupTextures {
    private static var cache: [String: UIImage] = [:]

    /// Interior wall texture (wraps around the tube; V runs bottom→top).
    static func wallLeather() -> UIImage {
        cached("wall") { context, size in
            drawLeatherBase(context, size: size,
                            top: UIColor(red: 0.36, green: 0.22, blue: 0.12, alpha: 1),
                            bottom: UIColor(red: 0.16, green: 0.09, blue: 0.05, alpha: 1))
            // Stitch band near the rim: paired dashes in waxed thread gold.
            let stitchY = size.height * 0.10
            context.setStrokeColor(UIColor(red: 0.78, green: 0.62, blue: 0.38,
                                           alpha: 0.85).cgColor)
            context.setLineWidth(size.height * 0.012)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [size.width * 0.022, size.width * 0.016])
            context.move(to: CGPoint(x: 0, y: stitchY))
            context.addLine(to: CGPoint(x: size.width, y: stitchY))
            context.strokePath()
        }
    }

    /// The warm room-light disc visible through the cup's mouth: bright
    /// gold-white core fading to amber at the edges. Emissive — it IS the
    /// light the eye sees past the rim.
    static func openingGlow() -> UIImage {
        cached("glow") { context, size in
            let space = CGColorSpaceCreateDeviceRGB()
            let core = UIColor(red: 1.0, green: 0.96, blue: 0.86, alpha: 1)
            let mid = UIColor(red: 0.98, green: 0.82, blue: 0.55, alpha: 1)
            let edge = UIColor(red: 0.35, green: 0.24, blue: 0.12, alpha: 1)
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [core.cgColor, mid.cgColor, edge.cgColor] as CFArray,
                locations: [0, 0.45, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: 0,
                    endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                    endRadius: size.width / 2,
                    options: [])
            }
        }
    }

    /// Cup floor texture: darker, center-worn leather.
    static func floorLeather() -> UIImage {
        cached("floor") { context, size in
            drawLeatherBase(context, size: size,
                            top: UIColor(red: 0.24, green: 0.14, blue: 0.075, alpha: 1),
                            bottom: UIColor(red: 0.18, green: 0.105, blue: 0.055, alpha: 1))
            // Worn pale patch in the middle where dice have lived.
            let space = CGColorSpaceCreateDeviceRGB()
            let worn = UIColor(red: 0.42, green: 0.28, blue: 0.16, alpha: 0.35)
            let clear = UIColor(white: 0, alpha: 0)
            if let gradient = CGGradient(colorsSpace: space,
                                         colors: [worn.cgColor, clear.cgColor] as CFArray,
                                         locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                    endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                    endRadius: size.width * 0.35,
                    options: [])
            }
        }
    }

    /// A soft diagonal polish streak for the glass base (C3): faint white
    /// wash, brightest along the center line, feathering to nothing.
    static func glassStreak() -> UIImage {
        cached("streak") { context, size in
            let space = CGColorSpaceCreateDeviceRGB()
            let core = UIColor(white: 1, alpha: 0.35)
            let clear = UIColor(white: 1, alpha: 0)
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [clear.cgColor, core.cgColor, clear.cgColor] as CFArray,
                locations: [0, 0.5, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: size.height),
                    options: [])
            }
        }
    }

    private static func drawLeatherBase(_ context: CGContext, size: CGSize,
                                        top: UIColor, bottom: UIColor) {
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [top.cgColor, bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero,
                                       end: CGPoint(x: 0, y: size.height), options: [])
        }
        // Mottling: soft random blotches, lighter and darker, seeded so the
        // texture is stable across runs.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<140 {
            let radius = CGFloat.random(in: size.width * 0.01...size.width * 0.05, using: &rng)
            let x = CGFloat.random(in: 0...size.width, using: &rng)
            let y = CGFloat.random(in: 0...size.height, using: &rng)
            let lighten = Bool.random(using: &rng)
            context.setFillColor(UIColor(white: lighten ? 1 : 0,
                                         alpha: CGFloat.random(in: 0.015...0.05, using: &rng)).cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 1.4))
        }
    }

    private static func cached(_ key: String,
                               draw: (CGContext, CGSize) -> Void) -> UIImage {
        if let hit = cache[key] { return hit }
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image {
            draw($0.cgContext, size)
        }
        cache[key] = image
        return image
    }
}
