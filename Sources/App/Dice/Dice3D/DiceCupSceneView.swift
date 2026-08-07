import SwiftUI
import SceneKit
import CoreMotion

/// The three looks for the phone-as-dice-cup. All three share one physics
/// world, one motion pipeline, one pour gesture, and the same felt-and-
/// leather cup construction — only the camera framing, lighting, and (for
/// the deep look-in) the cup's own height change. Persisted via
/// @AppStorage("gn.cupConcept"); toggling is instant (the scene is
/// rebuilt fresh, dice re-seeded).
enum CupConcept: Int, CaseIterable {
    /// C1 — the phone is a CROSS-SECTION of the cup: oblique interior,
    /// opening at the top of the device, leather walls sweeping past.
    case crossSection = 0
    /// C2 — LOOK-IN: straight down into the cup from just under the rim,
    /// the whole floor and wall circle in frame (the original view).
    case lookIn = 1
    /// C3 — DEEP LOOK-IN (rawValue kept at 2 — this used to be the "glass
    /// bottom" concept; the owner killed that design outright because it
    /// made gravity read as pulling the WRONG way, and asked for this in
    /// its place so old stored prefs still land somewhere sane). Camera
    /// at the mouth, straight down, wide-angle — the rim hugs the screen
    /// edges and the walls telescope down a MUCH taller shaft to a small,
    /// distant felt floor. Same gravity mapping as `.lookIn` (dice still
    /// get pulled down toward the floor when the phone is face-up — see
    /// `mapToCup`); the drama comes from geometry, FOV, and lighting
    /// falloff, not a different axis convention.
    case deepLookIn = 2

    var label: String {
        switch self {
        case .crossSection: return "Cross-section"
        case .lookIn: return "Look-in"
        case .deepLookIn: return "Deep cup"
        }
    }

    var next: CupConcept {
        CupConcept(rawValue: (rawValue + 1) % CupConcept.allCases.count) ?? .crossSection
    }

    /// Wave 5 (photoreal pass): lookIn and deepLookIn traded their fully
    /// procedural leather-tube geometry for a generated PHOTO of a real
    /// leather dice-cup interior, composited full-bleed behind a
    /// transparent SCNView so only the live 3D dice (+ shadows) draw over
    /// it — see `DiceCupSceneView`'s UIViewRepresentable. crossSection
    /// keeps its own render this pass (untouched) and has no photo.
    /// `nil` here means "build the procedural cup" to both the view layer
    /// and `DiceCupSceneCoordinator.buildCup`.
    var photoBackdropImageName: String? {
        switch self {
        case .crossSection: return nil
        case .lookIn: return "CupInteriorShallow"
        case .deepLookIn: return "CupInteriorDeep"
        }
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
    /// How many dice should be in the cup right now — the full
    /// min(chips, 3) once `cupReady`, or however many have been loaded so
    /// far while manual cup mode is still gating the turn (see
    /// `DiceCupView.cupSceneDiceCount`). A rise from one call to the next
    /// spawns just the new die/dice falling in from the mouth rather than
    /// re-seeding everything — see `DiceCupSceneCoordinator.setDiceCount`.
    let diceCount: Int
    /// Motion source: the coordinator subscribes to the model's sample
    /// stream (single CMMotionManager for pour detection AND physics).
    let model: DiceCupModel
    /// Which of the three cup looks to build.
    var concept: CupConcept = .crossSection

    /// Returns a plain `UIView` rather than the `SCNView` directly so the
    /// photo backdrop (lookIn/deepLookIn — see `CupConcept.photoBackdropImageName`)
    /// can live UNDER a transparent SCNView, self-contained inside this one
    /// representable. That matters beyond DiceCupView: `-autoCupPreview`
    /// (DiceCupPreviewHarness) also instantiates this view directly, so
    /// building the composite here — instead of one layer up, in
    /// DiceCupView's own ZStack — is what makes the harness screenshot the
    /// photo too, without that file needing to know the photo exists.
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .clear

        if let photoName = concept.photoBackdropImageName {
            // Full-bleed, aspect-fill, center-cropped — same "the screen
            // edges are the frame" language TableCup's photo uses, just at
            // full scale instead of a small on-felt sprite. `clipsToBounds`
            // does the center-crop; UIKit's own scaleAspectFill matches the
            // calibration math in `DiceCupSceneCoordinator.photoContainerRadius`
            // (which assumes only the horizontal axis ever gets cropped).
            let imageView = UIImageView(image: UIImage(named: photoName))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        let sceneView = SCNView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: container.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // The real starting count (0 mid-load, full count once ready or in
        // auto-cup/back-compat) goes straight to the coordinator so it
        // seeds correctly on the very first frame — no placeholder count
        // that then has to be torn down again a moment later.
        context.coordinator.attach(to: sceneView, model: model, concept: concept, diceCount: diceCount)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
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
    /// Cup depth — varies by concept. Cross-section and the classic
    /// look-in keep the original modest tumbler; the deep look-in more
    /// than doubles it, since a genuinely tall shaft between the rim and
    /// the floor is the entire point of that redesign (owner: the old
    /// glass-bottom concept "makes gravity go the wrong way" — this is
    /// real, correctly-signed depth in its place). A computed property
    /// rather than a stored constant so every piece of geometry/lighting
    /// below that's positioned off `cupHeight` (rim, sky glow, invisible
    /// lid, room lamp) automatically scales with it — nothing here is
    /// hand-duplicated per concept.
    /// Owner field feedback on the first deep-cup build: 34 units tall on
    /// a 10.4-unit-wide cup read as a mineshaft — "not physically
    /// possible." A real leather dice cup is only ~1.3× its diameter deep,
    /// so the deep look-in now uses honest proportions (13.8 ≈ 1.33×) and
    /// leans on the wide-angle camera at the mouth + lighting falloff for
    /// its depth drama instead of impossible geometry.
    private var cupHeight: CGFloat { concept == .deepLookIn ? 13.8 : 15.0 }

    /// World-unit radius for the invisible physics cylinder that replaces
    /// the leather tube in the two photo-composited concepts (lookIn,
    /// deepLookIn — see `buildPhotoBackedCup`), calibrated so a die resting
    /// at the wall visually sits at the picked photo's own rim/interior
    /// circle instead of floating out over the leather or vanishing into
    /// the black margin outside it.
    ///
    /// Measured (PIL, on the recentered picks in `_review/assets/cup/`):
    /// the rim's INNER edge — the boundary between leather and the dark
    /// interior/felt, i.e. exactly where a die must stop — forms a circle
    /// whose radius is a fraction `rf` of the (square) photo's height.
    /// Both photos were re-centered in Python first so that circle sits at
    /// image-fraction (0.5, 0.5) — dead center — which matters because the
    /// UIImageView composites `.scaleAspectFill` + `clipsToBounds`: on a
    /// portrait phone that scales the square photo up until its HEIGHT
    /// matches the screen height (cropping only left/right), so the
    /// photo's vertical axis maps 1:1 onto the screen regardless of device
    /// — the one measurement this math actually needs.
    ///
    /// Camera projection (both concepts use `projectionDirection = .vertical`,
    /// looking straight down at height `H` above the floor plane y = 0):
    /// the floor plane's visible vertical extent is 2·H·tan(fovV⁄2), which
    /// maps onto the full screen height. A world radius `r` therefore lands
    /// at screen-fraction r ⁄ (2·H·tan(fovV⁄2)) from center — set equal to
    /// the photo's own measured `rf` and solve for `r`:
    ///     r = rf · 2 · H · tan(fovV⁄2)
    ///
    ///            rf      H (camera Y − floor Y=0)   fovV   → r (raw)
    /// lookIn:     0.31    13.8 (cupHeight − 1.2)     76°    ≈ 6.7
    /// deepLookIn: 0.3225  19.8 (cupHeight + 6.0)     100°   ≈ 15.2
    ///
    /// (deepLookIn's raw radius comes out much larger than lookIn's — not a
    /// bug: its camera sits higher AND wider-FOV, so it frames a much
    /// bigger patch of floor for the same on-screen circle size. The
    /// container is invisible either way; only its screen-space projection
    /// has to match the photo.)
    ///
    /// The formula alone still isn't the shipped number: it places a die's
    /// CENTER at the photo's rim boundary, but a resting/tumbling die's
    /// visible edge reaches up to its own half-diagonal (√2, ≈1.41 world
    /// units for a side-2 die) past center — screenshotted at the raw
    /// radius (`_review/wave5-photoreal-deep-raw.png`, first pass), dice
    /// visibly overlapped the gold rim band. Pulling the radius in by a
    /// flat 2.0 world units (comfortably past that half-diagonal, same
    /// margin for both concepts since it's a physical die property, not a
    /// per-concept one) keeps the die's OUTER edge inside the felt instead
    /// of just its center — confirmed against `_review/wave5-photoreal-*.png`.
    ///            r (raw)   − margin  = shipped
    /// lookIn:     6.7       2.0        4.7
    /// deepLookIn: 15.2      2.0        13.2
    private var photoContainerRadius: CGFloat {
        switch concept {
        case .lookIn: return 4.7
        case .deepLookIn: return 13.2
        case .crossSection: return cupInnerRadius // unused — crossSection builds its own tube
        }
    }

    private let scene = SCNScene()
    private weak var view: SCNView?
    private var concept: CupConcept = .crossSection
    private var dice: [DieNode] = []
    private var audio = CupAudio()
    private var contactThrottle: DiceContactThrottle?
    private let clackHaptic = UIImpactFeedbackGenerator(style: .light)
    private let thumpHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastImpulse = Date.distantPast
    /// `-autoCupLoadDemo` sim-verify hook (see `scheduleLoadDemo`).
    private var loadDemoTimer: Timer?

    func attach(to view: SCNView, model: DiceCupModel, concept: CupConcept, diceCount: Int) {
        self.view = view
        self.concept = concept
        view.scene = scene
        if concept.photoBackdropImageName != nil {
            // lookIn/deepLookIn: the photo drawn by DiceCupSceneView's
            // UIImageView sits BEHIND this SCNView (see makeUIView) — the
            // view (and the scene's own background) must be fully
            // transparent so only the dice and the shadow-catcher plane
            // (see buildPhotoBackedCup) draw over it. `isOpaque = false` is
            // required alongside `.clear` — SCNView defaults to an opaque
            // backing layer for performance, which would otherwise punch a
            // solid rectangle through the photo regardless of this color.
            view.backgroundColor = .clear
            view.isOpaque = false
            scene.background.contents = nil
        } else {
            view.backgroundColor = .black // interior fills the frame; no felt behind
            scene.background.contents = UIColor.black
        }
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false // SwiftUI keeps the pour swipe
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true // motion drives physics nonstop

        // Until the first real motion sample lands (and always in the
        // simulator), assume the natural hold: phone reclined ~25° from
        // flat, the way a seated player actually looks at a screen.
        scene.physicsWorld.gravity = restingGravity()
        scene.physicsWorld.timeStep = 1.0 / 120.0
        scene.physicsWorld.contactDelegate = self

        buildCup()
        buildLights()
        buildCamera()
        if Self.isLoadDemoActive {
            // Sim-verify hook: the loading-mirror flow can't be driven
            // end-to-end without a real table broadcasting `loadedDice`,
            // so this ignores whatever count the hosting SwiftUI view
            // passed in and drives the exact same "start empty, spawn one
            // die per increment" timeline that a live broadcast would —
            // see `scheduleLoadDemo`.
            seedDice(count: 0)
            scheduleLoadDemo()
        } else {
            seedDice(count: diceCount)
        }

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
    /// - deepLookIn: SAME mapping as lookIn — it's the same camera-at-the-
    ///   mouth-looking-down setup, just a taller shaft underneath it. Face-
    ///   up phone → dice still pressed onto the floor, just a lot farther
    ///   from the lens now. (This is deliberate: the concept it replaced,
    ///   glass-bottom, used a DIFFERENT mapping — camera looking UP through
    ///   the base — which is exactly what made its gravity read backwards.
    ///   Reusing lookIn's mapping here is the actual fix.)
    private func mapToCup(x: Double, y: Double, z: Double) -> SCNVector3 {
        switch concept {
        case .crossSection:
            return SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
        case .lookIn, .deepLookIn:
            return SCNVector3(CGFloat(x), CGFloat(z), CGFloat(-y))
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
        guard concept == .crossSection else {
            buildPhotoBackedCup()
            return
        }
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

        // Floor: red felt — where the dice actually rest. crossSection-only
        // now (lookIn/deepLookIn get an invisible physics floor instead;
        // see `buildPhotoBackedCup` — their felt is the photo underneath).
        let floor = SCNCylinder(radius: cupInnerRadius + cupWall, height: 0.6)
        let floorFelt = SCNMaterial()
        floorFelt.diffuse.contents = CupSurfaces.feltFloorDiffuse()
        floorFelt.normal.contents = CupSurfaces.feltFloorNormal()
        CupSurfaces.applyFiltering(floorFelt)
        floorFelt.lightingModel = .blinn
        floorFelt.specular.contents = UIColor(white: 0.14, alpha: 1)
        floorFelt.shininess = 0.06
        floor.materials = [floorFelt]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.3, 0) // top surface at y = 0
        floorNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: floor, options: nil))
            // Felt-lined base: grippy enough to bite a rolling die,
            // restitution low so landings THUD and die fast.
            body.friction = 0.62
            body.restitution = 0.26
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(floorNode)

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

    /// lookIn / deepLookIn: the photoreal replacement for the block above.
    /// No leather/felt/rim/sky geometry gets built at all — the picked
    /// photo (`CupConcept.photoBackdropImageName`, drawn by
    /// `DiceCupSceneView`'s UIImageView) IS the cup, visually. All this
    /// builds is what the PHYSICS still needs: an invisible wall + floor
    /// sized by `photoContainerRadius` so a die resting at the wall lines
    /// up with the photo's own rim/interior circle, plus a shadow-catcher
    /// plane so real dice cast real shadows onto the photo underneath.
    private func buildPhotoBackedCup() {
        let radius = photoContainerRadius

        // Invisible wall: same leather-over-wood feel as the tube it
        // replaces (friction/restitution unchanged) — just nothing here is
        // ever assigned to `node.geometry`, so there's nothing to render,
        // matching `DiceScenePhysics.boundsNode`'s own invisible-collider
        // trick.
        let wallShape = SCNTube(innerRadius: radius, outerRadius: radius + cupWall, height: cupHeight)
        let wallNode = SCNNode()
        wallNode.position = SCNVector3(0, cupHeight / 2, 0)
        wallNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: wallShape,
                                       options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]))
            body.friction = 0.55
            body.restitution = 0.28
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(wallNode)

        // Invisible floor: same felt-ish grip/bounce as the procedural
        // floor it replaces — the photo's own felt is the visible floor.
        let floorShape = SCNCylinder(radius: radius + cupWall, height: 0.6)
        let floorNode = SCNNode()
        floorNode.position = SCNVector3(0, -0.3, 0) // top surface at y = 0
        floorNode.physicsBody = {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(geometry: floorShape, options: nil))
            body.friction = 0.62
            body.restitution = 0.26
            body.categoryBitMask = Dice3D.boundsCategory
            body.collisionBitMask = Dice3D.dieCategory
            return body
        }()
        scene.rootNode.addChildNode(floorNode)

        // Shadow catcher: a REAL (rendered) plane at floor height, but
        // with a `.shadowOnly` material (iOS 11+) — every pixel is fully
        // transparent except where the scene's shadow-casting key light
        // (see buildLights) says a die's shadow falls, so the only thing
        // this plane ever draws is a soft shadow landing on the photo.
        // Verification note: SceneKit shadows don't render in the iOS
        // Simulator at all (confirmed earlier, wave 3/4, against the
        // crossSection/lookIn shadow-casters — a Simulator-side limitation,
        // not a config bug) — this plane compiles and stays fully clear
        // there either way, which is the correct "no shadow, no crash"
        // behavior to verify in sim. The shadow itself needs a real device.
        let shadowPlane = SCNPlane(width: (radius + cupWall) * 2.4,
                                   height: (radius + cupWall) * 2.4)
        let shadowMaterial = SCNMaterial()
        shadowMaterial.lightingModel = .shadowOnly
        shadowMaterial.isDoubleSided = true
        shadowMaterial.writesToDepthBuffer = false
        shadowPlane.materials = [shadowMaterial]
        let shadowNode = SCNNode(geometry: shadowPlane)
        shadowNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // lie flat, facing up
        shadowNode.position = SCNVector3(0, 0.02, 0) // a hair above the floor body — no z-fighting
        shadowNode.castsShadow = false
        scene.rootNode.addChildNode(shadowNode)

        // Invisible lid: same "hard shakes never launch dice out of frame"
        // job as crossSection's, just widened to comfortably clear this
        // concept's own (photo-calibrated) wall radius — deepLookIn's is
        // bigger than the old fixed 30-unit span.
        let lidSpan = max(30, (radius + cupWall) * 2.4)
        scene.rootNode.addChildNode(DiceScenePhysics.boundsNode(
            width: lidSpan, height: 1, length: lidSpan,
            position: SCNVector3(0, cupHeight + 1.6, 0)))
    }

    private func buildLights() {
        // Dim warm ambient so the cup shades darker away from the mouth.
        // The deep look-in runs noticeably dimmer ambient than the other
        // two — with a 34-unit shaft, ambient has to stay out of the way
        // for the local lights below to actually CREATE the falloff the
        // concept is built around, instead of ambient flattening it back
        // out into an evenly-lit tube.
        let ambient = SCNNode()
        ambient.light = {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = concept == .deepLookIn ? 150 : 260
            light.color = UIColor(red: 1.0, green: 0.90, blue: 0.78, alpha: 1)
            return light
        }()
        scene.rootNode.addChildNode(ambient)

        // The room lamp beyond the mouth: warm light entering from the
        // opening, falling off down the cup. For the deep look-in its
        // range is deliberately SHORT (spent by mid-shaft, nowhere near
        // reaching the floor 34 units down) — that falloff, not a longer
        // reach, is what sells the depth; `deepLookIn`'s own floor pool
        // light (below) handles the "subtle pooling" at the bottom.
        let lamp = SCNNode()
        lamp.light = {
            let light = SCNLight()
            light.type = .omni
            light.intensity = concept == .deepLookIn ? 2200 : 1600
            light.color = UIColor(red: 1.0, green: 0.93, blue: 0.80, alpha: 1)
            light.attenuationStartDistance = 6
            light.attenuationEndDistance = concept == .deepLookIn ? 26 : 46
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

        case .deepLookIn:
            // Rim glow: warm light hugging the camera/rim — the "warm
            // light from the rim behind the camera" the redesign calls
            // for. Short attenuation range ON PURPOSE: spent well before
            // mid-shaft, which is what makes the middle of the tube read
            // as dim and the depth as real, instead of one evenly-lit
            // tube with a floor at the bottom of it.
            let rimGlow = SCNNode()
            rimGlow.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 1500
                light.color = UIColor(red: 1.0, green: 0.90, blue: 0.72, alpha: 1)
                light.attenuationStartDistance = 2
                light.attenuationEndDistance = 20
                return light
            }()
            rimGlow.position = SCNVector3(0, cupHeight + 1.5, 0)
            scene.rootNode.addChildNode(rimGlow)

            // A dim straight-down key so the floor and the dice resting
            // on it stay legible at all — much weaker than lookIn's own
            // (700): its job here is filling in the shadow the rim glow
            // above leaves in the lower third, not lighting the whole
            // shaft (that would kill the falloff the concept depends on).
            // Also the shadow-caster for the photo pass (see
            // buildPhotoBackedCup's shadowPlane): it's the only directional
            // light already aimed straight down the cup's own axis, so it
            // doubles as the one light the shadow-only catcher plane needs
            // — same shadow tuning as lookIn's own key light below.
            let key = SCNNode()
            key.light = {
                let light = SCNLight()
                light.type = .directional
                light.intensity = 260
                light.color = UIColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1)
                light.castsShadow = true
                light.shadowMode = .forward
                light.shadowColor = UIColor.black.withAlphaComponent(0.5)
                light.shadowRadius = 6
                light.shadowSampleCount = 8
                light.orthographicScale = photoContainerRadius * 1.1
                return light
            }()
            key.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            scene.rootNode.addChildNode(key)

            // Floor pool: a small warm light sitting just above the felt
            // so the bottom of the shaft — where the dice actually live —
            // gets its own soft pool of light instead of reading as flat
            // black between the rim glow above and nothing else. This is
            // the "subtle light pooling on the floor" the redesign calls
            // for; its short range keeps it from re-lighting the shaft.
            let floorPool = SCNNode()
            floorPool.light = {
                let light = SCNLight()
                light.type = .omni
                light.intensity = 420
                light.color = UIColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
                light.attenuationStartDistance = 1
                light.attenuationEndDistance = 9
                return light
            }()
            floorPool.position = SCNVector3(0, 2.4, 0)
            scene.rootNode.addChildNode(floorPool)
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
        case .deepLookIn:
            // Straight down, hovering above the rim — far enough back for
            // the rim to actually land IN frame. The rim torus's outer
            // extent is ringRadius(cupInnerRadius + cupWall/2) + pipeRadius
            // ≈ 6.3 (see `buildCup`); at a 100° FOV (50° half-angle) that
            // needs the camera roughly height/tan(46°) ≈ 6 units above the
            // rim to sit just inside the frame edge with a hair of margin —
            // any closer (this used to sit at +2.4) and the rim is simply
            // OUTSIDE the frustum, invisible, which is what the first pass
            // at this got wrong. At that height the interior wall spans
            // roughly 7° (near the distant floor) to ~46° (near the rim) of
            // the frame, so "the outer circle hugs the screen edges" while
            // the shaft telescopes down to the floor in the middle (real
            // dice-cup proportions — see cupHeight). Comfortably clears the
            // invisible lid (`cupHeight + 1.6`, built in `buildCup()`), so
            // a hard-shaken die can still get right up near the lens
            // without ever visually passing through/behind it.
            camera.fieldOfView = 100
            cameraNode.position = SCNVector3(0, cupHeight + 6.0, 0)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
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

    /// Whether `-autoCupLoadDemo` is on the launch line (see `attach` and
    /// `scheduleLoadDemo`).
    private static var isLoadDemoActive: Bool {
        CommandLine.arguments.contains("-autoCupLoadDemo")
    }

    /// Full reseed: clears every die and rebuilds `count` of them from
    /// scratch at their resting spread. This is the ORIGINAL `setDiceCount`
    /// body — still what runs for the very first seed (see `attach`) and
    /// whenever the target count DROPS (chip count changed under us, rare
    /// enough not to warrant its own animation). Increments no longer come
    /// through here — see `setDiceCount` below.
    private func seedDice(count: Int) {
        let clamped = max(0, min(3, count))
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
                // lookIn/deepLookIn: the camera sits ON the tube's own
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

    /// Called from `updateUIView` whenever the SwiftUI side's target dice
    /// count changes. During the loading-mirror phase (owner feedback:
    /// "you should be able to see each die entering the cup") this fires
    /// once per `loadedDice` broadcast — one real die dragged into the
    /// table's cup — and a HIGHER target than what's currently in the
    /// scene means dice arrived: spawn just the new one(s) falling in from
    /// the mouth (`spawnFromMouth`), leaving every die already resting in
    /// the cup completely untouched — no rebuild, no flash, same physics
    /// world throughout. Once `cupReady` flips true the target stops
    /// changing (it's already at the full count), so this stays silent
    /// through the rest of the turn. A target that DROPS falls back to a
    /// full reseed — that direction was never spec'd to animate and is
    /// rare enough (a chip count changing mid-turn) not to need to.
    func setDiceCount(_ count: Int) {
        guard !Self.isLoadDemoActive else { return } // the demo timeline owns dice count
        let clamped = max(0, min(3, count))
        if clamped == dice.count { return }
        if clamped > dice.count {
            spawnFromMouth(additional: clamped - dice.count)
        } else {
            seedDice(count: clamped)
        }
    }

    /// Drops `additional` new dice in from the cup's mouth with real
    /// downward velocity — the loading-mirror's actual "watch it enter the
    /// cup" moment, and the same beat `-autoCupLoadDemo` exercises. Each
    /// spawned die is a normal physics body from the instant it appears:
    /// it falls under the SAME gravity as everything else, and the very
    /// next contact it makes fires the ordinary rattle audio/haptic
    /// (`DiceContactThrottle` doesn't know or care how a die got airborne)
    /// — the "impact" the owner asked for comes for free, not bespoke.
    private func spawnFromMouth(additional: Int) {
        guard additional > 0 else { return }
        for _ in 0..<additional {
            guard dice.count < 3 else { break }
            let die = DieNode(lcrDie: dice.count)
            die.physicsBody?.damping = 0.30
            die.physicsBody?.angularDamping = 0.45
            die.physicsBody?.rollingFriction = 0.55
            die.position = mouthSpawnPoint()
            die.eulerAngles = SCNVector3(CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)),
                                         CGFloat.random(in: 0..<(2 * .pi)))
            // "Downward" here means whichever direction gravity actually
            // pulls in THIS concept's mapping (see `restingGravity`) — a
            // kick-start in the direction the die was going to fall
            // anyway, not a hardcoded world axis that could point the
            // wrong way in the cross-section's tilted frame.
            let fall = CupVector.normalized(restingGravity())
            let speed: Float = 6.0
            die.physicsBody?.velocity = SCNVector3(fall.x * speed + Float.random(in: -0.4...0.4),
                                                    fall.y * speed,
                                                    fall.z * speed + Float.random(in: -0.4...0.4))
            scene.rootNode.addChildNode(die)
            dice.append(die)
        }
    }

    /// Where a newly-loaded die enters, near the mouth. For the
    /// cross-section this reuses its own frustum helper (near the top of
    /// the safe cone, i.e. mouth-ward) so the drop is actually IN the
    /// camera's tight view — a die spawned at the tube's true geometric
    /// mouth would very likely land outside that concept's narrow frame
    /// and never be seen entering at all. lookIn/deepLookIn sit on the
    /// tube's own axis of symmetry, so a simple near-mouth point with a
    /// little scatter (clearing the 5.2 inner radius easily) is in frame
    /// by construction.
    private func mouthSpawnPoint() -> SCNVector3 {
        if concept == .crossSection,
           let point = crossSectionSpawnPoint(depth: 6.2, lateralFraction: .random(in: -0.5...0.5),
                                              verticalFraction: 0.8) {
            return point
        }
        return SCNVector3(CGFloat.random(in: -1.3...1.3), cupHeight - 1.4,
                          CGFloat.random(in: -1.3...1.3))
    }

    /// Sim-verify hook for the loading mirror: `-autoCupLoadDemo` starts
    /// the scene empty (see `attach`) and this fires one `spawnFromMouth`
    /// every 2s until there are 3 dice in the cup, then stops itself — the
    /// exact spawn-on-increment path a live `loadedDice` broadcast would
    /// drive, screenshot-able mid-sequence without needing a real table.
    private func scheduleLoadDemo() {
        loadDemoTimer?.invalidate()
        loadDemoTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.dice.count < 3 else { timer.invalidate(); return }
            self.spawnFromMouth(additional: 1)
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
        // The deep look-in's camera sits at the mouth looking down the
        // shaft — a shake still needs a touch more lift than the classic
        // cup for a hard rattle to bring a die up near the lens, but with
        // the cup back at REAL proportions (~1.33× diameter deep, owner
        // feedback: the 34-unit first pass was "not physically possible")
        // the old 1.9× overshot violently into the lid. ~1.25× peaks a
        // hard shake just under the mouth (v²/2g against
        // `DiceScenePhysics.cupGravityStrength`). Scoped to `lift` alone:
        // the lateral/rattle feel elsewhere is unchanged.
        let axisScale: CGFloat = concept == .deepLookIn ? 1.25 : 1.0
        let lift = Dice3D.mass * axisScale * (hard ? CGFloat.random(in: 26...36)
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
/// CupSurfaces for that) — just the room glow through the mouth. Generated
/// once, cached.
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
