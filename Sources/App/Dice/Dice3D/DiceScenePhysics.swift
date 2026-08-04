import SceneKit
import UIKit

/// Shared physics-world plumbing for both dice scenes (table + cup):
/// gravity, invisible static bounds, the shadow-catching floor, and the
/// rate-limited contact-sound gate.
enum DiceScenePhysics {
    /// Scaled-up gravity: at our world scale (a die is 2 units), true 9.8
    /// reads floaty — 2.2× gives the snap of real bone on felt.
    static let gravity = SCNVector3(0, -9.8 * 2.2, 0)

    /// An invisible static collider box. No geometry is attached to the
    /// node at all — the physics shape alone does the work, so there is
    /// nothing to render, hide, or shadow.
    static func boundsNode(width: CGFloat, height: CGFloat, length: CGFloat,
                           position: SCNVector3) -> SCNNode {
        let node = SCNNode()
        node.position = position
        let shape = SCNPhysicsShape(
            geometry: SCNBox(width: width, height: height, length: length, chamferRadius: 0))
        let body = SCNPhysicsBody(type: .static, shape: shape)
        body.friction = 0.5
        body.restitution = 0.4
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
    static func physicsFloor() -> SCNNode {
        let node = SCNNode()
        let body = SCNPhysicsBody(
            type: .static,
            shape: SCNPhysicsShape(geometry: SCNBox(width: 600, height: 1, length: 600,
                                                    chamferRadius: 0),
                                   options: nil))
        body.friction = 0.55
        body.restitution = 0.38
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
            let dark = UIColor(white: 0, alpha: 0.85)
            let mid = UIColor(white: 0, alpha: 0.32)
            let clear = UIColor(white: 0, alpha: 0)
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [dark.cgColor, mid.cgColor, clear.cgColor] as CFArray,
                locations: [0, 0.55, 1]) {
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
        let spread = 1 + CGFloat(height) * 0.10
        simdPosition = simd_float3(p.x + 0.28 + height * 0.10,
                                   0.04,
                                   p.z + 0.24 + height * 0.08)
        scale = SCNVector3(spread, spread, spread)
        opacity = CGFloat(max(0.06, 0.60 / Double(1 + height * 0.45)))
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
    private let onClack: (_ strength: Double) -> Void

    /// `onClack` is always invoked on the main queue; strength is 0…1.
    init(minInterval: TimeInterval = 0.09, minImpulse: CGFloat = 0.012,
         onClack: @escaping (_ strength: Double) -> Void) {
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
        DispatchQueue.main.async { [onClack] in onClack(strength) }
    }
}
