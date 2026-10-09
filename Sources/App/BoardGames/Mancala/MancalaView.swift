import SwiftUI

/// Mancala (Kalah): table-only pass-and-play, two seats at the iPad.
/// Entry contract: `MancalaView(onClose: @escaping () -> Void)`. Setup,
/// play, game over and rematch are all internal. Not wired into
/// `TableRootView` / `MenuView` here (outside this worker's file scope);
/// see `MancalaDemo` for the launch hook the lead should route.
///
/// Seat 0 sits at the NEAR (bottom) edge and owns the bottom row of pits
/// plus the store at the right; seat 1 sits across the table and owns the
/// top row plus the store at the left. The far seat's plaque, store badge
/// and "Go again" flourish are rotated 180 degrees so they read right-side-up
/// from where that player sits.
struct MancalaView: View {
    var onClose: () -> Void
    /// Mount straight into the parked game (`ResumeCatalog`), skipping setup.
    var resumeSaved = false

    @State private var controller: MancalaController?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    var body: some View {
        ZStack {
            TableSurface()
            if let controller {
                gameLayer(controller)
            } else {
                MancalaSetupView(onStart: start)
            }
        }
        .statusBarHidden()
        .onAppear {
            if controller == nil, let demo = MancalaDemo.controllerIfRequested() {
                demo.reduceMotion = motionReduced
                controller = demo
                demo.scheduleBotIfNeeded()
            }
            if controller == nil, resumeSaved, let saved = LocalGameSave.loadMancala() {
                let restored = MancalaController(restoring: saved)
                restored.reduceMotion = motionReduced
                controller = restored
                restored.scheduleBotIfNeeded()
            }
        }
        .onChange(of: motionReduced) { _, reduced in controller?.reduceMotion = reduced }
        .onChange(of: controller?.revision) { _, _ in
            // Autosave 2s after the last settled move; game over clears it.
            if let controller { LocalGameSave.noteMancala(controller.state) }
        }
    }

    private func start(names: [String], bots: [Bool]) {
        LocalGameSave.clear(.board("mancala"))
        let players = [MancalaPlayer(name: names[0], isBot: bots[0]), MancalaPlayer(name: names[1], isBot: bots[1])]
        let fresh = MancalaController(players: players, firstPlayer: 0)
        fresh.reduceMotion = motionReduced
        controller = fresh
        fresh.scheduleBotIfNeeded() // bot-vs-bot, or "bot opens"
    }

    // MARK: - Layout

    private func gameLayer(_ controller: MancalaController) -> some View {
        GeometryReader { geo in
            let boardW = min(geo.size.width * 0.90, (geo.size.height - 300) / MancalaGeometry.aspect, 1250)
            let boardH = boardW * MancalaGeometry.aspect
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let top = cy - boardH / 2
            let bottom = cy + boardH / 2
            let rightStoreX = cx + (MancalaGeometry.rightStoreX - 0.5) * boardW
            let leftStoreX = cx + (MancalaGeometry.leftStoreX - 0.5) * boardW

            ZStack {
                MancalaBoardView(controller: controller, width: boardW, onSow: { controller.sow(localPit: $0) })
                    .position(x: cx, y: cy)

                // Store medallions: seat 0's under the right end, seat 1's
                // over the left end (upside-down for the far seat).
                storeBadge(controller, seat: 0).position(x: rightStoreX, y: bottom + 38)
                storeBadge(controller, seat: 1).rotationEffect(.degrees(180)).position(x: leftStoreX, y: top - 38)

                plaque(controller, seat: 0).position(x: cx, y: bottom + 70)
                plaque(controller, seat: 1).rotationEffect(.degrees(180)).position(x: cx, y: top - 70)

                goAgainBanner(controller)
                    .position(x: cx, y: cy)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topTrailing) {
            GameHUD(title: "Mancala", onExit: onClose).padding(16)
        }
        .overlay {
            if controller.isOver {
                recap(controller)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.isOver)
    }

    /// End of game: winner (or an honest draw), final store counts, rematch.
    private func recap(_ controller: MancalaController) -> some View {
        let state = controller.state
        let scores = state.scores
        let order = [0, 1].sorted { scores[$0] > scores[$1] }
        let rows = order.map { seat in
            RecapRow(id: seat, name: state.players[seat].name, colorIndex: seat,
                     score: "\(scores[seat])", detail: "stones in store", isWinner: state.winner == seat)
        }
        let title = state.winner.map { "\(state.players[$0].name) wins Mancala" } ?? "A draw"
        let highlight = state.winner == nil
            ? "Twenty-four stones each. Perfectly matched."
            : "Won by \(abs(scores[0] - scores[1])) stones after \(state.moveCount) sowings"
        return GameRecapCard(title: title, rows: rows, highlight: highlight, onRematch: {
            let last = state.winner ?? state.currentPlayer
            controller.restart(players: state.players, firstPlayer: 1 - last)
        }, onDone: onClose)
    }

    private func plaque(_ controller: MancalaController, seat: Int) -> some View {
        let state = controller.state
        let player = state.players[seat]
        let over = state.phase == .gameOver
        let active = !over && controller.shownTurn == seat
        var status = ""
        if over {
            status = state.winner == seat ? "winner" : ""
        } else if active {
            if controller.isBusy { status = "sowing" }
            else if player.isBot { status = "thinking" }
            else { status = "your move" }
        }
        return MancalaPlaqueView(name: player.name, isBot: player.isBot, status: status, isActive: active)
    }

    /// Live count: stones already landed in the store, so the number ticks up
    /// pour by pour instead of jumping at the end of the move.
    private func storeBadge(_ controller: MancalaController, seat: Int) -> some View {
        let stage = controller.stage
        let slot = MancalaRules.store(of: seat)
        let plan = stage.plan
        let resting = stage.slots[slot].count
        let start = stage.startDate
        return TimelineView(.animation(paused: plan == nil)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let count = plan.map { $0.landedCount(in: slot, at: t) } ?? resting
            MancalaStoreBadge(count: count)
        }
    }

    @ViewBuilder
    private func goAgainBanner(_ controller: MancalaController) -> some View {
        if let seat = controller.goAgainSeat {
            Text("Go again")
                .font(.system(size: 30, weight: .semibold, design: .serif).italic())
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.62), CardStyle.gold],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .shadow(color: CardStyle.gold.opacity(0.7), radius: 12)
                .rotationEffect(.degrees(seat == 1 ? 180 : 0))
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityLabel(Text("\(controller.state.players[seat].name), go again"))
        }
    }
}

#Preview("Mancala - setup") {
    MancalaView(onClose: {})
}

#Preview("Mancala - scripted mid-game") {
    MancalaDemoPreview()
}

private struct MancalaDemoPreview: View {
    @State private var controller = MancalaDemo.makeMidGameController()
    var body: some View {
        ZStack {
            TableSurface()
            MancalaBoardView(controller: controller, width: 900, onSow: { controller.sow(localPit: $0) })
        }
    }
}
