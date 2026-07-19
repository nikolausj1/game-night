import SwiftUI

/// Where things sit on the table for a given seat count. Unit coordinates
/// (0…1 in both axes) over the felt area; the views scale them.
enum TableGeometry {
    /// Seat anchor positions around the rim, clockwise from bottom center.
    /// Chosen per player count so plates never crowd a corner.
    static func seatAnchors(count: Int) -> [CGPoint] {
        switch count {
        case ...2: return [CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.5, y: 0.06)]
        case 3: return [CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.12, y: 0.22),
                        CGPoint(x: 0.88, y: 0.22)]
        case 4: return [CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.07, y: 0.5),
                        CGPoint(x: 0.5, y: 0.06), CGPoint(x: 0.93, y: 0.5)]
        case 5: return [CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.08, y: 0.68),
                        CGPoint(x: 0.20, y: 0.10), CGPoint(x: 0.80, y: 0.10),
                        CGPoint(x: 0.92, y: 0.68)]
        default: return [CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.08, y: 0.72),
                         CGPoint(x: 0.13, y: 0.14), CGPoint(x: 0.5, y: 0.06),
                         CGPoint(x: 0.87, y: 0.14), CGPoint(x: 0.92, y: 0.72)]
        }
    }

    /// A played card lands between its seat and the center — pulled 62% of
    /// the way in, rotated to point where it came from, with a small settle
    /// jitter derived stably from the card id (same jitter every render).
    static func trickCardPose(seatAnchor: CGPoint, cardID: String) -> (position: CGPoint, rotation: Angle) {
        let center = CGPoint(x: 0.5, y: 0.47)
        let position = CGPoint(x: seatAnchor.x + (center.x - seatAnchor.x) * 0.62,
                               y: seatAnchor.y + (center.y - seatAnchor.y) * 0.62)
        let towardCenter = atan2(center.y - seatAnchor.y, center.x - seatAnchor.x)
        let jitter = jitterDegrees(cardID: cardID)
        return (position, .radians(Double(towardCenter) + .pi / 2 + jitter * .pi / 180))
    }

    /// −9°…+9°, deterministic per card so the table doesn't twitch on redraw.
    static func jitterDegrees(cardID: String) -> Double {
        var hash: UInt64 = 5381
        for byte in cardID.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 1800) / 100.0 - 9.0
    }
}
