import SwiftUI

/// The felt stage for Yahtzee — mounted by the lead's `DiceLauncher`
/// exactly the way `DiceTableView` is mounted for LCR today (see
/// `YahtzeeController`'s doc for the one-line wiring this expects). Real 3D
/// pip dice tumble center-table from the roller's cup edge; between rolls
/// the roller taps settled dice to hold/unhold them; category picking
/// happens on the paper scoresheet pinned near the rail, never on a phone.
struct YahtzeeTableView: View {
    @Bindable var controller: YahtzeeController
    var onClose: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    /// Manual cup loading, default ON — identical contract/default to
    /// DiceTableView's own `gn.autoCup`, read live by the controller too.
    @AppStorage("gn.autoCup") private var autoCup = false

    @State private var showCloseButton = false
    @State private var closeRingProgress: CGFloat = 0
    /// The most recent score event, held on screen for its flourish/trophy
    /// beat and cleared afterward — see `scoreFlourishOverlay`.
    @State private var flourishEvent: YahtzeeController.ScoreEvent?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showCloseButton.toggle()
                        }
                        if showCloseButton {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                withAnimation { showCloseButton = false }
                            }
                        }
                    }
                platesLayer(size: geo.size)
                cupLayer(size: geo.size)
                diceScene(size: geo.size)
                    .onAppear {
                        TableMotion.shared.onBump = { intensity in
                            TableSFX.shared.play(.tableKnock, intensity: 0.7 + intensity * 0.3)
                            guard !motionReduced else { return }
                            DiceTableSceneCoordinator.activeCoordinator?.jolt(intensity: intensity)
                        }
                        TableMotion.shared.onNudge = { direction, strength in
                            guard !motionReduced else { return }
                            DiceTableSceneCoordinator.activeCoordinator?.nudge(
                                direction: direction, strength: strength)
                        }
                        TableMotion.shared.start()
                    }
                    .onDisappear { TableMotion.shared.stop() }
                YahtzeeScoresheetView(controller: controller) { category in
                    controller.scoreCategory(category, forSeat: controller.turnSeat)
                }
                .position(x: scoresheetWidth / 2 + 18, y: geo.size.height * 0.52)

                scoreFlourishOverlay(size: geo.size)

                if controller.gameOver {
                    gameOverBanner
                }
                if showCloseButton, let onClose {
                    TableGameView.HoldToCloseButton(progress: $closeRingProgress) {
                        onClose()
                    }
                    .position(x: 64, y: 56)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                GameHUD(title: "Yahtzee", onExit: { onClose?() },
                       toggles: [HUDToggle(label: "Auto-cup", isOn: $autoCup)])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .onChange(of: controller.lastScoreEvent) { _, event in
                triggerFlourish(event)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.turnSeat)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: controller.gameOver)
    }

    /// Mirrors `YahtzeeScoresheetView.sheetWidth` — kept as a small local
    /// duplicate (same spirit as `DiceTableView`'s own duplicated
    /// `railEdge` geometry) since the table needs it to CENTER the sheet
    /// before that view has laid itself out.
    private var scoresheetWidth: CGFloat { 148 + CGFloat(max(1, controller.seats.count)) * 62 }

    // MARK: - Dice (the 3D layer)

    private func diceScene(size: CGSize) -> some View {
        let seat = activeCupSeat
        let required = seat.map { _ in YahtzeeController.diceCount - controller.heldIndices.count } ?? 0
        return DiceTableSceneView(
            roll: controller.currentRoll, anchor: rollerAnchor,
            diceCount: YahtzeeController.diceCount, faceStyle: .pips,
            cupSeat: seat, requiredCount: required, loadedCount: controller.loadedDiceCount,
            autoCup: autoCup, mouthScreen: seat != nil ? cupMouthScreen(seatID: seat!, size: size) : nil,
            onDieLoaded: { s in controller.loadDie(forSeat: s) },
            heldIndices: controller.heldIndices,
            onDieTapped: { index in controller.toggleHold(poolIndex: index) }
        ) { rollID, results in
            controller.completeRoll(id: rollID, results: results)
        }
    }

    private var rollerAnchor: CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        if let roll = controller.currentRoll, anchors.indices.contains(roll.seat) {
            return anchors[roll.seat]
        }
        if anchors.indices.contains(controller.turnSeat) { return anchors[controller.turnSeat] }
        return CGPoint(x: 0.5, y: 0.94)
    }

    // MARK: - Cup loading (real dice — manual drag OR auto-glide)
    // Geometry helpers below duplicate DiceTableView's own (private there,
    // and DiceTableView itself is out of this wave's edit scope) — same
    // small, deliberate duplication that view's own doc comment already
    // accepts for `railEdge`.

    private func railEdge(for anchor: CGPoint) -> TableCupView.RailEdge {
        let dLeft = anchor.x, dRight = 1 - anchor.x, dTop = anchor.y, dBottom = 1 - anchor.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return .bottom }
        if nearest == dTop { return .top }
        if nearest == dLeft { return .left }
        return .right
    }

    private func cupCenter(seatAnchor: CGPoint, size: CGSize) -> CGPoint {
        let plate = platePosition(anchor: seatAnchor, size: size)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.47)
        let outward = CGVector(dx: plate.x - center.x, dy: plate.y - center.y)
        let length = max(1, hypot(outward.dx, outward.dy))
        let unit = CGVector(dx: outward.dx / length, dy: outward.dy / length)
        return CGPoint(x: plate.x + unit.dx * 92, y: plate.y + unit.dy * 92)
    }

    private var activeCupSeat: Int? {
        guard !controller.gameOver, !controller.rollInFlight, controller.rollsUsed < 3,
              controller.seats.indices.contains(controller.turnSeat),
              !controller.seats[controller.turnSeat].isBot else { return nil }
        return controller.turnSeat
    }

    private func cupMouthScreen(seatID: Int, size: CGSize) -> CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        guard anchors.indices.contains(seatID) else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let anchor = anchors[seatID]
        let edge = railEdge(for: anchor)
        let cup = cupCenter(seatAnchor: anchor, size: size)
        let mouthOffset = TableCupView.mouthOffset(for: edge)
        return CGPoint(x: cup.x + mouthOffset.dx, y: cup.y + mouthOffset.dy)
    }

    @ViewBuilder
    private func cupLayer(size: CGSize) -> some View {
        if let seat = activeCupSeat {
            let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
            let edge = railEdge(for: anchors[seat])
            let cup = cupCenter(seatAnchor: anchors[seat], size: size)
            let required = YahtzeeController.diceCount - controller.heldIndices.count

            TableCupView(edge: edge, loadedCount: controller.loadedDiceCount, requiredCount: required)
                .position(cup)
        }
    }

    // MARK: - Plates

    private func platesLayer(size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        return ForEach(controller.seats) { seat in
            let isTurn = !controller.gameOver && controller.turnSeat == seat.id
            VStack(spacing: 6) {
                YahtzeeSeatPlate(
                    name: seat.name,
                    color: PlayerPalette.color(seat.colorIndex),
                    total: controller.scorecards[safe: seat.id]?.total ?? 0,
                    isTurn: isTurn,
                    isWinner: controller.gameOver && controller.winnerSeats.contains(seat.id),
                    isBot: seat.isBot)
                    .onTapGesture {
                        // Phoneless / iPad-only play: tap the active plate
                        // to roll, same fallback LCR's own plate offers.
                        guard isTurn, !controller.rollInFlight, controller.rollsUsed < 3,
                              !seat.isBot else { return }
                        Haptics.arm()
                        controller.roll(from: seat.id, intensity: .random(in: 0.5...1.1))
                    }
                    .accessibilityLabel("\(seat.name), \(controller.scorecards[safe: seat.id]?.total ?? 0) points")
                    .accessibilityHint(canTapToRoll(seat: seat, isTurn: isTurn) ? "Double-tap to roll" : "")
                    .accessibilityAddTraits(canTapToRoll(seat: seat, isTurn: isTurn) ? .isButton : [])
                if isTurn, !seat.isBot, !controller.rollInFlight {
                    Text(plateHint(seat: seat))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CardStyle.gold.opacity(0.85))
                        .transition(.opacity)
                }
            }
            .position(platePosition(anchor: anchors.indices.contains(seat.id) ? anchors[seat.id]
                                     : CGPoint(x: 0.5, y: 0.5), size: size))
        }
    }

    private func platePosition(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
    }

    private func canTapToRoll(seat: YahtzeeController.YahtzeeSeat, isTurn: Bool) -> Bool {
        isTurn && !controller.rollInFlight && controller.rollsUsed < 3 && !seat.isBot
    }

    private func plateHint(seat: YahtzeeController.YahtzeeSeat) -> String {
        if controller.rollsUsed >= 3 { return "pick a category on the scoresheet" }
        if !controller.canRoll(seat: seat.id) { return "drag your dice into the cup" }
        return seat.deviceID == nil ? "tap to roll" : "shake your phone — or tap to roll"
    }

    // MARK: - Score flourishes (bonus flourish + the Yahtzee trophy beat)

    /// Watches `controller.lastScoreEvent` and holds it on screen for its
    /// own reaction beat — a quick gold pulse for an upper-section bonus,
    /// a longer serif-callout-and-fanfare beat for a genuine Yahtzee
    /// (first or a joker bonus). Ordinary scores get no overlay at all.
    private func triggerFlourish(_ event: YahtzeeController.ScoreEvent?) {
        guard let event, isFlourishWorthy(event) else { return }
        flourishEvent = event
        let holdDuration: Double = isTrophyMoment(event) ? 2.4 : 1.2
        let eventID = event.id
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
            if flourishEvent?.id == eventID { flourishEvent = nil }
        }
    }

    private func isTrophyMoment(_ event: YahtzeeController.ScoreEvent) -> Bool {
        (event.category == .yahtzee && event.value > 0) || event.yahtzeeBonus
    }

    private func isFlourishWorthy(_ event: YahtzeeController.ScoreEvent) -> Bool {
        isTrophyMoment(event) || event.upperBonusJustEarned
    }

    @ViewBuilder
    private func scoreFlourishOverlay(size: CGSize) -> some View {
        if let event = flourishEvent {
            if isTrophyMoment(event) {
                yahtzeeTrophyOverlay(event, size: size)
                    .transition(motionReduced ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
            } else if event.upperBonusJustEarned, controller.seats.indices.contains(event.seat) {
                let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
                let point = anchors.indices.contains(event.seat)
                    ? platePosition(anchor: anchors[event.seat], size: size)
                    : CGPoint(x: size.width / 2, y: size.height / 2)
                bonusFlourish
                    .position(x: point.x, y: point.y - 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The trophy moment: a gold radiant pulse over the dice with a big
    /// serif "YAHTZEE!" callout — approximated as a 2D SwiftUI overlay
    /// rather than a true SceneKit material glow on the physical dice,
    /// since the 3D dice layer (`Sources/App/Dice/Dice3D/**`) was outside
    /// this wave's edit scope. `TableSFX.shared.play(.fanfareWin)` (fired
    /// from `YahtzeeController.scoreCategory`) supplies the sting.
    private func yahtzeeTrophyOverlay(_ event: YahtzeeController.ScoreEvent, size: CGSize) -> some View {
        VStack(spacing: 10) {
            Text("YAHTZEE!")
                .font(.system(size: 56, weight: .black, design: .serif))
                .foregroundStyle(CardStyle.gold)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
            Text(event.yahtzeeBonus ? "+100 bonus for \(controller.seats[safe: event.seat]?.name ?? "")"
                 : "\(controller.seats[safe: event.seat]?.name ?? "") scores 50!")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 6)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 1.5))
                .shadow(color: CardStyle.gold.opacity(0.5), radius: 30)
        )
        .position(x: size.width * 0.5, y: size.height * 0.42)
        .allowsHitTesting(false)
    }

    private var bonusFlourish: some View {
        Text("+35 BONUS!")
            .font(.system(.headline, design: .serif).weight(.black))
            .foregroundStyle(CardStyle.gold)
            .shadow(color: .black.opacity(0.7), radius: 4)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.4)))
            .allowsHitTesting(false)
    }

    // MARK: - Game over

    private var gameOverBanner: some View {
        VStack(spacing: 14) {
            if controller.winnerSeats.count == 1, let winner = controller.winnerSeats.first,
               controller.seats.indices.contains(winner) {
                Text(controller.seats[winner].name)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                Text("wins with \(controller.scorecards[safe: winner]?.total ?? 0) points!")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
            } else if controller.winnerSeats.count > 1 {
                Text("It's a tie!")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                let names = controller.winnerSeats.compactMap { controller.seats[safe: $0]?.name }
                Text(names.joined(separator: " & "))
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
            }
            HStack(spacing: 16) {
                Button {
                    Haptics.arm()
                    controller.restart()
                } label: {
                    Text("Play again")
                        .font(.headline.weight(.bold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                if let onClose {
                    Button {
                        Haptics.tick()
                        onClose()
                    } label: {
                        Text("Back to menu")
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(CardStyle.stockTop)
                }
            }
        }
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1.5))
        )
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

/// A Yahtzee seat plate: name + running total, turn glow, winner crown —
/// the score-sheet-driven sibling of `DicePlate` (which shows a chip
/// count, not a total, so it isn't reused as-is here).
struct YahtzeeSeatPlate: View {
    let name: String
    let color: Color
    let total: Int
    let isTurn: Bool
    let isWinner: Bool
    let isBot: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 14, height: 14)
            Text(name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
            if isBot {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(CardStyle.stockTop.opacity(0.5))
            }
            if isWinner {
                Image(systemName: "crown.fill")
                    .font(.caption)
                    .foregroundStyle(CardStyle.gold)
            }
            Text("\(total)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.38))
                .overlay(Capsule().strokeBorder(isTurn ? color : .white.opacity(0.08),
                                                lineWidth: isTurn ? 2.5 : 1))
                .shadow(color: isTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
    }
}
