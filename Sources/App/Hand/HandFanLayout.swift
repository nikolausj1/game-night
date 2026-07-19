import SwiftUI

/// Geometry of a hand of cards held in a fan: positions along a shallow arc,
/// like cards pivoting around a point below the wrist. Pure math, no views.
struct HandFanLayout {
    let cardCount: Int
    let containerWidth: CGFloat
    let cardWidth: CGFloat

    /// Total angular spread grows with hand size but saturates so a 15-card
    /// Wizard endgame hand still fits a thumb's reach.
    private var totalSpreadDegrees: CGFloat {
        guard cardCount > 1 else { return 0 }
        return min(46, CGFloat(cardCount - 1) * 6.5)
    }

    /// The virtual pivot sits well below the screen: shallow, natural arc.
    private var pivotRadius: CGFloat { containerWidth * 1.55 }

    struct Slot {
        let angle: Angle          // card's own tilt
        let offset: CGSize        // from the fan's center anchor
        let zIndex: Double
    }

    func slot(for index: Int, selected: Bool = false) -> Slot {
        guard cardCount > 0 else { return Slot(angle: .zero, offset: .zero, zIndex: 0) }
        let t = cardCount == 1 ? 0.5 : CGFloat(index) / CGFloat(cardCount - 1)
        let degrees = (t - 0.5) * totalSpreadDegrees
        let radians = degrees * .pi / 180

        // Position on the arc around the below-screen pivot.
        var x = sin(radians) * pivotRadius
        var y = (1 - cos(radians)) * pivotRadius

        // A touched card slides up out of the fan to say "I'm yours".
        if selected { y -= cardWidth * 0.55 }

        // Keep extreme fans inside the container.
        let maxX = (containerWidth - cardWidth) / 2
        x = max(-maxX, min(maxX, x))

        return Slot(angle: .degrees(Double(degrees)),
                    offset: CGSize(width: x, height: y),
                    zIndex: Double(index))
    }
}

/// Interactive state for one card being dragged out of the fan.
/// Owned by HandView; separated so the maths stay testable.
struct CardDragState {
    var translation: CGSize = .zero
    var isDragging = false

    /// How far along the "this is a play" gesture we are, 0…1.
    /// Crossing 1 and releasing = play the card. (Fast flicks can also
    /// play via predicted momentum — see HandView's gesture.)
    func playProgress(handHeight: CGFloat) -> CGFloat {
        let liftDistance = -translation.height
        let threshold = handHeight * 0.26
        return max(0, min(1, liftDistance / threshold))
    }

    /// Elevation for CardView shadows: rises quickly at drag start, then eases.
    func elevation(handHeight: CGFloat) -> CGFloat {
        guard isDragging else { return 0 }
        return 0.4 + 0.6 * playProgress(handHeight: handHeight)
    }
}
