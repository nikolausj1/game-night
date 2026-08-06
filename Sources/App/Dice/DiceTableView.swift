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
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    @State private var chipFlights: [ChipFlight] = []
    /// Manual cup loading, default ON (manual): the roller must drag every
    /// required die into their TableCupView before rolling. Read live by
    /// `DiceGameController.canRoll`/`roll` too (straight off UserDefaults,
    /// not this binding) so flipping it mid-game takes effect immediately.
    @AppStorage("gn.autoCup") private var autoCup = false

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
                feltCoinLayer(size: geo.size)
                cupLayer(size: geo.size)
                diceScene
                    .onAppear {
                        // The table feels being touched: slams re-tumble a
                        // live roll (fair chaos — faces are read only after
                        // settling); settled dice just hop in place. Gentle
                        // handling slides them a touch.
                        TableMotion.shared.onBump = { intensity in
                            TableSFX.shared.play(.tableKnock, intensity: 0.7 + intensity * 0.3)
                            // Reduce Motion: the knock still sounds, but the
                            // re-tumble/hop it would trigger is damped to zero.
                            guard !motionReduced else { return }
                            DiceTableSceneCoordinator.activeCoordinator?.jolt(intensity: intensity)
                        }
                        TableMotion.shared.onNudge = { direction, strength in
                            guard !motionReduced else { return }
                            DiceTableSceneCoordinator.activeCoordinator?.nudge(
                                direction: direction, strength: strength)
                        }
                        TableMotion.shared.start()
                        TableNudgeTip.isEligible = TableMotion.isEnabled
                    }
                    .onDisappear { TableMotion.shared.stop() }
                chipFlightLayer
                // First game with table motion enabled: same one-shot
                // TipKit nudge TableGameView shows for card games.
                GhostHintTipView(tip: TableNudgeTip())
                    .position(x: geo.size.width * 0.5, y: geo.size.height - 40)
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
                GameHUD(title: "Dice", onExit: { onClose?() },
                       toggles: [HUDToggle(label: "Auto-cup", isOn: $autoCup)])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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

    // MARK: - Manual cup loading (gn.autoCup off, the default)

    /// Which rail edge a normalized seat anchor is nearest — same
    /// nearest-edge test TableGameView's plate rotation uses, duplicated
    /// locally since that logic is private over there and this view owns
    /// its own cup placement.
    private func railEdge(for anchor: CGPoint) -> TableCupView.RailEdge {
        let dLeft = anchor.x, dRight = 1 - anchor.x, dTop = anchor.y, dBottom = 1 - anchor.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return .bottom }
        if nearest == dTop { return .top }
        if nearest == dLeft { return .left }
        return .right
    }

    /// The cup sits BEYOND the plate, toward (and bleeding past) the rail.
    private func cupCenter(seatAnchor: CGPoint, size: CGSize) -> CGPoint {
        let plate = platePosition(anchor: seatAnchor, size: size)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.47)
        let outward = CGVector(dx: plate.x - center.x, dy: plate.y - center.y)
        let length = max(1, hypot(outward.dx, outward.dy))
        let unit = CGVector(dx: outward.dx / length, dy: outward.dy / length)
        return CGPoint(x: plate.x + unit.dx * 92, y: plate.y + unit.dy * 92)
    }

    /// Only ever shown for a HUMAN whose turn it is, manual mode, mid-
    /// nothing-else (no roll in flight, no pending debts) — bots and
    /// auto-cup skip this entirely.
    private var manualCupSeat: Int? {
        guard !autoCup, !controller.gameOver, !controller.rollInFlight,
              controller.pendingTransfers.isEmpty,
              controller.seats.indices.contains(controller.turnSeat),
              !controller.seats[controller.turnSeat].isBot else { return nil }
        return controller.turnSeat
    }

    @ViewBuilder
    private func cupLayer(size: CGSize) -> some View {
        if let seat = manualCupSeat {
            let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
            let anchor = anchors[seat]
            let edge = railEdge(for: anchor)
            let cup = cupCenter(seatAnchor: anchor, size: size)
            let mouthOffset = TableCupView.mouthOffset(for: edge)
            let mouth = CGPoint(x: cup.x + mouthOffset.dx, y: cup.y + mouthOffset.dy)
            let plate = platePosition(anchor: anchor, size: size)
            let required = min(controller.chips[seat], 3)

            TableCupView(edge: edge, loadedCount: controller.loadedDiceCount,
                        requiredCount: required)
                .position(cup)
            ForEach(0..<max(0, required), id: \.self) { index in
                LoadableDieToken(home: dieHome(plate: plate, edge: edge, index: index,
                                               of: required),
                                 cupMouth: mouth,
                                 face: restingFace(for: index)) {
                    controller.loadDie(forSeat: seat)
                }
            }
        }
    }

    /// Purely flavor — which face an unloaded die shows at rest. Physics
    /// decides the real result once the roll actually happens.
    private func restingFace(for index: Int) -> LcrFace {
        let faces: [LcrFace] = [.dot, .left, .right, .center]
        return faces[index % faces.count]
    }

    /// A small resting row/column of loose dice just off the plate, fanned
    /// perpendicular to the rail so they don't overlap the cup itself.
    private func dieHome(plate: CGPoint, edge: TableCupView.RailEdge, index: Int,
                         of count: Int) -> CGPoint {
        let lateral = (CGFloat(index) - CGFloat(count - 1) / 2) * 44
        switch edge {
        case .bottom: return CGPoint(x: plate.x + lateral, y: plate.y - 56)
        case .top: return CGPoint(x: plate.x + lateral, y: plate.y + 56)
        case .left: return CGPoint(x: plate.x + 56, y: plate.y + lateral)
        case .right: return CGPoint(x: plate.x - 56, y: plate.y + lateral)
        }
    }

    // MARK: - Plates

    private func platesLayer(size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        let pendingIdle = controller.pendingTransfers.isEmpty
        return ForEach(controller.seats) { seat in
            let isTurn = !controller.gameOver && controller.turnSeat == seat.id
            let isDestination = controller.pendingTransfers.contains { $0.to == seat.id }
            VStack(spacing: 6) {
                DicePlate(name: seat.name,
                          color: PlayerPalette.color(seat.colorIndex),
                          chips: controller.chips[seat.id],
                          isTurn: isTurn,
                          isWinner: controller.winnerSeat == seat.id,
                          isBot: seat.isBot,
                          isDestination: isDestination)
                    .onTapGesture {
                        // Phoneless / iPad-only play: tap the active plate
                        // to roll from the table.
                        guard isTurn, !controller.rollInFlight, pendingIdle,
                              !seat.isBot else { return }
                        Haptics.arm()
                        controller.roll(from: seat.id, intensity: .random(in: 0.5...1.1))
                    }
                    .accessibilityLabel("\(seat.name), \(controller.chips[seat.id]) coins")
                    .accessibilityHint(canTapToRoll(seat: seat, isTurn: isTurn, pendingIdle: pendingIdle)
                                       ? "Double-tap to roll" : "")
                    .accessibilityAddTraits(canTapToRoll(seat: seat, isTurn: isTurn, pendingIdle: pendingIdle)
                                            ? .isButton : [])
                if isTurn && !seat.isBot && !controller.rollInFlight {
                    if pendingIdle, !controller.canRoll(seat: seat.id) {
                        Text("drag your dice into the cup")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CardStyle.gold.opacity(0.85))
                            .transition(.opacity)
                    } else if pendingIdle {
                        Text(seat.deviceID == nil ? "tap to roll" : "shake your phone — or tap to roll")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CardStyle.gold.opacity(0.85))
                            .transition(.opacity)
                    } else if controller.pendingTransfers.first?.from == seat.id {
                        Text("slide your coins to the glowing spots")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CardStyle.gold)
                            .transition(.opacity)
                    }
                }
            }
            .position(platePosition(anchor: anchors[seat.id], size: size))
        }
    }

    private func platePosition(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
    }

    /// Mirrors the plate's own tap-gesture guard, for the accessibility
    /// hint/trait — a VoiceOver user shouldn't be told "double-tap to roll"
    /// on a plate the tap gesture would silently ignore.
    private func canTapToRoll(seat: DiceGameController.DiceSeat, isTurn: Bool, pendingIdle: Bool) -> Bool {
        isTurn && !controller.rollInFlight && pendingIdle && !seat.isBot
    }

    // MARK: - Pot

    private var potView: some View {
        let potGlows = controller.pendingTransfers.contains { $0.to == nil }
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.25))
                    .frame(width: 150, height: 150)
                    .overlay(Circle().strokeBorder(
                        potGlows ? CardStyle.gold : CardStyle.gold.opacity(0.4),
                        lineWidth: potGlows ? 3 : 1.5))
                    .shadow(color: potGlows ? CardStyle.gold.opacity(0.7) : .clear,
                            radius: 14)
                // Real money in the well: a big loose pile of full-size
                // coins, one landing spot per coin (stable spiral seeded by
                // index) so the pile GROWS instead of twitching.
                CoinCluster(count: controller.centerPot, diameter: 44,
                            maxVisible: 12, seedKey: "pot", spreadScale: 0.36)
                if controller.centerPot > 0 {
                    Text("\(controller.centerPot)")
                        .font(.system(.title2, design: .serif).weight(.black))
                        .foregroundStyle(CardStyle.stockTop)
                        .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
                        .offset(y: 52)
                }
            }
            Text("POT")
                .font(.caption.weight(.bold))
                .kerning(3)
                .foregroundStyle(CardStyle.gold.opacity(0.7))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: controller.centerPot)
        .animation(.easeInOut(duration: 0.4), value: potGlows)
    }

    // MARK: - Coins on the felt

    /// Where a seat's coin cluster lives: just inside the rail from the
    /// plate, pulled toward the pot — the same "in front of your spot"
    /// band the pending coins use.
    private func clusterCenter(seat: Int, size: CGSize) -> CGPoint {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        guard anchors.indices.contains(seat) else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let plate = platePosition(anchor: anchors[seat], size: size)
        let pot = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        let toward = CGVector(dx: pot.x - plate.x, dy: pot.y - plate.y)
        let length = max(1, hypot(toward.dx, toward.dy))
        return CGPoint(x: plate.x + toward.dx / length * 108,
                       y: plate.y + toward.dy / length * 108)
    }

    /// Every player's chips live ON the felt as a loose cluster of big
    /// coins — always visible, always draggable (they tidy themselves
    /// gently after a fidget). During a penalty phase the destination
    /// cluster gets a gold call-out ring, AND — this is the actual payment
    /// mechanism — every coin in the OWING seat's own cluster becomes a
    /// valid payer: drag ANY of them to a glowing destination and IT pays
    /// the debt. There's no separate synthetic "the one pending coin"
    /// token; the choice of which physical coin pays is the player's,
    /// same as reaching into a real pile of chips.
    private func feltCoinLayer(size: CGSize) -> some View {
        let pot = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        return ForEach(controller.seats) { seat in
            let center = clusterCenter(seat: seat.id, size: size)
            let isDestination = controller.pendingTransfers.contains { $0.to == seat.id }
            // Every pending debt THIS seat owes, as a (transfer id,
            // absolute felt point) pair. Non-empty = "you owe — drag any
            // coin from your own pile to one of these spots to pay it."
            let owedTargets: [(id: Int, point: CGPoint)] = controller.pendingTransfers
                .filter { $0.from == seat.id }
                .map { pending in
                    (pending.id, pending.to.map { clusterCenter(seat: $0, size: size) } ?? pot)
                }
            ZStack {
                if isDestination {
                    Circle()
                        .strokeBorder(CardStyle.gold.opacity(0.85),
                                      style: StrokeStyle(lineWidth: 2.5, dash: [7, 6]))
                        .frame(width: 120, height: 120)
                        .shadow(color: CardStyle.gold.opacity(0.6), radius: 10)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                DraggableCoinCluster(count: controller.chips[seat.id],
                                     diameter: 50,
                                     seedKey: "seat\(seat.id)",
                                     center: center,
                                     payTargets: owedTargets,
                                     onPay: { transferID in
                                         controller.completePendingTransfer(id: transferID)
                                     })
            }
            .position(center)
            .animation(.easeInOut(duration: 0.35), value: isDestination)
        }
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
        let pot = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        let flights = transfers.enumerated().map { index, transfer in
            ChipFlight(id: transfer.id,
                       from: clusterCenter(seat: transfer.from, size: size),
                       to: transfer.to.map { clusterCenter(seat: $0, size: size) } ?? pot,
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
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
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
    /// A pending penalty coin is owed HERE — glow gold until it lands.
    var isDestination: Bool = false

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
                        isDestination ? CardStyle.gold
                            : isTurn ? color : .white.opacity(0.08),
                        lineWidth: isDestination ? 3 : isTurn ? 2.5 : 1)
                )
                .shadow(color: isDestination ? CardStyle.gold.opacity(0.75)
                            : isTurn ? color.opacity(0.65) : .clear,
                        radius: isDestination ? 14 : 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
        .animation(.easeInOut(duration: 0.4), value: isDestination)
    }

    /// The coins themselves live ON the felt now (DraggableCoinCluster in
    /// DiceTableView) — the plate keeps only a whisper of status: the
    /// count as a number, or the empty-handed lament.
    @ViewBuilder
    private var chipRow: some View {
        Group {
            if chips == 0 {
                Text("empty-handed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.45))
            } else {
                Text("\(chips) coin\(chips == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.75))
            }
        }
        .frame(minHeight: 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: chips)
    }
}

/// One gold coin, the currency of LCR night — and it must read as METAL,
/// not a flat circle: visible edge thickness below the face, a raised rim
/// with a milled band, an embossed center star (dark bite toward the
/// light, catch-light away), an angular brushed-metal sweep across the
/// face, and a soft specular sheen that drifts a few degrees so the gold
/// glints as the eye lingers.
struct ChipToken: View {
    var diameter: CGFloat = 20
    /// Set false for coins drawn dozens at a time where the drifting
    /// sheen would burn battery for no visible gain (tiny plate stacks).
    var animatesSheen: Bool = true

    @State private var sheenShift = false

    private var edgeDrop: CGFloat { diameter * 0.10 }

    var body: some View {
        ZStack {
            // Coin edge: the metal slab under the face — a darker gold
            // band peeking out below, like a coin seen slightly from above.
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.55, green: 0.38, blue: 0.10),
                             Color(red: 0.35, green: 0.22, blue: 0.04)],
                    startPoint: .top, endPoint: .bottom))
                .offset(y: edgeDrop)

            // Face: angular brushed-gold sweep — the signature of metal.
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.98, green: 0.84, blue: 0.44),
                        Color(red: 0.78, green: 0.58, blue: 0.18),
                        Color(red: 1.00, green: 0.93, blue: 0.62),
                        Color(red: 0.82, green: 0.62, blue: 0.22),
                        Color(red: 0.95, green: 0.78, blue: 0.36),
                        Color(red: 0.98, green: 0.84, blue: 0.44),
                    ]),
                    center: .center,
                    angle: .degrees(-40)))

            // Raised rim: bright top-left, shadowed bottom-right.
            Circle()
                .strokeBorder(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.95, blue: 0.72),
                             Color(red: 0.55, green: 0.38, blue: 0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: diameter * 0.09)

            // Milled band just inside the rim.
            Circle()
                .strokeBorder(Color(red: 0.45, green: 0.30, blue: 0.08).opacity(0.55),
                              style: StrokeStyle(lineWidth: diameter * 0.035,
                                                 dash: [diameter * 0.045, diameter * 0.05]))
                .padding(diameter * 0.11)

            // Embossed star: shadow wall pressed down-right, catch light
            // up-left, metal face on top.
            embossedStar

            // Drifting specular sheen — a soft white radial pool that
            // wanders a few degrees, so the coin glints like metal under
            // a real lamp instead of holding one frozen highlight.
            Circle()
                .fill(RadialGradient(
                    colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                    center: .init(x: 0.32, y: 0.26),
                    startRadius: 0, endRadius: diameter * 0.55))
                .rotationEffect(.degrees(sheenShift ? 16 : -10))
                .blendMode(.screen)
        }
        .frame(width: diameter, height: diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: diameter * 0.08, y: diameter * 0.07)
        .onAppear {
            guard animatesSheen else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                sheenShift = true
            }
        }
    }

    private var embossedStar: some View {
        let size = diameter * 0.44
        return ZStack {
            Image(systemName: "seal.fill")
                .font(.system(size: size))
                .foregroundStyle(Color(red: 0.42, green: 0.27, blue: 0.05).opacity(0.9))
                .offset(x: diameter * 0.015, y: diameter * 0.025)
            Image(systemName: "seal.fill")
                .font(.system(size: size))
                .foregroundStyle(Color(red: 1.0, green: 0.96, blue: 0.75).opacity(0.9))
                .offset(x: -diameter * 0.015, y: -diameter * 0.02)
            Image(systemName: "seal.fill")
                .font(.system(size: size))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.93, green: 0.76, blue: 0.32),
                             Color(red: 0.72, green: 0.52, blue: 0.14)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

/// A loose CLUSTER of full-size coins lying on the felt — how real chips
/// actually sit in front of a player. Coins take stable seeded spots on a
/// golden-angle spiral (the pile grows outward instead of twitching), each
/// with its own resting rotation, position jitter, stamp-scale variance,
/// vertical stack lift, and a tight individual contact shadow — on top of
/// the whole pile's shared soft ambient shadow. Overflow past `maxVisible`
/// shows as a small "×N" tag.
struct CoinCluster: View {
    let count: Int
    var diameter: CGFloat = 50
    var maxVisible: Int = 8
    /// Stable per-cluster seed so layouts differ per seat but never twitch.
    var seedKey: String = "cluster"
    /// Spiral pitch as a fraction of the coin diameter.
    var spreadScale: CGFloat = 0.40

    static func slot(index: Int, seedKey: String, diameter: CGFloat,
                     spreadScale: CGFloat) -> CGSize {
        let seed = Double(TableGeometry.jitterDegrees(cardID: seedKey)) // ±4°-ish
        let angle = Double(index) * 2.39996 + seed * 1.3
        let radius = diameter * spreadScale * sqrt(CGFloat(index))
        return CGSize(width: CGFloat(cos(angle)) * radius,
                      height: CGFloat(sin(angle)) * radius * 0.86) // felt-flat oval
    }

    /// Per-coin "it's a messy real pile, not a mathematical spiral":
    /// extra position jitter on top of the spiral slot, a stamp-to-stamp
    /// scale variance (no two coins minted identically), and a vertical
    /// lift so higher-index coins — already painted on top by ZStack's
    /// draw order — visually RISE onto the ones below instead of merely
    /// overlapping them. Pure function of `index`/`seedKey`: deterministic,
    /// never re-rolled per frame, so the pile never twitches.
    static func pileJitter(index: Int, seedKey: String,
                           diameter: CGFloat) -> (offset: CGSize, scale: CGFloat, lift: CGFloat) {
        let jx = TableGeometry.jitterDegrees(cardID: "\(seedKey)jx\(index)") / 9.0  // -1...1
        let jy = TableGeometry.jitterDegrees(cardID: "\(seedKey)jy\(index)") / 9.0
        let js = TableGeometry.jitterDegrees(cardID: "\(seedKey)js\(index)") / 9.0
        let jl = abs(TableGeometry.jitterDegrees(cardID: "\(seedKey)jl\(index)")) / 9.0 // 0...1
        return (offset: CGSize(width: jx * diameter * 0.10, height: jy * diameter * 0.08),
                scale: 1 + js * 0.05,
                lift: jl * diameter * 0.055)
    }

    var body: some View {
        let visible = min(count, maxVisible)
        ZStack {
            if visible > 0 {
                // One soft pooled shadow under the whole cluster — the
                // per-coin CoinContactShadow below handles the TIGHT
                // grounding; this is the wider, softer bed under all of it.
                Ellipse()
                    .fill(.black.opacity(0.30))
                    .frame(width: diameter * (1.1 + spreadScale * CGFloat(visible) * 0.5),
                           height: diameter * (0.8 + spreadScale * CGFloat(visible) * 0.35))
                    .blur(radius: 5)
                    .offset(y: diameter * 0.10)
            }
            ForEach(0..<visible, id: \.self) { index in
                let slot = Self.slot(index: index, seedKey: seedKey,
                                     diameter: diameter, spreadScale: spreadScale)
                let jitter = Self.pileJitter(index: index, seedKey: seedKey, diameter: diameter)
                let coinOffset = CGSize(width: slot.width + jitter.offset.width,
                                        height: slot.height + jitter.offset.height - jitter.lift)
                CoinContactShadow(diameter: diameter)
                    .offset(coinOffset)
                ChipToken(diameter: diameter, animatesSheen: index < 3)
                    .rotationEffect(.degrees(
                        TableGeometry.jitterDegrees(cardID: "\(seedKey)r\(index)") * 4))
                    .scaleEffect(jitter.scale)
                    .offset(coinOffset)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if count > maxVisible {
                Text("×\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .offset(x: diameter * 1.1, y: diameter * 0.55)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 coin" : "\(count) coins")
    }
}

/// A tight dark contact-shadow pool directly under ONE coin — distinct
/// from CoinCluster's single soft ambient shadow for the whole pile: this
/// one hugs an individual coin's footprint so an overlapped coin reads as
/// sitting ON the coin below it instead of the two alpha-blending into an
/// indistinct blob. Same "grounding" idea as the 3D table's DieShadowNode,
/// done natively in SwiftUI since coins are a 2D felt layer.
struct CoinContactShadow: View {
    var diameter: CGFloat
    var body: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.20), .clear],
                center: .center, startRadius: 0, endRadius: diameter * 0.5))
            .frame(width: diameter * 0.88, height: diameter * 0.58)
            .offset(y: diameter * 0.15)
    }
}

/// A CoinCluster whose coins the players can fidget with: every coin is
/// draggable on its own, rides the finger, and when released either drifts
/// gently back to its spot in the cluster (auto-tidy — the felt stays
/// composed without ever fighting the hand) OR, when `payTargets` is
/// non-empty (this seat currently owes a penalty coin), pays a debt if
/// released near one of them. `payTargets` deliberately doesn't
/// discriminate WHICH coin — any of them can settle any owed transfer for
/// this seat; the player's only choice is which physical coin to send.
struct DraggableCoinCluster: View {
    let count: Int
    var diameter: CGFloat = 50
    var seedKey: String = "cluster"
    var maxVisible: Int = 8
    var spreadScale: CGFloat = 0.40
    /// This cluster's own absolute felt position — needed to resolve a
    /// dragged coin's ABSOLUTE point against `payTargets`, which are given
    /// in that same felt coordinate space.
    var center: CGPoint = .zero
    /// Live pending-transfer destinations THIS seat currently owes coins
    /// to: (transfer id, absolute felt point). Empty outside a penalty
    /// phase — coins just auto-tidy as before.
    var payTargets: [(id: Int, point: CGPoint)] = []
    var onPay: ((Int) -> Void)?

    /// Live drag offsets per coin index (cleared by the tidy spring, or
    /// carried on into the pay-flight animation).
    @State private var dragOffsets: [Int: CGSize] = [:]
    @State private var draggingIndex: Int?
    /// Set the instant a drop resolves onto a pay target — freezes that
    /// coin's gesture and fades it out mid-flight instead of letting a
    /// second drag interrupt the payment.
    @State private var payingIndex: Int?

    var body: some View {
        let visible = min(count, maxVisible)
        ZStack {
            if visible > 0 {
                Ellipse()
                    .fill(.black.opacity(0.30))
                    .frame(width: diameter * (1.1 + spreadScale * CGFloat(visible) * 0.5),
                           height: diameter * (0.8 + spreadScale * CGFloat(visible) * 0.35))
                    .blur(radius: 5)
                    .offset(y: diameter * 0.10)
            }
            ForEach(0..<visible, id: \.self) { index in
                let slot = CoinCluster.slot(index: index, seedKey: seedKey,
                                            diameter: diameter, spreadScale: spreadScale)
                let jitter = CoinCluster.pileJitter(index: index, seedKey: seedKey, diameter: diameter)
                let rest = CGSize(width: slot.width + jitter.offset.width,
                                  height: slot.height + jitter.offset.height - jitter.lift)
                let drag = dragOffsets[index] ?? .zero
                CoinContactShadow(diameter: diameter)
                    .offset(x: rest.width, y: rest.height)
                    .opacity(payingIndex == index ? 0 : 1)
                ChipToken(diameter: diameter, animatesSheen: index < 3)
                    .rotationEffect(.degrees(
                        TableGeometry.jitterDegrees(cardID: "\(seedKey)r\(index)") * 4))
                    .scaleEffect(jitter.scale * (draggingIndex == index ? 1.18 : 1))
                    .opacity(payingIndex == index ? 0 : 1)
                    .shadow(color: .black.opacity(draggingIndex == index ? 0.45 : 0),
                            radius: 8, y: 5)
                    .offset(x: rest.width + drag.width, y: rest.height + drag.height)
                    .zIndex(draggingIndex == index ? 10 : 0)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard payingIndex == nil else { return }
                                if draggingIndex != index {
                                    draggingIndex = index
                                    Haptics.tick()
                                }
                                dragOffsets[index] = value.translation
                            }
                            .onEnded { value in
                                guard payingIndex == nil else { return }
                                draggingIndex = nil
                                if let target = nearestPayTarget(rest: rest, translation: value.translation) {
                                    // This coin pays: fly it to the target,
                                    // then apply — same beat the old
                                    // synthetic pending-coin token used.
                                    payingIndex = index
                                    Haptics.arm()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        dragOffsets[index] = CGSize(
                                            width: target.point.x - (center.x + rest.width),
                                            height: target.point.y - (center.y + rest.height))
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                        onPay?(target.id)
                                        dragOffsets[index] = nil
                                        payingIndex = nil
                                    }
                                } else {
                                    // Auto-tidy: a lazy, unhurried settle
                                    // back into the cluster.
                                    withAnimation(.spring(response: 0.9,
                                                          dampingFraction: 0.82)) {
                                        dragOffsets[index] = .zero
                                    }
                                }
                            }
                    )
            }
            if count > maxVisible {
                Text("×\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .offset(x: diameter * 1.1, y: diameter * 0.55)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: count)
        // Individual coins are drag targets, not discrete VoiceOver
        // elements — a labeled floor for the pile as a whole beats a dozen
        // unlabeled draggable circles.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 coin" : "\(count) coins")
        .accessibilityHint(payTargets.isEmpty ? ""
                           : "You owe a coin — drag any coin to the glowing spot to pay")
    }

    /// Nearest owed target within snap radius of where this coin was
    /// dropped (absolute felt coordinates), or nil if it landed nowhere
    /// meaningful.
    private func nearestPayTarget(rest: CGSize, translation: CGSize) -> (id: Int, point: CGPoint)? {
        guard !payTargets.isEmpty else { return nil }
        let at = CGPoint(x: center.x + rest.width + translation.width,
                         y: center.y + rest.height + translation.height)
        return payTargets
            .map { ($0, hypot(at.x - $0.point.x, at.y - $0.point.y)) }
            .filter { $0.1 <= coinPaySnapRadius }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Snap radius for dragging a real cluster coin onto a pending-transfer
/// target (DraggableCoinCluster's `payTargets`) — same generous ~110pt
/// PendingCoinView used to use before every coin in the pile became a
/// valid payer.
private let coinPaySnapRadius: CGFloat = 110

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
        ChipToken(diameter: 46)
            .position(arrived ? flight.to : flight.from)
            .opacity(arrived ? 0.9 : 1)
            .onAppear {
                withAnimation(FeltPhysics.slide(duration: 0.55).delay(flight.delay)) {
                    arrived = true
                }
            }
    }
}
