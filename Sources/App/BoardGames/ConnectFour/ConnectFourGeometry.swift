import SwiftUI

/// Calibrated against the `ConnectFourFrame` photo (560 x 393 pt, FRONT
/// view, holes are alpha 0). Column x values are fractions of the frame's
/// WIDTH and row y values fractions of its HEIGHT. They are per column and
/// per row (not evenly spaced) because the photo has slight perspective, so
/// a disc sits dead-centre in its hole in every one of the 42 cells.
enum ConnectFourGeometry {
    static let aspect: CGFloat = 393.0 / 560.0
    static let colX: [CGFloat] = [0.1737, 0.2897, 0.4040, 0.5152, 0.6259, 0.7341, 0.8406]
    static let rowY: [CGFloat] = [0.1003, 0.2414, 0.3820, 0.5236, 0.6657, 0.8051]
    /// Hole diameter as a fraction of frame width (about 43 pt of 560).
    static let hole: CGFloat = 43.0 / 560.0
    /// Disc diameter: a hair over the hole so its edge tucks under the
    /// frame's raised rim instead of leaving a sliver of felt.
    static let disc: CGFloat = 43.0 / 560.0 * 1.05
    /// Where a disc waits above the frame, as a fraction of frame HEIGHT
    /// (negative == above the top edge).
    static let hoverY: CGFloat = -0.125

    /// Nearest column to an x fraction (of frame width), or nil if the touch
    /// is well outside the frame's columns.
    static func column(atX x: CGFloat) -> Int? {
        var best: (c: Int, d: CGFloat)?
        for c in 0..<7 {
            let d = abs(x - colX[c])
            if best == nil || d < best!.d { best = (c, d) }
        }
        guard let best, best.d < 0.075 else { return nil }
        return best.c
    }
}

/// Gravity for one dropped disc: free fall from the hover point to its
/// resting hole, then two shrinking bounces (a plastic disc on a plastic
/// floor, or on the disc below). Everything in frame-HEIGHT units.
struct ConnectFourDropPlan {
    static let gravity: Double = 6.4

    let startY: Double
    let endY: Double
    let fall: Double
    let hop1: Double
    let hop2: Double
    private let height1: Double
    private let height2: Double

    init(row: Int) {
        let start = Double(ConnectFourGeometry.hoverY)
        let end = Double(ConnectFourGeometry.rowY[row])
        let d = end - start
        let g = Self.gravity
        // Bounce scales with how far it fell, but stays small: a few mm.
        let h1 = min(0.030, max(0.008, d * 0.032))
        let h2 = h1 * 0.30
        startY = start
        endY = end
        fall = (2 * d / g).squareRoot()
        height1 = h1
        height2 = h2
        hop1 = 2 * (2 * h1 / g).squareRoot()
        hop2 = 2 * (2 * h2 / g).squareRoot()
    }

    var duration: Double { fall + hop1 + hop2 }
    /// Times the disc strikes something: first the landing, then each bounce.
    var impacts: [Double] { [fall, fall + hop1, fall + hop1 + hop2] }

    /// Disc centre y (frame-height fraction) at time `t`.
    func y(at t: Double) -> Double {
        if t <= 0 { return startY }
        if t < fall { return startY + 0.5 * Self.gravity * t * t }
        var u = t - fall
        if u < hop1 { let p = u / hop1; return endY - 4 * height1 * p * (1 - p) }
        u -= hop1
        if u < hop2 { let p = u / hop2; return endY - 4 * height2 * p * (1 - p) }
        return endY
    }
}
