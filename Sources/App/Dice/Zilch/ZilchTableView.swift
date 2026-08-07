import SwiftUI

/// The felt stage for Zilch — `DiceTableView`'s sibling, same bones (seat
/// plates around the rim, real 3D dice tumbling out of the roller's edge,
/// a cup at their rail), different rules layer on top: no chips/pot, just
/// each seat's banked total, the current roller's live turn total on a
/// felt chip, and the tap-to-set-aside dice tray the platform's
/// `DiceTableSceneCoordinator.setHeld` already draws (the gold-ringed tray
/// — this view only has to feed it `heldIndices`/`onDieTapped`, never draw
/// it itself).
struct ZilchTableView: View {
    @Bindable var controller: ZilchController
    var onClose: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    /// Manual cup loading, same house key `DiceTableView`/`DiceGameController`
    /// read — one switch, shared across every dice game.
    @AppStorage("gn.autoCup") private var autoCup = false

    @State private var showCloseButton = false
    @State private var closeRingProgress: CGFloat = 0
    /// The ZILCH callout's shake offset — see `triggerZilchShake`.
    @State private var zilchShakeOffset: CGFloat = 0

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

                finalChaseBanner
                    .position(x: geo.size.width * 0.5, y: 40)

                if controller.zilchFlash { zilchOverlay }
                if controller.hotDiceFlash { hotDiceOverlay }
                if controller.gameOver { gameOverBanner }

                if showCloseButton, let onClose {
                    TableGameView.HoldToCloseButton(progress: $closeRingProgress) {
                        onClose()
                    }
                    .position(x: 64, y: 56)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                GameHUD(title: "Zilch", onExit: { onClose?() },
                       toggles: [HUDToggle(label: "Auto-cup", isOn: $autoCup)])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .onChange(of: controller.zilchFlash) { _, flashing in
                guard flashing else { return }
                triggerZilchShake()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.turnSeat)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: controller.gameOver)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: controller.zilchFlash)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: controller.hotDiceFlash)
    }

    // MARK: - Dice (the 3D layer)

    private func diceScene(size: CGSize) -> some View {
        let seat = activeCupSeat
        let mouth = seat.map { cupMouthScreen(seatID: $0, size: size) }
        return DiceTableSceneView(
            roll: controller.currentRoll, anchor: rollerAnchor,
            diceCount: controller.diceCount, faceStyle: .pips,
            cupSeat: seat, requiredCount: controller.liveDiceCount,
            loadedCount: controller.loadedDiceCount,
            autoCup: autoCup, mouthScreen: mouth,
            onDieLoaded: { s in controller.loadDie(forSeat: s) },
            heldIndices: controller.heldIndices,
            onDieTapped: { index in controller.dieTapped(index) }
        ) { rollID, results in
            let faces = results.compactMap { result -> Int? in
                if case .pip(let value) = result { return value }
                return nil
            }
            controller.completeRoll(id: rollID, faces: faces)
        }
    }

    /// The current roller's own felt anchor, continuously (not just mid-
    /// roll) — Zilch's hold tray needs to track the CURRENT roller's edge
    /// even between rolls (while they're deciding what to tap), and
    /// `DiceTableSceneCoordinator.heldTraySlot` reuses whatever `anchor`
    /// this view passes on every pass for exactly that reason.
    private var rollerAnchor: CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        guard anchors.indices.contains(controller.turnSeat) else { return CGPoint(x: 0.5, y: 0.94) }
        return anchors[controller.turnSeat]
    }

    // MARK: - Cup loading

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

    /// Only ever shown for a HUMAN whose turn it currently is and who may
    /// actually act (not mid-roll, not mid-ZILCH/hot-dice beat, and not
    /// stuck waiting to tap the table first — there's nothing to load a
    /// cup FOR during that last window since the next roll isn't chosen
    /// yet).
    private var activeCupSeat: Int? {
        guard controller.mayAct, controller.seats.indices.contains(controller.turnSeat),
              !controller.seats[controller.turnSeat].isBot else { return nil }
        return controller.turnSeat
    }

    private func cupMouthScreen(seatID: Int, size: CGSize) -> CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
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
            TableCupView(edge: edge, loadedCount: controller.loadedDiceCount,
                        requiredCount: controller.liveDiceCount)
                .position(cup)
        }
    }

    // MARK: - Plates

    private func platesLayer(size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        return ForEach(controller.seats) { seat in
            let isTurn = !controller.gameOver && controller.turnSeat == seat.id
            VStack(spacing: 6) {
                ZilchPlate(name: seat.name,
                          color: PlayerPalette.color(seat.colorIndex),
                          bankedScore: controller.bankedScore[seat.id],
                          isTurn: isTurn,
                          isWinner: controller.winnerSeat == seat.id,
                          isBot: seat.isBot)
                    .onTapGesture {
                        // Phoneless / iPad-only play: tap the active plate
                        // to roll from the table, same convention as LCR.
                        guard isTurn, !seat.isBot, controller.mayAct else { return }
                        Haptics.arm()
                        controller.roll(from: seat.id, intensity: .random(in: 0.5...1.1))
                    }
                    .accessibilityLabel("\(seat.name), \(controller.bankedScore[seat.id]) points\(isTurn ? ", rolling now" : "")")
                    .accessibilityHint(canTapToRoll(seat: seat, isTurn: isTurn) ? "Double-tap to roll" : "")
                    .accessibilityAddTraits(canTapToRoll(seat: seat, isTurn: isTurn) ? .isButton : [])

                if isTurn { turnControls(for: seat) }
            }
            .position(platePosition(anchor: anchors[seat.id], size: size))
        }
    }

    /// The active roller's own mini-HUD, riding right under their plate:
    /// the running turn total as a small gold felt chip (mission ask: "the
    /// tray shows a running turn total on a small felt chip"), a status
    /// caption, and — only for a human once `canBank` — the brass Bank
    /// button.
    @ViewBuilder
    private func turnControls(for seat: DiceGameController.DiceSeat) -> some View {
        VStack(spacing: 6) {
            if controller.turnScore > 0 {
                Text("+\(controller.turnScore)")
                    .font(.system(.subheadline, design: .serif).weight(.black))
                    .foregroundStyle(CardStyle.gold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(.black.opacity(0.42))
                            .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 1))
                    )
                    .accessibilityLabel("\(controller.turnScore) points banked so far this turn")
            }
            if !seat.isBot, !controller.rollInFlight, !controller.zilchFlash, !controller.hotDiceFlash {
                Text(turnCaption)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(CardStyle.gold.opacity(0.85))
                    .frame(maxWidth: 220)
                    .transition(.opacity)
            }
            if !seat.isBot, controller.canBank {
                Button {
                    Haptics.play()
                    controller.bank(seat: seat.id)
                } label: {
                    Text("BANK \(controller.turnScore)")
                        .font(.system(.caption, design: .serif).weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                .accessibilityLabel("Bank \(controller.turnScore) points and end your turn")
            }
        }
    }

    private var turnCaption: String {
        guard controller.mayAct else {
            return "Tap the scoring dice on the table"
        }
        if controller.turnScore == 0 {
            return controller.canRoll(seat: controller.turnSeat)
                ? "shake your phone — or tap to roll"
                : "drag your dice into the cup"
        }
        return "shake to press your luck, or bank"
    }

    private func platePosition(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
    }

    private func canTapToRoll(seat: DiceGameController.DiceSeat, isTurn: Bool) -> Bool {
        isTurn && !seat.isBot && controller.mayAct
    }

    // MARK: - ZILCH / hot dice beats

    /// A dramatic red-tinged serif callout with a dice-rattle shake — the
    /// bust moment. Reduce Motion keeps the callout (it still needs to be
    /// readable) but skips the shake entirely.
    private var zilchOverlay: some View {
        VStack(spacing: 10) {
            Text("ZILCH!")
                .font(.system(.largeTitle, design: .serif).weight(.black))
                .foregroundStyle(Color(red: 0.86, green: 0.20, blue: 0.17))
            Text("Turn lost")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(red: 0.86, green: 0.20, blue: 0.17).opacity(0.7), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 14)
        )
        .offset(x: zilchShakeOffset)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zilch. Turn lost.")
    }

    /// A handful of quick alternating offsets — a cheap "rattle" without
    /// standing up a full keyframe animator for one-shot drama.
    private func triggerZilchShake() {
        zilchShakeOffset = 0
        guard !motionReduced else { return }
        let steps: [CGFloat] = [-11, 11, -8, 8, -5, 5, 0]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                withAnimation(.easeInOut(duration: 0.06)) { zilchShakeOffset = step }
            }
        }
    }

    private var hotDiceOverlay: some View {
        Text("HOT DICE!")
            .font(.system(.largeTitle, design: .serif).weight(.black))
            .foregroundStyle(CardStyle.gold)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(
                Capsule().fill(.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.75), lineWidth: 2))
            )
            .shadow(color: CardStyle.gold.opacity(motionReduced ? 0.3 : 0.75),
                    radius: motionReduced ? 4 : 18)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .accessibilityLabel("Hot dice — all six dice roll again")
    }

    // MARK: - Final chase

    @ViewBuilder
    private var finalChaseBanner: some View {
        if let chaseSeat = controller.finalChaseSeat, !controller.gameOver,
           controller.seats.indices.contains(chaseSeat) {
            Text("\(controller.seats[chaseSeat].name) hit 5,000 — final chase! Everyone else gets one more turn.")
                .font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.45))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1)))
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Game over

    private var gameOverBanner: some View {
        VStack(spacing: 14) {
            if let winner = controller.winnerSeat, controller.seats.indices.contains(winner) {
                Text(controller.seats[winner].name)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                Text("wins with \(controller.bankedScore[winner]) points!")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
            }
            HStack(spacing: 16) {
                Button {
                    Haptics.arm()
                    controller.restart()
                } label: {
                    Text("Roll again")
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

/// A Zilch seat plate: name + banked total, turn glow — the Zilch sibling
/// of `DicePlate` (LCR's chip-count plate). No chip icons here since
/// there's nothing physical to count; the score itself is the whole story.
struct ZilchPlate: View {
    let name: String
    let color: Color
    let bankedScore: Int
    let isTurn: Bool
    let isWinner: Bool
    let isBot: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
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
            }
            Text("\(bankedScore) pts")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.75))
                .frame(minHeight: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.38))
                .overlay(
                    Capsule().strokeBorder(isTurn ? color : .white.opacity(0.08),
                                           lineWidth: isTurn ? 2.5 : 1)
                )
                .shadow(color: isTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: bankedScore)
    }
}
