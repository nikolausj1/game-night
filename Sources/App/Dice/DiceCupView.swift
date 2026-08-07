import SwiftUI
import CoreMotion
import AVFoundation

/// The phone is the dice cup. Routed from HandRootView whenever the table
/// runs a dice game (`client.diceState != nil`).
///
/// Your turn: you're looking straight down INSIDE a leather cup (a real
/// SceneKit interior — DiceCupSceneView) from the moment it's your turn,
/// full stop — manual cup mode no longer swaps in a separate text screen
/// first (owner feedback: "the visual on the screen when it's your turn
/// to shake should be the cup already"). While `cupReady` is false the cup
/// starts empty and fills in as dice are dragged into the table's cup —
/// each one drops in from the mouth and lands with a real physics
/// contact, the same beat as a card arriving in the hand — with the "load
/// your dice" instruction riding as an overlay on top, in the app's
/// established italic ghost-hint voice, until it flips true. From there
/// it's the SAME scene instance straight through to shake-and-pour: no
/// rebuild, no flash. Tilting the phone tilts gravity and the dice slide
/// around the cup floor; shaking throws real impulses at them — hard
/// shakes launch them up toward your eye. Every clack is a physics
/// contact. Shakes bank pour energy; flip the phone face-down (or swipe
/// down hard) to pour. The pour's intensity (0.3 + banked energy, clamped
/// to 0.3…1.5) rides the wire to the table and scales the dice physics
/// there. Not your turn: quiet standings.
struct DiceCupView: View {
    @Bindable var client: GameClientController
    @State private var model = DiceCupModel()
    /// Which of the three cup looks this phone uses (see CupConcept).
    /// Switchable right here on the cup stage (owner feedback: bring the
    /// switcher back) AND from Settings' Developer section — both read/
    /// write this same key; cross-section is the shipped default.
    @AppStorage("gn.cupConcept") private var cupConceptRaw = CupConcept.crossSection.rawValue

    private var cupConcept: CupConcept {
        CupConcept(rawValue: cupConceptRaw) ?? .crossSection
    }

    var body: some View {
        Group {
            if let state = client.diceState {
                if state.gameOver {
                    gameOverView(state)
                } else if state.isMyTurn {
                    // Always the cup, ready or still loading — see the
                    // type doc above. `cupStage` itself branches on
                    // `cupReady` for the overlay/dice-count only.
                    cupStage(state)
                } else {
                    standingsView(state)
                }
            }
        }
        .onAppear {
            model.onPour = { [weak client] intensity in
                guard let client else { return }
                // Same self-healing contract as card actions: a failed
                // hand-off means the session is wedged — start rebuilding
                // immediately so the NEXT pour (or the table's 10s RNG
                // watchdog) can't strand the game.
                if !client.session.send(.dicePour(intensity: intensity)) {
                    client.session.refresh()
                }
            }
            model.setTurnActive(client.diceState?.isMyTurn == true)
            scheduleAutoPourIfAsked(client.diceState?.isMyTurn == true)
            updatePourTipEligibility()
        }
        .onDisappear { model.setTurnActive(false) }
        .onChange(of: client.diceState?.isMyTurn) { _, isMyTurn in
            model.setTurnActive(isMyTurn == true)
            scheduleAutoPourIfAsked(isMyTurn == true)
            updatePourTipEligibility()
        }
        .onChange(of: client.diceState?.cupReady) { _, _ in
            // The shake-to-pour tip should only ever appear once there's
            // actually something to shake — during the loading phase
            // (cupReady == false) it stays suppressed even though the
            // scene underneath is already visible.
            updatePourTipEligibility()
        }
    }

    /// Sim-verify hook (-autoPour): no CoreMotion in the simulator, so 8s
    /// after the cup becomes active the pour fires by itself — exercising
    /// the exact same path as a real face-down flip.
    private func scheduleAutoPourIfAsked(_ isMyTurn: Bool) {
        guard isMyTurn, CommandLine.arguments.contains("-autoPour") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            model.pourFromSwipe()
        }
    }

    private func updatePourTipEligibility() {
        DiceCupPourTip.isEligible = client.diceState?.isMyTurn == true
            && client.diceState?.cupReady == true
    }

    // MARK: - Your turn: the cup

    private func cupStage(_ state: DiceClientState) -> some View {
        ZStack {
            if model.hasPoured {
                pouredView
            } else {
                // The phone IS the cup: the interior fills the screen edge
                // to edge, in whichever of the three looks this player
                // prefers. Dice roll around inside as the phone tilts and
                // shakes. `.id` rebuilds the scene instantly on toggle.
                DiceCupSceneView(diceCount: cupSceneDiceCount(state), model: model,
                                 concept: cupConcept)
                    .id(cupConcept)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                // A hard downward flick pours too.
                                if value.velocity.height > 1300 {
                                    model.pourFromSwipe()
                                }
                            }
                    )

                VStack {
                    VStack(spacing: 4) {
                        Text("Your roll!")
                            .font(.system(.title, design: .serif).weight(.bold))
                            .foregroundStyle(CardStyle.gold)
                        Text(rollingDiceLabel(state))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.top, 8)
                    .shadow(color: .black.opacity(0.8), radius: 6)
                    Spacer()
                    if state.cupReady {
                        VStack(spacing: 10) {
                            energyMeter
                            Text("Shake to rattle the dice,\nthen flip your phone over to pour")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.7))
                                .shadow(color: .black.opacity(0.8), radius: 4)
                        }
                        .padding(.bottom, 14)
                    } else {
                        loadInstructionOverlay
                            .padding(.bottom, 14)
                    }
                }
                .allowsHitTesting(false)

                // The concept switcher, back where players can actually
                // reach it (owner feedback: "I still want the ability to
                // switch between cup concepts. Bring back the switcher on
                // remote"). OUTSIDE the block above (which is
                // allowsHitTesting(false)) so it stays tappable — same
                // pattern as the TipKit view below. The Settings/Developer
                // picker still exists too; both read/write the same
                // `gn.cupConcept`.
                VStack {
                    HStack {
                        Spacer()
                        CupConceptToggle(concept: cupConcept) {
                            cupConceptRaw = cupConcept.next.rawValue
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.trailing, 12)

                // First-use tip (TipKit, one-shot) — outside the block
                // above so its own close button stays tappable.
                VStack {
                    Spacer()
                    GhostHintTipView(tip: DiceCupPourTip())
                        .padding(.horizontal, 24)
                    Spacer().frame(height: 120)
                }
            }
        }
    }

    private func myDiceCount(_ state: DiceClientState) -> Int {
        guard state.chips.indices.contains(state.mySeat) else { return 3 }
        return min(max(state.chips[state.mySeat], 0), 3)
    }

    /// What `DiceCupSceneView` should actually show right now: the full
    /// required count once `cupReady`, or however many have been loaded
    /// so far while it isn't (clamped to the required count — a stale/
    /// racy `loadedDice` should never overfill the cup). This is the
    /// number that drives the loading mirror: each time the host
    /// broadcasts one more loaded die, this ticks up by one and the scene
    /// spawns exactly that one die falling in from the mouth (see
    /// `DiceCupSceneCoordinator.setDiceCount`) — the SAME scene instance
    /// the shake-and-pour stage keeps using once ready.
    private func cupSceneDiceCount(_ state: DiceClientState) -> Int {
        let required = myDiceCount(state)
        guard !state.cupReady else { return required }
        return min(max(state.loadedDice, 0), required)
    }

    private func rollingDiceLabel(_ state: DiceClientState) -> String {
        let required = myDiceCount(state)
        guard state.cupReady else {
            let loaded = min(max(state.loadedDice, 0), required)
            return "\(loaded) of \(required) dice loaded"
        }
        return required == 1 ? "Rolling 1 die" : "Rolling \(required) dice"
    }

    /// The "load your dice into the table cup" gate, as an overlay on TOP
    /// of the same cup scene the shake-and-pour stage uses (owner
    /// feedback: "the visual on the screen when it's your turn to shake
    /// should be the cup already" — this used to be a whole separate
    /// screen; now it's just a hint riding over the real thing). Styled in
    /// the app's established italic ghost-hint voice — same serif-italic,
    /// gold-tinted-on-dark voice as `GhostHintTipView`'s tips elsewhere —
    /// but not built ON TipKit itself: this has to reappear every time
    /// `cupReady` is false, not just once ever. Vanishes the instant
    /// `cupReady` flips true; the scene underneath never rebuilds.
    private var loadInstructionOverlay: some View {
        Text("Load your dice into the cup on the table")
            .font(.system(.title3, design: .serif).italic())
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.4)))
            .shadow(color: .black.opacity(0.6), radius: 6)
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
            Image(systemName: "dice.fill")
                .font(.system(size: 72))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .rotationEffect(.degrees(24))
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

/// The small labeled pill that cycles the three cup looks. Back on the cup
/// stage itself (owner feedback, wave 4 — it had been demoted to a
/// Settings-only Developer picker; players wanted it in-hand again), gold-
/// on-dark styling to match the table's other overlays. Also used by
/// DiceCupPreviewHarness (the `-autoCupPreview` sim-verify hook) to cycle
/// looks for screenshotting.
struct CupConceptToggle: View {
    let concept: CupConcept
    let onCycle: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            onCycle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 10))
                Text(concept.label)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(CardStyle.gold.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.45))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.35),
                                                lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cup motion + audio model

/// CoreMotion brain for the cup. ~60Hz device-motion updates while it's
/// your turn. Every sample is forwarded to the 3D cup scene (which turns
/// attitude into a tilted gravity vector and jolts into impulses — rattle
/// SFX and haptics now come from actual physics CONTACTS in there, so the
/// sound matches what the eyes see). This model keeps the game-side jobs:
/// jolts bank shake energy, energy decays between jolts, and flipping the
/// phone past face-down-ish fires the pour exactly once.
@Observable
final class DiceCupModel {
    /// Banked shake energy, 0…1.2. Pour intensity = 0.3 + energy.
    private(set) var energy: Double = 0
    private(set) var hasPoured = false

    @ObservationIgnored var onPour: ((Double) -> Void)?
    /// The 3D cup scene subscribes here; called ~60Hz on the main queue.
    @ObservationIgnored var onMotionSample: ((CMDeviceMotion) -> Void)?

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let audio = CupAudio()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var lastJolt = Date.distantPast
    @ObservationIgnored private var lastUpdate: Date?

    func setTurnActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            hasPoured = false
            energy = 0
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
    }

    private func process(_ dm: CMDeviceMotion) {
        let now = Date()
        let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0
        lastUpdate = now

        // The physics scene sees every sample, even after the pour (the
        // emptied cup keeps simulating until the turn flips off).
        onMotionSample?(dm)

        // Energy decays between jolts — a pour right after a frenzy is
        // bigger than one after a polite pause.
        energy = max(0, energy * exp(-0.55 * dt))

        guard !hasPoured else { return }

        let a = dm.userAcceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        if magnitude > 0.75, now.timeIntervalSince(lastJolt) > 0.13 {
            // A jolt banks pour energy (the audible/haptic rattle comes
            // from the scene's contact delegate, not from here).
            lastJolt = now
            energy = min(1.2, energy + 0.10 + min(0.14, magnitude * 0.05))
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
