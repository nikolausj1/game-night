import UIKit
import CoreGraphics
import SceneKit

/// NOTE (night 2): UNUSED. The last procedural cup (cross-section's felt
/// tube) was replaced by a photo (`CupInteriorCrossSection`), so nothing
/// calls these anymore; kept only until the lead decides to delete the file.
///
/// Procedural surfaces for the perfected cross-section cup: deep red wool
/// felt lining the interior (walls + floor) and burnished, stitched
/// leather on the rim — the one "exterior" surface a player ever actually
/// sees, since every camera in this file lives INSIDE the cup. Everything
/// here is diffuse + tangent-space normal maps built from a tiny seeded
/// noise field, generated once and cached; no bundled texture assets, so
/// there's nothing to ship or go missing.
///
/// The old approach (see git history) painted flat gradients and dashed
/// lines straight into the diffuse map — the audit called it out as "a
/// flat brown gradient with blurry blobs." Real depth needs the light to
/// actually catch bumps, so every surface below carries a genuine normal
/// map: felt grain, leather hide grain, and raised stitch ridges you can
/// see rock back and forth as the light source (or the phone) moves.
enum CupSurfaces {
    private static var cache: [String: UIImage] = [:]
    /// 384px is plenty of grain detail for a texture that wraps a tube a
    /// few inches from the eye, and keeps the one-time generation cost
    /// (a handful of full-image noise passes) comfortably under a frame.
    private static let size = 384

    /// Mipmapped + linearly filtered sampling for both the diffuse and
    /// normal slots. Without this, the fine per-pixel grain in these
    /// textures aliases into visible static/shimmer wherever a surface is
    /// seen at a minified angle (the floor, mainly, viewed near
    /// edge-on) — a texture-quality bug, not a lighting one, and easy to
    /// mistake for the other since both show up as "the felt looks noisy."
    static func applyFiltering(_ material: SCNMaterial) {
        for property in [material.diffuse, material.normal] {
            property.mipFilter = .linear
            property.minificationFilter = .linear
            property.magnificationFilter = .linear
        }
    }

    // MARK: - Felt (interior: walls + floor)

    /// Photoreal pass (wave 4): the diffuse maps now come straight off the
    /// generated `CupFeltTile`/`CupLeatherTile` photo textures instead of
    /// the fully procedural color fields below — a plain woven-fiber
    /// close-up is a clean win over hand-painted noise. The NORMAL maps
    /// stay 100% procedural: they're derived from the same height fields
    /// that used to also drive color, so the bump detail (and the
    /// hard-won mipmapping/mirror-wrap antialiasing fix) is unchanged —
    /// only what's painted ON TOP of that bump changed.
    static func feltWallDiffuse() -> UIImage {
        cached("felt-wall-d") { photoImage("CupFeltTile") ?? felt(wornCenter: false, channel: .diffuse) }
    }

    static func feltWallNormal() -> UIImage {
        cached("felt-wall-n") { felt(wornCenter: false, channel: .normal) }
    }

    static func feltFloorDiffuse() -> UIImage {
        cached("felt-floor-d") { photoImage("CupFeltTile") ?? felt(wornCenter: true, channel: .diffuse) }
    }

    static func feltFloorNormal() -> UIImage {
        cached("felt-floor-n") { felt(wornCenter: true, channel: .normal) }
    }

    // MARK: - Rim: burnished leather, stitched, with a brass trim band

    /// The rim's diffuse is a COMPOSITE, not a straight photo swap: the
    /// brass band and raised stitch dashes are identity features of this
    /// cup (and are baked as real height-field bumps, not just paint) that
    /// a flat leather swatch photo can't reproduce on its own. `rim(...)`
    /// now samples `CupLeatherTile`'s actual pixels for the hide color
    /// wherever neither of those overlays applies, tinted by the same
    /// height field for a little shading variance — real leather grain
    /// under the brass/stitch detail instead of procedural noise under it.
    static func rimLeatherDiffuse() -> UIImage {
        cached("rim-leather-d") { rim(channel: .diffuse) }
    }

    static func rimLeatherNormal() -> UIImage {
        cached("rim-leather-n") { rim(channel: .normal) }
    }

    /// The generated photo texture, resampled to this file's working
    /// resolution so it composites pixel-for-pixel with the procedural
    /// normal maps and overlay masks. `nil` if the asset is somehow
    /// missing from the bundle — callers fall back to the old procedural
    /// diffuse rather than drawing nothing.
    private static func photoImage(_ name: String) -> UIImage? {
        guard let source = UIImage(named: name), let cg = source.cgImage else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// Raw RGBA bytes of a resampled photo texture, for per-pixel sampling
    /// (the rim composite needs to read leather color under its brass/
    /// stitch masks, not just hand it to SceneKit as a flat material map).
    private static func photoPixels(_ name: String) -> [UInt8]? {
        guard let image = photoImage(name), let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    // MARK: - Felt generation

    private enum Channel { case diffuse, normal }

    /// Deep red wool felt: a mid-frequency "weave" undulation plus a fine
    /// per-pixel grain on top (the actual fiber texture), darkened in the
    /// low spots (crevices) rather than just tinted uniformly. `wornCenter`
    /// adds the floor's pale worn patch where dice have lived.
    private static func felt(wornCenter: Bool, channel: Channel) -> UIImage {
        var height = HeightField.fractal(size: size, seed: 4001, baseCells: 5, octaves: 3)
        // Lower frequency than the first cut (24 cells, not 56) and a
        // lighter blend weight: the higher-frequency version aliased into
        // a sparkly "TV static" look wherever the felt was seen at a
        // minified, close-to-grazing angle (the floor, mostly, seen from
        // nearly overhead) — normal-map specular aliasing, not a lighting
        // bug. This is the actual fix; mipmapping alone didn't clear it.
        let grain = HeightField.fractal(size: size, seed: 4177, baseCells: 24, octaves: 1)
        for i in 0..<height.count { height[i] = height[i] * 0.70 + grain[i] * 0.30 }

        switch channel {
        case .normal:
            return NoiseImage.normalMap(height: height, size: size, strength: 1.3)
        case .diffuse:
            let crevice = UIColor(red: 0.24, green: 0.028, blue: 0.045, alpha: 1)
            let fiber = UIColor(red: 0.58, green: 0.075, blue: 0.10, alpha: 1)
            var pixels = [UInt8](repeating: 255, count: size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let h = height[y * size + x]
                    var color = crevice.mixed(with: fiber, t: CGFloat(h))
                    if wornCenter {
                        let dx = CGFloat(x) / CGFloat(size) - 0.5
                        let dy = CGFloat(y) / CGFloat(size) - 0.5
                        let worn = max(0, 1 - sqrt(dx * dx + dy * dy) / 0.32)
                        color = color.mixed(with: fiber.mixed(with: .white, t: 0.12), t: worn * 0.34)
                    }
                    NoiseImage.write(color, at: x, y, into: &pixels, size: size)
                }
            }
            return NoiseImage.image(from: pixels, size: size)
        }
    }

    // MARK: - Rim leather generation

    /// Hide-grain leather with a raised stitch line (dash pattern baked
    /// into the HEIGHT field, not just painted) near the mouth edge, and a
    /// burnished brass band lower on the roll — "warm brass rim band"
    /// meeting "leather with visible grain and stitching."
    private static func rim(channel: Channel) -> UIImage {
        var height = HeightField.fractal(size: size, seed: 5501, baseCells: 6, octaves: 3)
        let micro = HeightField.fractal(size: size, seed: 5730, baseCells: 48, octaves: 1)
        for i in 0..<height.count { height[i] = height[i] * 0.72 + micro[i] * 0.28 }

        // Stitch band: a row of short raised dashes, one full wrap around
        // U. Baked as a real bump so it reads under any light angle. Sits
        // right at the brass band's edge — wherever around the pipe's
        // circumference the camera happens to be looking, it lands close
        // to SOME accent detail rather than a big plain run of hide.
        let stitchRow = Int(0.22 * CGFloat(size))
        let dashLen = max(3, size / 34)
        let gap = max(2, size / 46)
        var x = 0
        var stitchMask = [Bool](repeating: false, count: size * size)
        while x < size {
            let end = min(size, x + dashLen)
            for px in x..<end {
                for dy in -2...2 {
                    let py = stitchRow + dy
                    guard py >= 0, py < size else { continue }
                    let falloff = 1 - Float(abs(dy)) / 3
                    let idx = py * size + px
                    height[idx] = min(1, height[idx] + 0.6 * falloff)
                    if dy == 0 { stitchMask[idx] = true }
                }
            }
            x = end + gap
        }

        // Brass band: a smoothed strip (height pulled toward a flat mid
        // value — burnished metal doesn't have hide grain) with fine
        // horizontal brushed streaks layered back in. Wide (a third of the
        // pipe's circumference) so it's a real identity feature of the
        // rim, not a sliver that only shows from one exact angle.
        let brassStart = Int(0.32 * CGFloat(size))
        let brassEnd = Int(0.66 * CGFloat(size))
        let brushed = HeightField.brushedStreaks(size: size, seed: 6100, rows: 90)
        var brassMask = [Bool](repeating: false, count: size * size)
        if brassStart < brassEnd {
            for y in brassStart..<brassEnd {
                for xPix in 0..<size {
                    let idx = y * size + xPix
                    height[idx] = 0.5 + (brushed[idx] - 0.5) * 0.5
                    brassMask[idx] = true
                }
            }
        }

        switch channel {
        case .normal:
            // Metal wants a much subtler bump than leather grain, or the
            // brass reads as hammered instead of burnished — the height
            // field already carries a gentler swing there (see above),
            // so one strength value works for the whole map.
            return NoiseImage.normalMap(height: height, size: size, strength: 2.1)
        case .diffuse:
            // Brighter than the interior felt's palette on purpose: the
            // rim's actual on-screen position (far from the eye, lit at a
            // grazing angle from the mouth) needs headroom or it crushes
            // to near-black — a real rolled edge should still read as
            // warm tan leather even in shade, not a dark smear.
            let hideDark = UIColor(red: 0.32, green: 0.185, blue: 0.10, alpha: 1)
            let hideLight = UIColor(red: 0.52, green: 0.325, blue: 0.185, alpha: 1)
            let thread = UIColor(red: 0.80, green: 0.64, blue: 0.36, alpha: 1)
            let brassDark = UIColor(red: 0.52, green: 0.37, blue: 0.15, alpha: 1)
            let brassLight = UIColor(red: 0.88, green: 0.71, blue: 0.36, alpha: 1)
            // Real leather grain under the hide areas, wherever the photo
            // texture is available — see `photoPixels` above.
            let leatherPhoto = photoPixels("CupLeatherTile")
            var pixels = [UInt8](repeating: 255, count: size * size * 4)
            for y in 0..<size {
                for xPix in 0..<size {
                    let idx = y * size + xPix
                    let h = height[idx]
                    let color: UIColor
                    if brassMask[idx] {
                        color = brassDark.mixed(with: brassLight, t: CGFloat(h))
                    } else if stitchMask[idx] {
                        color = thread
                    } else if let leatherPhoto {
                        // Photo color, gently shaded by the SAME height
                        // field driving the bump — real grain sits under
                        // real light-and-dark variation instead of a flat
                        // texture stamp.
                        let base = idx * 4
                        let shade = 0.78 + 0.32 * CGFloat(h)
                        let r = CGFloat(leatherPhoto[base]) / 255 * shade
                        let g = CGFloat(leatherPhoto[base + 1]) / 255 * shade
                        let b = CGFloat(leatherPhoto[base + 2]) / 255 * shade
                        color = UIColor(red: min(1, r), green: min(1, g), blue: min(1, b), alpha: 1)
                    } else {
                        color = hideDark.mixed(with: hideLight, t: CGFloat(h))
                    }
                    NoiseImage.write(color, at: xPix, y, into: &pixels, size: size)
                }
            }
            return NoiseImage.image(from: pixels, size: size)
        }
    }

    private static func cached(_ key: String, build: () -> UIImage) -> UIImage {
        if let hit = cache[key] { return hit }
        let image = build()
        cache[key] = image
        return image
    }
}

// MARK: - Noise plumbing

/// A tiny deterministic xorshift64 generator. Swift's SystemRandomNumberGenerator
/// isn't seedable, and texture generation needs to be stable across runs (so the
/// cache — and a screenshot diff, if anyone ever wants one — doesn't flicker).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Fractal value noise: cheap, seedable, and plenty organic at texture
/// scale once a couple of octaves are stacked. No external noise library —
/// this is the whole implementation.
private enum HeightField {
    /// Sums `octaves` layers of bilinear-interpolated random grids, each
    /// doubling in cell density and halving in amplitude, normalized to
    /// 0...1.
    static func fractal(size: Int, seed: UInt64, baseCells: Int, octaves: Int) -> [Float] {
        var field = [Float](repeating: 0, count: size * size)
        var amplitude: Float = 1
        var totalAmplitude: Float = 0
        var cells = max(2, baseCells)
        for octave in 0..<octaves {
            var rng = SeededRNG(seed: seed &+ UInt64(octave) &* 7919)
            let gridSize = cells + 1
            var grid = [Float](repeating: 0, count: gridSize * gridSize)
            for i in 0..<grid.count { grid[i] = Float.random(in: 0...1, using: &rng) }
            for y in 0..<size {
                let fy = Float(y) / Float(size) * Float(cells)
                let y0 = min(cells - 1, Int(fy))
                let ty = smoothstep(fy - Float(y0))
                for x in 0..<size {
                    let fx = Float(x) / Float(size) * Float(cells)
                    let x0 = min(cells - 1, Int(fx))
                    let tx = smoothstep(fx - Float(x0))
                    let v00 = grid[y0 * gridSize + x0]
                    let v10 = grid[y0 * gridSize + x0 + 1]
                    let v01 = grid[(y0 + 1) * gridSize + x0]
                    let v11 = grid[(y0 + 1) * gridSize + x0 + 1]
                    let vx0 = v00 + (v10 - v00) * tx
                    let vx1 = v01 + (v11 - v01) * tx
                    field[y * size + x] += (vx0 + (vx1 - vx0) * ty) * amplitude
                }
            }
            totalAmplitude += amplitude
            amplitude *= 0.5
            cells *= 2
        }
        if totalAmplitude > 0 {
            for i in 0..<field.count { field[i] /= totalAmplitude }
        }
        return field
    }

    /// Horizontal brushed-metal streaks: one 1D noise row, replicated down
    /// every scanline with a slight per-row jitter so the streaks aren't
    /// perfectly parallel copies of each other.
    static func brushedStreaks(size: Int, seed: UInt64, rows: Int) -> [Float] {
        var rng = SeededRNG(seed: seed)
        let row = fractal(size: size, seed: seed, baseCells: rows, octaves: 2)
        var field = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let jitter = Int.random(in: -1...1, using: &rng)
            for x in 0..<size {
                let sx = ((x + jitter) % size + size) % size
                field[y * size + x] = row[sx]
            }
        }
        return field
    }

    private static func smoothstep(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}

/// Turns a heightfield into a tangent-space normal map (finite differences,
/// wrapped at the edges since every surface here tiles), and provides the
/// small RGBA scratch buffer plumbing the diffuse passes share.
private enum NoiseImage {
    static func normalMap(height: [Float], size: Int, strength: Float) -> UIImage {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let yUp = (y + 1) % size
            let yDown = (y - 1 + size) % size
            for x in 0..<size {
                let xRight = (x + 1) % size
                let xLeft = (x - 1 + size) % size
                let hL = height[y * size + xLeft]
                let hR = height[y * size + xRight]
                let hD = height[yDown * size + x]
                let hU = height[yUp * size + x]
                let dx = (hR - hL) * strength
                let dy = (hU - hD) * strength
                var nx = -dx, ny = -dy, nz: Float = 1
                let len = max(0.0001, sqrt(nx * nx + ny * ny + nz * nz))
                nx /= len; ny /= len; nz /= len
                let idx = (y * size + x) * 4
                pixels[idx + 0] = UInt8(max(0, min(255, (nx * 0.5 + 0.5) * 255)))
                pixels[idx + 1] = UInt8(max(0, min(255, (ny * 0.5 + 0.5) * 255)))
                pixels[idx + 2] = UInt8(max(0, min(255, (nz * 0.5 + 0.5) * 255)))
                pixels[idx + 3] = 255
            }
        }
        return image(from: pixels, size: size)
    }

    static func write(_ color: UIColor, at x: Int, _ y: Int, into pixels: inout [UInt8], size: Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let idx = (y * size + x) * 4
        pixels[idx + 0] = UInt8(max(0, min(255, r * 255)))
        pixels[idx + 1] = UInt8(max(0, min(255, g * 255)))
        pixels[idx + 2] = UInt8(max(0, min(255, b * 255)))
        pixels[idx + 3] = UInt8(max(0, min(255, a * 255)))
    }

    static func image(from pixels: [UInt8], size: Int) -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        var data = pixels
        let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData)!
        let cgImage = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                              provider: provider, decode: nil, shouldInterpolate: true,
                              intent: .defaultIntent)!
        return UIImage(cgImage: cgImage)
    }
}

private extension UIColor {
    /// Linear RGB mix — used everywhere above instead of hand-rolled lerp
    /// math on raw components.
    func mixed(with other: UIColor, t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let c = max(0, min(1, t))
        return UIColor(red: r1 + (r2 - r1) * c, green: g1 + (g2 - g1) * c,
                       blue: b1 + (b2 - b1) * c, alpha: a1 + (a2 - a1) * c)
    }
}
