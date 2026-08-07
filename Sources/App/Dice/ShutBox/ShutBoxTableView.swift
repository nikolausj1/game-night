import SwiftUI

/// The felt stage for Shut the Box — the dice-game sibling of
/// `DiceTableView` (LCR), mirroring its shape (dead-felt hold-to-close,
/// GameHUD, the real 3D dice scene + table cup, Reduce Motion, VoiceOver)
/// but laid out around the box instead of a pot: the box owns the upper
/// felt, seat plates sit in a row along the bottom rail (never radially —
/// Shut the Box is sequential turns at one shared box, not everyone
/// gathered around a center pot), and the cup always opens from the
/// bottom edge since every seat lives there.
struct ShutBoxTableView: View {
    @Bindable var controller: ShutBoxController
    var onClose: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    /// Same shared key `DiceTableView`/`DiceGameController` read — one
    /// Auto-cup setting across every dice game, table-wide.
    @AppStorage("gn.autoCup") private var autoCup = false

    @State private var showCloseButton = false
    @State private var closeRingProgress: CGFloat = 0
    /// One-shot trophy burst on shutting the box — separate from the
    /// controller's own (persistent, game-over-spanning) `shutTheBoxSeat`
    /// so the celebratory FLASH plays exactly once, right when it happens.
    @State private var trophyBurstSeat: Int?

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
                diceScene(size: geo.size)
                cupLayer(size: geo.size)
                boxLayer(size: geo.size)
                selectionChip(size: geo.size)
                oneDieToggle(size: geo.size)

                if let bustedSeat = controller.lastBustedSeat {
                    scorecardOverlay(seat: bustedSeat, size: geo.size)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if let trophySeat = trophyBurstSeat {
                    trophyBurst(seat: trophySeat, size: geo.size)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
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
                GameHUD(title: "Shut the Box", onExit: { onClose?() },
                       toggles: [HUDToggle(label: "Auto-cup", isOn: $autoCup)])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.turnSeat)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: controller.gameOver)
        .onChange(of: controller.shutTheBoxSeat) { old, new in
            guard old == nil, let new else { return }
            trophyBurstSeat = new
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if trophyBurstSeat == new { trophyBurstSeat = nil }
            }
        }
    }

    // MARK: - Seat layout (bottom rail only — the box owns the top)

    private func seatAnchors(count: Int) -> [CGPoint] {
        switch count {
        case ...1: return [CGPoint(x: 0.5, y: 0.90)]
        case 2: return [CGPoint(x: 0.30, y: 0.90), CGPoint(x: 0.70, y: 0.90)]
        case 3: return [CGPoint(x: 0.20, y: 0.90), CGPoint(x: 0.5, y: 0.90), CGPoint(x: 0.80, y: 0.90)]
        default: return [CGPoint(x: 0.14, y: 0.90), CGPoint(x: 0.38, y: 0.90),
                         CGPoint(x: 0.62, y: 0.90), CGPoint(x: 0.86, y: 0.90)]
        }
    }

    private func platePosition(seat: Int, size: CGSize) -> CGPoint {
        let anchors = seatAnchors(count: controller.seats.count)
        guard anchors.indices.contains(seat) else { return CGPoint(x: size.width / 2, y: size.height * 0.9) }
        return CGPoint(x: anchors[seat].x * size.width, y: anchors[seat].y * size.height)
    }

    // MARK: - The box

    private func boxLayer(size: CGSize) -> some View {
        let width = min(ShutBoxBoxView.nativeWidth, size.width * 0.62)
        return ShutBoxBoxView(
            standing: controller.standing, selected: controller.selected,
            tilesInPlay: controller.tilesInPlay, hasLiveRoll: !controller.lastDice.isEmpty,
            reduceMotion: motionReduced, width: width,
            onTapTile: { controller.toggleTileCandidate($0) })
        .position(x: size.width * 0.5, y: size.height * 0.10 + width * ShutBoxBoxView.nativeAspect * 0.5)
    }

    // MARK: - Plates

    private func platesLayer(size: CGSize) -> some View {
        ForEach(controller.seats) { seat in
            let isTurn = !controller.gameOver && controller.turnSeat == seat.id
            ShutBoxPlate(
                name: seat.name, color: PlayerPalette.color(seat.colorIndex),
                score: controller.roundScores[seat.id], isTurn: isTurn,
                isBot: seat.isBot, isWinner: controller.winnerSeats.contains(seat.id) && controller.gameOver)
                .onTapGesture {
                    guard isTurn, !seat.isBot, !controller.rollInFlight, controller.lastDice.isEmpty else { return }
                    Haptics.arm()
                    controller.roll(from: seat.id, intensity: .random(in: 0.5...1.1))
                }
                .accessibilityLabel(plateAccessibilityLabel(seat: seat, isTurn: isTurn))
                .accessibilityAddTraits(canTapToRoll(seat: seat, isTurn: isTurn) ? .isButton : [])
                .position(platePosition(seat: seat.id, size: size))
        }
    }

    private func canTapToRoll(seat: ShutBoxController.ShutBoxSeat, isTurn: Bool) -> Bool {
        isTurn && !seat.isBot && !controller.rollInFlight && controller.lastDice.isEmpty
    }

    private func plateAccessibilityLabel(seat: ShutBoxController.ShutBoxSeat, isTurn: Bool) -> String {
        if let score = controller.roundScores[seat.id] {
            return "\(seat.name), scored \(score)"
        }
        return isTurn ? "\(seat.name), rolling now" : "\(seat.name), waiting"
    }

    // MARK: - Dice (the 3D layer) + cup

    private func diceScene(size: CGSize) -> some View {
        let seat = activeCupSeat
        let required = usingOneDieNow ? 1 : 2
        return DiceTableSceneView(
            roll: controller.currentRoll, anchor: rollerAnchor(size: size),
            diceCount: 2, faceStyle: .pips,
            cupSeat: seat, requiredCount: required, loadedCount: controller.loadedDiceCount,
            autoCup: autoCup, mouthScreen: seat != nil ? cupMouthScreen(seatID: seat!, size: size) : nil,
            onDieLoaded: { s in controller.loadDie(forSeat: s) }
        ) { rollID, results in
            controller.completeRoll(id: rollID, results: results)
        }
    }

    private var usingOneDieNow: Bool { controller.usingOneDie }

    private func rollerAnchor(size: CGSize) -> CGPoint {
        let anchors = seatAnchors(count: controller.seats.count)
        if let roll = controller.currentRoll, anchors.indices.contains(roll.seat) {
            return anchors[roll.seat]
        }
        if anchors.indices.contains(controller.turnSeat) { return anchors[controller.turnSeat] }
        return CGPoint(x: 0.5, y: 0.90)
    }

    /// Only a human whose turn it is, mid-nothing-else, gets a cup —
    /// identical gating to `DiceTableView.activeCupSeat`, minus LCR's
    /// pending-transfer concept (this game has none).
    private var activeCupSeat: Int? {
        guard !controller.gameOver, !controller.rollInFlight, controller.lastDice.isEmpty,
              controller.seats.indices.contains(controller.turnSeat),
              !controller.seats[controller.turnSeat].isBot else { return nil }
        return controller.turnSeat
    }

    private func cupCenter(seat: Int, size: CGSize) -> CGPoint {
        let plate = platePosition(seat: seat, size: size)
        return CGPoint(x: plate.x, y: min(size.height - 40, plate.y + 92))
    }

    private func cupMouthScreen(seatID: Int, size: CGSize) -> CGPoint {
        let cup = cupCenter(seat: seatID, size: size)
        let mouthOffset = TableCupView.mouthOffset(for: .bottom)
        return CGPoint(x: cup.x + mouthOffset.dx, y: cup.y + mouthOffset.dy)
    }

    @ViewBuilder
    private func cupLayer(size: CGSize) -> some View {
        if let seat = activeCupSeat {
            TableCupView(edge: .bottom, loadedCount: controller.loadedDiceCount,
                        requiredCount: usingOneDieNow ? 1 : 2)
                .position(cupCenter(seat: seat, size: size))
        }
    }

    // MARK: - Selection chip (running sum + confirm)

    @ViewBuilder
    private func selectionChip(size: CGSize) -> some View {
        if let seat = activeCupSeat, !controller.lastDice.isEmpty {
            let rollSum = controller.lastDice.reduce(0, +)
            VStack(spacing: 8) {
                Text(controller.statusLine.isEmpty ? "Flip tiles adding to \(rollSum)" : controller.statusLine)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.9))
                HStack(spacing: 10) {
                    Text("\(controller.selectedSum) of \(rollSum)")
                        .font(.system(.headline, design: .serif).weight(.bold))
                        .foregroundStyle(controller.selectionMatchesRoll ? CardStyle.gold : CardStyle.stockTop.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.4)))
                    Button {
                        Haptics.play()
                        controller.confirmSelection()
                    } label: {
                        Text("Confirm")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                    .disabled(!controller.selectionMatchesRoll)
                    .opacity(controller.selectionMatchesRoll ? 1 : 0.5)
                }
            }
            .position(x: platePosition(seat: seat, size: size).x,
                     y: platePosition(seat: seat, size: size).y - 150)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .animation(.easeInOut(duration: 0.25), value: controller.selectedSum)
        }
    }

    // MARK: - One-die brass toggle

    @ViewBuilder
    private func oneDieToggle(size: CGSize) -> some View {
        if let seat = activeCupSeat, controller.oneDieAvailable, controller.lastDice.isEmpty,
           !controller.rollInFlight {
            let cup = cupCenter(seat: seat, size: size)
            Button {
                controller.toggleOneDie()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: controller.usingOneDie ? "die.face.1.fill" : "die.face.2.fill")
                        .font(.caption.weight(.bold))
                    Text(controller.usingOneDie ? "1 die" : "2 dice")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color(red: 0.85, green: 0.68, blue: 0.30),
                                                Color(red: 0.62, green: 0.46, blue: 0.16)],
                                      startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                )
            }
            .buttonStyle(.plain)
            .position(x: cup.x + 96, y: cup.y - 10)
            .accessibilityLabel(controller.usingOneDie ? "Using one die" : "Using two dice")
            .accessibilityHint("Double-tap to switch")
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    // MARK: - Scorecard (bust) + trophy (shut the box)

    private func scorecardOverlay(seat: Int, size: CGSize) -> some View {
        VStack(spacing: 4) {
            Text(controller.seats[seat].name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))
            Text("\(controller.lastBustedScore ?? 0)")
                .font(.system(size: 40, weight: .black, design: .serif))
                .foregroundStyle(CardStyle.crimson)
            Text("no set left — that's the turn")
                .font(.system(.caption, design: .serif).italic())
                .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08).opacity(0.75))
        }
        .padding(20)
        .frame(width: 170)
        .background(
            Image("PaperGraph")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        )
        .rotationEffect(.degrees(-3))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
        .position(x: size.width * 0.14, y: size.height * 0.32)
    }

    private func trophyBurst(seat: Int, size: CGSize) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 46))
                .foregroundStyle(CardStyle.gold)
                .shadow(color: CardStyle.gold.opacity(0.8), radius: 14)
            Text("SHUT THE BOX!")
                .font(.system(.title, design: .serif).weight(.black))
                .foregroundStyle(CardStyle.gold)
            Text(controller.seats[seat].name)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 1.5))
                .shadow(color: CardStyle.gold.opacity(0.5), radius: 24)
        )
        .position(x: size.width * 0.5, y: size.height * 0.42)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(controller.seats[seat].name) shut the box")
    }

    // MARK: - Game over

    private var gameOverBanner: some View {
        let ranked = controller.seats.indices
            .compactMap { seat -> (String, Int)? in
                guard let score = controller.roundScores[seat] else { return nil }
                return (controller.seats[seat].name, score)
            }
            .sorted { $0.1 < $1.1 }
        return VStack(spacing: 14) {
            if controller.winnerSeats.count == 1, let winner = controller.winnerSeats.first {
                Text(controller.seats[winner].name)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                Text(controller.roundScores[winner] == 0 ? "shut the box!" : "wins the round")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
            } else if !controller.winnerSeats.isEmpty {
                Text("It's a tie!")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.0)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(CardStyle.stockTop.opacity(0.9))
                        Spacer()
                        Text("\(entry.1)")
                            .font(.body.weight(.bold))
                            .foregroundStyle(CardStyle.gold)
                    }
                }
            }
            .frame(width: 220)
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

/// A Shut the Box seat plate — the dice-game sibling of `DicePlate`, minus
/// coins (this game scores in points, not chips): name, live turn glow,
/// and either "rolling…", "waiting", or this round's inked score.
struct ShutBoxPlate: View {
    let name: String
    let color: Color
    let score: Int?
    let isTurn: Bool
    let isBot: Bool
    var isWinner: Bool = false

    var body: some View {
        VStack(spacing: 6) {
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
            }
            statusText
                .frame(minHeight: 14)
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

    @ViewBuilder
    private var statusText: some View {
        if let score {
            Text("scored \(score)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
        } else if isTurn {
            Text(isBot ? "rolling…" : "your turn")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
        } else {
            Text("waiting")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.4))
        }
    }
}
