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
    /// still at its seeded spawn slot — only set once a drag ends, so a
    /// LIVE drag never fights its own base position (see `dragOffsets`).
    @State private var positions: [Int: CGPoint] = [:]
    /// Live, in-flight drag offset per coin id — transient, cleared the
    /// instant the gesture ends and folded into `positions` instead.
    @State private var dragOffsets: [Int: CGSize] = [:]
    @State private var draggingID: Int?

    private let diameter: CGFloat = 46
    /// Where fresh coins spawn: a loose pile toward the middle-bottom of
    /// the felt, out of the way of the deck and the tray.
    private var spawnAnchor: CGPoint { CGPoint(x: size.width * 0.72, y: size.height * 0.62) }

    var body: some View {
        ForEach(0..<count, id: \.self) { id in
            let rest = positions[id] ?? defaultPosition(for: id)
            let drag = dragOffsets[id] ?? .zero
            let at = CGPoint(x: rest.x + drag.width, y: rest.y + drag.height)
            ChipToken(diameter: diameter, animatesSheen: id < 3)
                .rotationEffect(.degrees(TableGeometry.jitterDegrees(cardID: "fpcoin\(id)") * 5))
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
                            positions[id] = CGPoint(x: rest.x + value.translation.width,
                                                    y: rest.y + value.translation.height)
                            dragOffsets[id] = nil
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
