import SwiftUI

/// Ties the game to the `CheckersBoard` photo (600 pt square). Points are in
/// BOARD UNITS: 1.0 == the board's side. The playing area was measured off
/// the photo: x 0.1007 -> 0.8958, y 0.1015 -> 0.9008 (each square about
/// 0.0994 wide), dark corner bottom-left, which matches the engine's
/// "row 7, col 0 is playable".
enum CheckersGeometry {
    static let originX: CGFloat = 0.1007
    static let originY: CGFloat = 0.1015
    static let squareW: CGFloat = (0.8958 - 0.1007) / 8
    static let squareH: CGFloat = (0.9008 - 0.1015) / 8
    /// Rendered checker width (the sprite is 48 pt on a 600 pt board).
    static let pieceDiameter: CGFloat = 48.0 / 600.0
    /// Height of the sprite relative to its width (48 x 47).
    static let spriteAspect: CGFloat = 47.0 / 48.0
    /// How far a lifted piece floats, in board units.
    static let liftHeight: CGFloat = 0.035

    static func row(_ sq: Int) -> Int { sq >> 3 }
    static func col(_ sq: Int) -> Int { sq & 7 }

    static func center(of sq: Int) -> CGPoint {
        CGPoint(x: originX + (CGFloat(col(sq)) + 0.5) * squareW,
                y: originY + (CGFloat(row(sq)) + 0.5) * squareH)
    }

    /// Nearest PLAYABLE square within `tolerance` squares of `point`.
    static func square(at point: CGPoint, tolerance: CGFloat = 0.62) -> Int? {
        let c = Int(((point.x - originX) / squareW).rounded(.down))
        let r = Int(((point.y - originY) / squareH).rounded(.down))
        var best: (sq: Int, d: CGFloat)?
        // Clamp BOTH ends: a finger dragged far off the board must yield nil,
        // not an invalid (lower > upper) range.
        let rLo = max(0, min(7, r - 1)), rHi = max(0, min(7, r + 1))
        let cLo = max(0, min(7, c - 1)), cHi = max(0, min(7, c + 1))
        for rr in rLo...rHi {
            for cc in cLo...cHi {
                let sq = rr * 8 + cc
                guard CheckersRules.isPlayable(sq) else { continue }
                let ctr = center(of: sq)
                let d = hypot((point.x - ctr.x) / squareW, (point.y - ctr.y) / squareH)
                if d < tolerance, best == nil || d < best!.d { best = (sq, d) }
            }
        }
        return best?.sq
    }

    static func midpoint(_ a: Int, _ b: Int) -> Int { ((row(a) + row(b)) / 2) * 8 + (col(a) + col(b)) / 2 }
}
