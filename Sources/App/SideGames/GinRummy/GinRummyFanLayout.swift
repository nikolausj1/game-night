import CoreGraphics
import Foundation

/// Pure geometry for the Gin Rummy phone hand: the hand is auto-grouped into
/// melds (tight sub-fans) and deadwood (looser, so every index stays
/// readable and tappable), then the whole row bows along one shallow arc like
/// a held hand. No SwiftUI here on purpose; the numbers can be checked in
/// isolation (see the layout self-check recorded in the file header of
/// `GinRummyDemo.swift`).
///
/// Coordinates are relative to the fan's centre-bottom anchor: `x` runs
/// left/right from the middle, `y` runs DOWN (larger = lower on screen), and
/// both are card CENTRES.
struct GinFanLayout {
    struct GroupSpec: Equatable {
        let count: Int
        let isMeld: Bool
    }

    struct Slot: Equatable {
        let x: CGFloat
        let y: CGFloat
        /// Degrees; positive = clockwise.
        let angle: Double
        let group: Int
        let indexInGroup: Int
    }

    /// The thin gold line under a meld.
    struct Underline: Equatable {
        let centerX: CGFloat
        let y: CGFloat
        let width: CGFloat
        let angle: Double
        let group: Int
    }

    /// Centre-to-centre advance inside a meld (tight sub-fan).
    static let meldStep: CGFloat = 0.28
    /// Centre-to-centre advance between deadwood cards (looser).
    static let deadStep: CGFloat = 0.40
    /// Centre-to-centre advance from the last card of one group to the first of the next.
    static let groupGap: CGFloat = 0.94

    let cardWidth: CGFloat
    /// Visual width of the whole row at `cardWidth`.
    let totalWidth: CGFloat
    let slots: [Slot]
    let underlines: [Underline]

    init(groups: [GroupSpec], containerWidth: CGFloat, nominalCardWidth: CGFloat) {
        let live = groups.enumerated().filter { $0.element.count > 0 }
        // Width of the whole row, in card-widths.
        var units: CGFloat = 1
        for (n, entry) in live.enumerated() {
            if n > 0 { units += Self.groupGap }
            units += CGFloat(entry.element.count - 1) * (entry.element.isMeld ? Self.meldStep : Self.deadStep)
        }
        let available = max(120, containerWidth - 16)
        let cw = max(24, min(nominalCardWidth, available / units))
        let total = units * cw

        let halfSpan = max(1, (total - cw) / 2)
        var slots: [Slot] = []
        var underlines: [Underline] = []
        var x = -total / 2 + cw / 2
        for (n, entry) in live.enumerated() {
            let spec = entry.element
            if n > 0 { x += Self.groupGap * cw }
            var groupSlots: [Slot] = []
            for i in 0..<spec.count {
                if i > 0 { x += (spec.isMeld ? Self.meldStep : Self.deadStep) * cw }
                let norm = max(-1, min(1, x / halfSpan))
                let mid = CGFloat(spec.count - 1) / 2
                let local = CGFloat(i) - mid
                // Melds fan tightly around their own centre; deadwood barely tilts.
                let localAngle = Double(local) * (spec.isMeld ? 2.4 : 0.8)
                let globalAngle = Double(norm) * 9
                let arcY = norm * norm * 0.16 * cw
                let localY = local * local * (spec.isMeld ? 0.012 : 0.004) * cw
                groupSlots.append(Slot(x: x, y: arcY + localY, angle: globalAngle + localAngle,
                                       group: entry.offset, indexInGroup: i))
            }
            slots += groupSlots
            if spec.isMeld, let first = groupSlots.first, let last = groupSlots.last {
                let width = (last.x - first.x) + cw * 0.86
                let midY = groupSlots.map(\.y).reduce(0, +) / CGFloat(groupSlots.count)
                let midX = (first.x + last.x) / 2
                let norm = max(-1, min(1, midX / halfSpan))
                underlines.append(Underline(centerX: midX, y: midY + cw * 0.70 + cw * 0.10,
                                            width: width, angle: Double(norm) * 9, group: entry.offset))
            }
        }
        self.cardWidth = cw
        self.totalWidth = total
        self.slots = slots
        self.underlines = underlines
    }
}
