import SwiftUI
import UIKit

/// The registry's `table` view: finds the running `LiarsDiceHost` on the
/// `GameHostController` and hands it to the scene.
struct LiarsDiceTableView: View {
    @Bindable var host: GameHostController
    var onClose: () -> Void

    var body: some View {
        // Tracked read: every side-game mutation bumps this.
        let _ = host.stateVersion
        if let game = host.sideGame as? LiarsDiceHost {
            LiarsDiceTableScene(game: game, onClose: onClose,
                                onPlayAgain: { host.restartSideGame() })
        } else {
            SideGameMissingView(kind: LiarsDiceEngine.kind)
        }
    }
}

/// The beats of a call, in order. Driven by timers off the state change
/// (the table never sees engine events - only the redrawn state), paced by
/// the same `LiarsDiceTiming` the host holds the reveal for.
enum LiarsRevealStage: Int, Comparable {
    case idle, slam, lift, count, verdict, done
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Liar's Dice on the felt: a seat plate with a face-down leather cup and a
/// dice-count badge around the rim, the bid ledger and the standing bid in
/// the middle, and - on a call - the slam, the cups lifting, the count, and
/// the loser's die leaving the table.
struct LiarsDiceTableScene: View {
    var game: LiarsDiceHost
    var onClose: () -> Void = {}
    var onPlayAgain: () -> Void = {}
    /// Preview seam: freeze the reveal at a stage (and a count step).
    var previewStage: LiarsRevealStage? = nil
    var previewCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: LiarsRevealStage = .idle
    @State private var countStep = 0
    @State private var slide: Double = 0
    @State private var revealKey: String?
    @State private var work: [DispatchWorkItem] = []
    @State private var shakeX: CGFloat = 0
    @State private var slamIn = false

    // Seat unit metrics (drawn rail-bottom, then rotated to its rail).
    private let plateW: CGFloat = 176
    private let plateH: CGFloat = 48
    private let zoneW: CGFloat = 132
    private let zoneH: CGFloat = 132
    private let gap: CGFloat = 4
    private var cupW: CGFloat { 104 }

    // MARK: body

    var body: some View {
        let _ = game.tick
        let state = game.engine.state
        return GeometryReader { geo in
            let size = geo.size
            ZStack {
                ForEach(0..<state.seatCount, id: \.self) { seat in
                    seatUnit(seat, state: state, geo: seatGeo(seat, count: state.seatCount, size: size))
                }
                centerColumn(state, size: size)
                    .position(x: size.width * 0.5, y: size.height * 0.5)
                flyingDie(state, size: size)
                if stage == .slam, let r = state.lastResolution {
                    slam(r, state: state)
                        .position(x: size.width * 0.5, y: size.height * 0.46)
                        .zIndex(8)
                        .allowsHitTesting(false)
                }
                if let banner = bannerText(state) {
                    TableBanner(text: banner).zIndex(9)
                }
                roundTag(state)
                if state.phase == .gameOver, stage >= .done, let winner = state.winnerSeat {
                    gameOverPanel(state, winner: winner).zIndex(11)
                }
                GameHUD(title: "Liar's Dice", onExit: onClose, toggles: [])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(12)
            }
            .offset(x: shakeX)
        }
        .onAppear { sync() }
        .onChange(of: game.tick) { _, _ in sync() }
        .onDisappear { cancelWork() }
    }

    // MARK: seat geometry

    private struct SeatGeo {
        var angle: Angle
        var unitCenter: CGPoint
        var zoneCenter: CGPoint
    }

    private func seatGeo(_ seat: Int, count: Int, size: CGSize) -> SeatGeo {
        let anchors = TableGeometry.seatAnchors(count: count)
        let a = anchors[min(seat, anchors.count - 1)]
        let p = CGPoint(x: a.x * size.width, y: a.y * size.height)
        let dB = size.height - p.y, dT = p.y, dL = p.x, dR = size.width - p.x
        let m = min(dB, dT, dL, dR)
        let angle: Angle
        let inward: CGVector
        if m == dB { angle = .degrees(0); inward = CGVector(dx: 0, dy: -1) }
        else if m == dT { angle = .degrees(180); inward = CGVector(dx: 0, dy: 1) }
        else if m == dL { angle = .degrees(90); inward = CGVector(dx: 1, dy: 0) }
        else { angle = .degrees(-90); inward = CGVector(dx: -1, dy: 0) }
        let unitH = zoneH + gap + plateH
        let unitOffset = unitH / 2 - plateH / 2
        let zoneOffset = plateH / 2 + gap + zoneH / 2
        return SeatGeo(
            angle: angle,
            unitCenter: CGPoint(x: p.x + inward.dx * unitOffset, y: p.y + inward.dy * unitOffset),
            zoneCenter: CGPoint(x: p.x + inward.dx * zoneOffset, y: p.y + inward.dy * zoneOffset))
    }

    // MARK: seat unit (zone with cup + dice, then the plate)

    private var revealing: Bool { stage >= .lift }

    private func displayCount(_ seat: Int, _ state: LiarsDiceState) -> Int {
        var n = state.diceCounts[seat]
        // The engine already applied the loss; the table shows it only when
        // the loser's die has actually left (the verdict beat).
        if let r = state.lastResolution, stage < .verdict {
            if r.loserSeat == seat { n += 1 }
            if r.gainerSeat == seat { n -= 1 }
        }
        return n
    }

    private func seatUnit(_ seat: Int, state: LiarsDiceState, geo: SeatGeo) -> some View {
        let count = displayCount(seat, state)
        let alive = count > 0
        return VStack(spacing: gap) {
            zone(seat, state: state, alive: alive)
                .frame(width: zoneW, height: zoneH)
            plate(seat, state: state, count: count)
                .frame(width: plateW, height: plateH)
        }
        .frame(width: plateW)
        .rotationEffect(geo.angle)
        .position(x: geo.unitCenter.x, y: geo.unitCenter.y)
        .zIndex(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.name(of: seat)), \(count) dice, cup down")
    }

    private func zone(_ seat: Int, state: LiarsDiceState, alive: Bool) -> some View {
        let lifted = revealing && state.lastResolution != nil
        let rolling = state.phase == .bidding && game.seatsStillRolling.contains(seat)
        return ZStack {
            if lifted, let dice = state.lastResolution?.dice[seat] {
                revealCluster(seat, dice: dice, state: state)
                    .transition(.opacity)
            }
            if alive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !rolling || reduceMotion)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let amp = rolling ? 1.0 : 0.0
                    LiarsDiceCupArt(width: cupW, flip: 1,
                                    wobble: .degrees(sin(t * 19 + Double(seat)) * 4 * amp))
                        .offset(x: CGFloat(sin(t * 17 + Double(seat)) * 3 * amp))
                }
                .scaleEffect(lifted ? 1.14 : 1)
                .offset(y: lifted ? (reduceMotion ? 0 : -zoneH * 0.58) : 0)
                .opacity(lifted ? 0 : 1)
                .animation(reduceMotion ? .easeOut(duration: 0.25)
                                        : .easeInOut(duration: 0.7), value: lifted)
            }
        }
        .animation(.easeOut(duration: 0.3), value: alive)
    }

    // MARK: revealed dice

    /// Dice in a compact one- or two-row cluster; counted ones glow, the
    /// rest dim; the loser's last die is gone once the verdict lands.
    private func revealCluster(_ seat: Int, dice allDice: [Int], state: LiarsDiceState) -> some View {
        guard let r = state.lastResolution else { return AnyView(EmptyView()) }
        var dice = allDice
        if stage >= .verdict, r.loserSeat == seat, !dice.isEmpty { dice.removeLast() }
        let dieSize: CGFloat = dice.count > 4 ? 34 : 38
        let perRow = dice.count <= 3 ? max(1, dice.count) : Int(ceil(Double(dice.count) / 2.0))
        let rows = stride(from: 0, to: dice.count, by: perRow).map {
            Array(dice.indices[$0..<min(dice.count, $0 + perRow)])
        }
        let matches = matchList(r)
        let lit = Set(matches.prefix(countStep).map { "\($0.seat)-\($0.index)" })
        let counted = Set(matches.map { "\($0.seat)-\($0.index)" })
        return AnyView(
            VStack(spacing: dieSize * 0.14) {
                ForEach(rows.indices, id: \.self) { rIdx in
                    HStack(spacing: dieSize * 0.14) {
                        ForEach(rows[rIdx], id: \.self) { i in
                            let key = "\(seat)-\(i)"
                            LiarsPipDie(value: dice[i], size: dieSize,
                                        glow: lit.contains(key) && stage <= .verdict,
                                        dimmed: stage >= .count && !counted.contains(key))
                                .rotationEffect(.degrees(Double((seat * 11 + i * 7 + dice[i] * 3) % 21) - 10))
                                .scaleEffect(lit.contains(key) ? 1.1 : 1)
                                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: lit.contains(key))
                        }
                    }
                }
            }
        )
    }

    private struct DieRef { let seat: Int; let index: Int }

    /// Every die that counts toward the bid, in seat then position order -
    /// the order the count beat lights them.
    private func matchList(_ r: LiarsDiceResolution) -> [DieRef] {
        var out: [DieRef] = []
        for seat in r.dice.keys.sorted() {
            for (i, d) in (r.dice[seat] ?? []).enumerated()
            where liarsDiceDieCounts(d, face: r.bid.face, wildOnes: game.engine.state.config.wildOnes) {
                out.append(DieRef(seat: seat, index: i))
            }
        }
        return out
    }

    // MARK: plate

    private func plate(_ seat: Int, state: LiarsDiceState, count: Int) -> some View {
        let name = game.name(of: seat)
        let color = PlayerPalette.color(BotRoster.identity(named: name)?.colorIndex ?? seat)
        let isTurn = state.phase == .bidding && state.turnSeat == seat && count > 0
        let rolling = state.phase == .bidding && game.seatsStillRolling.contains(seat)
        let sub: String? = count == 0 ? "OUT"
            : rolling ? "shaking…"
            : (isTurn && game.botSeats.contains(seat) ? "thinking…" : nil)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15, style: .continuous)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11, weight: .semibold, design: .serif).italic())
                        .foregroundStyle(count == 0 ? CardStyle.crimson : CardStyle.gold.opacity(0.85))
                }
            }
            Spacer(minLength: 2)
            diceBadge(count)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(
            shape.fill(.black.opacity(count == 0 ? 0.25 : 0.42))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CardStyle.gold.opacity(0.55)).frame(height: 2).padding(.horizontal, 3)
                }
                .overlay(shape.strokeBorder(isTurn ? color : .white.opacity(0.08), lineWidth: isTurn ? 2.5 : 1))
                .shadow(color: isTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .opacity(count == 0 ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.3), value: isTurn)
    }

    /// Brass dice-count badge, the same dealer-button brass `SeatPlateView` uses.
    private func diceBadge(_ count: Int) -> some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [Color(red: 0.99, green: 0.92, blue: 0.72), CardStyle.gold,
                         Color(red: 0.52, green: 0.39, blue: 0.19)],
                center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 24))
            Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1)
            Text("\(count)")
                .font(.system(size: 17, weight: .black, design: .serif).monospacedDigit())
                .foregroundStyle(CardStyle.ink)
                .contentTransition(.numericText())
        }
        .frame(width: 30, height: 30)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: count)
    }

    // MARK: center column

    private func centerColumn(_ state: LiarsDiceState, size: CGSize) -> some View {
        let width = min(size.width * 0.36, 440)
        let reveal = state.lastResolution != nil && (state.phase == .reveal || state.phase == .gameOver) && stage != .idle
        return VStack(spacing: 12) {
            if reveal, let r = state.lastResolution {
                revealBlock(r, state: state)
            } else {
                bidHeadline(state)
            }
            ledger(state, rows: reveal ? 3 : 6)
                .opacity(reveal ? 0.55 : 1)
        }
        .frame(width: width)
        .animation(.easeOut(duration: 0.25), value: stage)
        .accessibilityElement(children: .contain)
    }

    private func bidHeadline(_ state: LiarsDiceState) -> some View {
        VStack(spacing: 4) {
            if let bid = state.currentBid {
                Text("\(game.name(of: bid.seat))'s bid")
                    .font(.system(.footnote, design: .serif))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 12) {
                    Text(LiarsDiceWords.number(bid.quantity).uppercased())
                        .font(.system(size: 54, weight: .heavy, design: .serif))
                        .foregroundStyle(CardStyle.gold)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    Text("×")
                        .font(.system(size: 34, design: .serif))
                        .foregroundStyle(CardStyle.gold.opacity(0.6))
                    LiarsPipDie(value: bid.face, size: 58)
                }
                .id("\(bid.seat)-\(bid.quantity)-\(bid.face)")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Current bid: \(game.name(of: bid.seat)), \(LiarsDiceWords.bid(bid.quantity, bid.face))")
            } else if state.phase == .awaitingDice || state.phase == .bidding {
                Text("Dice are down")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                Text("\(game.name(of: state.turnSeat)) opens the bidding")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text("\(state.totalDice) dice in play")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.white.opacity(0.5))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.currentBid)
        .frame(minHeight: 110)
    }

    private func revealBlock(_ r: LiarsDiceResolution, state: LiarsDiceState) -> some View {
        let verdict = LiarsDiceVerdict.make(r, diceCounts: state.diceCounts, name: { game.name(of: $0) })
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(game.name(of: r.bid.seat)) bid")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.white.opacity(0.7))
                Text(LiarsDiceWords.number(r.bid.quantity).uppercased())
                    .font(.system(size: 26, weight: .heavy, design: .serif))
                    .foregroundStyle(CardStyle.gold)
                Text("×").foregroundStyle(CardStyle.gold.opacity(0.6))
                LiarsPipDie(value: r.bid.face, size: 30)
            }
            // The count.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("COUNTED")
                    .font(.system(.footnote, design: .serif).weight(.bold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.6))
                Text("\(stage >= .count ? countStep : 0)")
                    .font(.system(size: 64, weight: .black, design: .serif).monospacedDigit())
                    .foregroundStyle(stage >= .count && countStep >= r.bid.quantity ? CardStyle.gold : CardStyle.stockTop)
                    .contentTransition(.numericText())
                    .shadow(color: CardStyle.gold.opacity(stage >= .count ? 0.6 : 0), radius: 10)
                Text("of \(r.bid.quantity)")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .opacity(stage >= .count ? 1 : 0.25)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: countStep)

            if stage >= .verdict {
                VStack(spacing: 4) {
                    Text(verdict.title)
                        .font(.system(.title2, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.stockTop)
                    Text(verdict.detail)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    if let out = verdict.outLine {
                        Text(out)
                            .font(.system(.headline, design: .serif).weight(.bold))
                            .foregroundStyle(CardStyle.crimson)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.4)))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(minHeight: 110)
    }

    // MARK: the ledger

    private func ledger(_ state: LiarsDiceState, rows: Int) -> some View {
        let bids = state.bids
        let shown = Array(bids.suffix(rows))
        let hidden = bids.count - shown.count
        return VStack(alignment: .leading, spacing: 3) {
            Text("THE LEDGER")
                .font(.system(size: 11, weight: .bold, design: .serif))
                .tracking(3)
                .foregroundStyle(CardStyle.ink.opacity(0.5))
            Rectangle().fill(CardStyle.ink.opacity(0.35)).frame(height: 1)
            if hidden > 0 {
                Text("… \(hidden) earlier")
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(CardStyle.ink.opacity(0.45))
            }
            if shown.isEmpty {
                Text("No bids yet.")
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(CardStyle.ink.opacity(0.5))
                    .padding(.vertical, 4)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, bid in
                let isLast = i == shown.count - 1
                HStack(spacing: 6) {
                    Text(game.name(of: bid.seat))
                        .font(.system(.body, design: .serif).weight(isLast ? .bold : .regular))
                    LiarsDottedLeader()
                        .stroke(CardStyle.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.5, 4]))
                        .frame(height: 6)
                    Text(LiarsDiceWords.bid(bid.quantity, bid.face))
                        .font(.system(.body, design: .serif).weight(isLast ? .heavy : .regular))
                    if !isLast {
                        Text("→")
                            .font(.system(.footnote, design: .serif))
                            .foregroundStyle(CardStyle.ink.opacity(0.4))
                    }
                }
                .foregroundStyle(CardStyle.ink.opacity(isLast ? 1 : 0.62))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Image("PaperGraph").resizable().scaledToFill()
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bids.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bid ledger: " + (bids.isEmpty ? "no bids yet" :
            bids.map { "\(game.name(of: $0.seat)) \(LiarsDiceWords.bid($0.quantity, $0.face))" }.joined(separator: ", then ")))
    }

    // MARK: the slam

    private func slam(_ r: LiarsDiceResolution, state: LiarsDiceState) -> some View {
        let spot = r.kind == .spotOn
        return VStack(spacing: 6) {
            Text(spot ? "SPOT ON!" : "LIAR!")
                .font(.system(size: 112, weight: .black, design: .serif))
                .foregroundStyle(spot ? CardStyle.gold : Color(red: 0.88, green: 0.20, blue: 0.16))
                .shadow(color: .black.opacity(0.75), radius: 0, x: 3, y: 4)
                .shadow(color: (spot ? CardStyle.gold : Color.red).opacity(0.6), radius: 24)
                .rotationEffect(.degrees(reduceMotion ? 0 : -5))
                .scaleEffect(slamIn || reduceMotion ? 1 : 2.6)
                .opacity(slamIn || reduceMotion ? 1 : 0)
            Text(spot
                 ? "\(game.name(of: r.caller)) says it's exactly right"
                 : "\(game.name(of: r.caller)) calls \(game.name(of: r.bid.seat))'s bluff")
                .font(.system(.title2, design: .serif).italic())
                .foregroundStyle(CardStyle.stockTop)
                .shadow(color: .black.opacity(0.7), radius: 5)
                .opacity(slamIn ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: the loser's (or gainer's) die

    @ViewBuilder
    private func flyingDie(_ state: LiarsDiceState, size: CGSize) -> some View {
        if stage >= .verdict, let r = state.lastResolution {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            if let loser = r.loserSeat, let dice = r.dice[loser], let value = dice.last {
                let from = seatGeo(loser, count: state.seatCount, size: size).zoneCenter
                die(value: value, from: from, to: center, forward: true)
            } else if let gainer = r.gainerSeat {
                let to = seatGeo(gainer, count: state.seatCount, size: size).zoneCenter
                die(value: r.bid.face, from: center, to: to, forward: false)
            }
        }
    }

    private func die(value: Int, from: CGPoint, to: CGPoint, forward: Bool) -> some View {
        let s = reduceMotion ? (forward ? 0 : 1) : slide
        let x = from.x + (to.x - from.x) * CGFloat(s)
        let y = from.y + (to.y - from.y) * CGFloat(s)
        // Loser: visible on the way in, gone by arrival. Gainer: appears
        // from the middle and settles into the cup.
        let opacity = forward ? 1 - max(0, (slide - 0.72) / 0.28) : min(1, slide / 0.2) * (1 - max(0, (slide - 0.85) / 0.15))
        return LiarsPipDie(value: value, size: 46, glow: true)
            .rotationEffect(.degrees(reduceMotion ? 0 : slide * 300))
            .scaleEffect(forward ? 1 - 0.45 * CGFloat(slide) : 0.7 + 0.3 * CGFloat(slide))
            .opacity(reduceMotion ? (slide > 0.5 ? 0 : 1) : opacity)
            .position(x: x, y: y)
            .allowsHitTesting(false)
            .zIndex(7)
    }

    // MARK: banner, tag, game over

    private func bannerText(_ state: LiarsDiceState) -> String? {
        switch state.phase {
        case .awaitingDice:
            return "Rolling the dice…"
        case .bidding:
            let rolling = game.seatsStillRolling
            if !rolling.isEmpty {
                return "Waiting on \(rolling.map { game.name(of: $0) }.joined(separator: " and ")) to shake…"
            }
            return "\(game.name(of: state.turnSeat)) to \(state.currentBid == nil ? "open" : "bid")…"
        case .reveal, .gameOver:
            return nil
        }
    }

    private func roundTag(_ state: LiarsDiceState) -> some View {
        Text("Round \(state.roundNumber)")
            .font(.system(.subheadline, design: .serif).weight(.semibold))
            .foregroundStyle(CardStyle.gold.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.35)))
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    private func gameOverPanel(_ state: LiarsDiceState, winner: Int) -> some View {
        let order = [winner] + state.eliminationOrder.reversed()
        let rows = order.enumerated().map { place, seat in
            let left = state.diceCounts.indices.contains(seat) ? state.diceCounts[seat] : 0
            return RecapRow(id: seat, name: game.name(of: seat),
                            colorIndex: BotRoster.identity(named: game.name(of: seat))?.colorIndex ?? seat,
                            score: left > 0 ? "\(left) dice" : "out",
                            detail: place == 0 ? "last cup standing" : "\(ordinal(place + 1)) place",
                            isWinner: seat == winner)
        }
        var highlight = "Last cup standing after \(state.roundNumber) rounds"
        if let r = state.lastResolution {
            let call = r.kind == .spotOn ? "called spot on" : "called"
            highlight = "\(game.name(of: r.caller)) \(call) \(game.name(of: r.bid.seat))'s \(LiarsDiceWords.bid(r.bid.quantity, r.bid.face)): there were \(r.actualCount)"
        }
        return GameRecapCard(title: "\(game.name(of: winner)) wins Liar's Dice", rows: rows, highlight: highlight,
                             onRematch: { onPlayAgain() }, onDone: { onClose() })
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    // MARK: reveal choreography

    private func cancelWork() {
        work.forEach { $0.cancel() }
        work = []
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func sync() {
        let state = game.engine.state
        if let previewStage {
            stage = previewStage
            countStep = previewCount
            slide = previewStage >= .verdict ? 0.55 : 0
            slamIn = true
            return
        }
        let revealed = (state.phase == .reveal || state.phase == .gameOver) && state.lastResolution != nil
        if revealed, let r = state.lastResolution {
            let key = "\(game.gameID)-\(state.roundNumber)"
            if revealKey != key {
                revealKey = key
                startReveal(r, state: state)
            }
        } else if revealKey != nil {
            revealKey = nil
            cancelWork()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                stage = .idle
                countStep = 0
                slide = 0
                slamIn = false
            }
        }
    }

    private func startReveal(_ r: LiarsDiceResolution, state: LiarsDiceState) {
        cancelWork()
        let rm = reduceMotion
        let matching = r.actualCount
        let slamEnd = LiarsDiceTiming.slamEnd(rm)
        let liftEnd = LiarsDiceTiming.liftEnd(rm)
        let step = LiarsDiceTiming.countStep(rm)
        let countEnd = LiarsDiceTiming.countEnd(matching: matching, rm)
        let verdictEnd = LiarsDiceTiming.verdictEnd(matching: matching, rm)

        countStep = 0
        slide = 0
        slamIn = false
        stage = .slam
        TableSFX.shared.play(.tableKnock, intensity: 1.0)
        Haptics.arm()
        withAnimation(rm ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.5)) { slamIn = true }
        if !rm { shakeScreen() }

        after(slamEnd) {
            TableSFX.shared.play(.diceRattle2, intensity: 0.8)
            withAnimation(.easeInOut(duration: 0.2)) { stage = .lift }
        }
        after(liftEnd) {
            withAnimation(.easeOut(duration: 0.2)) { stage = .count }
        }
        if matching > 0 {
            for i in 1...matching {
                after(liftEnd + 0.2 + Double(i) * step) {
                    countStep = i
                    TableSFX.shared.play(.diceSettleTick, intensity: 0.5 + 0.5 * Double(i) / Double(matching))
                }
            }
        }
        after(countEnd) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { stage = .verdict }
            withAnimation(rm ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.95)) { slide = 1 }
            TableSFX.shared.play(.chipPass, intensity: 0.7)
            AccessibilityNotification.Announcement(announcement(r, state: state)).post()
        }
        after(verdictEnd) {
            withAnimation(.easeOut(duration: 0.3)) { stage = .done }
            if game.engine.state.phase == .gameOver {
                TableSFX.shared.play(.fanfareWin)
            }
        }
    }

    private func announcement(_ r: LiarsDiceResolution, state: LiarsDiceState) -> String {
        let v = LiarsDiceVerdict.make(r, diceCounts: state.diceCounts, name: { game.name(of: $0) })
        return [v.title, v.detail, v.outLine].compactMap { $0 }.joined(separator: ". ")
    }

    /// A short, hard screen shake on the slam.
    private func shakeScreen() {
        let offsets: [CGFloat] = [-9, 8, -6, 5, -3, 2, 0]
        for (i, dx) in offsets.enumerated() {
            after(Double(i) * 0.045) {
                withAnimation(.linear(duration: 0.045)) { shakeX = dx }
            }
        }
    }
}

/// A horizontal line through the vertical middle, for the ledger's dotted leaders.
private struct LiarsDottedLeader: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY + 4))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + 4))
        return p
    }
}
