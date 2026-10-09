import SwiftUI

/// Everything that ties the game to the pixels of the `MancalaBoard` photo
/// (760 x 280 pt). All points are in BOARD UNITS: 1.0 == the board's WIDTH on
/// both axes (so y spans 0...`aspect`). A view multiplies by the rendered
/// board width and it is done; nothing here knows about screen size.
///
/// The calibration numbers were measured off the photo itself (pit centres,
/// store centres/extents, pit radius) so a stone drawn at a pit centre sits in
/// the carved bowl, not merely near it.
enum MancalaGeometry {
    /// height / width of the board image.
    static let aspect: CGFloat = 280.0 / 760.0

    static let pitX: [CGFloat] = [0.2323, 0.3441, 0.4555, 0.5679, 0.6800, 0.7908]
    static let topRowY: CGFloat = 0.3122 * aspect
    static let bottomRowY: CGFloat = 0.6947 * aspect
    static let storeY: CGFloat = 0.5033 * aspect
    static let leftStoreX: CGFloat = 0.1019
    static let rightStoreX: CGFloat = 0.9008
    static let storeHalfWidth: CGFloat = 0.0408
    static let storeHalfHeight: CGFloat = 0.3241 * aspect
    static let pitRadius: CGFloat = 0.0510

    /// Rendered gem diameter (the sheet's gem bbox is 22pt on a 760pt board).
    static let stoneDiameter: CGFloat = 0.031
    /// How high a lifted stone hovers (board units).
    static let handHeight: CGFloat = 0.050

    static func isStore(_ slot: Int) -> Bool { slot == 6 || slot == 13 }

    /// Centre of an ABSOLUTE slot (0...13), see `MancalaEngine` for the ring.
    static func center(of slot: Int) -> CGPoint {
        switch slot {
        case 0...5: return CGPoint(x: pitX[slot], y: bottomRowY)
        case 6: return CGPoint(x: rightStoreX, y: storeY)
        case 7...12: return CGPoint(x: pitX[12 - slot], y: topRowY)
        default: return CGPoint(x: leftStoreX, y: storeY)
        }
    }

    /// The slot under a board-unit point (pits only, generous radius), or nil.
    static func pit(at point: CGPoint) -> Int? {
        var best: (slot: Int, d: CGFloat)?
        for slot in 0..<14 where !isStore(slot) {
            let c = center(of: slot)
            let d = hypot(point.x - c.x, point.y - c.y)
            if d < pitRadius * 1.2, best == nil || d < best!.d { best = (slot, d) }
        }
        return best?.slot
    }

    // MARK: - Where a resting stone sits

    /// Deterministic per-stone wobble so no two stones sit like clones.
    static func jitter(_ id: Int) -> CGPoint {
        var g = SeededGenerator(seed: UInt64(id) &* 0x9E37_79B9 &+ 77)
        let a = CGFloat(Double(g.next() % 2000) / 1000.0 - 1.0)
        let b = CGFloat(Double(g.next() % 2000) / 1000.0 - 1.0)
        return CGPoint(x: a * 0.0022, y: b * 0.0022)
    }

    /// Resting position of the `index`-th stone (0-based, in landing order)
    /// in `slot`. Pits use a sunflower (phyllotaxis) packing: the k-th stone's
    /// place never depends on how many stones the pit holds, so dropping a new
    /// stone in never shoves the old ones around, and the heap looks natural
    /// at any count. Stones overlap a little once a pit gets full; a deep pit
    /// piles into a gentle mound. Stores fill column-wise from their owner's
    /// end.
    static func restPoint(slot: Int, index: Int, stoneID: Int) -> CGPoint {
        let c = center(of: slot)
        let j = jitter(stoneID)
        if isStore(slot) {
            let col = index % 3
            let row = index / 3
            let dir: CGFloat = slot == 6 ? 1 : -1       // seat 0 fills from the bottom, seat 1 from the top
            let xOff: [CGFloat] = [-0.0125, 0.0, 0.0125]
            let stagger: CGFloat = col == 1 ? 0.0055 : 0
            let start = storeHalfHeight - 0.032
            return CGPoint(x: c.x + xOff[col] + j.x,
                           y: c.y + dir * (start - CGFloat(row) * 0.0122 - stagger) + j.y)
        }
        let perLayer = 12
        let layer = index / perLayer
        let k = index % perLayer
        let phase = CGFloat(slot) * 0.83
        let theta = CGFloat(k) * 2.39996 + phase
        let radius = min(pitRadius * 0.58, 0.0118 * CGFloat(k + 1).squareRoot() * (layer == 0 ? 1.0 : 0.72))
        return CGPoint(x: c.x + cos(theta) * radius + j.x,
                       y: c.y + sin(theta) * radius + j.y - CGFloat(layer) * 0.0042)
    }

    /// Where the k-th stone of a lifted fistful hangs relative to the hand.
    static func handOffset(_ k: Int) -> CGPoint {
        let theta = CGFloat(k) * 2.39996
        let r = min(0.030, 0.0085 * CGFloat(k + 1).squareRoot())
        return CGPoint(x: cos(theta) * r, y: sin(theta) * r)
    }
}
