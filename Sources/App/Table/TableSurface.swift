import SwiftUI

/// One table "skin": every color and knob TableSurface needs to paint the
/// felt + rail + lighting. `classicClub` reproduces the original hard-coded
/// look exactly; the others are art-directed variants.
struct TableSkin: Identifiable, Hashable {
    let key: String
    let displayName: String
    /// Felt center tone (radial gradient's brightest stop rides on top of this).
    let feltBase: Color
    /// Felt highlight — the lit patch at the center of the radial gradient.
    /// Equal to `feltBase` when the skin has no distinct highlight tint.
    let feltHighlight: Color
    /// Base color under the walnut rail texture.
    let railColor: Color
    /// Opacity of the WalnutTexture overlay on the rail.
    let railImageOpacity: Double
    /// Gold used for rail trim and felt piping.
    let accentGold: Color
    /// Opacity of the overhead-lamp vignette at the table's edges.
    let vignetteStrength: Double

    var id: String { key }

    /// The original, un-skinned look: warm felt green, walnut rail, brass trim.
    static let classicClub = TableSkin(
        key: "classicClub",
        displayName: "Classic Club",
        feltBase: CardStyle.feltGreen,
        feltHighlight: CardStyle.feltGreen,
        railColor: Color(red: 0.28, green: 0.19, blue: 0.13),
        railImageOpacity: 0.7,
        accentGold: CardStyle.gold,
        vignetteStrength: 0.30
    )

    /// Near-black green felt, cool moonlit highlight, brighter gold trim,
    /// deeper shadows at the rail — a moodier hero theme.
    static let midnightArcane = TableSkin(
        key: "midnightArcane",
        displayName: "Midnight Arcane",
        feltBase: Color(red: 0.055, green: 0.129, blue: 0.102),      // #0E211A
        feltHighlight: Color(red: 0.235, green: 0.337, blue: 0.345), // cool moonlit sheen
        railColor: Color(red: 0.180, green: 0.125, blue: 0.094),     // near-black walnut
        railImageOpacity: 0.55,
        accentGold: Color(red: 0.941, green: 0.847, blue: 0.588),    // brighter gold-hi
        vignetteStrength: 0.42
    )

    /// Olive felt, warmer/darker wood, candlelight glow — a cozy tavern table.
    static let warmTavern = TableSkin(
        key: "warmTavern",
        displayName: "Warm Tavern",
        feltBase: Color(red: 0.310, green: 0.361, blue: 0.216),      // olive
        feltHighlight: Color(red: 0.400, green: 0.455, blue: 0.290), // lit olive
        railColor: Color(red: 0.235, green: 0.145, blue: 0.086),     // dark warm wood
        railImageOpacity: 0.75,
        accentGold: Color(red: 0.753, green: 0.541, blue: 0.243),    // warm amber gold
        vignetteStrength: 0.36
    )

    static let all: [TableSkin] = [.classicClub, .midnightArcane, .warmTavern]

    static func skin(for key: String) -> TableSkin {
        all.first { $0.key == key } ?? .classicClub
    }
}

// MARK: - The lamp

/// ONE warm overhead lamp over the table, shared by every surface that
/// wants to feel lit by it: the felt pool and falloff and the rail's shadow
/// (TableSurface), the brass bevel on seat plates (SeatPlateView), the deck's
/// side-stack shading (DeckAndTrumpView), the rail-hand card backs
/// (RailHandFan), and the lobby's place settings (AttractMode).
///
/// Coordinates are UNIT points over the whole table container (the full
/// screen, same convention as `TableGeometry`). Views that live inside the
/// table and want to know "where is the lamp from me?" use `.lampSample($s)`
/// below, which measures the view's own center in the window and hands
/// back a direction + a 0...1 light level. Nothing is a hard-coded
/// per-view guess any more: move `center` here and everything follows.
enum TableLamp {
    /// Lamp position, unit coords. A touch above the geometric middle:
    /// the bulb hangs over the play area, not over the dealer's lap.
    static let center = CGPoint(x: 0.5, y: 0.40)
    /// The lamp's reach as a fraction of the container's half-diagonal.
    static let reach: CGFloat = 1.0
    /// The bulb's color: warm tungsten, never white.
    static let warmTint = Color(red: 1.00, green: 0.86, blue: 0.62)
    /// Brass catching the lamp (specular) and brass in shadow.
    static let brassLit = Color(red: 0.99, green: 0.90, blue: 0.66)
    static let brassShade = Color(red: 0.36, green: 0.26, blue: 0.12)

    static func point(in size: CGSize) -> CGPoint {
        CGPoint(x: center.x * size.width, y: center.y * size.height)
    }

    static func radius(in size: CGSize) -> CGFloat {
        hypot(size.width, size.height) / 2 * reach
    }

    /// 1 directly under the lamp, easing smoothly toward 0 at `radius`.
    static func light(at point: CGPoint, in size: CGSize) -> Double {
        let lamp = Self.point(in: size)
        let d = hypot(point.x - lamp.x, point.y - lamp.y) / max(radius(in: size), 1)
        let t = min(max(Double(d), 0), 1)
        return 0.5 + 0.5 * cos(t * .pi) // cosine ease: wide pool, soft edge
    }

    /// Unit vector from `point` toward the lamp (screen coords, y down).
    static func direction(from point: CGPoint, in size: CGSize) -> CGVector {
        let lamp = Self.point(in: size)
        let dx = lamp.x - point.x, dy = lamp.y - point.y
        let len = max(hypot(dx, dy), 0.001)
        return CGVector(dx: dx / len, dy: dy / len)
    }

    /// The container size lamp math runs against: the key window's bounds
    /// (the table is always full-screen).
    static var containerSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.bounds.size ?? CGSize(width: 1366, height: 1024)
    }
}

/// What a view sees of the lamp from where it sits.
struct LampSample: Equatable {
    /// Unit vector pointing from the view toward the lamp, in WINDOW space.
    var toward = CGVector(dx: 0, dy: -1)
    /// 0 (far dim corner) ... 1 (right under the bulb).
    var light: Double = 0.7

    /// The same direction in the frame of a view rotated by `angle` (a seat
    /// plate turned to face its rim): local = R(-angle) * window.
    func toward(rotatedBy angle: Angle) -> CGVector {
        let c = cos(-angle.radians), s = sin(-angle.radians)
        return CGVector(dx: toward.dx * c - toward.dy * s, dy: toward.dx * s + toward.dy * c)
    }
}

private struct LampSampler: ViewModifier {
    @Binding var sample: LampSample

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear { update(frame) }
                    .onChange(of: frame) { _, new in update(new) }
            }
        )
    }

    private func update(_ frame: CGRect) {
        let size = TableLamp.containerSize
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let v = TableLamp.direction(from: center, in: size)
        let next = LampSample(toward: v, light: TableLamp.light(at: center, in: size))
        // Quantized so a card in flight doesn't churn a state write per frame.
        if abs(next.light - sample.light) > 0.02
            || abs(next.toward.dx - sample.toward.dx) > 0.03
            || abs(next.toward.dy - sample.toward.dy) > 0.03 {
            sample = next
        }
    }
}

extension View {
    /// Measure this view's position against the table lamp. Costs one
    /// background GeometryReader; writes are quantized.
    func lampSample(_ sample: Binding<LampSample>) -> some View {
        modifier(LampSampler(sample: sample))
    }
}

/// The physical stage: walnut rail around a felt playing surface, lit from
/// above. Everything on the table draws over this. Reads the player's
/// chosen `TableSkin` from `ThemeStore`; the FeltTexture/WalnutTexture image
/// overlays keep working across every skin via tint and opacity.
struct TableSurface: View {
    /// Set only by the #Preview below, to show every skin side by side
    /// without touching ThemeStore's persisted selection.
    private var previewSkin: TableSkin?

    init() { previewSkin = nil }
    fileprivate init(previewSkin: TableSkin) { self.previewSkin = previewSkin }

    private var skin: TableSkin { previewSkin ?? TableSkin.skin(for: ThemeStore.shared.selectedSkin) }

    var body: some View {
        GeometryReader { geo in
            // One lamp, one falloff. The felt's highlight-to-shadow gradient
            // and the overhead vignette used to be TWO independent
            // RadialGradients: this one, scoped to the inset felt rect's own
            // local frame, and a second one painted on a separate
            // `.ignoresSafeArea()` layer scoped to the surrounding
            // container's frame instead. Those two frames aren't guaranteed
            // to agree — safe-area insets or a parent layout that doesn't
            // fill the exact screen shift the vignette's center relative to
            // the felt's — and where the two falloffs crossed at different
            // rates it read as a lighter band across the lower third. A
            // single gradient anchored to the felt shape itself can't drift
            // out of alignment with itself.
            let feltSize = CGSize(width: max(geo.size.width - 28, 1),
                                  height: max(geo.size.height - 28, 1))
            let lampRadius = TableLamp.radius(in: feltSize)
            let lampUnit = UnitPoint(x: TableLamp.center.x, y: TableLamp.center.y)

            ZStack {
                // Walnut rail: photographic grain under a lighting gradient.
                skin.railColor.ignoresSafeArea()
                Image("WalnutTexture")
                    .resizable(resizingMode: .tile)
                    .ignoresSafeArea()
                    .opacity(skin.railImageOpacity)
                    .blendMode(.overlay)
                LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                // The lamp on the walnut: a warm sheen on the rail nearest
                // the bulb, falling to deep shade at the far corners.
                RadialGradient(colors: [TableLamp.warmTint.opacity(0.20),
                                        TableLamp.warmTint.opacity(0.05),
                                        .black.opacity(0.28)],
                               center: lampUnit,
                               startRadius: 0, endRadius: lampRadius * 1.05)
                    .ignoresSafeArea()
                    .blendMode(.softLight)
                // Felt inset with a soft inner shadow where it meets the
                // rail. The fill carries the whole lamp: bright highlight at
                // center, through the felt's base tone, out to the vignette
                // shadow at the corners — one continuous falloff.
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .fill(
                        RadialGradient(colors: [skin.feltHighlight.opacity(1.06),
                                                skin.feltBase,
                                                skin.feltBase.opacity(0.88),
                                                // SwiftUI interpolates RGBA linearly between
                                                // consecutive stops, so ending on plain black at
                                                // the vignette's opacity blends smoothly out of the
                                                // felt tone above it — no separate mix step needed,
                                                // and nothing iOS-18-only (deployment target is 17).
                                                .black.opacity(skin.vignetteStrength)],
                                       center: UnitPoint(x: TableLamp.center.x, y: TableLamp.center.y),
                                       startRadius: lampRadius * 0.065,
                                       endRadius: lampRadius)
                    )
                    .overlay(
                        // ONE crop of the grain, scaled to cover the felt —
                        // not tiled. `FeltTexture.png` isn't a seamlessly
                        // loopable tile: it has its own soft top-down bake,
                        // so repeating it with `.tile` stamped a visible
                        // seam at every tile boundary (confirmed by tiling
                        // it 2×2 outside the simulator — the seam is IN the
                        // asset, not in the gradient math above). A single
                        // stretched instance has no boundary to show.
                        Image("FeltTexture")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: feltSize.width, height: feltSize.height)
                            .clipped()
                            .opacity(0.5)
                            .blendMode(.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .strokeBorder(skin.accentGold.opacity(0.35), lineWidth: 1.5)
                            .padding(6)
                    )
                    .overlay(
                        // The lamp's pool: a warm patch of light on the felt,
                        // brightest under the bulb, gone well before the rail.
                        RadialGradient(colors: [TableLamp.warmTint.opacity(0.17),
                                                TableLamp.warmTint.opacity(0.06),
                                                .clear],
                                       center: lampUnit,
                                       startRadius: 0, endRadius: lampRadius * 0.62)
                            .blendMode(.screen)
                            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        // Rail shadow where felt meets walnut: the lip's
                        // occlusion, deepest where the lamp reaches least
                        // (the mask thickens the ring toward the far edges).
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .strokeBorder(.black.opacity(0.6), lineWidth: 12)
                            .blur(radius: 8)
                            .mask(
                                RadialGradient(colors: [.black.opacity(0.55), .black],
                                               center: lampUnit,
                                               startRadius: lampRadius * 0.45,
                                               endRadius: lampRadius * 1.0)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        // The raised lip itself catching the light: a hairline
                        // of lit walnut at the edge nearest the bulb, dark on
                        // the far side.
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [TableLamp.warmTint.opacity(0.26),
                                                        .clear,
                                                        .black.opacity(0.35)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 2)
                            .allowsHitTesting(false)
                    )
                    .padding(14)
            }
        }
    }
}

#Preview("Table skins") {
    VStack(spacing: 0) {
        ForEach(TableSkin.all) { skin in
            TableSurface(previewSkin: skin)
                .frame(height: 260)
        }
    }
}
