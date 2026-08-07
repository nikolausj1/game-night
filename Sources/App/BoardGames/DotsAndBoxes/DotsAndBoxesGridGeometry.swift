import SwiftUI

/// Maps the engine's dot-index coordinates onto real points inside a
/// drawable rect, and answers the inverse questions the pencil gesture
/// needs: "which dot is nearest this touch" and "which line is nearest
/// this touch." Pure math, no state — built fresh every layout pass from
/// `GeometryReader`'s current size, same as `TableGeometry` does for the
/// felt.
struct DotsAndBoxesGridGeometry {
    let gridSize: Int
    let paperRect: CGRect

    /// Distance between adjacent dots. The grid is always square (equal
    /// rows/cols), sized to the smaller dimension of the drawable rect so
    /// it never overruns a non-square sheet.
    var spacing: CGFloat {
        guard gridSize > 0 else { return 0 }
        return min(paperRect.width, paperRect.height) / CGFloat(gridSize)
    }

    /// Top-left dot's position — the grid is centered in `paperRect`.
    var origin: CGPoint {
        let side = spacing * CGFloat(gridSize)
        return CGPoint(x: paperRect.midX - side / 2, y: paperRect.midY - side / 2)
    }

    func dotPosition(row: Int, col: Int) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(col) * spacing, y: origin.y + CGFloat(row) * spacing)
    }

    func boxCenter(_ box: DotsAndBoxesBox) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(box.col) + 0.5) * spacing,
                y: origin.y + (CGFloat(box.row) + 0.5) * spacing)
    }

    /// The two dot positions an edge runs between.
    func edgeEndpoints(_ edge: DotsAndBoxesEdge) -> (CGPoint, CGPoint) {
        switch edge.orientation {
        case .horizontal:
            return (dotPosition(row: edge.row, col: edge.col), dotPosition(row: edge.row, col: edge.col + 1))
        case .vertical:
            return (dotPosition(row: edge.row, col: edge.col), dotPosition(row: edge.row + 1, col: edge.col))
        }
    }

    /// The dot nearest `point`, if it's close enough to count as "on" that
    /// dot rather than out in open paper. Used by the drag gesture: find
    /// the dot under the finger's start and end.
    func nearestDot(to point: CGPoint) -> (row: Int, col: Int)? {
        guard spacing > 0 else { return nil }
        let rawCol = ((point.x - origin.x) / spacing).rounded()
        let rawRow = ((point.y - origin.y) / spacing).rounded()
        guard (0...gridSize).contains(Int(rawRow)), (0...gridSize).contains(Int(rawCol)) else { return nil }
        let row = Int(rawRow), col = Int(rawCol)
        let candidate = dotPosition(row: row, col: col)
        guard hypot(candidate.x - point.x, candidate.y - point.y) < spacing * 0.55 else { return nil }
        return (row, col)
    }

    /// The edge between two ADJACENT dots, or nil if they aren't adjacent
    /// (a diagonal drag, or the same dot twice).
    func edge(from a: (row: Int, col: Int), to b: (row: Int, col: Int)) -> DotsAndBoxesEdge? {
        if a.row == b.row, abs(a.col - b.col) == 1 {
            return DotsAndBoxesEdge(orientation: .horizontal, row: a.row, col: min(a.col, b.col))
        }
        if a.col == b.col, abs(a.row - b.row) == 1 {
            return DotsAndBoxesEdge(orientation: .vertical, row: min(a.row, b.row), col: a.col)
        }
        return nil
    }

    /// The line whose midpoint is closest to `point`, among `candidates` —
    /// the "tap the gap between two dots" affordance. Gated to roughly
    /// half a cell so a tap in the middle of a box doesn't snap to a
    /// faraway line.
    func nearestEdge(to point: CGPoint, among candidates: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge? {
        var best: (edge: DotsAndBoxesEdge, distance: CGFloat)?
        for candidate in candidates {
            let (a, b) = edgeEndpoints(candidate)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let distance = hypot(mid.x - point.x, mid.y - point.y)
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        guard let best, best.distance < spacing * 0.42 else { return nil }
        return best.edge
    }
}
