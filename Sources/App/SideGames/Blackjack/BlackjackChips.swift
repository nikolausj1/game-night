import SwiftUI
import UIKit

/// The family chip set: ivory 1, red 5, blue 10, green 25, black 100 (the
/// photoreal `Chip*` imagesets), with a tasteful programmatic fallback when
/// an asset isn't in the bundle yet. Chips are bankroll tokens only.
enum BJChipDenom: Int, CaseIterable, Identifiable {
    case one = 1, five = 5, ten = 10, twentyFive = 25, hundred = 100

    var id: Int { rawValue }

    var faceAsset: String {
        switch self {
        case .one: return "ChipIvory"
        case .five: return "ChipRed"
        case .ten: return "ChipBlue"
        case .twentyFive: return "ChipGreen"
        case .hundred: return "ChipBlack"
        }
    }

    /// The red chip's edge is the unsuffixed `ChipEdge`.
    var edgeAsset: String {
        switch self {
        case .one: return "ChipEdgeIvory"
        case .five: return "ChipEdge"
        case .ten: return "ChipEdgeBlue"
        case .twentyFive: return "ChipEdgeGreen"
        case .hundred: return "ChipEdgeBlack"
        }
    }

    var tint: Color {
        switch self {
        case .one: return Color(red: 0.90, green: 0.86, blue: 0.76)
        case .five: return Color(red: 0.66, green: 0.20, blue: 0.17)
        case .ten: return Color(red: 0.17, green: 0.31, blue: 0.52)
        case .twentyFive: return Color(red: 0.14, green: 0.38, blue: 0.24)
        case .hundred: return Color(red: 0.13, green: 0.13, blue: 0.14)
        }
    }

    var inkOnTint: Color { self == .one ? CardStyle.ink : CardStyle.stockTop }

    /// Greedy change-making, largest first: 94 -> 3x25, 1x10, 1x5, 4x1.
    static func breakdown(_ amount: Int) -> [(denom: BJChipDenom, count: Int)] {
        var left = max(0, amount)
        var out: [(BJChipDenom, Int)] = []
        for d in BJChipDenom.allCases.reversed() {
            let n = left / d.rawValue
            if n > 0 { out.append((d, n)); left -= n * d.rawValue }
        }
        return out
    }

    /// Does the photo asset exist in this build?
    static func hasAsset(_ name: String) -> Bool { assetCache.has(name) }

    private static let assetCache = AssetCache()
    private final class AssetCache {
        private var known: [String: Bool] = [:]
        func has(_ name: String) -> Bool {
            if let hit = known[name] { return hit }
            let present = UIImage(named: name) != nil
            known[name] = present
            return present
        }
    }
}

/// The top of one chip (face-on, slightly foreshortened by the view).
struct BJChipFace: View {
    let denom: BJChipDenom
    let width: CGFloat
    /// 1 = a flat top-down disc; <1 squashes it the way a stack seen from
    /// the seat is foreshortened.
    var squash: CGFloat = 1

    var body: some View {
        Group {
            if BJChipDenom.hasAsset(denom.faceAsset) {
                Image(denom.faceAsset).resizable().interpolation(.high)
            } else {
                fallback
            }
        }
        .frame(width: width, height: width * squash)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height / max(squash, 0.01))
            ZStack {
                Circle().fill(denom.tint)
                Circle().strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: d * 0.07, dash: [d * 0.14, d * 0.12]))
                    .padding(d * 0.04)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1).padding(d * 0.2)
                Text("\(denom.rawValue)")
                    .font(.system(size: d * 0.34, weight: .bold, design: .serif))
                    .foregroundStyle(denom.inkOnTint)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: d, height: d)
            .scaleEffect(y: squash, anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The side wall of a chip: the thin strip that makes a stack read as a stack.
struct BJChipEdge: View {
    let denom: BJChipDenom
    let width: CGFloat

    var body: some View {
        Group {
            if BJChipDenom.hasAsset(denom.edgeAsset) {
                Image(denom.edgeAsset).resizable().interpolation(.high)
            } else {
                Capsule().fill(denom.tint.opacity(0.9))
                    .overlay(Capsule().fill(.black.opacity(0.18)))
            }
        }
        .frame(width: width, height: width * 0.125)
    }
}

/// One column of identical chips, drawn bottom to top, top chip showing its face.
struct BJChipColumn: View {
    let denom: BJChipDenom
    let count: Int
    let width: CGFloat

    static let faceSquash: CGFloat = 0.84
    static func height(count: Int, width: CGFloat) -> CGFloat {
        let n = max(1, min(count, BJChipColumn.maxShown))
        return width * faceSquash + CGFloat(n - 1) * width * 0.085 + width * 0.06
    }
    /// A very tall stack stops growing (a real rack would, but the felt
    /// would run out of room).
    static let maxShown = 12

    var body: some View {
        let n = max(1, min(count, BJChipColumn.maxShown))
        let step = width * 0.085
        let faceH = width * BJChipColumn.faceSquash
        let h = BJChipColumn.height(count: count, width: width)
        ZStack(alignment: .top) {
            // Lowest chip first so higher chips overlap it.
            ForEach(Array((0..<n).reversed()), id: \.self) { j in
                BJChipEdge(denom: denom, width: width)
                    .offset(y: faceH - width * 0.125 * 0.6 + CGFloat(j) * step)
            }
            BJChipFace(denom: denom, width: width, squash: BJChipColumn.faceSquash)
        }
        .frame(width: width, height: h, alignment: .top)
        .shadow(color: .black.opacity(0.35), radius: 1.2, y: 1.2)
    }
}

/// Chips for an amount: denomination columns clustered like real stacks
/// (overlapping, staggered front and back), centered on the view's frame.
struct BJChipStackView: View {
    let amount: Int
    let chipWidth: CGFloat

    static func footprint(amount: Int, chipWidth w: CGFloat) -> CGSize {
        let cols = BJChipDenom.breakdown(amount)
        guard !cols.isEmpty else { return .zero }
        let tallest = cols.map { BJChipColumn.height(count: $0.count, width: w) }.max() ?? 0
        let width = w + CGFloat(cols.count - 1) * w * 0.78
        return CGSize(width: width, height: tallest + (cols.count > 1 ? w * 0.28 : 0))
    }

    var body: some View {
        let cols = BJChipDenom.breakdown(amount)
        let size = BJChipStackView.footprint(amount: amount, chipWidth: chipWidth)
        ZStack(alignment: .bottomLeading) {
            // Back row first (odd columns sit higher = further away).
            ForEach(Array(cols.enumerated()).sorted { ($0.offset % 2 == 1 ? 0 : 1) < ($1.offset % 2 == 1 ? 0 : 1) },
                    id: \.element.denom) { i, col in
                BJChipColumn(denom: col.denom, count: col.count, width: chipWidth)
                    .offset(x: CGFloat(i) * chipWidth * 0.78,
                            y: i % 2 == 1 ? -chipWidth * 0.28 : 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(amount) chips")
    }
}

/// One chip in the player's tray (phone): a tappable face with its value.
struct BJTrayChip: View {
    let denom: BJChipDenom
    var size: CGFloat = 58
    var enabled: Bool = true

    var body: some View {
        BJChipFace(denom: denom, width: size)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
            .opacity(enabled ? 1 : 0.35)
            .saturation(enabled ? 1 : 0.2)
            .contentShape(Circle())
    }
}

// MARK: - Chip flight

/// A stack of chips travelling between two points on the felt in ONE
/// motion (same single-progress design as `PileTossCardView`): position,
/// lift, scale, and shadow all derive from `progress`.
struct BJChipFlightView: View, Animatable {
    var progress: CGFloat
    let amount: Int
    let chipWidth: CGFloat
    let from: CGPoint
    let to: CGPoint
    var flat: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        let lift: CGFloat = flat ? 0 : 4 * p * (1 - p) * min(46, 18 + hypot(to.x - from.x, to.y - from.y) * 0.08)
        let x = from.x + (to.x - from.x) * p
        let y = from.y + (to.y - from.y) * p - lift
        let scale = 1 + lift * 0.004
        ZStack {
            Ellipse()
                .fill(.black.opacity(0.28 - Double(lift) * 0.003))
                .frame(width: chipWidth * 0.9, height: chipWidth * 0.4)
                .blur(radius: 3 + lift * 0.1)
                .position(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p + chipWidth * 0.1)
            BJChipStackView(amount: amount, chipWidth: chipWidth)
                .scaleEffect(scale)
                .position(x: x, y: y)
        }
        .allowsHitTesting(false)
    }
}
