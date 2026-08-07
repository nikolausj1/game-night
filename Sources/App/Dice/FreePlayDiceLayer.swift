import SwiftUI

/// Free play's dice toy, upgraded to the SAME manual-cup ceremony LCR uses
/// ("when I hit the DICE button, a cup appears by my name so I can put the
/// DICE in the cup" — owner feedback). Turning the Dice toggle on spawns
/// the persistent 3-die pool AND the photoreal `TableCupView` at the host
/// player's own plate edge (free play's one local human, seat 0 — every
/// seat count's `TableGeometry.seatAnchors` puts index 0 at (0.5, 0.94),
/// the same anchor the old bare scene hardcoded); dragging dice into the
/// cup (or, with `gn.autoCup` on, watching them glide in on their own) is
/// what "loads" a roll, exactly `DiceTableView`'s LCR flow — just with no
/// rules, chips, or turns attached.
///
/// ## Root cause of "I can't use DICE on free play"
///
/// The old call site (still in TableGameView, see the integration note
/// below) predates the manual-cup rewrite: it called `DiceTableSceneView`
/// with only `roll:anchor:onResult:`, leaving every cup param at its
/// LCR-oriented default (`cupSeat: nil`, `autoCup: false`, …) — so
/// `dragSeat` never got set and the pool's touch-claim (`shouldClaim`)
/// never fired — AND it force-disabled all touch with
/// `.allowsHitTesting(false)` on top of that, a leftover from the pre-cup
/// toy that only ever needed the Roll button. The persistent pool still
/// spawned and the Roll button still launched real rolls (verified: 3 real
/// dice appear and settle on toggling Dice on, in a clean sim run) — but
/// there was never any way to drag a die anywhere, which is what reads as
/// "I can't use DICE" once you've seen LCR's cup. This view fixes that by
/// wiring the same cup params LCR does and dropping the hit-testing block.
///
/// ## Self-contained by design
///
/// Same reasoning as `FreePlayCoinsLayer`: free play's dice carry no
/// gameplay state worth routing through the engine, so the cup ceremony's
/// `loadedDice` count lives in local `@State` here, with
/// `GameHostController.freePlayLoadedDice`/`setFreePlayLoadedDice` as a
/// thin outbound mirror for a connected host-seat phone (see
/// `Sources/Engine/DiceTypes.swift`'s `loadedDice` field and
/// `GameHostController.sendFreePlayDiceState`).
struct FreePlayDiceLayer: View {
    @Bindable var host: GameHostController
    let size: CGSize
    /// The in-flight roll request. TableGameView still owns the id counter
    /// and the Roll button's tap target (and remote pours still route
    /// through `host.onFreePlayDicePour` exactly as before) — this view
    /// only reads the result and reports back, same contract the old bare
    /// scene had.
    var roll: DiceGameController.Roll?
    var onResult: (_ rollID: Int, _ faces: [LcrFace]) -> Void

    @AppStorage("gn.autoCup") private var autoCup = false
    @State private var loadedDice = 0

    /// Seat 0's anchor — every `TableGeometry.seatAnchors(count:)` case
    /// puts index 0 here, so this doesn't need to know the real seat count.
    private let seatAnchor = CGPoint(x: 0.5, y: 0.94)
    /// Matches the Roll button's long-standing fixed `count: 3`.
    private let requiredCount = 3

    var body: some View {
        ZStack {
            DiceTableSceneView(
                roll: roll, anchor: seatAnchor,
                cupSeat: 0, requiredCount: requiredCount, loadedCount: loadedDice,
                autoCup: autoCup, mouthScreen: cupMouthScreen,
                onDieLoaded: { _ in
                    loadedDice = min(requiredCount, loadedDice + 1)
                    host.setFreePlayLoadedDice(loadedDice)
                }
            ) { rollID, faces in
                onResult(rollID, faces)
            }
            TableCupView(edge: .bottom, loadedCount: loadedDice, requiredCount: requiredCount)
                .position(cupCenter)
        }
        // A launch from ANY source — this view's own Roll button OR a
        // remote pour — empties the on-screen cup; the dice just left it.
        // `.dicePour` for the host seat is itself gated by
        // `GameHostController.freePlayCanRoll` (mirrors this same count),
        // so this can never race a load that hasn't happened yet.
        .onChange(of: roll?.id) { _, newID in
            guard newID != nil else { return }
            loadedDice = 0
            host.setFreePlayLoadedDice(0)
        }
    }

    private var plateCenter: CGPoint {
        CGPoint(x: seatAnchor.x * size.width, y: seatAnchor.y * size.height)
    }

    /// The cup sits BEYOND the plate, toward the rail — identical geometry
    /// to `DiceTableView.cupCenter` (duplicated locally rather than shared:
    /// that one is LCR-private and keys off a live seat list this sandbox
    /// doesn't have).
    private var cupCenter: CGPoint {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.47)
        let outward = CGVector(dx: plateCenter.x - center.x, dy: plateCenter.y - center.y)
        let length = max(1, hypot(outward.dx, outward.dy))
        let unit = CGVector(dx: outward.dx / length, dy: outward.dy / length)
        return CGPoint(x: plateCenter.x + unit.dx * 92, y: plateCenter.y + unit.dy * 92)
    }

    private var cupMouthScreen: CGPoint {
        let mouthOffset = TableCupView.mouthOffset(for: .bottom)
        return CGPoint(x: cupCenter.x + mouthOffset.dx, y: cupCenter.y + mouthOffset.dy)
    }
}
