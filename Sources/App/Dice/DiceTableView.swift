import SwiftUI

/// The felt stage for a dice game — placed by TableRootView exactly like
/// TableGameView (full screen, over TableSurface). Seat plates around the
/// rim, the pot in the middle, and the star of the show: REAL 3D dice
/// (SceneKit, in DiceTableSceneView) that tumble out of the roller's edge,
/// carom off the rails and each other, and come to rest — the settled
/// faces are read back and become the game result.
struct DiceTableView: View {
    @Bindable var controller: DiceGameController
    var onClose: (() -> Void)?

    @State private var chipFlights: [ChipFlight] = []

    /// Exit affordance: tap dead felt → a hold-to-close dial appears
    /// (same pattern as TableGameView).
    @State private var showCloseButton = false
    @State private var closeRingProgress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dead-felt tap: summon the exit dial (auto-hides).
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
                potView
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.45)
                platesLayer(size: geo.size)
                diceScene
                    .onAppear {
                        // The table feels being touched: slams re-tumble a
                        // live roll (fair chaos — faces are read only after
                        // settling); settled dice just hop in place. Gentle
                        // handling slides them a touch.
                        TableMotion.shared.onBump = { intensity in
                            TableSFX.shared.play(.tableKnock, intensity: 0.7 + intensity * 0.3)
                            DiceTableSceneCoordinator.activeCoordinator?.jolt(intensity: intensity)
                        }
                        TableMotion.shared.onNudge = { direction, strength in
                            DiceTableSceneCoordinator.activeCoordinator?.nudge(
                                direction: direction, strength: strength)
                        }
                        TableMotion.shared.start()
                    }
                    .onDisappear { TableMotion.shared.stop() }
                chipFlightLayer
                if controller.gameOver {
                    gameOverBanner
                }
                if showCloseButton, let onClose {
                    // Reuse TableGameView's press-and-hold dial (it's a
                    // nested type there).
                    TableGameView.HoldToCloseButton(progress: $closeRingProgress) {
                        onClose()
                    }
                    .position(x: 64, y: 56)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .onChange(of: controller.lastTransfers) { _, transfers in
                spawnChipFlights(transfers, size: geo.size)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.turnSeat)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: controller.gameOver)
    }

    // MARK: - Dice (the 3D layer)

    /// Transparent SceneKit overlay: rolls spawn real dice, gravity and
    /// friction settle them, DieFaceReader reads the result back into the
    /// controller. Never intercepts touches.
    private var diceScene: some View {
        DiceTableSceneView(roll: controller.currentRoll,
                           anchor: rollerAnchor) { rollID, faces in
            controller.completeRoll(id: rollID, faces: faces)
        }
        .allowsHitTesting(false)
    }

    private var rollerAnchor: CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        if let roll = controller.currentRoll, anchors.indices.contains(roll.seat) {
            return anchors[roll.seat]
        }
        return CGPoint(x: 0.5, y: 0.94)
    }

    // MARK: - Plates

    private func platesLayer(size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        return ForEach(controller.seats) { seat in
            let isTurn = !controller.gameOver && controller.turnSeat == seat.id
            VStack(spacing: 6) {
                DicePlate(name: seat.name,
                          color: PlayerPalette.color(seat.colorIndex),
                          chips: controller.chips[seat.id],
                          isTurn: isTurn,
                          isWinner: controller.winnerSeat == seat.id,
                          isBot: seat.isBot)
                    .onTapGesture {
                        // Phoneless / iPad-only play: tap the active plate
                        // to roll from the table.
                        guard isTurn, !controller.rollInFlight, !seat.isBot else { return }
                        Haptics.arm()
                        controller.roll(from: seat.id, intensity: .random(in: 0.5...1.1))
                    }
                if isTurn && !seat.isBot && !controller.rollInFlight {
                    Text(seat.deviceID == nil ? "tap to roll" : "shake your phone — or tap to roll")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CardStyle.gold.opacity(0.85))
                        .transition(.opacity)
                }
            }
            .position(platePosition(anchor: anchors[seat.id], size: size))
        }
    }

    private func platePosition(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
    }

    // MARK: - Pot

    private var potView: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.25))
                    .frame(width: 118, height: 118)
                    .overlay(Circle().strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1.5))
                // A loose pile: one chip drawn per pot chip (capped), with
                // stable per-index scatter so the pile doesn't twitch.
                ForEach(0..<min(controller.centerPot, 14), id: \.self) { index in
                    ChipToken()
                        .offset(chipScatter(index))
                }
                if controller.centerPot > 0 {
                    Text("\(controller.centerPot)")
                        .font(.system(.title2, design: .serif).weight(.black))
                        .foregroundStyle(CardStyle.stockTop)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                }
            }
            Text("POT")
                .font(.caption.weight(.bold))
                .kerning(3)
                .foregroundStyle(CardStyle.gold.opacity(0.7))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: controller.centerPot)
    }

    private func chipScatter(_ index: Int) -> CGSize {
        let jx = TableGeometry.jitterDegrees(cardID: "potx\(index)") * 3.4
        let jy = TableGeometry.jitterDegrees(cardID: "poty\(index)") * 3.4
        return CGSize(width: jx, height: jy)
    }

    // MARK: - Chip flights

    private struct ChipFlight: Identifiable {
        let id: Int
        let from: CGPoint
        let to: CGPoint
        let delay: Double
    }

    private func spawnChipFlights(_ transfers: [DiceGameController.ChipTransfer],
                                  size: CGSize) {
        guard !transfers.isEmpty else { return }
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        let pot = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        let flights = transfers.enumerated().map { index, transfer in
            ChipFlight(id: transfer.id,
                       from: platePosition(anchor: anchors[transfer.from], size: size),
                       to: transfer.to.map { platePosition(anchor: anchors[$0], size: size) } ?? pot,
                       delay: Double(index) * 0.14)
        }
        chipFlights.append(contentsOf: flights)
        // Clean up after the last flight lands.
        let lifetime = 0.7 + (flights.last?.delay ?? 0)
        let ids = Set(flights.map(\.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 0.2) {
            chipFlights.removeAll { ids.contains($0.id) }
        }
    }

    private var chipFlightLayer: some View {
        ForEach(chipFlights) { flight in
            ChipFlightView(flight: .init(from: flight.from, to: flight.to, delay: flight.delay))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Game over

    private var gameOverBanner: some View {
        VStack(spacing: 14) {
            if let winner = controller.winnerSeat {
                Text(controller.seats[winner].name)
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(CardStyle.gold)
                Text("takes the pot — \(controller.chips[winner]) chips!")
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

// MARK: - Plates, chips, flights

/// A dice-game seat plate: name + live chip count, turn glow — the dice
/// sibling of SeatPlateView (which is welded to card GameState).
struct DicePlate: View {
    let name: String
    let color: Color
    let chips: Int
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
            chipRow
                .frame(minHeight: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.38))
                .overlay(
                    Capsule().strokeBorder(
                        isTurn ? color : .white.opacity(0.08),
                        lineWidth: isTurn ? 2.5 : 1)
                )
                .shadow(color: isTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
    }

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 4) {
            if chips == 0 {
                Text("empty-handed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.45))
            } else {
                ForEach(0..<min(chips, 6), id: \.self) { _ in
                    ChipToken(diameter: 11)
                }
                if chips > 6 {
                    Text("×\(chips)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CardStyle.gold)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: chips)
    }
}

/// One gold chip, the currency of LCR night.
struct ChipToken: View {
    var diameter: CGFloat = 20

    var body: some View {
        Circle()
            .fill(
                RadialGradient(colors: [CardStyle.gold.opacity(1.0),
                                        CardStyle.gold.opacity(0.75)],
                               center: .topLeading,
                               startRadius: 1, endRadius: diameter)
            )
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
            .overlay(
                Circle()
                    .strokeBorder(CardStyle.stockTop.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [2, 2.6]))
                    .padding(diameter * 0.14)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

/// One chip sliding from a plate to its destination (neighbor or pot).
struct ChipFlightView: View {
    struct Spec {
        let from: CGPoint
        let to: CGPoint
        let delay: Double
    }

    let flight: Spec
    @State private var arrived = false

    var body: some View {
        ChipToken()
            .position(arrived ? flight.to : flight.from)
            .opacity(arrived ? 0.9 : 1)
            .onAppear {
                withAnimation(FeltPhysics.slide(duration: 0.55).delay(flight.delay)) {
                    arrived = true
                }
            }
    }
}
