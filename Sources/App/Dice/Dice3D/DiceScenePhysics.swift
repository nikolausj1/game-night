import SceneKit
import UIKit

/// Shared physics-world plumbing for both dice scenes (table + cup):
/// gravity, invisible static bounds, the shadow-catching floor, and the
/// rate-limited contact-sound gate.
enum DiceScenePhysics {
    /// Scaled-up gravity. At our world scale a die is 2 units for ~16mm of
    /// real bone, so TRUE scale gravity would be ~1200 units/s² — pure 9.8
    /// reads like the moon. 5× is the sweet spot found by eye: throws
    /// arc down hard, bounces die fast, and a frozen frame mid-roll looks
    /// like a thrown die instead of a drifting balloon.
    static let gravity = SCNVector3(0, -9.8 * 5.6, 0)

    /// The cup runs the SAME scaled-up gravity as the table (5.6×). It
    /// used to run 2.6× "so dice don't glue to the wall", but the field
    /// verdict was floaty — dice drifted like balloons instead of
    /// THUDDING. Real weight comes from full gravity plus heavier per-die
    /// damping in the cup (see DiceCupSceneCoordinator.setDiceCount);
    /// shake impulses are scaled up to match so a rattle still fills the
    /// cup.
    static let cupGravityStrength: CGFloat = 9.8 * 5.6

    /// An invisible static collider box. No geometry is attached to the
    /// node at all — the physics shape alone does the work, so there is
    /// nothing to render, hide, or shadow. `name` defaults to a generic
    /// tag; the table scene overrides it to "rail-wall" so
    /// `DiceContactThrottle` can tell a rail knock from a felt landing by
    /// node identity alone (the cup scene doesn't care and leaves it
    /// default).
    static func boundsNode(width: CGFloat, height: CGFloat, length: CGFloat,
                           position: SCNVector3, name: String = "bounds") -> SCNNode {
        let node = SCNNode()
        node.name = name
        node.position = position
        let shape = SCNPhysicsShape(
            geometry: SCNBox(width: width, height: height, length: length, chamferRadius: 0))
        let body = SCNPhysicsBody(type: .static, shape: shape)
        // Padded wood rail: some life (die 0.7 × 0.5 → ~0.35 effective)
        // but it doesn't launch dice back across the table.
        body.friction = 0.4
        body.restitution = 0.5
        body.categoryBitMask = Dice3D.boundsCategory
        body.collisionBitMask = Dice3D.dieCategory
        node.physicsBody = body
        return node
    }

    /// The invisible physics floor (top surface at y = 0). Rendering-wise
    /// there is nothing here — the SwiftUI felt IS the floor visually, and
    /// dice shadows come from DieShadowNode planes (SceneKit's shadow-map
    /// recipes all proved unreliable against a transparent SCNView with an
    /// orthographic camera; tracked contact shadows always work).
    static func physicsFloor(name: String = "floor") -> SCNNode {
        let node = SCNNode()
        node.name = name
        let body = SCNPhysicsBody(
            type: .static,
            shape: SCNPhysicsShape(geometry: SCNBox(width: 600, height: 1, length: 600,
                                                    chamferRadius: 0),
                                   options: nil))
        // Felt over wood: high grip (bites the die into a tumble instead of
        // a slide) and bounce-killing restitution — die 0.7 × 0.35 → ~0.25
        // effective, so a thrown die bounces once or twice and dies.
        body.friction = 1.0
        body.restitution = 0.35
        body.categoryBitMask = Dice3D.boundsCategory
        body.collisionBitMask = Dice3D.dieCategory
        // Shape is centered on the node; sink it so the top surface is y=0.
        node.position = SCNVector3(0, -0.5, 0)
        node.physicsBody = body
        return node
    }

    /// Key + fill lighting shared by both scenes. Shadow maps are OFF —
    /// dice shadows are tracked DieShadowNode planes instead.
    static func addLights(to scene: SCNScene, shadowScale: CGFloat) {
        let ambient = SCNNode()
        ambient.light = {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 520
            light.color = UIColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            return light
        }()
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 720
            light.color = UIColor(red: 1.0, green: 0.98, blue: 0.94, alpha: 1)
            return light
        }()
        // Overhead lamp, biased down-right — matches the shadow offset
        // baked into DieShadowNode.
        key.position = SCNVector3(12, 60, 10)
        key.eulerAngles = SCNVector3(-Float.pi * 0.42, -0.35, 0)
        scene.rootNode.addChildNode(key)
        _ = shadowScale
    }
}

/// A soft contact shadow that rides under one die: a radial-gradient dark
/// plane lying just above the floor, repositioned every frame from the
/// die's presentation transform. Low dice get a tight dark pool; airborne
/// dice get a wider, fainter, offset one — the separation between die and
/// shadow is exactly what makes a bounce READ as height.
final class DieShadowNode: SCNNode {
    private static let texture: UIImage = {
        let size: CGFloat = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size),
                                       format: format).image { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let dark = UIColor(white: 0, alpha: 0.90)
            let mid = UIColor(white: 0, alpha: 0.30)
            let clear = UIColor(white: 0, alpha: 0)
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [dark.cgColor, mid.cgColor, clear.cgColor] as CFArray,
                // Tighter core (0.42 vs the old 0.55) so the dark part of
                // the pool hugs the die instead of a wide soft outline.
                locations: [0, 0.42, 1]) {
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
        let plane = SCNPlane(width: Dice3D.side * 1.75, height: Dice3D.side * 1.75)
        let material = SCNMaterial()
        material.diffuse.contents = Self.texture
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        plane.materials = [material]
        geometry = plane
        eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // lie flat
        castsShadow = false
        opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    /// Per-frame update from the render delegate (no allocations).
    /// `floorY` is the resting height of a die's center (side/2 on a flat
    /// floor); height above that drives the spread/fade.
    func track(_ die: DieNode, floorY: Float) {
        let p = die.presentation.simdWorldPosition
        let height = max(0, p.y - floorY)
        // Tighter than before at rest (0.82× the die instead of a full
        // 1×) so a settled die reads as PRESSED into the felt — a real
        // contact shadow hugs the object, it doesn't outline it — and
        // grows/softens as the die lifts off, same as before.
        let spread = 0.82 + CGFloat(height) * 0.11
        simdPosition = simd_float3(p.x + 0.20 + height * 0.10,
                                   0.04,
                                   p.z + 0.17 + height * 0.08)
        scale = SCNVector3(spread, spread, spread)
        opacity = CGFloat(max(0.05, 0.74 / Double(1 + height * 0.55)))
    }
}

/// Rate-limited, impulse-gated contact sound + haptic gate. SceneKit's
/// contact delegate fires from the physics thread in bursts; this hands a
/// clean, capped stream of "one audible clack" events to the main thread
/// so the sound always matches what the eyes see, never a machine gun.
final class DiceContactThrottle {
    private var lastFire = Date.distantPast
    private let minInterval: TimeInterval
    private let minImpulse: CGFloat
    private let onClack: (_ strength: Double, _ contactClass: DiceContactClass) -> Void

    /// `onClack` is always invoked on the main queue; strength is 0…1.
    init(minInterval: TimeInterval = 0.09, minImpulse: CGFloat = 0.012,
         onClack: @escaping (_ strength: Double, _ contactClass: DiceContactClass) -> Void) {
        self.minInterval = minInterval
        self.minImpulse = minImpulse
        self.onClack = onClack
    }

    /// Call from `physicsWorld(_:didBegin:)` (any thread).
    func register(_ contact: SCNPhysicsContact) {
        guard contact.collisionImpulse > minImpulse else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) > minInterval else { return }
        lastFire = now
        let strength = min(1.0, Double(contact.collisionImpulse / (minImpulse * 14)))
        let contactClass = Self.classify(contact)
        DispatchQueue.main.async { [onClack] in onClack(strength, contactClass) }
    }

    /// Which material actually hit which: both nodes named "die*" → bone-
    /// on-bone; a die against the node named "rail-wall" → the rail; a die
    /// against anything else (the felt floor, by construction) → felt.
    /// Node identity is deliberately the ONLY signal here — cheap, and it
    /// can't drift out of sync with the physics the way a velocity/height
    /// heuristic could.
    private static func classify(_ contact: SCNPhysicsContact) -> DiceContactClass {
        let nameA = contact.nodeA.name ?? ""
        let nameB = contact.nodeB.name ?? ""
        let aIsDie = nameA.hasPrefix("die")
        let bIsDie = nameB.hasPrefix("die")
        if aIsDie && bIsDie { return .die }
        let other = aIsDie ? nameB : nameA
        return other == "rail-wall" ? .rail : .felt
    }
}
