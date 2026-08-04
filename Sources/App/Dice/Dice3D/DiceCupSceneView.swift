import SwiftUI
import SceneKit
import CoreMotion

/// The inside of the dice cup, first person: camera looking straight down
/// into a leather cylinder, dice resting on its floor. CoreMotion drives
/// the physics continuously — tilting the phone tilts gravity so the dice
/// slide and roll around the floor; shakes become real impulses, so a
/// gentle shake skitters them and a hard one launches them up toward your
/// eye, tumbling. Every clack you hear (and feel) is an actual physics
/// contact, rate-limited — the sound matches what the eyes see.
struct DiceCupSceneView: UIViewRepresentable {
    /// How many dice are in the cup (min(chips, 3)).
    let diceCount: Int
    /// Motion source: the coordinator subscribes to the model's sample
    /// stream (single CMMotionManager for pour detection AND physics).
    let model: DiceCupModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        context.coordinator.attach(to: view, model: model)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.setDiceCount(diceCount)
    }

    func makeCoordinator() -> DiceCupSceneCoordinator { DiceCupSceneCoordinator() }
}

final class DiceCupSceneCoordinator: NSObject, SCNPhysicsContactDelegate,
                                     SCNSceneRendererDelegate {
    // Cup geometry, scene units (a die is 2).
    private let cupInnerRadius: CGFloat = 5.0
    private let cupWall: CGFloat = 0.55
    private let cupHeight: CGFloat = 10.0

    private let scene = SCNScene()
    private weak var view: SCNView?
    private var dice: [DieNode] = []
    private var shadows: [DieShadowNode] = []
    private var audio = CupAudio()
    private var contactThrottle: DiceContactThrottle?
    private let clackHaptic = UIImpactFeedbackGenerator(style: .light)
    private let thumpHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastImpulse = Date.distantPast

    func attach(to view: SCNView, model: DiceCupModel) {
        self.view = view
        view.scene = scene
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false // SwiftUI keeps the pour swipe
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true // motion drives physics nonstop
        view.delegate = self // per-frame contact-shadow tracking

        scene.background.contents = UIColor.clear
        scene.physicsWorld.gravity = DiceScenePhysics.gravity
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
            body.friction = 0.5
            body.restitution = 0.45
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(wallNode)

        // Floor disc.
        let floor = SCNCylinder(radius: cupInnerRadius + cupWall, height: 0.6)
        let floorLeather = SCNMaterial()
        floorLeather.diffuse.contents = CupTextures.floorLeather()
        floorLeather.lightingModel = .blinn
        floorLeather.specular.contents = UIColor(white: 0.18, alpha: 1)
        floor.materials = [floorLeather]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.3, 0) // top surface at y = 0
        floorNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: floor, options: nil))
            body.friction = 0.55
            body.restitution = 0.42
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(floorNode)

        // Invisible lid just above the rim: hard shakes launch the dice
        // toward the camera, but never through it.
        scene.rootNode.addChildNode(DiceScenePhysics.boundsNode(
            width: 30, height: 1, length: 30,
            position: SCNVector3(0, cupHeight + 1.0, 0)))
    }

    private func buildLights() {
        let ambient = SCNNode()
        ambient.light = {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 420
            light.color = UIColor(red: 1.0, green: 0.93, blue: 0.84, alpha: 1)
            return light
        }()
        scene.rootNode.addChildNode(ambient)

        // Lamp over the shoulder: an omni above the mouth, slightly off
        // axis, so the interior wall shades around the circle and the
        // dice throw contact shadows on the cup floor.
        let lamp = SCNNode()
        lamp.light = {
            let light = SCNLight()
            light.type = .omni
            light.intensity = 900
            light.color = UIColor(red: 1.0, green: 0.95, blue: 0.86, alpha: 1)
            light.attenuationStartDistance = 8
            light.attenuationEndDistance = 40
            return light
        }()
        lamp.position = SCNVector3(3.5, 18, -2.5)
        scene.rootNode.addChildNode(lamp)

        let key = SCNNode()
        key.light = {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 500
            light.castsShadow = true
            light.shadowMode = .forward
            light.shadowColor = UIColor.black.withAlphaComponent(0.5)
            light.shadowRadius = 6
            light.shadowSampleCount = 8
            light.orthographicScale = 9
            return light
        }()
        key.eulerAngles = SCNVector3(-Float.pi * 0.45, 0.3, 0)
        scene.rootNode.addChildNode(key)
    }

    private func buildCamera() {
        let cameraNode = SCNNode()
        cameraNode.camera = {
            let camera = SCNCamera()
            camera.fieldOfView = 52
            camera.zNear = 0.4
            camera.zFar = 80
            return camera
        }()
        cameraNode.position = SCNVector3(0, 14.5, 0)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // straight down
        scene.rootNode.addChildNode(cameraNode)
        view?.pointOfView = cameraNode
    }

    // MARK: dice

    func setDiceCount(_ count: Int) {
        let clamped = max(0, min(3, count))
        guard clamped != dice.count else { return }
        dice.forEach { $0.removeFromParentNode() }
        dice = []
        shadows.forEach { $0.removeFromParentNode() }
        shadows = []
        for index in 0..<clamped {
            let die = DieNode(lcrDie: index)
            let angle = CGFloat(index) * 2.1 + CGFloat.random(in: -0.3...0.3)
            let radius = CGFloat.random(in: 0.5...2.2)
            die.position = SCNVector3(cos(angle) * radius,
                                      Dice3D.side * (0.6 + CGFloat(index) * 0.9),
                                      sin(angle) * radius)
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))
            scene.rootNode.addChildNode(die)
            dice.append(die)

            let shadow = DieShadowNode()
            scene.rootNode.addChildNode(shadow)
            shadows.append(shadow)
        }
    }

    /// Per-frame: keep each contact shadow under its die.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard shadows.count == dice.count else { return }
        let floorY = Float(Dice3D.side / 2)
        for index in dice.indices {
            shadows[index].track(dice[index], floorY: floorY)
        }
    }

    // MARK: motion → physics

    /// Called ~60Hz on the main queue while it's this player's turn.
    /// Attitude tilts gravity (dice roll around the floor as the phone
    /// tilts); acceleration spikes become impulses (gentle shake =
    /// skitter, hard shake = airborne dice).
    private func apply(_ dm: CMDeviceMotion) {
        // Device gravity → cup space. Screen right = +X, screen up = −Z,
        // out of the screen = cup-up (+Y). Face-up phone: g=(0,0,−1) →
        // scene (0,−1,0); upright phone: dice rest against the near wall.
        let g = dm.gravity
        let strength = 9.8 * 2.2
        scene.physicsWorld.gravity = SCNVector3(CGFloat(g.x) * strength,
                                                CGFloat(g.z) * strength,
                                                CGFloat(-g.y) * strength)

        // Shake impulses. The cup jerks, the dice lag: push them opposite
        // the hand's acceleration, plus lift when it's a real jolt.
        let a = dm.userAcceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        let now = Date()
        guard magnitude > 0.55, now.timeIntervalSince(lastImpulse) > 0.09 else { return }
        lastImpulse = now

        let hard = magnitude > 1.5
        let lateralScale = Dice3D.mass * min(16, magnitude * 7.5)
        let lift = Dice3D.mass * (hard ? CGFloat.random(in: 14...19)
                                       : min(9, CGFloat(magnitude) * 4.5))
        for die in dice {
            let jitter: (CGFloat) -> CGFloat = { CGFloat.random(in: -$0...$0) }
            let impulse = SCNVector3(
                CGFloat(-a.x) * lateralScale + jitter(0.04),
                lift * CGFloat.random(in: 0.8...1.15),
                CGFloat(a.y) * lateralScale + jitter(0.04))
            die.physicsBody?.applyForce(impulse, asImpulse: true)
            // A twist of spin so airborne dice tumble, faces cycling.
            die.physicsBody?.applyTorque(
                SCNVector4(jitter(1), jitter(1), jitter(1),
                           Dice3D.mass * CGFloat.random(in: 6...14)),
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
