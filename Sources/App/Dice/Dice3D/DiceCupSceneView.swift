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

/// Just enough SCNVector3 arithmetic for the viewport-containment math
/// below — the project doesn't define global operators for it elsewhere,
/// and this is the only place that needs more than a literal. SCNVector3's
/// components are plain `Float` on iOS (unlike macOS, where they're
/// CGFloat), so this works in Float throughout rather than fighting that.
private enum CupVector {
    static func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    static func scaled(_ a: SCNVector3, _ s: Float) -> SCNVector3 {
        SCNVector3(a.x * s, a.y * s, a.z * s)
    }

    static func normalized(_ a: SCNVector3) -> SCNVector3 {
        let length = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        guard length > 0.0001 else { return a }
        return SCNVector3(a.x / length, a.y / length, a.z / length)
    }
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
            [weak self] strength, _ in
            // The cup doesn't (yet) split its rattle SFX by contact
            // material the way the table's TableSFX does — out of scope
            // for this pass; just keeping this call site in sync with
            // DiceContactThrottle's now-two-argument callback.
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
        // Interior wall: open-top tube, lined in deep red felt (real
        // fiber grain via a normal map — see CupSurfaces — not a flat
        // gradient), stitched leather rim above.
        let tube = SCNTube(innerRadius: cupInnerRadius,
                           outerRadius: cupInnerRadius + cupWall,
                           height: cupHeight)
        tube.radialSegmentCount = 64
        let felt = SCNMaterial()
        felt.diffuse.contents = CupSurfaces.feltWallDiffuse()
        // Mirror, not repeat: the procedural noise isn't tileable, so a
        // plain repeat stamped a visible vertical seam at the U=0/1 wrap
        // (dead center of the cross-section view). Mirroring makes the
        // boundary self-matching by construction.
        felt.diffuse.wrapS = .mirror
        felt.normal.contents = CupSurfaces.feltWallNormal()
        felt.normal.wrapS = .mirror
        // The fine grain in these procedural textures aliases into ugly
        // static/shimmer without mipmapping — this is what actually fixes
        // it, not texture resolution.
        CupSurfaces.applyFiltering(felt)
        felt.lightingModel = .blinn
        // A whisper of sheen — the normal map's fiber bumps do the real
        // work of scattering the specular into something that reads as
        // cloth instead of plastic; this just gives it something to catch.
        felt.specular.contents = UIColor(white: 0.18, alpha: 1)
        felt.shininess = 0.08
        felt.isDoubleSided = true
        tube.materials = [felt]
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
            let floorFelt = SCNMaterial()
            floorFelt.diffuse.contents = CupSurfaces.feltFloorDiffuse()
            floorFelt.normal.contents = CupSurfaces.feltFloorNormal()
            CupSurfaces.applyFiltering(floorFelt)
            floorFelt.lightingModel = .blinn
            floorFelt.specular.contents = UIColor(white: 0.14, alpha: 1)
            floorFelt.shininess = 0.06
            floor.materials = [floorFelt]
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

        // Rolled rim at the mouth: this is the one real "exterior" surface
        // a player sees, since every camera lives inside the cup — grained,
        // stitched leather with a burnished brass trim band baked into the
        // same texture (see CupSurfaces.rim).
        // A bold, chunky roll (nearly double the old 0.45) — the rim sits
        // far from the eye in the cross-section framing, so it needs real
        // physical size to read as leather-and-brass rather than a thin
        // dark line at the top of frame.
        let rim = SCNTorus(ringRadius: cupInnerRadius + cupWall / 2, pipeRadius: 0.85)
        rim.ringSegmentCount = 64
        rim.pipeSegmentCount = 32
        let rimLeather = SCNMaterial()
        rimLeather.diffuse.contents = CupSurfaces.rimLeatherDiffuse()
        rimLeather.normal.contents = CupSurfaces.rimLeatherNormal()
        CupSurfaces.applyFiltering(rimLeather)
        rimLeather.lightingModel = .blinn
        rimLeather.specular.contents = UIColor(white: 0.55, alpha: 1)
        rimLeather.shininess = 0.4
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
            // The shadow-caster: a spot hung just past the mouth, aimed
            // down into the cup — light believably falls IN through the
            // opening, same as the room glow. Soft penumbra (spotInner <
            // spotOuter, moderate shadowRadius) so a tumbling die's shadow
            // reads as a real soft-edged shadow, not a hard cutout, while
            // still being cheap enough to redraw every frame at 60fps
            // (physics runs at 120Hz but the shadow map only needs to
            // match the render rate). shadowMapSize is capped at 1024 —
            // doubling it did not read as sharper on a phone screen at
            // this distance, only cost more.
            //
            // Verification note: in the iOS Simulator (no physical device
            // available this pass), no shadow is visible from EITHER this
            // spot OR lookIn's pre-existing, untouched directional
            // shadow-caster — confirmed by swapping this light to
            // directional and cranking shadowColor to near-opaque black as
            // a debug probe; still nothing. That rules out a mistake in
            // this specific setup and points at a Simulator-side
            // limitation with SceneKit forward-mode shadows rather than
            // this configuration. Left in its intended, reasoned form
            // below — needs a real-device check to confirm shadows
            // actually paint.
            let spot = SCNNode()
            spot.light = {
                let light = SCNLight()
                light.type = .spot
                light.intensity = 980
                light.color = UIColor(red: 1.0, green: 0.93, blue: 0.80, alpha: 1)
                light.spotInnerAngle = 28
                light.spotOuterAngle = 68
                light.castsShadow = true
                light.shadowMode = .forward
                // Not pure black: a dark warm red so shadowed felt still
                // reads as felt, never a black hole in the cup.
                light.shadowColor = UIColor(red: 0.10, green: 0.015, blue: 0.02, alpha: 0.62)
                light.shadowRadius = 5.5
                light.shadowSampleCount = 8
                light.shadowMapSize = CGSize(width: 1024, height: 1024)
                light.zNear = 0.5
                light.zFar = 26
                light.attenuationStartDistance = 4
                light.attenuationEndDistance = 30
                return light
            }()
            spot.position = SCNVector3(1.4, cupHeight + 3.2, -1.2)
            spot.look(at: SCNVector3(0, 1.5, -1.0))
            scene.rootNode.addChildNode(spot)

            // Rim light: a low warm slash across the near rim/wall so the
            // cross-section edge catches the room, killing the flat band
            // the old build had at the bottom of the frame. Warmed further
            // (audit: "warmer rim light") and pulled toward the brass band.
            let rimLight = SCNNode()
            rimLight.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 420
                light.color = UIColor(red: 1.0, green: 0.78, blue: 0.48, alpha: 1)
                light.attenuationStartDistance = 3
                light.attenuationEndDistance = 22
                return light
            }()
            rimLight.position = SCNVector3(0, cupHeight * 0.95, cupInnerRadius + 3.0)
            scene.rootNode.addChildNode(rimLight)

            // The camera sits low and looks UP at the rim, so what it
            // actually sees is the rim's inner underside — a face none of
            // the lights above (aimed down into the cup, or in from
            // outside the wall) reach well. Without this it crushes to
            // near-black regardless of how bright the leather texture is.
            // A small warm fill tucked just inside the mouth, aimed back
            // down at that underside, keeps the grain/stitch/brass
            // actually legible from where the player is looking.
            let rimFill = SCNNode()
            rimFill.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 360
                light.color = UIColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
                light.attenuationStartDistance = 2
                light.attenuationEndDistance = 14
                return light
            }()
            rimFill.position = SCNVector3(0, cupHeight - 1.6, -2.0)
            scene.rootNode.addChildNode(rimFill)

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
            // Low and inside, near dice height, offset toward the near
            // (+Z) wall — you're down among the dice, not hovering above
            // them. The gaze tilts well up toward the mouth (audit: "the
            // opening must read as an opening") so the rim sits with real
            // margin near the top of frame, while the wide FOV still dips
            // low enough to keep the floor — where the dice actually rest
            // — inside the bottom of the frame.
            camera.fieldOfView = 92
            cameraNode.position = SCNVector3(0, 3.8, 3.2)
            cameraNode.look(at: SCNVector3(0, 7.2, -5.6),
                            up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            scene.rootNode.addChildNode(cameraNode)
            view?.pointOfView = cameraNode
            // "The screen edges ARE the cup walls": dice can never tumble
            // out of frame because their container is literally shaped to
            // the camera's own view frustum (see below) — the round
            // leather tube stays as the visual backdrop, this is a second,
            // tighter invisible boundary nested inside it.
            buildCrossSectionContainmentWalls(cameraNode: cameraNode,
                                              verticalFOVDegrees: camera.fieldOfView)
            return
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

    // MARK: viewport containment (cross-section only)

    /// Builds four invisible static planes anchored at the camera's own
    /// position, each tilted to sit exactly on one edge of its view
    /// frustum (pulled in ~12% for a hair of buffer). A die physically
    /// cannot cross one — no matter how hard the shake — because the
    /// walls fan out from the lens itself at the FOV's own angle: the
    /// screen edge and the wall are the same plane. The round leather tube
    /// is still there behind these for the visual "cup" read; this is a
    /// second, tighter boundary nested inside it that only crossSection
    /// needs, since it's the only concept whose camera doesn't already sit
    /// on the cup's own axis of symmetry.
    private func buildCrossSectionContainmentWalls(cameraNode: SCNNode, verticalFOVDegrees: CGFloat) {
        let screenBounds = view?.window?.screen.bounds ?? UIScreen.main.bounds
        let aspect = min(screenBounds.width, screenBounds.height) /
                     max(screenBounds.width, screenBounds.height)
        let halfV = verticalFOVDegrees * .pi / 180 / 2
        let halfH = atan(tan(halfV) * aspect)
        let margin: CGFloat = 0.88 // sit just inside the true edge

        // Camera basis, read straight off its transform — safer than
        // reasoning about Euler-angle signs by hand.
        let t = cameraNode.transform
        let right = CupVector.normalized(SCNVector3(t.m11, t.m12, t.m13))
        let up = CupVector.normalized(SCNVector3(t.m21, t.m22, t.m23))
        let forward = CupVector.normalized(SCNVector3(-t.m31, -t.m32, -t.m33))

        // Captured for setDiceCount's crossSectionSpawnPoint — dice spawn
        // inside this SAME cone the walls below fence in (see that
        // function's doc comment for why that matters).
        crossSectionFrustum = CrossSectionFrustum(
            cameraPosition: cameraNode.position, right: right, up: up, forward: forward,
            rightSlope: tan(halfH * margin), upSlope: tan(halfV * margin))

        func edgeDirection(right hSign: CGFloat, up vSign: CGFloat) -> SCNVector3 {
            var dir = forward
            if hSign != 0 {
                dir = CupVector.add(dir, CupVector.scaled(right, Float(tan(halfH * margin) * hSign)))
            }
            if vSign != 0 {
                dir = CupVector.add(dir, CupVector.scaled(up, Float(tan(halfV * margin) * vSign)))
            }
            return CupVector.normalized(dir)
        }

        let depth: CGFloat = 22
        let span: CGFloat = 30
        let thickness: CGFloat = 0.5

        addContainmentPlane(cameraNode: cameraNode, edgeDirection: edgeDirection(right: 1, up: 0),
                            spanAxis: up, depth: depth, thickness: thickness, span: span)
        addContainmentPlane(cameraNode: cameraNode, edgeDirection: edgeDirection(right: -1, up: 0),
                            spanAxis: up, depth: depth, thickness: thickness, span: span)
        addContainmentPlane(cameraNode: cameraNode, edgeDirection: edgeDirection(right: 0, up: 1),
                            spanAxis: right, depth: depth, thickness: thickness, span: span)
        addContainmentPlane(cameraNode: cameraNode, edgeDirection: edgeDirection(right: 0, up: -1),
                            spanAxis: right, depth: depth, thickness: thickness, span: span)
    }

    /// One containment plane: a thin static box whose near face passes
    /// through the camera position and extends `depth` outward along
    /// `edgeDirection`, spanning `span` wide along `spanAxis` (the screen
    /// axis this particular edge runs along — camera-up for the left/right
    /// walls, camera-right for the top/bottom ones).
    private func addContainmentPlane(cameraNode: SCNNode, edgeDirection: SCNVector3, spanAxis: SCNVector3,
                                      depth: CGFloat, thickness: CGFloat, span: CGFloat) {
        let pivot = SCNNode()
        pivot.position = cameraNode.position
        pivot.look(at: CupVector.add(cameraNode.position, edgeDirection),
                   up: spanAxis, localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(pivot)

        let box = SCNBox(width: thickness, height: span, length: depth, chamferRadius: 0)
        let boxNode = SCNNode(geometry: box)
        boxNode.position = SCNVector3(0, 0, -depth / 2)
        boxNode.physicsBody = {
            let body = SCNPhysicsBody(type: .static,
                                      shape: SCNPhysicsShape(geometry: box, options: nil))
            // Soft, leather-cup-adjacent knock — not a superball bounce —
            // to match the tube's own wall feel.
            body.friction = 0.5
            body.restitution = 0.30
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        pivot.addChildNode(boxNode)
    }

    // MARK: dice

    /// The cross-section camera's own frustum, captured once (by
    /// `buildCrossSectionContainmentWalls`, right after the containment
    /// walls above are built) so dice can be SPAWNED inside the exact same
    /// cone those walls fence in. `rightSlope`/`upSlope` are
    /// tan(halfAngle · margin) — the same margin the walls themselves use
    /// — so "fraction 1.0" lands a spawn right at the wall.
    private struct CrossSectionFrustum {
        let cameraPosition: SCNVector3
        let right: SCNVector3
        let up: SCNVector3
        let forward: SCNVector3
        let rightSlope: CGFloat
        let upSlope: CGFloat
    }
    private var crossSectionFrustum: CrossSectionFrustum?

    /// A spawn point expressed IN the cross-section camera's own frustum
    /// (forward depth + lateral/vertical fractions of the safe cone at
    /// that depth), converted to world space. This is the actual fix for
    /// "only one die visible": the three cup dice used to spawn at fixed
    /// WORLD offsets sized for the old, wider open-tube view (±1.6 die
    /// widths of lateral spread). The containment walls added later fence
    /// in a MUCH narrower cone — the crossSection camera's horizontal FOV
    /// works out to roughly ±25° vs. ±46° vertical — so the two outer dice
    /// were spawning already outside the frustum, overlapping/beyond the
    /// walls. Bullet's overlap-recovery impulse then flung them off far
    /// enough to leave only the center die (index 1, spread 0, the one
    /// that happened to spawn on-axis) visible. Spawning relative to the
    /// SAME frustum the walls are built from can't repeat that mistake.
    private func crossSectionSpawnPoint(depth: CGFloat, lateralFraction: CGFloat,
                                        verticalFraction: CGFloat) -> SCNVector3? {
        guard let frustum = crossSectionFrustum else { return nil }
        // Comfortably inside the walls (which sit at fraction ~1.0 of the
        // margin-adjusted frustum) — leaves real clearance for a die's own
        // half-width so it doesn't spawn already touching a wall.
        let safety: CGFloat = 0.5
        let lateral = depth * frustum.rightSlope * safety * lateralFraction
        let vertical = depth * frustum.upSlope * safety * verticalFraction
        let offset = CupVector.add(
            CupVector.scaled(frustum.forward, Float(depth)),
            CupVector.add(CupVector.scaled(frustum.right, Float(lateral)),
                         CupVector.scaled(frustum.up, Float(vertical))))
        return CupVector.add(frustum.cameraPosition, offset)
    }

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
            if concept == .crossSection,
               let point = crossSectionSpawnPoint(depth: 5.4 + CGFloat(index) * 0.9,
                                                  lateralFraction: spread,
                                                  verticalFraction: .random(in: -0.3...0.3)) {
                // Frustum-safe placement (see crossSectionSpawnPoint) —
                // the fix for the "only one die visible" bug.
                die.position = point
            } else {
                // lookIn/glassBottom: the camera sits ON the tube's own
                // axis of symmetry and this spread comfortably clears the
                // tube's inner radius (5.2) either way, so no frustum
                // math is needed here — unaffected by the bug above.
                die.position = SCNVector3(spread * Dice3D.side * 1.6 + .random(in: -0.5...0.5),
                                          5.0 + CGFloat(index) * Dice3D.side * 0.8,
                                          CGFloat.random(in: -2.6 ... -1.2))
            }
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

/// Programmatic textures that aren't the felt/leather cup lining (see
/// CupSurfaces for that) — the room glow through the mouth and the glass
/// base's polish streak. Generated once, cached.
enum CupTextures {
    private static var cache: [String: UIImage] = [:]

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
