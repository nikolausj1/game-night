import SwiftUI

/// Free play's coin toy: a small stack of LCR-style coins that live purely
/// as felt decoration — no rules, no chip counts, nothing synced across
/// the table, just something to nudge around while testing the app.
/// "I want to test every interaction in free play" extends the existing
/// card toy's spirit (drag anything, anywhere, nothing enforced) to coins.
///
/// Self-contained on purpose: unlike LCR's chip clusters (which mirror
/// `DiceGameController.chips`, real game state), these coins carry no
/// gameplay meaning worth syncing, so position state lives entirely in
/// this view's own `@State` rather than routing through
/// `GameHostController`. `ChipToken`/`CoinCluster` (DiceTableView.swift)
/// are reused directly — same module, same material language, no
/// duplication.
struct FreePlayCoinsLayer: View {
    let size: CGSize
    /// How many coins spawn when the toy is switched on.
    var count: Int = 8

    /// Committed rest position per coin id (screen coordinates). `nil` =
    /// still at its seeded spawn slot — only set once a drag (or a glide
    /// it kicked off) settles, so a LIVE drag never fights its own base
    /// position (see `dragOffsets`).
    @State private var positions: [Int: CGPoint] = [:]
    /// Live, in-flight drag/glide offset per coin id — transient, cleared
    /// once the gesture (or its momentum glide) settles and folded into
    /// `positions` instead.
    @State private var dragOffsets: [Int: CGSize] = [:]
    @State private var draggingID: Int?
    /// Extra rotation riding on top of a coin's resting spin while a glide
    /// is in flight — decays to 0 in the same animation as the glide.
    @State private var glideSpin: [Int: Double] = [:]

    private let diameter: CGFloat = 46
    /// Where fresh coins spawn: a loose pile toward the middle-bottom of
    /// the felt, out of the way of the deck and the tray.
    private var spawnAnchor: CGPoint { CGPoint(x: size.width * 0.72, y: size.height * 0.62) }
    /// Same generous felt margins DiceTableView's coin piles clamp a
    /// flicked coin's glide to.
    private var feltBounds: CGRect {
        CGRect(x: size.width * 0.04, y: size.height * 0.07,
              width: size.width * 0.92, height: size.height * 0.86)
    }

    var body: some View {
        ForEach(0..<count, id: \.self) { id in
            let rest = positions[id] ?? defaultPosition(for: id)
            let drag = dragOffsets[id] ?? .zero
            let at = CGPoint(x: rest.x + drag.width, y: rest.y + drag.height)
            let baseRotation = TableGeometry.jitterDegrees(cardID: "fpcoin\(id)") * 5
            ChipToken(diameter: diameter, animatesSheen: id < 3)
                .rotationEffect(.degrees(baseRotation + (glideSpin[id] ?? 0)))
                .scaleEffect(draggingID == id ? 1.16 : 1)
                .shadow(color: .black.opacity(draggingID == id ? 0.4 : 0), radius: 9, y: 5)
                .position(at)
                .zIndex(draggingID == id ? 10 : Double(id))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if draggingID != id { draggingID = id; Haptics.tick() }
                            dragOffsets[id] = value.translation
                        }
                        .onEnded { value in
                            draggingID = nil
                            let releasePoint = CGPoint(x: rest.x + value.translation.width,
                                                       y: rest.y + value.translation.height)
                            if let glide = CoinPhysics.glide(velocity: value.velocity) {
                                // Metal-on-felt: it keeps sliding past the
                                // release point on its own momentum, with a
                                // soft rail stop if it would run off table
                                // — same model the LCR pile coins use.
                                let glideTo = CoinPhysics.clamp(
                                    CoinPhysics.project(from: releasePoint, velocity: value.velocity,
                                                        distance: glide.distance),
                                    to: feltBounds, radius: diameter / 2)
                                glideSpin[id] = CoinPhysics.spinDrift(velocity: value.velocity)
                                withAnimation(FeltPhysics.slide(duration: glide.duration)) {
                                    dragOffsets[id] = CGSize(width: glideTo.x - rest.x,
                                                             height: glideTo.y - rest.y)
                                    glideSpin[id] = 0
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + glide.duration) {
                                    positions[id] = glideTo
                                    dragOffsets[id] = nil
                                }
                            } else {
                                positions[id] = releasePoint
                                dragOffsets[id] = nil
                            }
                        }
                )
        }
    }

    /// Deterministic seeded spawn slot — a loose pile, not a grid, using
    /// the same golden-angle spiral CoinCluster piles use elsewhere.
    private func defaultPosition(for id: Int) -> CGPoint {
        let slot = CoinCluster.slot(index: id, seedKey: "freeplay-coins",
                                    diameter: diameter, spreadScale: 0.62)
        let anchor = spawnAnchor
        return CGPoint(x: anchor.x + slot.width, y: anchor.y + slot.height)
    }
}
