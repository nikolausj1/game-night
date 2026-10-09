import SwiftUI
import UIKit

// MARK: - Card stock textures

/// Seamless linen / casino-stock texture for every card face and back.
///
/// Two layers, both periodic by construction so tiling can never show a seam:
///   - `linen`   : warm multiply tile (thread weave, slubs, fiber mottle).
///   - `speckle` : sparse screen tile of "pits" that sit in the weave
///                 valleys — laid over printed ink it breaks the ink up the
///                 way a press does on real stock, so ink sits IN the paper.
///
/// If a photographic `CardStockLinen` imageset is bundled it wins for the
/// linen layer (mirrored 2x2 once at load so ANY image tiles seamlessly —
/// the house lesson from FeltTile); otherwise the procedural tile below is
/// used. Both are built once and cached for the app's lifetime.
enum CardStock {
    /// Edge of the tile in points (384 px at 3x).
    static let tilePoints: CGFloat = 128

    static let linen: UIImage = {
        if let base = UIImage(named: "CardStockLinen") {
            return mirroredTile(base, targetPoints: tilePoints)
        }
        return procedural.linen
    }()

    static let speckle: UIImage = procedural.speckle

    /// Deterministic 0..<1000 hash of a card id (djb2, same family as
    /// CardFaceView.wearSeed / TableGeometry.jitterDegrees).
    static func seed(_ id: String) -> Int {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(hash % 1000)
    }

    /// Texture visibility vs. card width. The tile has a fixed physical pitch
    /// (~2pt threads), so on tiny chips it would read as noise: fade it out
    /// below ~52pt and reach full strength by ~112pt. Hand cards (~117pt)
    /// and table cards (~140pt) sit on the plateau.
    static func visibility(width w: CGFloat) -> Double {
        let t = min(1, max(0, Double((w - 52) / (112 - 52))))
        return t * t * (3 - 2 * t)
    }

    // MARK: asset path

    /// 2x2 mirror of a possibly non-tileable image, re-scaled so the whole
    /// 2x2 block spans 2 * targetPoints.
    private static func mirroredTile(_ base: UIImage, targetPoints: CGFloat) -> UIImage {
        let side = targetPoints   // each quadrant is targetPoints square-ish
        let size = CGSize(width: side * 2, height: side * 2)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            base.draw(in: rect)
            cg.saveGState(); cg.translateBy(x: side * 2, y: 0); cg.scaleBy(x: -1, y: 1)
            base.draw(in: rect); cg.restoreGState()
            cg.saveGState(); cg.translateBy(x: 0, y: side * 2); cg.scaleBy(x: 1, y: -1)
            base.draw(in: rect); cg.restoreGState()
            cg.saveGState(); cg.translateBy(x: side * 2, y: side * 2); cg.scaleBy(x: -1, y: -1)
            base.draw(in: rect); cg.restoreGState()
        }
    }

    // MARK: procedural path

    private static let procedural: (linen: UIImage, speckle: UIImage) = {
        let n = 384          // pixels per side; 3x => 128pt
        let pitch = 6        // thread pitch in px (2pt); divides n => periodic
        let threads = n / pitch
        var rng = SplitMix64(seed: 0x4C49_4E45_4E31)

        func unit() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

        // Per-thread gain, and a periodic 1D "slub" noise along each thread.
        let warpGain = (0..<threads).map { _ in 0.72 + 0.28 * unit() }
        let weftGain = (0..<threads).map { _ in 0.72 + 0.28 * unit() }
        let slubCells = 24
        let warpSlub = (0..<threads).map { _ in (0..<slubCells).map { _ in unit() } }
        let weftSlub = (0..<threads).map { _ in (0..<slubCells).map { _ in unit() } }

        func smooth1D(_ a: [Double], _ t: Double) -> Double {
            let c = a.count
            let f = t * Double(c)
            let i0 = Int(f) % c, i1 = (i0 + 1) % c
            let k = f - floor(f)
            let s = k * k * (3 - 2 * k)
            return a[i0] * (1 - s) + a[i1] * s
        }

        // Periodic 2D value noise for fiber mottle.
        func makeGrid(_ cells: Int) -> [Double] { (0..<(cells * cells)).map { _ in unit() } }
        let gridA = makeGrid(8), gridB = makeGrid(24)
        func smooth2D(_ g: [Double], _ cells: Int, _ u: Double, _ v: Double) -> Double {
            let fx = u * Double(cells), fy = v * Double(cells)
            let x0 = Int(fx) % cells, y0 = Int(fy) % cells
            let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
            let kx = fx - floor(fx), ky = fy - floor(fy)
            let sx = kx * kx * (3 - 2 * kx), sy = ky * ky * (3 - 2 * ky)
            let a = g[y0 * cells + x0] * (1 - sx) + g[y0 * cells + x1] * sx
            let b = g[y1 * cells + x0] * (1 - sx) + g[y1 * cells + x1] * sx
            return a * (1 - sy) + b * sy
        }

        // Pass 1: raw "darkness" per pixel (0 = fiber crest, bigger = valley).
        var dark = [Double](repeating: 0, count: n * n)
        var sum = 0.0
        for y in 0..<n {
            let v = Double(y) / Double(n)
            let j = y / pitch
            let fy = Double(y % pitch) / Double(pitch)
            let wy = 0.5 - 0.5 * cos(2 * .pi * fy)
            for x in 0..<n {
                let u = Double(x) / Double(n)
                let i = x / pitch
                let fx = Double(x % pitch) / Double(pitch)
                let wx = 0.5 - 0.5 * cos(2 * .pi * fx)
                let warp = wx * warpGain[i] * (0.82 + 0.36 * smooth1D(warpSlub[i], v))
                let weft = wy * weftGain[j] * (0.82 + 0.36 * smooth1D(weftSlub[j], u))
                let over = ((i + j) & 1) == 0
                let crest = over ? (0.68 * warp + 0.32 * weft) : (0.68 * weft + 0.32 * warp)
                let mottle = 0.62 * smooth2D(gridA, 8, u, v) + 0.38 * smooth2D(gridB, 24, u, v)
                let grain = unit()
                var d = 0.78 * pow(max(0, 1 - crest), 1.15) + 0.34 * mottle + 0.05 * grain
                d = max(0, d)
                dark[y * n + x] = d
                sum += d
            }
        }
        let mean = sum / Double(n * n)
        let maxD = dark.max() ?? 1

        // Pass 2: linen (warm multiply) + speckle (screen pits).
        var linenPx = [UInt8](repeating: 255, count: n * n * 4)
        var speckPx = [UInt8](repeating: 0, count: n * n)
        let targetMeanDark = 0.060          // mean multiply ~0.94 (paper stays bright)
        let gain = targetMeanDark / max(mean, 0.0001)
        for p in 0..<(n * n) {
            let d = dark[p] * gain
            // Sepia-warm shadows: blue falls fastest, so fibers read as aged
            // paper rather than gray dirt.
            let r = 1 - d * 0.90
            let g = 1 - d * 1.04
            let b = 1 - d * 1.32
            linenPx[p * 4 + 0] = UInt8(max(0, min(255, r * 255)))
            linenPx[p * 4 + 1] = UInt8(max(0, min(255, g * 255)))
            linenPx[p * 4 + 2] = UInt8(max(0, min(255, b * 255)))
            linenPx[p * 4 + 3] = 255
            // Pits live in the deepest valleys, and only some of them.
            let depth = dark[p] / maxD
            let pit = max(0, (depth - 0.58) / 0.42)
            let ink = pit * pit * (0.35 + 0.65 * unit())
            speckPx[p] = UInt8(max(0, min(255, ink * 0.9 * 255)))
        }

        func makeImage(_ bytes: [UInt8], gray: Bool) -> UIImage {
            let cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
            let bpp = gray ? 1 : 4
            let info: CGBitmapInfo = gray
                ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8 * bpp,
                                   bytesPerRow: n * bpp, space: cs, bitmapInfo: info,
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent)
            else { return UIImage() }
            return UIImage(cgImage: cg, scale: 3, orientation: .up)
        }
        return (makeImage(linenPx, gray: false), makeImage(speckPx, gray: true))
    }()
}

/// Tiny deterministic PRNG so the procedural tile is identical on every
/// launch and device.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Material overlay

/// Everything that makes a printed face/back read as physical stock, as one
/// overlay clipped to the card's rounded rect. Purely visual, hit-test free.
///
///  - linen weave    : `.multiply` tile (warm), the paper itself
///  - ink pickup     : `.screen` pit tile — ink sits IN the paper
///  - edge wear      : grimed border, scuffed corners, a hairline bevel
///
/// Opacity rules (see `CardStock.visibility`): everything scales by card
/// width so 40-60pt chips stay clean and 110-150pt cards carry the full
/// effect. `linen`/`ink`/`wear` are per-surface multipliers: UNO fields use
/// a low `linen` so saturated color is not dulled.
struct CardMaterial: View {
    let width: CGFloat
    var seed: Int = 0
    var linen: Double = 1
    var ink: Double = 1
    var wear: Double = 1

    var body: some View {
        let w = width
        let h = w / CardStyle.aspectRatio
        let radius = CardStyle.cornerRadius(width: w)
        let vis = CardStock.visibility(width: w)
        // Per-card weave phase so neighbors in a fan don't share thread
        // positions (tile is periodic, any offset is seamless).
        let tile = CardStock.tilePoints
        let px = CGFloat(seed % 128) / 128 * tile
        let py = CGFloat((seed / 7) % 128) / 128 * tile

        ZStack {
            if vis > 0.01 {
                if linen > 0 {
                    tiled(CardStock.linen, w: w, h: h, dx: px, dy: py)
                        .blendMode(.multiply)
                        .opacity(0.95 * linen * vis)
                }
                if ink > 0 {
                    tiled(CardStock.speckle, w: w, h: h, dx: py, dy: px)
                        .blendMode(.screen)
                        .opacity(0.34 * ink * vis)
                }
            }
            if wear > 0 {
                wearLayer(w: w, h: h, radius: radius, vis: vis)
                    .opacity(wear)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
    }

    private func tiled(_ image: UIImage, w: CGFloat, h: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        let tile = CardStock.tilePoints * (image.size.width > CardStock.tilePoints * 1.5 ? 2 : 1)
        return Image(uiImage: image)
            .resizable(resizingMode: .tile)
            .frame(width: w + tile * 2, height: h + tile * 2)
            .offset(x: -dx, y: -dy)
            .frame(width: w, height: h, alignment: .topLeading)
    }

    private func wearLayer(w: CGFloat, h: CGFloat, radius: CGFloat, vis: Double) -> some View {
        // Four corner scuff strengths from the seed (0.3...1).
        let s0 = 0.3 + 0.7 * Double((seed * 13) % 17) / 16
        let s1 = 0.3 + 0.7 * Double((seed * 7) % 13) / 12
        let s2 = 0.3 + 0.7 * Double((seed * 5) % 11) / 10
        let s3 = 0.3 + 0.7 * Double((seed * 3) % 19) / 18
        let strengths = [s0, s1, s2, s3]
        return Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            // Handled-edge grime: a soft sepia band hugging the border.
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: w * 0.004))
                layer.stroke(shape.path(in: rect.insetBy(dx: w * 0.004, dy: w * 0.004)),
                             with: .color(Color(red: 0.45, green: 0.34, blue: 0.20).opacity(0.17)),
                             lineWidth: w * 0.014)
            }
            // Corner scuffs: thumb-worn, darker and slightly gray.
            let r = w * 0.20
            let centers = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                           CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            for (c, s) in zip(centers, strengths) {
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.fill(circle, with: .radialGradient(
                    Gradient(colors: [Color(red: 0.42, green: 0.33, blue: 0.22).opacity(0.17 * s), .clear]),
                    center: c, startRadius: 0, endRadius: r))
            }
            // Hairline bevel where the lamp catches the top-left edge.
            ctx.stroke(shape.path(in: rect.insetBy(dx: 0.3, dy: 0.3)),
                       with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.65), .white.opacity(0.0), .black.opacity(0.10)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
                       lineWidth: 0.6)
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Thickness

/// A thin dark stack of paper edges peeking out below / right of a card.
/// Barely there at rest, thicker as the card lifts (elevation 0...1).
struct CardEdgeStack: View {
    let width: CGFloat
    var elevation: CGFloat = 0

    var body: some View {
        let radius = CardStyle.cornerRadius(width: width)
        let t = max(0.6, width * 0.0055) + elevation * width * 0.016
        ZStack {
            // Two sheets: the paper edge itself and the shadow line under it.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(red: 0.30, green: 0.25, blue: 0.19).opacity(0.55))
                .offset(x: t * 0.55, y: t)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(red: 0.74, green: 0.69, blue: 0.60).opacity(0.85))
                .offset(x: t * 0.28, y: t * 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Specular sheen

/// Light-on-glossy-stock state for one card, injected by the hand fan.
/// Tables and menus never set it, so their cards pay nothing for sheen.
struct CardSheen: Equatable {
    /// HandMotion tilt (already low-passed), roughly -1...1. Zero under
    /// Reduce Motion (HandMotion never starts), which makes the sheen static.
    var tiltX: Double = 0
    var tiltY: Double = 0
    /// The card's own fan rotation in degrees. Offsets the highlight phase so
    /// the fan reads as one curved surface under one lamp.
    var fanAngle: Double = 0
    /// 0...1 — how strongly this card catches the light (top/lifted card most).
    var strength: Double = 0.6

    /// Highlight band center along the card's diagonal (0 = top-left corner,
    /// 1 = bottom-right). 0.62 per full tilt-x sweep, 0.25 per tilt-y sweep,
    /// 0.022 per degree of fan angle (a +-18 degree fan spreads the band
    /// across ~0.8 of a card).
    var bandCenter: Double {
        0.5 + 0.62 * tiltX + 0.25 * tiltY + 0.022 * fanAngle
    }
}

private struct CardSheenKey: EnvironmentKey {
    static let defaultValue: CardSheen? = nil
}

extension EnvironmentValues {
    var cardSheen: CardSheen? {
        get { self[CardSheenKey.self] }
        set { self[CardSheenKey.self] = newValue }
    }
}

/// One gradient, no blur: a faint diagonal band that slides with tilt.
/// The gradient stops never move — the start/end points translate along the
/// diagonal, so there is nothing to re-tessellate and band edges can never
/// collide or leave the 0...1 stop range.
struct CardSheenLayer: View {
    let sheen: CardSheen
    var elevation: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = CardStyle.cornerRadius(width: w)
            let c = sheen.bandCenter
            // Out of range: band is entirely off the card, draw nothing.
            if c > -0.45 && c < 1.45 {
                let k = min(1, sheen.strength + Double(elevation) * 0.25)
                let delta = c - 0.5
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0.00),
                            .init(color: .white.opacity(0.030 * k), location: 0.26),
                            .init(color: .white.opacity(0.200 * k), location: 0.47),
                            .init(color: .white.opacity(0.230 * k), location: 0.50),
                            .init(color: .white.opacity(0.060 * k), location: 0.60),
                            .init(color: .white.opacity(0.0), location: 0.74),
                            .init(color: .white.opacity(0.050 * k), location: 0.86),
                            .init(color: .white.opacity(0.0), location: 1.00)
                        ],
                        startPoint: UnitPoint(x: delta, y: delta),
                        endPoint: UnitPoint(x: 1 + delta, y: 1 + delta)))
            }
        }
        .allowsHitTesting(false)
    }
}
