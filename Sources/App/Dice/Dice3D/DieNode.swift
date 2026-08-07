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

    // Physics material — tuned for a real thrown-dice feel. SceneKit
    // (Bullet underneath) COMBINES restitution/friction of the two bodies
    // in a contact multiplicatively, so these are calibrated as pairs:
    //   die 0.70 × felt floor 0.35  → ~0.25 effective (felt kills bounce)
    //   die 0.70 × die 0.70         → ~0.49 effective (bone-on-bone is lively)
    //   die 0.60 × felt floor 1.00  → ~0.60 effective grip (dice bite, tumble)
    // Rolling friction starts LOW so the throw carries, then the table
    // scene ramps it (plus damping) as a die slows — dice tumble-stop in
    // about a second instead of gliding like pucks.
    static let mass: CGFloat = 0.02
    static let restitution: CGFloat = 0.70
    static let friction: CGFloat = 0.60
    static let rollingFriction: CGFloat = 0.05
    static let angularDamping: CGFloat = 0.12

    /// Physics categories.
    static let dieCategory = 1 << 0
    static let boundsCategory = 1 << 1
}

/// One physical die: a chamfered SCNBox with six independently textured
/// faces and a dynamic physics body. The face on each local axis is
/// recorded so DieFaceReader can turn a settled orientation back into a
/// game result. Two face styles share this same geometry/physics recipe
/// (see the private `build` helper below) — only the six face images and
/// which axis-data array is meaningful differ between them:
///  - `.lcr` (`init(lcrDie:)`): LCR's three letters + dot, read back via
///    `axisFaces`/`DieFaceReader.upFace`.
///  - `.pips` (`init(pipDie:)`): a standard 1-6 pip die for Yahtzee/Zilch/
///    Shut the Box, read back via `axisPipValues`/`DieFaceReader.upPipValue`.
final class DieNode: SCNNode {
    /// Which face style this instance actually is — lets DieFaceReader (or
    /// anything else) branch without guessing from the axis arrays.
    let faceStyle: DieFaceStyle
    /// Which LcrFace lives on each local axis, ordered
    /// [+X, −X, +Y, −Y, +Z, −Z] — the order DieFaceReader indexes by.
    /// Meaningful only when `faceStyle == .lcr`; a `.pips` die carries an
    /// unused all-`.dot` placeholder here so this stays non-optional.
    let axisFaces: [LcrFace]
    /// Which 1-6 value lives on each local axis, same [+X, −X, +Y, −Y,
    /// +Z, −Z] order. Meaningful only when `faceStyle == .pips`; an
    /// `.lcr` die carries an unused all-zero placeholder here.
    let axisPipValues: [Int]

    /// A standard LCR die: three dot sides, one L, one R, one C. Physics
    /// rolls a fair 1/6 per face, so the classic 1/2-dot distribution
    /// falls out of the geometry for free.
    init(lcrDie index: Int) {
        // +X: L   −X: R   +Y: dot   −Y: dot   +Z: C   −Z: dot
        axisFaces = [.left, .right, .dot, .dot, .center, .dot]
        axisPipValues = Array(repeating: 0, count: 6) // unused for .lcr dice
        faceStyle = .lcr
        super.init()

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
        Self.build(self, images: images, index: index)
    }

    /// A standard 1-6 pip die for the roll-and-score games (Yahtzee,
    /// Zilch, Shut the Box): opposite faces sum to 7, the universal
    /// Western/casino convention. Physics rolls a fair 1/6 per face
    /// exactly like the LCR die above — only the face art and
    /// DieFaceReader's mapping differ.
    init(pipDie index: Int) {
        // +X: 2   −X: 5   +Y: 3   −Y: 4   +Z: 1   −Z: 6  (each pair sums to 7)
        axisPipValues = [2, 5, 3, 4, 1, 6]
        axisFaces = Array(repeating: .dot, count: 6) // unused for .pips dice
        faceStyle = .pips
        super.init()

        // Same SCNBox material order as the LCR die above.
        let images: [UIImage] = [
            DieFaceTextures.standard(1), // +Z
            DieFaceTextures.standard(2), // +X
            DieFaceTextures.standard(6), // −Z
            DieFaceTextures.standard(5), // −X
            DieFaceTextures.standard(3), // +Y
            DieFaceTextures.standard(4), // −Y
        ]
        Self.build(self, images: images, index: index)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    /// Shared geometry + physics-body construction for both face styles —
    /// called after `super.init()` once each initializer above has set its
    /// own axis data; only the six face `images` (and the die's own random
    /// jitter, re-rolled per instance either way) differ from here on.
    private static func build(_ node: DieNode, images: [UIImage], index: Int) {
        let box = SCNBox(width: Dice3D.side, height: Dice3D.side,
                         length: Dice3D.side, chamferRadius: Dice3D.chamfer)
        box.chamferSegmentCount = 6

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
        node.geometry = box
        node.name = "die\(index)"

        let body = SCNPhysicsBody(
            type: .dynamic,
            shape: SCNPhysicsShape(geometry: box, options: nil)) // convex hull of the rounded cube
        // No two real dice are identical: tiny paint-fill and drilling
        // asymmetries shift mass and inertia. Jitter both (and the surface
        // coefficients a whisker) so every die in a throw rolls its own way.
        body.mass = Dice3D.mass * CGFloat.random(in: 0.90...1.12)
        body.usesDefaultMomentOfInertia = false
        let inertia = body.mass * Dice3D.side * Dice3D.side / 6 // uniform cube baseline
        body.momentOfInertia = SCNVector3(inertia * CGFloat.random(in: 0.82...1.22),
                                          inertia * CGFloat.random(in: 0.82...1.22),
                                          inertia * CGFloat.random(in: 0.82...1.22))
        body.restitution = Dice3D.restitution + CGFloat.random(in: -0.05...0.04)
        body.friction = Dice3D.friction + CGFloat.random(in: -0.05...0.06)
        body.rollingFriction = Dice3D.rollingFriction
        body.angularDamping = Dice3D.angularDamping + CGFloat.random(in: -0.02...0.03)
        body.categoryBitMask = Dice3D.dieCategory
        body.collisionBitMask = Dice3D.dieCategory | Dice3D.boundsCategory
        body.contactTestBitMask = Dice3D.dieCategory | Dice3D.boundsCategory
        node.physicsBody = body
    }
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

    /// Standard casino pip layouts, 1–6 — the roll-and-score games'
    /// (Yahtzee/Zilch/Shut the Box) face art, built on the same ivory
    /// stock/inked-pip pipeline as LCR's own dot face.
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
            // Classic casino/craps convention: every pip is inked black
            // except the lone center pip on the 1 face, which is red — the
            // one splash of color a real pip die carries.
            let color = value == 1 ? Self.redPip : Self.blackPip
            for point in layouts[max(1, min(6, value))] ?? [] {
                drawPip(at: point, context: context, radius: size * 0.075, color: color)
            }
        }
    }

    private static let blackPip = UIColor(red: 0.06, green: 0.05, blue: 0.05, alpha: 1)
    private static let redPip = UIColor(red: 0.72, green: 0.09, blue: 0.09, alpha: 1)

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
    /// `color` is the pip's own ink (near-black by default — the LCR dot
    /// face and every non-1 pip on a standard die; `standard(_:)` passes
    /// red in for the 1 face's lone center pip, the classic casino tell).
    private static func drawPip(at point: CGPoint, context: CGContext,
                                radius: CGFloat = 0, color: UIColor = blackPip) {
        let r = radius > 0 ? radius : size * 0.105
        let space = CGColorSpaceCreateDeviceRGB()
        // Recess shadow ring just outside the pip.
        context.setFillColor(UIColor(white: 1, alpha: 0.55).cgColor)
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r + r * 0.14,
                                       width: r * 2, height: r * 2))
        // Pip body: `color` (near-black, or red for the 1's center pip)
        // with a slightly lighter bottom (light bounce) — same shading
        // recipe either way, just tinted.
        let lift = lightened(color, by: 0.16)
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [color.cgColor, lift.cgColor] as CFArray,
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

    /// `color` blended `fraction` of the way toward white — used to derive
    /// a pip's "light bounce" bottom stop from whatever ink color it's
    /// drawn in (near-black normally, red for the 1's center pip) instead
    /// of hardcoding a second color per ink.
    private static func lightened(_ color: UIColor, by fraction: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * fraction, green: g + (1 - g) * fraction,
                       blue: b + (1 - b) * fraction, alpha: a)
    }
}
