import SwiftUI
import CoreMotion
import AVFoundation

/// The phone is the dice cup. Routed from HandRootView whenever the table
/// runs a dice game (`client.diceState != nil`).
///
/// Your turn: shake the phone — every jolt rattles the dice audibly inside
/// the cup (SFX + haptic) and banks shake energy; then flip the phone
/// face-down (or swipe down hard) to pour. The pour's intensity
/// (0.3 + banked energy, clamped to 0.3…1.5) rides the wire to the table
/// and scales the dice physics there. Not your turn: quiet standings.
struct DiceCupView: View {
    @Bindable var client: GameClientController
    @State private var model = DiceCupModel()
    @State private var cupJiggle: Double = 0

    var body: some View {
        Group {
            if let state = client.diceState {
                if state.gameOver {
                    gameOverView(state)
                } else if state.isMyTurn {
                    cupStage(state)
                } else {
                    standingsView(state)
                }
            }
        }
        .onAppear {
            model.onPour = { intensity in
                _ = client.session.send(.dicePour(intensity: intensity))
            }
            model.setTurnActive(client.diceState?.isMyTurn == true)
        }
        .onDisappear { model.setTurnActive(false) }
        .onChange(of: client.diceState?.isMyTurn) { _, isMyTurn in
            model.setTurnActive(isMyTurn == true)
        }
        .onChange(of: model.joltCount) { _, _ in
            // Jolt → the cup jerks in the hand.
            cupJiggle = Double.random(in: -6...6)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.35)) {
                cupJiggle = 0
            }
        }
    }

    // MARK: - Your turn: the cup

    private func cupStage(_ state: DiceClientState) -> some View {
        VStack(spacing: 26) {
            if model.hasPoured {
                pouredView
            } else {
                Text("Your roll!")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                Text(rollingDiceLabel(state))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                LeatherCupView(tilt: model.tilt, emptied: false, diceCount: myDiceCount(state))
                    .rotationEffect(.degrees(cupJiggle), anchor: .bottom)
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                // A hard downward flick pours too.
                                if value.velocity.height > 1300 {
                                    model.pourFromSwipe()
                                }
                            }
                    )

                energyMeter
                Text("Shake to rattle the dice,\nthen flip your phone over to pour")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 30)
    }

    private func myDiceCount(_ state: DiceClientState) -> Int {
        guard state.chips.indices.contains(state.mySeat) else { return 3 }
        return min(max(state.chips[state.mySeat], 0), 3)
    }

    private func rollingDiceLabel(_ state: DiceClientState) -> String {
        let count = myDiceCount(state)
        return count == 1 ? "Rolling 1 die" : "Rolling \(count) dice"
    }

    private var energyMeter: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.4))
                    Capsule()
                        .fill(LinearGradient(colors: [CardStyle.gold.opacity(0.7), CardStyle.gold],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, geo.size.width * min(1, model.energy / 1.2)))
                        .animation(.easeOut(duration: 0.15), value: model.energy)
                }
            }
            .frame(width: 220, height: 10)
            Text(model.energy > 0.8 ? "Big pour banked!" :
                 model.energy > 0.25 ? "That's a rattle…" : "shake it")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.75))
        }
    }

    private var pouredView: some View {
        VStack(spacing: 18) {
            LeatherCupView(tilt: .zero, emptied: true, diceCount: 0)
                .rotationEffect(.degrees(140))
                .opacity(0.85)
            Text("Dice are on the table!")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            Text("Watch them tumble on the iPad.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    // MARK: - Not your turn: standings

    private func standingsView(_ state: DiceClientState) -> some View {
        VStack(spacing: 20) {
            Text("Left · Right · Center")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold)

            if state.seatNames.indices.contains(state.turnSeat) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(CardStyle.gold)
                    Text("\(state.seatNames[state.turnSeat]) is rolling…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            VStack(spacing: 10) {
                ForEach(state.seatNames.indices, id: \.self) { seat in
                    HStack {
                        Text(state.seatNames[seat])
                            .font(.system(.body, design: .serif)
                                .weight(seat == state.mySeat ? .bold : .regular))
                            .foregroundStyle(seat == state.mySeat ? CardStyle.gold : .white.opacity(0.85))
                        Spacer()
                        chipDots(state.chips.indices.contains(seat) ? state.chips[seat] : 0)
                    }
                }
                Divider().overlay(.white.opacity(0.2))
                HStack {
                    Text("Pot")
                        .font(.system(.body, design: .serif).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("\(state.centerPot)")
                        .font(.body.weight(.bold))
                        .foregroundStyle(CardStyle.gold)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.35)))

            if state.chips.indices.contains(state.mySeat), state.chips[state.mySeat] == 0 {
                Text("Out of chips — but not out of the game.\nA neighbor can roll you back in.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 24)
    }

    private func chipDots(_ count: Int) -> some View {
        HStack(spacing: 4) {
            if count == 0 {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ForEach(0..<min(count, 6), id: \.self) { _ in
                    Circle().fill(CardStyle.gold).frame(width: 9, height: 9)
                }
                if count > 6 {
                    Text("×\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CardStyle.gold)
                }
            }
        }
    }

    // MARK: - Game over

    private func gameOverView(_ state: DiceClientState) -> some View {
        VStack(spacing: 14) {
            let iWon = state.winnerSeat == state.mySeat
            Text(iWon ? "You take the pot!" : "That's the game!")
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.gold)
            if let winner = state.winnerSeat, state.seatNames.indices.contains(winner), !iWon {
                Text("\(state.seatNames[winner]) takes the pot.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text("The full story is on the table.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Cup motion + audio model

/// CoreMotion brain for the cup. ~60Hz device-motion updates while it's
/// your turn: jolts above threshold bank shake energy (with rattle SFX +
/// impact haptics — the dice knocking around INSIDE the cup), energy
/// decays between jolts, attitude drives the idle wobble, and flipping the
/// phone past face-down-ish fires the pour exactly once.
@Observable
final class DiceCupModel {
    /// Banked shake energy, 0…1.2. Pour intensity = 0.3 + energy.
    private(set) var energy: Double = 0
    private(set) var hasPoured = false
    /// Idle wobble: gravity-driven offset for the dice resting in the cup.
    private(set) var tilt: CGSize = .zero
    /// Bumped on every jolt so the view can jerk the cup.
    private(set) var joltCount = 0

    @ObservationIgnored var onPour: ((Double) -> Void)?

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let audio = CupAudio()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var lastJolt = Date.distantPast
    @ObservationIgnored private var lastIdleClick = Date.distantPast
    @ObservationIgnored private var lastUpdate: Date?
    @ObservationIgnored private let joltHaptic = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let hardJoltHaptic = UIImpactFeedbackGenerator(style: .heavy)

    func setTurnActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            hasPoured = false
            energy = 0
            joltHaptic.prepare()
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let self, let deviceMotion else { return }
            self.process(deviceMotion)
        }
    }

    private func stop() {
        motion.stopDeviceMotionUpdates()
        lastUpdate = nil
        tilt = .zero
    }

    private func process(_ dm: CMDeviceMotion) {
        let now = Date()
        let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0
        lastUpdate = now

        // Energy decays between jolts — a pour right after a frenzy is
        // bigger than one after a polite pause.
        energy = max(0, energy * exp(-0.55 * dt))

        // Idle wobble: the dice slide gently toward the low side of the cup.
        tilt = CGSize(width: dm.gravity.x * 30, height: dm.gravity.y * -30)

        guard !hasPoured else { return }

        let a = dm.userAcceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        if magnitude > 0.75, now.timeIntervalSince(lastJolt) > 0.13 {
            // A jolt: dice audibly knock inside the cup.
            lastJolt = now
            energy = min(1.2, energy + 0.10 + min(0.14, magnitude * 0.05))
            joltCount += 1
            let hard = magnitude > 1.6
            audio.playRattle(volume: hard ? 0.85 : 0.6)
            (hard ? hardJoltHaptic : joltHaptic)
                .impactOccurred(intensity: min(1.0, 0.5 + magnitude * 0.25))
        } else if now.timeIntervalSince(lastJolt) > 0.5,
                  now.timeIntervalSince(lastIdleClick) > 0.7,
                  abs(dm.rotationRate.x) + abs(dm.rotationRate.y) > 1.7 {
            // Gentle tilt: the dice roll over inside with a soft click.
            lastIdleClick = now
            audio.playRattle(volume: 0.18)
        }

        // The pour: phone flipped past ~120° toward face-down. In device
        // coordinates gravity.z runs −1 (flat, screen up) to +1 (face
        // down); +0.35 ≈ 110–120° of flip.
        if dm.gravity.z > 0.35 {
            pour()
        }
    }

    func pourFromSwipe() { pour() }

    private func pour() {
        guard active, !hasPoured else { return }
        hasPoured = true
        let intensity = min(1.5, max(0.3, 0.3 + energy))
        audio.playPour()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onPour?(intensity)
    }
}

/// Tiny phone-side AVAudioPlayer pool: the three cup-rattle variants plus
/// the pour. Separate from TableSFX (that's the iPad's ambient voice; this
/// is the cup in your hand) but the same graceful-skip philosophy — clips
/// missing from the bundle just don't play.
final class CupAudio {
    private var rattles: [AVAudioPlayer] = []
    private var pourPlayer: AVAudioPlayer?
    private var lastRattleIndex = -1

    init() {
        for index in 1...3 {
            guard let url = Self.resolvedURL(basename: "dice_rattle_\(index)"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            rattles.append(player)
        }
        if let url = Self.resolvedURL(basename: "dice_pour"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.7
            player.prepareToPlay()
            pourPlayer = player
        }
    }

    /// A random rattle variant, avoiding an immediate repeat.
    func playRattle(volume: Float) {
        guard !rattles.isEmpty else { return }
        var index = Int.random(in: 0..<rattles.count)
        if rattles.count > 1, index == lastRattleIndex {
            index = (index + 1) % rattles.count
        }
        lastRattleIndex = index
        let player = rattles[index]
        if player.isPlaying { player.stop() }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    func playPour() {
        guard let pourPlayer else { return }
        if pourPlayer.isPlaying { pourPlayer.stop() }
        pourPlayer.currentTime = 0
        pourPlayer.play()
    }

    /// Same dual-layout fallback as TableSFX.resolvedURL — the SFX folder
    /// reference ships in the phone bundle too.
    private static func resolvedURL(basename: String) -> URL? {
        if let url = Bundle.main.url(forResource: basename, withExtension: "mp3", subdirectory: "SFX") {
            return url
        }
        return Bundle.main.url(forResource: basename, withExtension: "mp3")
    }
}

// MARK: - The leather cup

/// Programmatic leather dice cup: tapered body with stitched seams, dark
/// rim, and the dice visible inside — nudged around by the phone's tilt.
struct LeatherCupView: View {
    let tilt: CGSize
    let emptied: Bool
    let diceCount: Int

    private let width: CGFloat = 190
    private let height: CGFloat = 230

    var body: some View {
        ZStack {
            // Body.
            CupShape()
                .fill(
                    LinearGradient(colors: [Color(red: 0.42, green: 0.27, blue: 0.15),
                                            Color(red: 0.30, green: 0.18, blue: 0.10),
                                            Color(red: 0.20, green: 0.12, blue: 0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    // Vertical sheen — lamp light on worn leather.
                    CupShape()
                        .fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .clear,
                                                      .white.opacity(0.05)],
                                             startPoint: .leading, endPoint: .trailing))
                )
                .overlay(
                    // Stitching.
                    CupShape()
                        .strokeBorder(Color(red: 0.62, green: 0.45, blue: 0.26).opacity(0.75),
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4.5]))
                        .padding(9)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 10)

            // Mouth of the cup.
            Ellipse()
                .fill(
                    RadialGradient(colors: [Color(red: 0.10, green: 0.06, blue: 0.03),
                                            Color(red: 0.17, green: 0.10, blue: 0.05)],
                                   center: .center, startRadius: 6, endRadius: 90)
                )
                .frame(width: width * 0.82, height: 46)
                .overlay(Ellipse().strokeBorder(Color(red: 0.55, green: 0.38, blue: 0.21)
                    .opacity(0.9), lineWidth: 3))
                .offset(y: -height / 2 + 20)

            // The dice inside, riding the tilt.
            if !emptied && diceCount > 0 {
                HStack(spacing: -6) {
                    ForEach(0..<diceCount, id: \.self) { index in
                        MiniDie()
                            .rotationEffect(.degrees(Double(index * 17) - 15))
                            .offset(y: CGFloat(index % 2) * 4)
                    }
                }
                .offset(x: clampedTilt.width, y: -height / 2 + 20 + clampedTilt.height * 0.25)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: clampedTilt)
            }
        }
        .frame(width: width, height: height)
    }

    private var clampedTilt: CGSize {
        CGSize(width: max(-34, min(34, tilt.width)),
               height: max(-10, min(10, tilt.height)))
    }
}

private struct MiniDie: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.985, blue: 0.96),
                                          Color(red: 0.88, green: 0.87, blue: 0.83)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().fill(CardStyle.crimson.opacity(0.8))
                .frame(width: 5, height: 5))
            .frame(width: 30, height: 30)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
    }
}

/// Tapered cup silhouette: wider at the mouth, gently rounded base.
struct CupShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> CupShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let taper = rect.width * 0.13
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 12))
        // Left wall, tapering in.
        path.addLine(to: CGPoint(x: rect.minX + taper, y: rect.maxY - 20))
        // Rounded base.
        path.addQuadCurve(to: CGPoint(x: rect.maxX - taper, y: rect.maxY - 20),
                          control: CGPoint(x: rect.midX, y: rect.maxY + 14))
        // Right wall back up.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 12))
        // Mouth.
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + 12),
                          control: CGPoint(x: rect.midX, y: rect.minY - 10))
        path.closeSubpath()
        return path
    }
}
