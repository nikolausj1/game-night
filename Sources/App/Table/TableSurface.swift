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
            let lampRadius = hypot(feltSize.width, feltSize.height) / 2

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
                                       center: .center,
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
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .strokeBorder(.black.opacity(0.45), lineWidth: 10)
                            .blur(radius: 8)
                            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
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
