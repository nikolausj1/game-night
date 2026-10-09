import SwiftUI
import UIKit

/// The phone during Liar's Dice - the registry's `hand` view.
///
///     "liarsDice": Entry(table: { AnyView(LiarsDiceTableView(host: $0, onClose: $1)) },
///                        hand:  { AnyView(LiarsDiceHandView(client: $0)) }),
///
/// Every phone hides its own dice under its own cup:
/// 1. ROLL - the cup sits upright in your hand. Shake the phone (CoreMotion
///    jolts, same test as the dice cup) and it rattles, then flips over onto
///    the felt, covering your dice. (The host already rolled them; this is
///    the ceremony - see `LiarsDiceHost` for the physical-roll upgrade path.)
/// 2. PEEK - drag the cup UP to look underneath; let go and it drops back,
///    so nobody across the table sees. Dice appear only while it is lifted.
/// 3. BID - on your turn, a brass quantity/face stepper with BID / LIAR! /
///    SPOT ON, each gated by the engine's `legalActions`. LIAR! and SPOT ON
///    ask for a second tap (armed for 3 seconds) because they cannot be undone.
struct LiarsDiceHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        if let payload = client.sideGameState,
           payload.kind == LiarsDiceEngine.kind,
           let phone = payload.decode(LiarsDicePhoneState.self) {
            LiarsDicePhoneScreen(
                state: phone,
                events: client.sideGameEvents?.decode([LiarsDiceEvent].self) ?? [],
                send: { client.sendSideGameAction(kind: LiarsDiceEngine.kind, $0) },
                sendShook: { client.sendSideGameAction(kind: LiarsDiceEngine.kind, LiarsDiceCeremonyAction.shook) })
        } else {
            ZStack {
                FeltBackground()
                Text("Setting the table…")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.7))
            }
        }
    }
}

/// Phone-local plumbing that must not be re-created on every struct init.
private final class LiarsDicePhoneModel {
    let shake = LiarsDiceShakeDetector()
    lazy var audio = CupAudio()
    var lastRattle = Date.distantPast
}

/// The real screen, driven by plain values so previews can feed it demo
/// states without a `GameClientController`.
struct LiarsDicePhoneScreen: View {
    let state: LiarsDicePhoneState
    var events: [LiarsDiceEvent] = []
    var send: (LiarsDiceAction) -> Void = { _ in }
    var sendShook: () -> Void = {}
    /// Preview seams: start already rolled / already peeking.
    var previewRolled = false
    var previewPeek = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = LiarsDicePhoneModel()

    @State private var rolledKey: String?
    @State private var rolling = false
    @State private var flip: Double = 0
    @State private var peekLift: CGFloat = 0
    @State private var a11yPeeking = false

    @State private var qty = 1
    @State private var face = 2
    @State private var armed: LiarsDiceActionKind?
    @State private var armToken = 0
    @State private var toast: String?

    // MARK: derived

    private var snap: LiarsDiceSnapshot { state.snapshot }
    private var me: Int { snap.mySeat }
    private var myCount: Int { snap.diceCounts.indices.contains(me) ? snap.diceCounts[me] : 0 }
    private var alive: Bool { myCount > 0 }
    private var roundKey: String { "\(state.gameID)-\(snap.roundNumber)" }
    private var isReveal: Bool { snap.phase == .reveal || snap.phase == .gameOver }
    private var hasRolled: Bool { previewRolled || rolledKey == roundKey || state.shaken }
    private var myTurn: Bool { snap.phase == .bidding && snap.turnSeat == me && alive }
    private var canPeek: Bool { hasRolled && !rolling && alive && !isReveal }
    private var wantsShake: Bool { alive && !hasRolled && !isReveal && snap.phase != .gameOver }
    private var myDice: [Int] { snap.myDice.sorted() }

    private func name(_ seat: Int) -> String {
        state.names.indices.contains(seat) ? state.names[seat] : "Seat \(seat + 1)"
    }

    private var verdict: LiarsDiceVerdict? {
        guard let r = snap.resolution else { return nil }
        return LiarsDiceVerdict.make(r, diceCounts: snap.diceCounts, name: name)
    }

    // MARK: body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                VStack(spacing: 0) {
                    header
                    statusBlock
                        .padding(.top, 6)
                    cupStage(in: geo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomPanel
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                if let toast {
                    VStack {
                        Text(toast)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(CardStyle.stockTop)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .padding(.top, 60)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .statusBarHidden()
        .animation(.easeOut(duration: 0.25), value: toast)
        .onAppear {
            flip = (hasRolled || isReveal) ? 1 : 0
            resetSelection()
            updateShake()
            if previewPeek { peekLift = 200 }
            if CommandLine.arguments.contains("-autoShakeLiarsDice"), wantsShake {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settle() }
            }
        }
        .onDisappear { model.shake.stop() }
        .onChange(of: roundKey) { _, _ in
            armed = nil
            peekLift = 0
            model.shake.reset()
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.45)) {
                flip = (hasRolled || isReveal) ? 1 : 0
            }
            resetSelection()
            updateShake()
            if CommandLine.arguments.contains("-autoShakeLiarsDice"), wantsShake {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settle() }
            }
        }
        .onChange(of: snap.bids.count) { _, _ in
            armed = nil
            resetSelection()
        }
        .onChange(of: isReveal) { _, now in
            armed = nil
            if now {
                // The call reveals every cup: yours lifts itself.
                withAnimation(.easeInOut(duration: 0.3)) { flip = 1 }
            }
            updateShake()
        }
        .onChange(of: snap.phase) { _, _ in updateShake() }
        .onChange(of: model.shake.fired) { _, fired in
            if fired { settle() }
        }
        .onChange(of: model.shake.jolts) { _, jolts in
            guard jolts > 0, Date().timeIntervalSince(model.lastRattle) > 0.14 else { return }
            model.lastRattle = Date()
            model.audio.playRattle(volume: 0.55 + Float(min(0.4, model.shake.energy * 0.4)))
            Haptics.tick()
        }
        .onChange(of: events) { _, new in handle(new) }
    }

    // MARK: chrome

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Liar's Dice")
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.88))
                Spacer()
                Text("Round \(snap.roundNumber)")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(CardStyle.gold.opacity(0.9))
                    .monospacedDigit()
            }
            .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(snap.diceCounts.indices, id: \.self) { seat in
                        seatChip(seat)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private func seatChip(_ seat: Int) -> some View {
        let count = snap.diceCounts[seat]
        let isTurn = snap.phase == .bidding && snap.turnSeat == seat && count > 0
        let isMe = seat == me
        return HStack(spacing: 5) {
            Circle()
                .fill(PlayerPalette.color(BotRoster.identity(named: name(seat))?.colorIndex ?? seat))
                .frame(width: 8, height: 8)
            Text(isMe ? "You" : name(seat))
                .font(.system(.caption, design: .serif).weight(isMe ? .bold : .regular))
                .lineLimit(1)
            Text("\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(CardStyle.gold)
        }
        .foregroundStyle(CardStyle.stockTop.opacity(count > 0 ? 0.95 : 0.4))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(.black.opacity(isTurn ? 0.5 : 0.28))
                .overlay(Capsule().strokeBorder(isTurn ? CardStyle.gold : .white.opacity(0.08),
                                                lineWidth: isTurn ? 1.5 : 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isMe ? "You" : name(seat)), \(count) dice\(isTurn ? ", their turn" : "")")
    }

    // MARK: current bid / verdict

    @ViewBuilder
    private var statusBlock: some View {
        VStack(spacing: 4) {
            if let v = verdict, isReveal {
                if snap.phase == .gameOver, let w = snap.winnerSeat {
                    Text(w == me ? "You win!" : "\(name(w)) wins")
                        .font(.system(.title, design: .serif).weight(.heavy))
                        .foregroundStyle(CardStyle.gold)
                }
                Text(v.title)
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                Text(v.detail)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                if let out = v.outLine {
                    Text(out)
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.crimson.opacity(1))
                }
            } else if let bid = snap.currentBid {
                Text(bid.seat == me ? "Your bid" : "\(name(bid.seat))'s bid")
                    .font(.system(.caption, design: .serif))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 10) {
                    Text(LiarsDiceWords.number(bid.quantity).capitalized)
                        .font(.system(size: 40, weight: .heavy, design: .serif))
                        .foregroundStyle(CardStyle.gold)
                    Text("×")
                        .font(.system(.title, design: .serif))
                        .foregroundStyle(CardStyle.gold.opacity(0.6))
                    LiarsPipDie(value: bid.face, size: 38)
                }
                Text("\(snap.totalDice) dice in play")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(.white.opacity(0.55))
            } else if snap.phase == .bidding {
                Text("\(name(snap.turnSeat)) opens the bidding")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                Text("\(snap.totalDice) dice in play")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 96)
        .animation(.easeOut(duration: 0.2), value: snap.currentBid)
        .accessibilityElement(children: .combine)
    }

    // MARK: cup

    private func cupWidth(in size: CGSize) -> CGFloat {
        max(110, min(size.width * 0.5, size.height * 0.24, 230))
    }

    private var liftDisplay: CGFloat {
        if isReveal && alive { return 1_000 } // clamped below; the call lifts every cup
        if a11yPeeking { return 200 }
        return peekLift
    }

    @ViewBuilder
    private func cupStage(in size: CGSize) -> some View {
        let w = cupWidth(in: size)
        let h = w * (968.0 / 879.0)
        let maxLift = h * 0.92
        let lift = min(maxLift, max(0, liftDisplay))
        ZStack {
            if !alive {
                outOfDice
            } else {
                // Dice live under the cup and only show once it is lifted.
                diceCluster(width: w)
                    .opacity(Double(min(1, max(0, (lift - 26) / 46))))
                    .offset(y: h * 0.07)
                cup(width: w, lift: lift, maxLift: maxLift)
                    .gesture(peekGesture(maxLift: maxLift))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Your cup")
                    .accessibilityValue(a11yPeeking
                        ? "Dice: " + myDice.map(String.init).joined(separator: ", ")
                        : (hasRolled ? "Dice hidden" : "Not rolled yet"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: hasRolled ? "Peek at your dice" : "Roll your dice") {
                        if hasRolled { a11yPeek() } else { settle() }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { cupHint.padding(.bottom, 2) }
    }

    @ViewBuilder
    private func cup(width w: CGFloat, lift: CGFloat, maxLift: CGFloat) -> some View {
        let shaking = rolling || model.shake.energy > 0.02
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shaking || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let amp = rolling ? 1.0 : model.shake.energy
            let lean = Double(lift / max(1, maxLift)) * -8
            LiarsDiceCupArt(width: w, flip: flip,
                            wobble: .degrees(sin(t * 31) * 9 * amp + lean))
                .offset(x: CGFloat(sin(t * 27) * 10 * amp),
                        y: CGFloat(cos(t * 23) * 6 * amp) - lift)
                .scaleEffect(1 + (lift / max(1, maxLift)) * 0.06)
        }
    }

    private func peekGesture(maxLift: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard canPeek else { return }
                peekLift = min(maxLift, max(0, -v.translation.height))
            }
            .onEnded { _ in
                let wasLifted = peekLift > 0
                withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { peekLift = 0 }
                if wasLifted { Haptics.tick() }
            }
    }

    private func a11yPeek() {
        guard canPeek else { return }
        a11yPeeking = true
        AccessibilityNotification.Announcement(
            "Your dice: " + myDice.map(String.init).joined(separator: ", ")).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { a11yPeeking = false }
    }

    private func diceCluster(width w: CGFloat) -> some View {
        let dice = myDice
        let dieSize = min(52, w * 0.26)
        let perRow = dice.count <= 3 ? max(1, dice.count) : Int(ceil(Double(dice.count) / 2.0))
        let rows = stride(from: 0, to: dice.count, by: perRow).map { Array(dice[$0..<min(dice.count, $0 + perRow)]) }
        let bid = snap.resolution?.bid
        return VStack(spacing: dieSize * 0.16) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: dieSize * 0.16) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let value = rows[r][c]
                        let counted = bid.map { liarsDiceDieCounts(value, face: $0.face, wildOnes: snap.config.wildOnes) } ?? false
                        LiarsPipDie(value: value, size: dieSize, glow: isReveal && counted,
                                    dimmed: isReveal && !counted)
                            .rotationEffect(.degrees(Double((r * 7 + c * 13 + value * 5) % 17) - 8))
                    }
                }
            }
        }
        .accessibilityHidden(!(a11yPeeking || isReveal))
    }

    private var outOfDice: some View {
        VStack(spacing: 10) {
            Image(systemName: "dice")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.3))
            Text("You're out of dice")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Text("Watch the table - it's still a good show.")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var cupHint: some View {
        if canPeek && peekLift < 4 {
            Text("Drag the cup up to peek")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.6))
                .shadow(color: .black.opacity(0.7), radius: 4)
        } else if wantsShake && !rolling {
            Text("Shake your phone to rattle the dice")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.7))
                .shadow(color: .black.opacity(0.7), radius: 4)
        }
    }

    // MARK: bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        if snap.phase == .gameOver {
            quietPanel("Game over - the table has the recap")
        } else if isReveal {
            quietPanel("Next round starting…")
        } else if !alive {
            quietPanel("You're out. Cheer loudly.")
        } else if !hasRolled {
            rollPanel
        } else if myTurn {
            bidPanel
        } else {
            waitingPanel
        }
    }

    private func quietPanel(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Capsule().fill(.black.opacity(0.3)))
            .frame(maxWidth: .infinity)
    }

    private var rollPanel: some View {
        VStack(spacing: 10) {
            // Energy meter: same gold capsule as the dice cup's.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.4))
                    Capsule()
                        .fill(LinearGradient(colors: [CardStyle.gold.opacity(0.7), CardStyle.gold],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, g.size.width * CGFloat(min(1, Double(model.shake.jolts) / Double(model.shake.joltsNeeded)))))
                        .animation(.easeOut(duration: 0.15), value: model.shake.jolts)
                }
            }
            .frame(width: 220, height: 10)
            Button {
                Haptics.arm()
                settle()
            } label: {
                Text(rolling ? "Rolling…" : "Tap to roll instead")
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(rolling)
        }
        .padding(.vertical, 8)
    }

    private var waitingPanel: some View {
        VStack(spacing: 4) {
            Text("\(name(snap.turnSeat)) is thinking…")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CardStyle.stockTop.opacity(0.9))
            if let last = snap.currentBid {
                Text("Last bid: \(name(last.seat)) - \(LiarsDiceWords.bid(last.quantity, last.face))")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(CardStyle.gold.opacity(0.9))
            } else {
                Text("No bids yet")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.white.opacity(0.6))
            }
            let waiting = snap.diceCounts.indices.filter {
                snap.diceCounts[$0] > 0 && !state.botSeats.contains($0) && !state.shakenSeats.contains($0)
            }
            if !waiting.isEmpty {
                Text("Still shaking: " + waiting.map { $0 == me ? "you" : name($0) }.joined(separator: ", "))
                    .font(.system(.caption, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.black.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    // MARK: bid panel

    private var bidPanel: some View {
        let legal = snap.legalActions
        let canBid = legal.contains(.bid) && isLegal(qty, face)
        return VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                stepper(label: "How many", value: "\(qty)",
                        down: qtyStep(-1) != nil, up: qtyStep(+1) != nil,
                        onDown: { applyQty(-1) }, onUp: { applyQty(+1) })
                Text("×")
                    .font(.system(.title, design: .serif))
                    .foregroundStyle(CardStyle.gold.opacity(0.6))
                stepper(label: "Face", die: face,
                        down: faceStep(-1) != nil, up: faceStep(+1) != nil,
                        onDown: { applyFace(-1) }, onUp: { applyFace(+1) })
            }
            Button {
                Haptics.arm()
                armed = nil
                send(.bid(quantity: qty, face: face))
            } label: {
                Text("BID  \(LiarsDiceWords.bid(qty, face))")
                    .font(.system(.title3, design: .serif).weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(CardStyle.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Color(red: 0.93, green: 0.80, blue: 0.52), CardStyle.gold],
                                                      startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    )
                    .opacity(canBid ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canBid)
            .accessibilityHint(canBid ? "" : "Raise the quantity or the face")

            HStack(spacing: 10) {
                callButton(.challenge, title: "LIAR!", armedTitle: "SURE? TAP AGAIN",
                           fill: Color(red: 0.70, green: 0.17, blue: 0.14), enabled: legal.contains(.challenge))
                if snap.config.spotOnEnabled {
                    callButton(.spotOn, title: "SPOT ON", armedTitle: "SURE? TAP AGAIN",
                               fill: Color(red: 0.20, green: 0.46, blue: 0.34), enabled: legal.contains(.spotOn))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.38))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.45), lineWidth: 1.5))
        )
    }

    private func callButton(_ kind: LiarsDiceActionKind, title: String, armedTitle: String,
                            fill: Color, enabled: Bool) -> some View {
        let isArmed = armed == kind
        return Button {
            if isArmed {
                armed = nil
                Haptics.arm()
                send(kind == .challenge ? .challenge : .spotOn)
            } else {
                Haptics.tick()
                arm(kind)
            }
        } label: {
            Text(isArmed ? armedTitle : title)
                .font(.system(isArmed ? .footnote : .headline, design: .serif).weight(.heavy))
                .tracking(1.5)
                .foregroundStyle(CardStyle.stockTop)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(fill.opacity(isArmed ? 1 : 0.85))
                        .overlay(Capsule().strokeBorder(isArmed ? CardStyle.gold : .black.opacity(0.35),
                                                        lineWidth: isArmed ? 2 : 1))
                        .shadow(color: isArmed ? fill.opacity(0.8) : .black.opacity(0.35), radius: isArmed ? 9 : 3, y: 2)
                )
                .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHint(kind == .challenge ? "Calls the last bid a lie. Double tap twice to confirm."
                                              : "Calls the last bid exactly right. Double tap twice to confirm.")
    }

    private func arm(_ kind: LiarsDiceActionKind) {
        armed = kind
        armToken += 1
        let token = armToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if armToken == token { armed = nil }
        }
    }

    private func stepper(label: String, value: String? = nil, die: Int? = nil,
                         down: Bool, up: Bool,
                         onDown: @escaping () -> Void, onUp: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .serif))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 10) {
                LiarsBrassButton(systemName: "minus", enabled: down, diameter: 40, action: onDown)
                    .accessibilityLabel("Decrease \(label.lowercased())")
                Group {
                    if let die {
                        LiarsPipDie(value: die, size: 48)
                    } else {
                        Text(value ?? "")
                            .font(.system(size: 40, weight: .heavy, design: .serif))
                            .monospacedDigit()
                            .foregroundStyle(CardStyle.gold)
                            .frame(minWidth: 48)
                    }
                }
                LiarsBrassButton(systemName: "plus", enabled: up, diameter: 40, action: onUp)
                    .accessibilityLabel("Increase \(label.lowercased())")
            }
        }
    }

    // MARK: stepping rules

    private func isLegal(_ q: Int, _ f: Int) -> Bool {
        LiarsDiceRules.isLegalBid(quantity: q, face: f, over: snap.currentBid, totalDice: snap.totalDice)
    }

    /// Where the quantity stepper would land (nil = blocked). Dropping the
    /// quantity back to the standing bid's snaps the face above it.
    private func qtyStep(_ d: Int) -> (Int, Int)? {
        let nq = qty + d
        guard nq >= 1, nq <= snap.totalDice else { return nil }
        if isLegal(nq, face) { return (nq, face) }
        if d < 0, let p = snap.currentBid, nq == p.quantity, p.face < 6 { return (nq, p.face + 1) }
        return nil
    }

    private func faceStep(_ d: Int) -> Int? {
        let nf = face + d
        guard (1...6).contains(nf), isLegal(qty, nf) else { return nil }
        return nf
    }

    private func applyQty(_ d: Int) {
        guard let next = qtyStep(d) else { return }
        qty = next.0; face = next.1
        Haptics.tick()
    }

    private func applyFace(_ d: Int) {
        guard let next = faceStep(d) else { return }
        face = next
        Haptics.tick()
    }

    /// Opening bids default to your best face (ones are wild); raises
    /// default to the smallest legal raise.
    private func resetSelection() {
        let total = snap.totalDice
        guard total > 0 else { return }
        if snap.currentBid == nil {
            var best = (face: 2, count: -1)
            for f in 2...6 {
                let c = LiarsDiceRules.count(face: f, in: snap.myDice, wildOnes: snap.config.wildOnes)
                if c > best.count { best = (f, c) }
            }
            qty = min(max(1, best.count), total)
            face = best.face
        } else if let first = LiarsDiceRules.legalBids(over: snap.currentBid, totalDice: total).first {
            qty = first.quantity
            face = first.face
        }
    }

    // MARK: rolling ceremony

    private func updateShake() {
        if wantsShake && !rolling {
            model.shake.start()
        } else {
            model.shake.stop()
        }
    }

    /// The shake landed (or "tap to roll"): rattle, then turn the cup over
    /// onto the dice and tell the host.
    private func settle() {
        guard wantsShake, !rolling else { return }
        let key = roundKey
        rolling = true
        model.shake.stop()
        model.audio.playRattle(volume: 0.85)
        Haptics.arm()
        let rattle = reduceMotion ? 0.2 : 0.85
        DispatchQueue.main.asyncAfter(deadline: .now() + rattle) {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.6)) {
                flip = 1
            }
            rolling = false
            rolledKey = key
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            sendShook()
            updateShake()
            if CommandLine.arguments.contains("-autoPeekLiarsDice") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.5)) { peekLift = 200 }
                }
            }
        }
    }

    // MARK: events

    private func handle(_ events: [LiarsDiceEvent]) {
        for event in events {
            switch event {
            case .illegalAttempt(let seat, let reason) where seat == me:
                showToast(reason)
            case .challenged, .spotOnCalled:
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            case .dieLost(let seat, _) where seat == me:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .dieGained(let seat, _) where seat == me:
                Haptics.play()
            case .gameWon(let seat) where seat == me:
                Haptics.play()
            default:
                break
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == text { toast = nil }
        }
    }
}
