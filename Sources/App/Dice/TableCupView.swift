import SwiftUI

/// Manual cup loading's table-side hardware: a photoreal leather dice cup
/// (the generated `TableCup` asset — brass rim, red felt interior, tilted
/// mouth) sitting at the current roller's rail edge. `gn.autoCup` off (the
/// default) means a human roller must drag every required die into this
/// cup's mouth before `DiceGameController.roll` will do anything — see
/// `DiceGameController.canRoll`/`loadDie`. In auto-cup mode the SAME cup
/// shows at the roller's seat and the dice glide in on their own instead
/// of being dragged.
///
/// The cup itself is presentation-only (`allowsHitTesting(false)`): the
/// interaction lives entirely in the SceneKit dice layer
/// (`DiceTableSceneView`), which hit-tests the REAL dice already resting
/// on the felt and drags/drops them into the mouth. `DiceTableView` owns
/// placement (seat anchor → edge, plate position → cup center) and reads
/// `mouthOffset(for:)` to tell that SceneKit layer exactly where the drop
/// zone is — this file only knows how to draw the cup.
struct TableCupView: View {
    /// Which rail this cup sits against — the same four-way convention
    /// TableGameView's plate rotation uses (bottom 0°, top 180°, left 90°,
    /// right -90°), so a cup always tilts its mouth toward the table
    /// center and lets its body bleed off the correct screen edge.
    enum RailEdge {
        case bottom, top, left, right

        var rotation: Angle {
            switch self {
            case .bottom: return .degrees(0)
            case .top: return .degrees(180)
            case .left: return .degrees(90)
            case .right: return .degrees(-90)
            }
        }
    }

    var edge: RailEdge
    /// How many of the required dice are already loaded. Cosmetic only —
    /// the real dice themselves disappear INTO the cup as they're loaded
    /// (DiceTableSceneCoordinator hides each one once its drop animation
    /// lands), so there's nothing left for this view to draw per-die; kept
    /// as a parameter for callers/future use rather than dropped outright.
    var loadedCount: Int
    var requiredCount: Int

    /// The `TableCup` asset's native footprint (table-cup-FINAL, 879×968 —
    /// a tight crop, aspect ~0.908) scaled to roughly the same on-felt
    /// presence the old vector cup drew at.
    private let bodyWidth: CGFloat = 172
    private var bodyHeight: CGFloat { bodyWidth * (968.0 / 879.0) }

    /// Where the mouth sits relative to wherever the caller `.position()`s
    /// this view, ALREADY rotated for `edge` — callers (DiceTableView's
    /// cup layer AND the SceneKit drag-drop layer) aim there without
    /// needing to know the cup's internal layout. The photo's mouth sits
    /// in the upper third of the frame with a slight rightward tilt; the
    /// dominant "toward table center" component matches the old vector
    /// cup's per-edge geometry (so table placement math didn't need to
    /// change), with a small secondary offset for that tilt.
    static func mouthOffset(for edge: RailEdge) -> CGVector {
        let distance: CGFloat = 58
        let tilt: CGFloat = 14
        switch edge {
        case .bottom: return CGVector(dx: tilt, dy: -distance)
        case .top: return CGVector(dx: -tilt, dy: distance)
        case .left: return CGVector(dx: distance, dy: -tilt)
        case .right: return CGVector(dx: -distance, dy: tilt)
        }
    }

    var body: some View {
        ZStack {
            contactShadow
            Image("TableCup")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: bodyWidth, height: bodyHeight)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
        }
        .rotationEffect(edge.rotation)
        .allowsHitTesting(false) // the SceneKit dice layer owns the interaction
    }

    /// A soft dark contact-shadow pool grounding the cup on the felt — same
    /// "pressed into the surface" language as DieShadowNode/
    /// CoinContactShadow elsewhere on the table, done natively in SwiftUI
    /// since the cup is a 2D felt-layer overlay, not a 3D scene node.
    private var contactShadow: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.22), .clear],
                center: .center, startRadius: 0, endRadius: bodyWidth * 0.6))
            .frame(width: bodyWidth * 0.94, height: bodyHeight * 0.40)
            .offset(y: bodyHeight * 0.37)
            .blur(radius: 3)
    }
}
