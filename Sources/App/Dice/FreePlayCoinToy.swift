import SwiftUI

/// Free play's coin toy: a small pile of LCR-style coins that live purely
/// as felt decoration, no rules, no chip counts, nothing synced across
/// the table, just something to nudge around while testing the app.
///
/// The coins are real metal now: the same shared `CoinSim` world LCR uses
/// (see `Coins/CoinWorld.swift`). Drag any coin, flick it into the others
/// and they scatter; a hard flick can tip a coin onto its edge to roll and
/// whirr down; dice landing near them make them hop. Unlike LCR's piles
/// they never tidy themselves back: a coin stays wherever it comes to rest.
struct FreePlayCoinsLayer: View {
    let size: CGSize
    /// How many coins spawn when the toy is switched on.
    var count: Int = 8

    private let diameter: CGFloat = 46
    /// Where fresh coins spawn: a loose pile toward the middle-bottom of
    /// the felt, out of the way of the deck and the tray.
    private var spawnAnchor: CGPoint { CGPoint(x: size.width * 0.72, y: size.height * 0.62) }
    /// Same generous felt margins DiceTableView's coin piles use.
    private var feltBounds: CGRect {
        CGRect(x: size.width * 0.04, y: size.height * 0.07,
               width: size.width * 0.92, height: size.height * 0.86)
    }

    var body: some View {
        CoinWorldView(
            size: size,
            groups: [CoinGroupSpec(key: "freeplay-coins", count: count, diameter: diameter,
                                   maxVisible: count, seedKey: "freeplay-coins",
                                   spreadScale: 0.62, center: spawnAnchor)],
            bounds: feltBounds,
            tidyDelay: nil)
    }
}
