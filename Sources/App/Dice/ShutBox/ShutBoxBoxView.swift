import SwiftUI

/// The box itself — the star of the show. A photoreal walnut frame
/// (`ShutBoxFrame`, 640×493 native — a green felt well below a brass hinge
/// rail near the top) with 9 wooden tiles hinged along that rail
/// (`ShutBoxTileWood`, a blank maple face this view stamps a numeral onto).
/// A standing tile hangs straight down from the rail, numeral facing the
/// player; tipping it (candidate preview) rotates it back ~25° around that
/// TOP hinge; confirming a set rotates it the rest of the way to ~110° —
/// tipped up and away, folded back out of the well, exactly a real
/// shut-the-box tile played.
struct ShutBoxBoxView: View {
    /// Tile 0...8 standing state (index = value − 1).
    let standing: [Bool]
    /// Tiles the current human roller has tipped as candidates this roll.
    let selected: Set<Int>
    /// Standing tiles that participate in SOME legal set for the live roll
    /// — everything else standing dims. Ignored (nothing dims) when empty
    /// AND there's no live roll (`hasLiveRoll == false`).
    let tilesInPlay: Set<Int>
    let hasLiveRoll: Bool
    var reduceMotion: Bool
    var width: CGFloat
    var onTapTile: (Int) -> Void

    /// The frame asset's own native footprint (640×493) — displayed near
    /// 1:1 so the rail-geometry fractions below line up exactly with how
    /// the asset was authored.
    static let nativeWidth: CGFloat = 640
    static let nativeAspect: CGFloat = 493.0 / 640.0

    /// Explicit init (rather than the compiler's memberwise one) so call
    /// sites can pass arguments in whatever order reads best without
    /// tripping Swift's strict declaration-order rule for defaulted
    /// parameters.
    init(standing: [Bool], selected: Set<Int>, tilesInPlay: Set<Int>, hasLiveRoll: Bool,
        reduceMotion: Bool = false, width: CGFloat = ShutBoxBoxView.nativeWidth,
        onTapTile: @escaping (Int) -> Void = { _ in }) {
        self.standing = standing
        self.selected = selected
        self.tilesInPlay = tilesInPlay
        self.hasLiveRoll = hasLiveRoll
        self.reduceMotion = reduceMotion
        self.width = width
        self.onTapTile = onTapTile
    }

    private var height: CGFloat { width * Self.nativeAspect }

    // Rail geometry, straight from the asset maker's own measurements.
    private let railCenterYFraction: CGFloat = 0.115
    private let railLeftFraction: CGFloat = 0.056
    private let railRightFraction: CGFloat = 0.937

    private let tileHeightFraction: CGFloat = 0.27 // of box width
    private let tileGapFraction: CGFloat = 0.010   // of box width

    private var railY: CGFloat { height * railCenterYFraction }
    private var railLeftX: CGFloat { width * railLeftFraction }
    private var railRightX: CGFloat { width * railRightFraction }
    private var tileGap: CGFloat { width * tileGapFraction }
    private var tileWidth: CGFloat { (railRightX - railLeftX - tileGap * 8) / 9 }
    private var tileHeight: CGFloat { width * tileHeightFraction }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("ShutBoxFrame")
                .resizable()
                .frame(width: width, height: height)
            ForEach(0..<9, id: \.self) { index in
                tileView(index: index)
                    .frame(width: tileWidth, height: tileHeight)
                    .position(x: tileCenterX(index), y: railY + tileHeight / 2)
                    .zIndex(standing[index] ? 1 : 0) // folded tiles tuck behind standing ones
            }
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
    }

    private func tileCenterX(_ index: Int) -> CGFloat {
        railLeftX + CGFloat(index) * (tileWidth + tileGap) + tileWidth / 2
    }

    private func tileView(index: Int) -> some View {
        let isStanding = standing[index]
        let isCandidate = selected.contains(index)
        let angle: Double = isStanding ? (isCandidate ? -25 : 0) : -112
        // Dim a standing, non-candidate tile only while there's a live roll
        // AND it genuinely can't help — never dim a tile just because
        // nothing's happened yet.
        let dimmed = hasLiveRoll && isStanding && !isCandidate && !tilesInPlay.contains(index)
        return ShutBoxTileFlap(value: index + 1, angle: angle, dimmed: dimmed,
                               folded: !isStanding, reduceMotion: reduceMotion)
            .contentShape(Rectangle())
            .onTapGesture { if isStanding { onTapTile(index) } }
            .allowsHitTesting(isStanding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tile \(index + 1)")
            .accessibilityValue(isStanding ? (isCandidate ? "selected" : "standing") : "flipped down")
            .accessibilityAddTraits(isStanding ? .isButton : [])
    }
}

/// One wooden tile flap: the maple face texture, a stamped serif numeral,
/// a rim, and shading that darkens as the tile tips away from the light —
/// hinged (rotation3DEffect, anchor `.top`) around the rail line above it.
struct ShutBoxTileFlap: View {
    let value: Int
    /// Degrees around the top hinge: 0 standing flat, −25 tipped as a
    /// candidate, −112 fully flipped (folded back out of the well).
    let angle: Double
    let dimmed: Bool
    let folded: Bool
    var reduceMotion: Bool = false

    private var shadeOpacity: Double { min(0.6, abs(angle) / 112 * 0.6) }

    var body: some View {
        ZStack {
            Image("ShutBoxTileWood")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("\(value)")
                .font(.system(size: 30, weight: .black, design: .serif))
                .foregroundStyle(Color(red: 0.24, green: 0.15, blue: 0.07))
                .shadow(color: .white.opacity(0.28), radius: 0.5, y: 0.5)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black.opacity(shadeOpacity))
        }
        .opacity(dimmed ? 0.42 : (folded ? 0.88 : 1))
        .compositingGroup()
        .shadow(color: .black.opacity(folded ? 0.18 : 0.42),
               radius: folded ? 2 : 6, y: folded ? 1 : 5)
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0),
                          anchor: .top, anchorZ: 0, perspective: 0.55)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.74), value: angle)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: dimmed)
    }
}
