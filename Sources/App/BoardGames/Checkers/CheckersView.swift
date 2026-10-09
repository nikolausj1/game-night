import SwiftUI

/// Checkers (American draughts): table-only pass-and-play.
/// Entry contract: `CheckersView(onClose: @escaping () -> Void)`; setup,
/// play, game over and rematch are internal. See `CheckersDemo` for the
/// `-demoCheckers` / `-demoCheckersBots` hooks the lead should route.
///
/// Red (seat 0) sits at the near edge and moves up the board; black (seat 1)
/// sits across the table. The far seat's plaque is rotated 180 degrees.
struct CheckersView: View {
    var onClose: () -> Void

    @State private var controller: CheckersController?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    var body: some View {
        ZStack {
            TableSurface()
            if let controller {
                gameLayer(controller)
            } else {
                CheckersSetupView(onStart: start)
            }
        }
        .statusBarHidden()
        .onAppear {
            if controller == nil, let demo = CheckersDemo.controllerIfRequested() {
                demo.reduceMotion = motionReduced
                controller = demo
                demo.scheduleBotIfNeeded()
            }
        }
        .onChange(of: motionReduced) { _, reduced in controller?.reduceMotion = reduced }
    }

    private func start(names: [String], bots: [Bool]) {
        let players = [CheckersPlayer(name: names[0], isBot: bots[0]), CheckersPlayer(name: names[1], isBot: bots[1])]
        let fresh = CheckersController(players: players, firstPlayer: 0)
        fresh.reduceMotion = motionReduced
        controller = fresh
        fresh.scheduleBotIfNeeded()
    }

    private func gameLayer(_ controller: CheckersController) -> some View {
        GeometryReader { geo in
            let layout = CheckersLayout(size: geo.size)
            ZStack {
                CheckersBoardView(controller: controller, layout: layout)

                plaque(controller, seat: 0).position(layout.plaqueCenter(seat: 0))
                plaque(controller, seat: 1).rotationEffect(.degrees(180)).position(layout.plaqueCenter(seat: 1))

                notices(controller, layout: layout)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topTrailing) {
            GameHUD(title: "Checkers", onExit: onClose).padding(16)
        }
        .overlay {
            if controller.isOver {
                CheckersResultOverlay(state: controller.state, onRematch: {
                    let last = controller.state.winner ?? controller.state.currentPlayer
                    controller.restart(players: controller.state.players, firstPlayer: 1 - last)
                }, onClose: onClose)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.isOver)
    }

    private func plaque(_ controller: CheckersController, seat: Int) -> some View {
        let state = controller.state
        let player = state.players[seat]
        let over = state.phase == .gameOver
        let active = !over && controller.shownTurn == seat
        var status = ""
        if over {
            status = state.winner == seat ? "winner" : ""
        } else if active {
            if controller.isBusy { status = "moving" }
            else if player.isBot { status = "thinking" }
            else if controller.prefix.count > 1 { status = "keep jumping" }
            else { status = "your move" }
        }
        return CheckersPlaqueView(name: player.name, isBot: player.isBot, owner: seat, status: status,
                                  isActive: active, capturedCount: controller.stage.pile[seat])
    }

    @ViewBuilder
    private func notices(_ controller: CheckersController, layout: CheckersLayout) -> some View {
        let seat = controller.state.currentPlayer
        if let nudge = controller.nudge {
            // Drawn over the wooden frame nearest the player who erred, so it
            // reads upright for them.
            CheckersNoticeChip(text: nudge.message, urgent: true)
                .rotationEffect(.degrees(seat == 1 ? 180 : 0))
                .position(x: layout.center.x, y: seat == 0 ? layout.boardBottom - layout.boardSize * 0.04 : layout.boardTop + layout.boardSize * 0.04)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .allowsHitTesting(false)
        }
        if controller.state.phase == .playing, controller.pliesUntilDraw <= 20 {
            let left = (controller.pliesUntilDraw + 1) / 2
            CheckersNoticeChip(text: left <= 1 ? "Draw next move without a capture" : "Draw in \(left) moves without a capture")
                .position(x: 16 + 150, y: 40)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

#Preview("Checkers - setup") {
    CheckersView(onClose: {})
}

#Preview("Checkers - scripted mid-game") {
    CheckersPreviewHarness()
}

private struct CheckersPreviewHarness: View {
    @State private var controller = CheckersDemo.makeMidGameController()
    var body: some View {
        GeometryReader { geo in
            ZStack {
                TableSurface()
                CheckersBoardView(controller: controller, layout: CheckersLayout(size: geo.size))
            }
        }
    }
}
