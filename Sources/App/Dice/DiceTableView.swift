import SwiftUI
import UIKit

/// The felt stage for a dice game — placed by TableRootView exactly like
/// TableGameView (full screen, over TableSurface). Seat plates around the
/// rim, the pot in the middle, and the star of the show: dice that tumble
/// out of the roller's edge, carom off the rails and each other, and lock
/// their faces as friction wins.
struct DiceTableView: View {
    @Bindable var controller: DiceGameController
    var onClose: (() -> Void)?

    @State private var field = DiceFieldModel()
    @State private var chipFlights: [ChipFlight] = []

    private let dieSize: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let felt = feltBounds(in: geo.size)
            ZStack {
                potView
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.45)
                platesLayer(size: geo.size)
                diceLayer(felt: felt)
                chipFlightLayer
                if controller.gameOver {
                    gameOverBanner
                }
            }
            .onChange(of: controller.currentRoll) { _, roll in
                guard let roll else { return }
                let anchors = TableGeometry.seatAnchors(count: controller.seats.count)
                field.launch(roll: roll, bounds: felt,
                             from: anchors[roll.seat], dieSize: dieSize)
            }
            .onChange(of: controller.lastTransfers) { _, transfers in
                spawnChipFlights(transfers, size: geo.size)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.turnSeat)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: controller.gameOver)
    }

    /// Where dice may travel: the felt inset from TableSurface's rail.
    private func feltBounds(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: size.height)
            .insetBy(dx: 52, dy: 52)
    }

    // MARK: - Dice

    private func diceLayer(felt: CGRect) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !field.isActive)) { timeline in
            let _ = field.advance(to: timeline.date, bounds: felt, dieSize: dieSize)
            ZStack {
                ForEach(field.dice) { die in
                    DieFaceView(face: die.face,
                                size: dieSize,
                                locked: die.locked,
                                lift: CGFloat(min(0.12, die.speed / 9000)),
                                wobble: die.wobble(at: timeline.date))
                        .rotationEffect(.degrees(die.angle))
                        .position(die.position)
                }
            }
        }
        .allowsHitTesting(false)
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

// MARK: - Dice physics

/// Position/velocity/angular-velocity integration for the tumbling dice.
/// `isActive` is the only observed property — it wakes/parks the
/// TimelineView. The hot per-frame state (`dice`) is observation-ignored
/// and read directly inside the TimelineView closure, which already
/// redraws every frame while active.
@Observable
final class DiceFieldModel {
    struct Die: Identifiable {
        let id: Int
        var position: CGPoint
        var velocity: CGVector
        var angle: Double        // z-rotation, degrees
        var spin: Double         // degrees/sec
        var face: LcrFace        // face currently shown (cycles while tumbling)
        let finalFace: LcrFace   // authoritative result, locked in at rest
        var locked = false
        var lockDate: Date?
        var faceOdometer: Double = 0 // points traveled since last face flip

        var speed: Double { Double(hypot(velocity.dx, velocity.dy)) }

        /// Tiny settle wobble right after locking: a damped rotation nudge.
        func wobble(at now: Date) -> Double {
            guard let lockDate else { return 0 }
            let t = now.timeIntervalSince(lockDate)
            guard t < 0.5 else { return 0 }
            return 9 * exp(-t * 7) * sin(t * 30)
        }
    }

    private(set) var isActive = false
    @ObservationIgnored private(set) var dice: [Die] = []
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var launchDate: Date?
    @ObservationIgnored private var maxTumble: Double = 2.2
    @ObservationIgnored private var lastBounceSFX = Date.distantPast
    @ObservationIgnored private let lockHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Pour: the dice explode from the roller's edge toward the middle.
    /// Launch speed 900–1600 pt/s scaled by intensity; 1.2–2.2s to settle.
    func launch(roll: DiceGameController.Roll, bounds: CGRect,
                from anchorNorm: CGPoint, dieSize: CGFloat) {
        let norm = min(1, max(0, (roll.intensity - 0.3) / 1.2))
        let baseSpeed = 900.0 + 700.0 * norm
        maxTumble = DiceGameController.settleDuration(intensity: roll.intensity)

        // Entry: at the roller's edge of the felt, just inside the rail.
        let entry = CGPoint(
            x: bounds.minX + min(max(anchorNorm.x, 0.06), 0.94) * bounds.width,
            y: bounds.minY + min(max(anchorNorm.y, 0.06), 0.94) * bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let heading = atan2(center.y - entry.y, center.x - entry.x)

        dice = roll.faces.enumerated().map { index, face in
            let spread = (Double(index) - Double(roll.faces.count - 1) / 2) * 0.24
            let angle = heading + spread + Double.random(in: -0.09...0.09)
            let speed = baseSpeed * Double.random(in: 0.85...1.15)
            let offset = CGFloat(index - 1) * dieSize * 0.5
            return Die(
                id: index,
                position: CGPoint(x: entry.x - CGFloat(sin(heading)) * offset,
                                  y: entry.y + CGFloat(cos(heading)) * offset),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                angle: .random(in: 0..<360),
                spin: Double.random(in: 380...820) * (Bool.random() ? 1 : -1),
                face: .dot,
                finalFace: face)
        }
        lastTick = nil
        launchDate = Date()
        lockHaptic.prepare()
        isActive = true
    }

    /// One integration step, called from the TimelineView every frame.
    func advance(to now: Date, bounds: CGRect, dieSize: CGFloat) {
        guard isActive, !dice.isEmpty else { return }
        guard let last = lastTick else { lastTick = now; return }
        let dt = min(now.timeIntervalSince(last), 1.0 / 30.0)
        lastTick = now
        guard dt > 0 else { return }

        let radius = dieSize * 0.52
        let restitution = 0.45
        var bounced = false

        for i in dice.indices where !dice[i].locked {
            var die = dice[i]

            // Felt friction: constant floor + speed-proportional drag, so
            // fast dice shed speed dramatically and slow ones grind to rest.
            let speed = die.speed
            let newSpeed = max(0, speed - (340.0 + speed * 1.35) * dt)
            if speed > 0.01 {
                let scale = newSpeed / speed
                die.velocity.dx *= scale
                die.velocity.dy *= scale
            }
            die.position.x += die.velocity.dx * dt
            die.position.y += die.velocity.dy * dt
            die.angle += die.spin * dt
            die.spin *= exp(-1.9 * dt)

            // Rail bounces, damped.
            if die.position.x < bounds.minX + radius {
                die.position.x = bounds.minX + radius
                die.velocity.dx = abs(die.velocity.dx) * restitution
                die.spin *= -0.7; bounced = true
            }
            if die.position.x > bounds.maxX - radius {
                die.position.x = bounds.maxX - radius
                die.velocity.dx = -abs(die.velocity.dx) * restitution
                die.spin *= -0.7; bounced = true
            }
            if die.position.y < bounds.minY + radius {
                die.position.y = bounds.minY + radius
                die.velocity.dy = abs(die.velocity.dy) * restitution
                die.spin *= -0.7; bounced = true
            }
            if die.position.y > bounds.maxY - radius {
                die.position.y = bounds.maxY - radius
                die.velocity.dy = -abs(die.velocity.dy) * restitution
                die.spin *= -0.7; bounced = true
            }

            // Faces cycle rapidly while tumbling — one flip per ~70pt of
            // travel, weighted like the real die (3 of 6 sides are dots).
            die.faceOdometer += newSpeed * dt
            if die.faceOdometer > 70 {
                die.faceOdometer = 0
                die.face = Self.tumbleFace()
            }

            dice[i] = die
        }

        // Dice collide with each other: circle-circle separation + a
        // lightly damped impulse swap along the contact normal.
        if dice.count > 1 {
            for i in 0..<(dice.count - 1) {
                for j in (i + 1)..<dice.count {
                    collide(i, j, radius: radius)
                }
            }
        }

        // Lock each die as it runs out of steam (or when the tumble-time
        // budget is spent — the controller resolves on that clock).
        let overtime = launchDate.map { now.timeIntervalSince($0) > maxTumble } ?? false
        var justLocked = false
        for i in dice.indices where !dice[i].locked {
            if (dice[i].speed < 55 && abs(dice[i].spin) < 90) || overtime {
                dice[i].locked = true
                dice[i].face = dice[i].finalFace
                dice[i].velocity = .zero
                dice[i].spin = 0
                dice[i].lockDate = now
                justLocked = true
            }
        }

        // Side effects off the render path.
        if bounced, now.timeIntervalSince(lastBounceSFX) > 0.12 {
            lastBounceSFX = now
            DispatchQueue.main.async { TableSFX.shared.play(.tableKnock) }
        }
        if justLocked {
            DispatchQueue.main.async { [lockHaptic] in
                lockHaptic.impactOccurred(intensity: 0.9)
            }
        }
        if dice.allSatisfy({ $0.locked }),
           let latest = dice.compactMap(\.lockDate).max(),
           now.timeIntervalSince(latest) > 0.6 {
            // Park the TimelineView once the wobble has played out; the
            // locked dice keep rendering in their final pose.
            DispatchQueue.main.async { [weak self] in self?.isActive = false }
        }
    }

    private static func tumbleFace() -> LcrFace {
        switch Int.random(in: 0..<6) {
        case 0, 1, 2: return .dot
        case 3: return .left
        case 4: return .right
        default: return .center
        }
    }

    private func collide(_ i: Int, _ j: Int, radius: CGFloat) {
        let dx = dice[j].position.x - dice[i].position.x
        let dy = dice[j].position.y - dice[i].position.y
        let dist = hypot(dx, dy)
        let minDist = radius * 2
        guard dist > 0.001, dist < minDist else { return }

        let nx = dx / dist, ny = dy / dist
        let overlap = (minDist - dist) / 2

        // Positional separation (skip locked dice — they're at rest).
        if !dice[i].locked {
            dice[i].position.x -= nx * overlap
            dice[i].position.y -= ny * overlap
        }
        if !dice[j].locked {
            dice[j].position.x += nx * overlap
            dice[j].position.y += ny * overlap
        }

        // Relative velocity along the normal; only resolve if approaching.
        let rvx = dice[j].velocity.dx - dice[i].velocity.dx
        let rvy = dice[j].velocity.dy - dice[i].velocity.dy
        let approach = rvx * nx + rvy * ny
        guard approach < 0 else { return }
        let impulse = -approach * 0.9 // equal masses, restitution 0.8-ish
        if !dice[i].locked {
            dice[i].velocity.dx -= nx * impulse / 2
            dice[i].velocity.dy -= ny * impulse / 2
            dice[i].spin += Double.random(in: -160...160)
        }
        if !dice[j].locked {
            dice[j].velocity.dx += nx * impulse / 2
            dice[j].velocity.dy += ny * impulse / 2
            dice[j].spin += Double.random(in: -160...160)
        }
        // A locked die that gets rammed wakes back up just a little.
        if dice[i].locked && !dice[j].locked { nudgeAwake(i, dx: -nx, dy: -ny, impulse: impulse) }
        if dice[j].locked && !dice[i].locked { nudgeAwake(j, dx: nx, dy: ny, impulse: impulse) }
    }

    private func nudgeAwake(_ index: Int, dx: CGFloat, dy: CGFloat, impulse: CGFloat) {
        guard impulse > 220 else { return }
        dice[index].locked = false
        dice[index].lockDate = nil
        dice[index].velocity = CGVector(dx: dx * impulse * 0.3, dy: dy * impulse * 0.3)
    }
}

// MARK: - Die rendering

/// A rounded-square ivory die: subtle top-lighting gradient, engraved red
/// L/R/C letters (or a single centered pip for a dot), contact shadow that
/// snaps tight when the die locks.
struct DieFaceView: View {
    let face: LcrFace
    let size: CGFloat
    let locked: Bool
    /// 0…0.12, speed-derived — a fast die "hops", riding higher off the felt.
    let lift: CGFloat
    let wobble: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.995, green: 0.99, blue: 0.965),
                                            Color(red: 0.905, green: 0.89, blue: 0.845)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    // Top light catching the upper edge.
                    RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.75), .clear],
                                             startPoint: .top, endPoint: .center))
                        .padding(size * 0.06)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(.black.opacity(0.10), lineWidth: 1)
                )
            mark
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + lift)
        .shadow(color: .black.opacity(locked ? 0.38 : 0.20),
                radius: locked ? 2.5 : 8,
                y: locked ? 2.5 : 9 + lift * 40)
        .rotation3DEffect(.degrees(wobble), axis: (x: 1, y: 0.35, z: 0))
    }

    @ViewBuilder
    private var mark: some View {
        switch face {
        case .dot:
            Circle()
                .fill(CardStyle.ink.opacity(0.85))
                .frame(width: size * 0.17, height: size * 0.17)
                .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .white.opacity(0.7), radius: 0.5, y: 1)
        case .left, .right, .center:
            Text(letter)
                .font(.system(size: size * 0.52, weight: .black, design: .serif))
                .foregroundStyle(CardStyle.crimson)
                // Engraved: dark bite above, paper catch-light below.
                .shadow(color: .black.opacity(0.35), radius: 0.4, y: -0.8)
                .shadow(color: .white.opacity(0.8), radius: 0.4, y: 1)
        }
    }

    private var letter: String {
        switch face {
        case .left: return "L"
        case .right: return "R"
        case .center: return "C"
        case .dot: return ""
        }
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
