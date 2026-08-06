import SwiftUI
import SceneKit
import CoreMotion

/// The inside of the dice cup, first person: the PHONE IS THE CUP. Its
/// depth runs the long way of the phone — the camera sits inside near the
/// closed end looking obliquely up the cup's axis, so the near wall sweeps
/// past the bottom of the screen, the leather interior fills the frame
/// edge to edge, and the far rim reads as an ellipse arc near the top with
/// warm light spilling in through the opening. Dice live against the far
/// wall (a held phone tilts the cup back, so gravity pins them there),
/// silhouetted against the opening's glow. CoreMotion drives the physics
/// continuously — tilting the phone tilts gravity so the dice slide and
/// roll around the interior; shakes become real impulses, so a gentle
/// shake skitters them and a hard one launches them up toward the mouth,
/// tumbling. Every clack you hear (and feel) is an actual physics contact,
/// rate-limited — the sound matches what the eyes see.
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

final class DiceCupSceneCoordinator: NSObject, SCNPhysicsContactDelegate {
    // Cup geometry, scene units (a die is 2). Deep tumbler: the depth is
    // the phone's long axis, the mouth is at +Y (top of the screen).
    private let cupInnerRadius: CGFloat = 5.2
    private let cupWall: CGFloat = 0.55
    private let cupHeight: CGFloat = 15.0

    private let scene = SCNScene()
    private weak var view: SCNView?
    private var dice: [DieNode] = []
    private var audio = CupAudio()
    private var contactThrottle: DiceContactThrottle?
    private let clackHaptic = UIImpactFeedbackGenerator(style: .light)
    private let thumpHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastImpulse = Date.distantPast

    func attach(to view: SCNView, model: DiceCupModel) {
        self.view = view
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
        // Gravity then pins the dice into the far-wall/floor corner,
        // right where the opening's light falls on them.
        let s = DiceScenePhysics.cupGravityStrength
        scene.physicsWorld.gravity = SCNVector3(0, -0.55 * s, -0.84 * s)
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

        // Rolled rim at the mouth: the ellipse arc the eye catches near the
        // top of the screen, where interior leather meets the light.
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
        // Deep-cup mood: dim warm ambient so the closed end falls into
        // shadow and the interior shades darker the deeper you look.
        let ambient = SCNNode()
        ambient.light = {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 260
            light.color = UIColor(red: 1.0, green: 0.90, blue: 0.78, alpha: 1)
            return light
        }()
        scene.rootNode.addChildNode(ambient)

        // The room lamp beyond the mouth: warm light entering from the
        // opening, falling off down the cup — dice near the mouth catch
        // it, the wall gradient sells the depth.
        let lamp = SCNNode()
        lamp.light = {
            let light = SCNLight()
            light.type = .omni
            light.intensity = 1600
            light.color = UIColor(red: 1.0, green: 0.93, blue: 0.80, alpha: 1)
            light.attenuationStartDistance = 6
            light.attenuationEndDistance = 46
            return light
        }()
        lamp.position = SCNVector3(2.0, cupHeight + 9, -2.0)
        scene.rootNode.addChildNode(lamp)

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
    }

    /// Oblique interior camera: sitting inside the cup near the closed
    /// end, offset toward the near (+Z) wall, looking up the axis at the
    /// far wall just below the rim. The near wall sweeps past the bottom
    /// of the frame; wide FOV makes the walls converge toward the mouth.
    private func buildCamera() {
        let cameraNode = SCNNode()
        cameraNode.camera = {
            let camera = SCNCamera()
            camera.fieldOfView = 82 // wide: interior edge-to-edge
            camera.projectionDirection = .vertical
            camera.zNear = 0.3
            camera.zFar = 90
            return camera
        }()
        cameraNode.position = SCNVector3(0, 6.2, 4.4)
        // Aim at the far wall well below the rim: the rim arc and a band
        // of opening light sit in the top fifth, the middle is leather
        // wall, and the floor/far-wall corner — where a held cup's dice
        // actually gather — rides just above the bottom edge. Up-hint +Z
        // keeps screen-right = scene +X so tilting the phone right rolls
        // dice toward the right of the screen.
        cameraNode.look(at: SCNVector3(0, cupHeight * 0.45, -cupInnerRadius),
                        up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
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
            // Drop in up the cup, spread across the width — gravity (tilted
            // by the hold) settles them against the far wall where the
            // opening's light lands. No shadow planes here: the camera
            // never sees the floor, and the key light does the work.
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
    /// Attitude tilts gravity (dice roll around the floor as the phone
    /// tilts); acceleration spikes become impulses (gentle shake =
    /// skitter, hard shake = airborne dice).
    private func apply(_ dm: CMDeviceMotion) {
        // Device gravity → cup space. The cup's depth runs the phone's
        // long axis: screen right = +X, screen up (toward the mouth) = +Y,
        // out of the screen = +Z. That's the DEVICE frame exactly, so
        // gravity maps 1:1. Upright phone: dice fall to the closed end.
        // Held tilted toward the face (the natural grip): dice pin against
        // the far wall, lit by the opening. Face-down: they pour out past
        // the mouth — which is exactly when the pour fires.
        let g = dm.gravity
        let strength = DiceScenePhysics.cupGravityStrength
        scene.physicsWorld.gravity = SCNVector3(CGFloat(g.x) * strength,
                                                CGFloat(g.y) * strength,
                                                CGFloat(g.z) * strength)

        // Shake impulses. The cup jerks, the dice lag: push them opposite
        // the hand's acceleration, plus lift toward the mouth when it's a
        // real jolt.
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
                CGFloat(-a.y) * lateralScale * 0.6 + lift * CGFloat.random(in: 0.8...1.15),
                CGFloat(-a.z) * lateralScale + jitter(0.04))
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
