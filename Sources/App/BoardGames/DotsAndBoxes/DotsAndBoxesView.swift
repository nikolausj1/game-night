import SwiftUI

/// Dots & Boxes: a real sheet of paper lying on the felt, played directly
/// on the iPad — pass-and-play, finger as pencil, phones never involved.
/// Entry contract for the menu worker: `DotsAndBoxesView(onClose:)`, mounted
/// wherever a standalone game view goes (see `DiceTableView`/`DiceLauncher`
/// for the sibling "game that lives outside the card engine" pattern this
/// follows — no `GameHostController`, no `GameState`, entirely self-owned).
///
/// Owns its own setup → play → scoreboard flow internally: nothing outside
/// this file needs to know whether a game is mid-setup, mid-play, or just
/// finished. `onClose` is only ever the "leave Dots & Boxes entirely" exit.
struct DotsAndBoxesView: View {
    var onClose: () -> Void

    @State private var controller: DotsAndBoxesController?
    @State private var showScoreboard = false

    var body: some View {
        ZStack {
            if let controller {
                playArea(controller)
            } else {
                DotsAndBoxesSetupView(
                    onStart: { gridSize, players in
                        withAnimation(.easeOut(duration: 0.25)) {
                            controller = DotsAndBoxesController(gridSize: gridSize, players: players, seed: .random(in: .min ... .max))
                        }
                    },
                    onClose: onClose
                )
            }
        }
        .onAppear {
            // Sim-verify hook: -demoDotsAndBoxes drops straight into a
            // scripted mid-game instead of the setup overlay. See
            // DotsAndBoxesDemoData for the routing note to the menu worker —
            // this flag only does anything once THIS view is reachable.
            if controller == nil, DotsAndBoxesDemoData.wantsDemo {
                controller = DotsAndBoxesDemoData.makeMidGameController()
            }
        }
    }

    @ViewBuilder
    private func playArea(_ controller: DotsAndBoxesController) -> some View {
        ZStack {
            DotsAndBoxesPaperView(controller: controller) { edge in
                controller.claim(edge, by: controller.state.turnIndex)
            }
            .padding(24)

            VStack {
                DotsAndBoxesTurnCardView(
                    player: controller.state.players[safe: controller.state.turnIndex] ?? controller.state.players[0],
                    isBotThinking: currentPlayerIsBot(controller)
                )
                .padding(.top, 8)
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            GameHUD(title: "Dots & Boxes", onExit: onClose)
                .padding(16)
        }
        .onChange(of: controller.state.isGameOver) { _, isOver in
            if isOver {
                // A beat to let the final stroke/initial animate in before
                // the scoreboard covers the paper.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        showScoreboard = true
                    }
                }
            }
        }
        .overlay {
            if showScoreboard {
                DotsAndBoxesScoreboardView(
                    players: controller.state.players,
                    winners: winners(for: controller.state),
                    onPlayAgain: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            showScoreboard = false
                        }
                        controller.playAgain()
                    },
                    onClose: onClose
                )
            }
        }
    }

    private func currentPlayerIsBot(_ controller: DotsAndBoxesController) -> Bool {
        let turn = controller.state.turnIndex
        return controller.state.players[safe: turn]?.isBot ?? false
    }

    /// Recomputes the same tie-aware winner set the engine's `gameOver`
    /// event carries, from final state alone — the scoreboard doesn't keep
    /// its own copy of the event stream, it just reads `state` once the
    /// board is full.
    private func winners(for state: DotsAndBoxesState) -> [Int] {
        guard let top = state.players.map(\.score).max() else { return [] }
        return state.players.indices.filter { state.players[$0].score == top }
    }
}

#Preview("Dots & Boxes — setup") {
    DotsAndBoxesView(onClose: {})
}

/// Canvas-only preview of the scripted mid-game state (same engine script
/// `-demoDotsAndBoxes` uses) — lets the paper/pencil rendering be eyeballed
/// in Xcode without the setup overlay in the way, ahead of route wiring.
#Preview("Dots & Boxes — scripted mid-game") {
    DotsAndBoxesMidGamePreviewHarness()
}

private struct DotsAndBoxesMidGamePreviewHarness: View {
    @State private var controller = DotsAndBoxesDemoData.makeMidGameController()

    var body: some View {
        ZStack {
            CardStyle.feltGreen.ignoresSafeArea()
            DotsAndBoxesPaperView(controller: controller) { edge in
                controller.claim(edge, by: controller.state.turnIndex)
            }
            .padding(24)
            VStack {
                DotsAndBoxesTurnCardView(player: controller.state.players[controller.state.turnIndex])
                Spacer()
            }
        }
    }
}
