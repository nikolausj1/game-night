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
                pendingCoinLayer(size: geo.size)
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
                if isTurn && !seat.isBot && !controller.rollInFlight {
                    if pendingIdle {
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

    // MARK: - Pot

    private var potView: some View {
        let potGlows = controller.pendingTransfers.contains { $0.to == nil }
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.25))
                    .frame(width: 118, height: 118)
                    .overlay(Circle().strokeBorder(
                        potGlows ? CardStyle.gold : CardStyle.gold.opacity(0.4),
                        lineWidth: potGlows ? 3 : 1.5))
                    .shadow(color: potGlows ? CardStyle.gold.opacity(0.7) : .clear,
                            radius: 14)
                // Real money on the felt: the pot builds up as short coin
                // stacks clustered in the well, stable positions per stack
                // so the pile grows instead of twitching.
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(potStacks.enumerated()), id: \.offset) { index, stackCount in
                        CoinStack(count: stackCount, diameter: 20, maxVisible: 5,
                                  seed: "pot\(index)")
                            .offset(y: CGFloat(TableGeometry.jitterDegrees(
                                cardID: "potdrop\(index)")) * 0.8)
                    }
                }
                if controller.centerPot > 0 {
                    Text("\(controller.centerPot)")
                        .font(.system(.title2, design: .serif).weight(.black))
                        .foregroundStyle(CardStyle.stockTop)
                        .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
                        .offset(y: 36)
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

    /// Pot chips split into believable stacks of up to 5 (max 3 stacks
    /// drawn; the count label carries the rest).
    private var potStacks: [Int] {
        var remaining = min(controller.centerPot, 15)
        var stacks: [Int] = []
        while remaining > 0 && stacks.count < 3 {
            let take = min(5, remaining)
            stacks.append(take)
            remaining -= take
        }
        return stacks
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

    // MARK: - Pending coins (humans pay their own debts)

    /// A human's owed coins after their roll: each floats up off the plate
    /// and pulses until DRAGGED home. Within ~110pt of the right target it
    /// snaps in and the transfer applies; anywhere else it shakes back.
    /// The turn is blocked until the queue is empty (25s watchdog in the
    /// controller catches walk-aways).
    private func pendingCoinLayer(size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
        let pot = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        return ForEach(Array(controller.pendingTransfers.enumerated()),
                       id: \.element.id) { index, pending in
            let plate = platePosition(anchor: anchors[pending.from], size: size)
            let toward = CGVector(dx: pot.x - plate.x, dy: pot.y - plate.y)
            let length = max(1, hypot(toward.dx, toward.dy))
            let unit = CGVector(dx: toward.dx / length, dy: toward.dy / length)
            // Home: floated up off the plate toward the felt, siblings
            // spread perpendicular so three owed coins sit in a neat rank.
            let spread = CGFloat(index) - CGFloat(controller.pendingTransfers.count - 1) / 2
            let home = CGPoint(
                x: plate.x + unit.dx * 84 + -unit.dy * spread * 46,
                y: plate.y + unit.dy * 84 + unit.dx * spread * 46)
            let destination = pending.to.map {
                platePosition(anchor: anchors[$0], size: size)
            } ?? pot
            PendingCoinView(plate: plate, home: home, destination: destination) {
                controller.completePendingTransfer(id: pending.id)
            }
        }
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

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 4) {
            if chips == 0 {
                Text("empty-handed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.45))
            } else {
                CoinStack(count: chips, diameter: 13, maxVisible: 6, seed: name)
            }
        }
        .frame(minHeight: 22, alignment: .bottom)
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

/// A believable STACK of coins: each coin rides the one below with a hair
/// of sideways wobble (real stacks are never laser-straight), the shared
/// edge thickness makes the pile read tall, and a contact shadow pools
/// under the bottom coin. Overflow shows as "×N".
struct CoinStack: View {
    let count: Int
    var diameter: CGFloat = 18
    var maxVisible: Int = 8
    /// Stable per-stack wobble seed so piles don't twitch on redraw.
    var seed: String = "stack"

    private var step: CGFloat { diameter * 0.22 }

    var body: some View {
        let visible = min(count, maxVisible)
        HStack(spacing: 5) {
            ZStack {
                // Contact shadow under the pile.
                Ellipse()
                    .fill(.black.opacity(0.38))
                    .frame(width: diameter * 1.15, height: diameter * 0.42)
                    .blur(radius: 1.6)
                    .offset(y: diameter * 0.42)
                ForEach(0..<visible, id: \.self) { level in
                    ChipToken(diameter: diameter, animatesSheen: false)
                        .offset(x: TableGeometry.jitterDegrees(cardID: "\(seed)x\(level)")
                                    * diameter * 0.012,
                                y: -CGFloat(level) * step)
                }
            }
            .frame(width: diameter * 1.3,
                   height: diameter + CGFloat(max(0, visible - 1)) * step,
                   alignment: .bottom)
            if count > maxVisible {
                Text("×\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CardStyle.gold)
            }
        }
    }
}

/// One owed coin waiting to be paid: floats up from the roller's plate,
/// pulses for attention, and rides the finger. Release within the snap
/// radius of ITS destination → it seats itself and the transfer applies;
/// release anywhere else → a rejection wobble back home.
struct PendingCoinView: View {
    let plate: CGPoint
    let home: CGPoint
    let destination: CGPoint
    let onComplete: () -> Void

    static let snapRadius: CGFloat = 110

    /// Current position offset relative to `home`.
    @State private var offset: CGSize
    @State private var dragStart: CGSize = .zero
    @State private var dragging = false
    @State private var pulsing = false
    @State private var landed = false

    init(plate: CGPoint, home: CGPoint, destination: CGPoint,
         onComplete: @escaping () -> Void) {
        self.plate = plate
        self.home = home
        self.destination = destination
        self.onComplete = onComplete
        // Born ON the plate; floats up to its waiting spot on appear.
        _offset = State(initialValue: CGSize(width: plate.x - home.x,
                                             height: plate.y - home.y))
    }

    var body: some View {
        ChipToken(diameter: 36)
            .scaleEffect(dragging ? 1.3 : (pulsing ? 1.12 : 0.96))
            .shadow(color: CardStyle.gold.opacity(dragging ? 0.8 : 0.5),
                    radius: dragging ? 16 : 9)
            .contentShape(Circle().inset(by: -12)) // forgiving finger target
            .position(x: home.x + offset.width, y: home.y + offset.height)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard !landed else { return }
                        if !dragging {
                            dragging = true
                            dragStart = offset
                        }
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in
                        guard !landed else { return }
                        let at = CGPoint(x: home.x + offset.width,
                                         y: home.y + offset.height)
                        if hypot(at.x - destination.x, at.y - destination.y)
                            <= Self.snapRadius {
                            landed = true
                            Haptics.arm()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                offset = CGSize(width: destination.x - home.x,
                                                height: destination.y - home.y)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                onComplete()
                            }
                        } else {
                            // Wrong spot: indignant little shake back home.
                            Haptics.tick()
                            dragging = false
                            withAnimation(.interpolatingSpring(stiffness: 340,
                                                               damping: 9)) {
                                offset = .zero
                            }
                        }
                    }
            )
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                    offset = .zero
                }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    .delay(0.55)) {
                    pulsing = true
                }
            }
            .animation(.easeInOut(duration: 0.15), value: dragging)
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
