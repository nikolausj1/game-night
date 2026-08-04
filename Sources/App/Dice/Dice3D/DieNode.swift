import SceneKit
import UIKit

/// Shared constants for the 3D dice world. One die is 2.0 scene units on a
/// side everywhere (table and cup); views scale the WORLD around the die,
/// never the die itself, so physics tuning holds across screens.
enum Dice3D {
    /// Die edge length, scene units.
    static let side: CGFloat = 2.0
    /// Rounded-edge radius (real dice are heavily chamfered).
    static let chamfer: CGFloat = side * 0.18

    // Physics material — tuned for a lively-but-settling tumble.
    static let mass: CGFloat = 0.02
    static let restitution: CGFloat = 0.42
    static let friction: CGFloat = 0.55
    static let rollingFriction: CGFloat = 0.09
    static let angularDamping: CGFloat = 0.18

    /// Physics categories.
    static let dieCategory = 1 << 0
    static let boundsCategory = 1 << 1
}

/// One physical die: a chamfered SCNBox with six independently textured
/// faces and a dynamic physics body. The face on each local axis is
/// recorded so DieFaceReader can turn a settled orientation back into a
/// game result.
final class DieNode: SCNNode {
    /// Which LcrFace lives on each local axis, ordered
    /// [+X, −X, +Y, −Y, +Z, −Z] — the order DieFaceReader indexes by.
    let axisFaces: [LcrFace]

    /// A standard LCR die: three dot sides, one L, one R, one C. Physics
    /// rolls a fair 1/6 per face, so the classic 1/2-dot distribution
    /// falls out of the geometry for free.
    init(lcrDie index: Int) {
        // +X: L   −X: R   +Y: dot   −Y: dot   +Z: C   −Z: dot
        axisFaces = [.left, .right, .dot, .dot, .center, .dot]
        super.init()

        let box = SCNBox(width: Dice3D.side, height: Dice3D.side,
                         length: Dice3D.side, chamferRadius: Dice3D.chamfer)
        box.chamferSegmentCount = 6

        // SCNBox material order: front(+Z), right(+X), back(−Z), left(−X),
        // top(+Y), bottom(−Y).
        let images: [UIImage] = [
            DieFaceTextures.letter("C"),   // +Z
            DieFaceTextures.letter("L"),   // +X
            DieFaceTextures.pip(),         // −Z
            DieFaceTextures.letter("R"),   // −X
            DieFaceTextures.pip(),         // +Y
            DieFaceTextures.pip(),         // −Y
        ]
        // Slight per-die warmth jitter so a spilled handful doesn't look
        // like clones of one die.
        let tint = UIColor(hue: 0.115,
                           saturation: CGFloat.random(in: 0.015...0.06),
                           brightness: CGFloat.random(in: 0.965...1.0),
                           alpha: 1)
        box.materials = images.map { image in
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.multiply.contents = tint
            material.lightingModel = .blinn
            material.specular.contents = UIColor(white: 0.55, alpha: 1)
            material.shininess = 0.35
            material.diffuse.mipFilter = .linear
            return material
        }
        geometry = box
        name = "die\(index)"

        let body = SCNPhysicsBody(
            type: .dynamic,
            shape: SCNPhysicsShape(geometry: box, options: nil)) // convex hull of the rounded cube
        body.mass = Dice3D.mass
        body.restitution = Dice3D.restitution
        body.friction = Dice3D.friction
        body.rollingFriction = Dice3D.rollingFriction
        body.angularDamping = Dice3D.angularDamping
        body.categoryBitMask = Dice3D.dieCategory
        body.collisionBitMask = Dice3D.dieCategory | Dice3D.boundsCategory
        body.contactTestBitMask = Dice3D.dieCategory | Dice3D.boundsCategory
        physicsBody = body
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
}

/// Programmatic 512px face textures: warm ivory stock with edge shading,
/// engraved-look red serif letters, and inked pips. Generated once and
/// cached — every die shares the same images (per-die variation comes from
/// the material multiply tint).
enum DieFaceTextures {
    private static var cache: [String: UIImage] = [:]
    private static let size: CGFloat = 512

    static func letter(_ glyph: String) -> UIImage {
        cached("letter-\(glyph)") { context in
            drawIvoryBase(context)
            drawEngravedLetter(glyph, context: context)
        }
    }

    /// Single centered pip — the LCR "dot" face.
    static func pip() -> UIImage {
        cached("pip-1") { context in
            drawIvoryBase(context)
            drawPip(at: CGPoint(x: size / 2, y: size / 2), context: context)
        }
    }

    /// Standard casino pip layouts, 1–6, for future dice games.
    static func standard(_ value: Int) -> UIImage {
        cached("std-\(value)") { context in
            drawIvoryBase(context)
            let lo = size * 0.26, mid = size * 0.5, hi = size * 0.74
            let layouts: [Int: [CGPoint]] = [
                1: [CGPoint(x: mid, y: mid)],
                2: [CGPoint(x: lo, y: lo), CGPoint(x: hi, y: hi)],
                3: [CGPoint(x: lo, y: lo), CGPoint(x: mid, y: mid), CGPoint(x: hi, y: hi)],
                4: [CGPoint(x: lo, y: lo), CGPoint(x: hi, y: lo),
                    CGPoint(x: lo, y: hi), CGPoint(x: hi, y: hi)],
                5: [CGPoint(x: lo, y: lo), CGPoint(x: hi, y: lo), CGPoint(x: mid, y: mid),
                    CGPoint(x: lo, y: hi), CGPoint(x: hi, y: hi)],
                6: [CGPoint(x: lo, y: lo), CGPoint(x: hi, y: lo),
                    CGPoint(x: lo, y: mid), CGPoint(x: hi, y: mid),
                    CGPoint(x: lo, y: hi), CGPoint(x: hi, y: hi)],
            ]
            for point in layouts[max(1, min(6, value))] ?? [] {
                drawPip(at: point, context: context, radius: size * 0.075)
            }
        }
    }

    // MARK: drawing

    private static func cached(_ key: String,
                               draw: (CGContext) -> Void) -> UIImage {
        if let hit = cache[key] { return hit }
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                return format
            }())
        let image = renderer.image { draw($0.cgContext) }
        cache[key] = image
        return image
    }

    /// Ivory stock: warm white with a soft top-lit gradient and darker
    /// vignetted edges so the chamfers read as worn corners.
    private static func drawIvoryBase(_ context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let space = CGColorSpaceCreateDeviceRGB()

        // Vertical light gradient.
        let top = UIColor(red: 0.985, green: 0.975, blue: 0.935, alpha: 1)
        let bottom = UIColor(red: 0.905, green: 0.885, blue: 0.83, alpha: 1)
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [top.cgColor, bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: .zero,
                                       end: CGPoint(x: 0, y: size),
                                       options: [])
        }
        // Radial edge vignette — center stays bright, edges dim slightly.
        let clear = UIColor(white: 0, alpha: 0)
        let edge = UIColor(red: 0.28, green: 0.24, blue: 0.16, alpha: 0.20)
        if let vignette = CGGradient(colorsSpace: space,
                                     colors: [clear.cgColor, clear.cgColor, edge.cgColor] as CFArray,
                                     locations: [0, 0.62, 1]) {
            context.drawRadialGradient(vignette,
                                       startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size * 0.72,
                                       options: [])
        }
        _ = rect
    }

    /// Engraved serif letter: dark bite offset toward the light, paper
    /// catch-light offset away, crimson fill between them.
    private static func drawEngravedLetter(_ glyph: String, context: CGContext) {
        let font = UIFont(name: "Georgia-Bold", size: size * 0.62)
            ?? UIFont.systemFont(ofSize: size * 0.62, weight: .black)
        let center = CGPoint(x: size / 2, y: size / 2)

        func draw(_ color: UIColor, offset: CGPoint) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let text = NSAttributedString(string: glyph, attributes: attrs)
            let bounds = text.boundingRect(with: CGSize(width: size, height: size),
                                           options: .usesLineFragmentOrigin, context: nil)
            text.draw(at: CGPoint(x: center.x - bounds.width / 2 + offset.x,
                                  y: center.y - bounds.height / 2 + offset.y))
        }
        UIGraphicsPushContext(context)
        draw(UIColor(red: 0.30, green: 0.02, blue: 0.02, alpha: 0.85),
             offset: CGPoint(x: -size * 0.006, y: -size * 0.009)) // shadow wall
        draw(UIColor(white: 1, alpha: 0.75),
             offset: CGPoint(x: size * 0.006, y: size * 0.011))   // catch light
        draw(UIColor(red: 0.72, green: 0.09, blue: 0.09, alpha: 1), offset: .zero)
        UIGraphicsPopContext()
    }

    /// Inked pip with a concave shading gradient and a small catch light.
    private static func drawPip(at point: CGPoint, context: CGContext,
                                radius: CGFloat = 0) {
        let r = radius > 0 ? radius : size * 0.105
        let space = CGColorSpaceCreateDeviceRGB()
        // Recess shadow ring just outside the pip.
        context.setFillColor(UIColor(white: 1, alpha: 0.55).cgColor)
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r + r * 0.14,
                                       width: r * 2, height: r * 2))
        // Pip body: near-black with a slightly lighter bottom (light bounce).
        let dark = UIColor(red: 0.06, green: 0.05, blue: 0.05, alpha: 1)
        let lift = UIColor(red: 0.22, green: 0.19, blue: 0.17, alpha: 1)
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [dark.cgColor, lift.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.saveGState()
            context.addEllipse(in: CGRect(x: point.x - r, y: point.y - r,
                                          width: r * 2, height: r * 2))
            context.clip()
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: point.x, y: point.y - r),
                                       end: CGPoint(x: point.x, y: point.y + r),
                                       options: [])
            context.restoreGState()
        }
        // Tiny specular dot.
        context.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
        context.fillEllipse(in: CGRect(x: point.x - r * 0.38, y: point.y - r * 0.55,
                                       width: r * 0.5, height: r * 0.35))
    }
}
