import SwiftUI

/// Connect Four: table-only pass-and-play with the standing frame photo.
/// Entry contract: `ConnectFourView(onClose: @escaping () -> Void)`; setup,
/// play, game over and rematch are internal. See `ConnectFourDemo` for the
/// `-demoConnectFour` / `-demoConnectFourBots` / `-demoConnectFourWin` hooks.
///
/// Red (seat 0) sits at the near edge; yellow (seat 1) across the table, and
/// the far plaque is rotated 180 degrees.
struct ConnectFourView: View {
    var onClose: () -> Void
    /// Mount straight into the parked game (`ResumeCatalog`), skipping setup.
    var resumeSaved = false

    @State private var controller: ConnectFourController?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    var body: some View {
        ZStack {
            TableSurface()
            if let controller {
                gameLayer(controller)
            } else {
                ConnectFourSetupView(onStart: start)
            }
        }
        .statusBarHidden()
        .onAppear {
            if controller == nil, let demo = ConnectFourDemo.controllerIfRequested() {
                demo.reduceMotion = motionReduced
                controller = demo
                demo.scheduleBotIfNeeded()
            }
            if controller == nil, resumeSaved, let saved = LocalGameSave.loadConnectFour() {
                let restored = ConnectFourController(restoring: saved)
                restored.reduceMotion = motionReduced
                controller = restored
                restored.scheduleBotIfNeeded()
            }
        }
        .onChange(of: motionReduced) { _, reduced in controller?.reduceMotion = reduced }
        .onChange(of: controller?.revision) { _, _ in
            // Autosave 2s after the last disc settles; game over clears it.
            if let controller { LocalGameSave.noteConnectFour(controller.state) }
        }
    }

    private func start(names: [String], bots: [Bool]) {
        LocalGameSave.clear(.board("connectFour"))
        let players = [ConnectFourPlayer(name: names[0], isBot: bots[0]), ConnectFourPlayer(name: names[1], isBot: bots[1])]
        let fresh = ConnectFourController(players: players, firstPlayer: 0)
        fresh.reduceMotion = motionReduced
        controller = fresh
        fresh.scheduleBotIfNeeded()
    }

    private func gameLayer(_ controller: ConnectFourController) -> some View {
        GeometryReader { geo in
            let layout = ConnectFourLayout(size: geo.size)
            ZStack {
                ConnectFourFrameView(controller: controller, layout: layout, reduceMotion: motionReduced)
                plaque(controller, seat: 0).position(layout.plaqueCenter(seat: 0))
                plaque(controller, seat: 1).rotationEffect(.degrees(180)).position(layout.plaqueCenter(seat: 1))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topTrailing) {
            GameHUD(title: "Connect Four", onExit: onClose).padding(16)
        }
        .overlay {
            if controller.resultVisible, controller.state.phase == .gameOver {
                recap(controller)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.resultVisible)
    }

    /// End of game: the line (or a full, lineless board), discs each, rematch.
    private func recap(_ controller: ConnectFourController) -> some View {
        let state = controller.state
        let discs = [0, 1].map { seat in state.cells.filter { $0 == seat }.count }
        let order = [0, 1].sorted { (state.winner == $0) || (state.winner != $1 && discs[$0] > discs[$1]) }
        let rows = order.map { seat in
            RecapRow(id: seat, name: state.players[seat].name, colorIndex: seat == 0 ? 1 : 2,
                     score: "\(discs[seat])", detail: seat == 0 ? "red discs" : "yellow discs",
                     isWinner: state.winner == seat)
        }
        let title = state.winner.map { "\(state.players[$0].name) wins Connect Four" } ?? "A draw"
        let highlight = state.winner == nil
            ? "Every hole is filled and nobody lined up four"
            : "Four in a row on move \(state.moveCount)"
        return GameRecapCard(title: title, rows: rows, highlight: highlight, onRematch: {
            let last = state.winner ?? state.currentPlayer
            controller.restart(players: state.players, firstPlayer: 1 - last)
        }, onDone: onClose)
    }

    private func plaque(_ controller: ConnectFourController, seat: Int) -> some View {
        let state = controller.state
        let player = state.players[seat]
        let over = state.phase == .gameOver
        let active = !over && controller.shownTurn == seat
        var status = ""
        if over {
            status = state.winner == seat ? "winner" : ""
        } else if active {
            if controller.isBusy { status = "dropping" }
            else if player.isBot { status = "thinking" }
            else { status = "your drop" }
        }
        return ConnectFourPlaqueView(name: player.name, isBot: player.isBot, seat: seat, status: status, isActive: active)
    }
}

#Preview("Connect Four - setup") {
    ConnectFourView(onClose: {})
}

#Preview("Connect Four - scripted mid-game") {
    ConnectFourPreviewHarness()
}

private struct ConnectFourPreviewHarness: View {
    @State private var controller = ConnectFourDemo.makeMidGameController()
    var body: some View {
        GeometryReader { geo in
            ZStack {
                TableSurface()
                ConnectFourFrameView(controller: controller, layout: ConnectFourLayout(size: geo.size), reduceMotion: false)
            }
        }
    }
}
