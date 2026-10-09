import SwiftUI

/// The war room: two big nautical charts side by side on the felt, one per
/// admiral, each showing ONLY that admiral's shots (built from the public
/// `BattleshipTableSnapshot`, which never contains an unsunk ship's
/// position). Pegs drop in with a wooden knock, sunk ships are laid on the
/// chart, and at game over the surviving fleets are revealed.
///
/// Mounted by `SideGameRegistry` (see the line documented on
/// `BattleshipHost`). Exit is `GameHUD`'s two-step button; rematch calls
/// `host.restartSideGame()`.
struct BattleshipTableView: View {
    @Bindable var host: GameHostController
    let onClose: () -> Void

    var body: some View {
        // Tracked read: every side-game mutation bumps this (same rule the
        // cribbage table follows), which redraws the charts.
        let _ = host.stateVersion
        if let game = host.sideGame as? BattleshipHost {
            BattleshipTableContent(
                snapshot: game.tableSnapshot(),
                names: game.seatNames.merging(host.sideGameSeatNames.filter { !$0.value.isEmpty }) { $1 },
                botSeats: game.botSeats,
                log: game.eventLog,
                onRematch: { host.restartSideGame() },
                onClose: onClose)
                // A rematch swaps the host object: rebuild so "what was
                // already on the chart" resets with it.
                .id(ObjectIdentifier(game))
        }
    }
}

/// The table's pure core (snapshot + event log in, closures out) so
/// previews can drive it with demo snapshots.
struct BattleshipTableContent: View {
    let snapshot: BattleshipTableSnapshot
    let names: [Int: String]
    var botSeats: Set<Int> = []
    var log: [BattleshipEventBatch] = []
    var onRematch: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var effects: [Int: [ChartEffect]] = [:]
    @State private var callouts: [Int: String] = [:]
    @State private var announcement: String?
    @State private var lastSerial: Int

    init(snapshot: BattleshipTableSnapshot, names: [Int: String], botSeats: Set<Int> = [],
         log: [BattleshipEventBatch] = [], onRematch: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.names = names
        self.botSeats = botSeats
        self.log = log
        self.onRematch = onRematch
        self.onClose = onClose
        // Start "caught up": history that predates this view never replays.
        _lastSerial = State(initialValue: log.last?.serial ?? 0)
    }

    private func name(_ seat: Int) -> String {
        let n = names[seat] ?? ""
        return n.isEmpty ? "Admiral \(seat + 1)" : n
    }

    // MARK: layout

    private let margin: CGFloat = 40
    private let plateH: CGFloat = 50
    private let fleetH: CGFloat = 36
    private let plaqueH: CGFloat = 84
    private let gap: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let portrait = h > w * 1.05
            let chrome = plateH + fleetH + 16
            let side: CGFloat = portrait
                ? max(160, min(w - 2 * margin, (h - 2 * margin - plaqueH - gap * 2 - 2 * chrome) / 2))
                : max(160, min((w - 2 * margin - gap) / 2, h - 2 * margin - plaqueH - chrome - gap))
            ZStack {
                VStack(spacing: gap) {
                    if portrait {
                        VStack(spacing: gap * 0.6) { column(0, side); column(1, side) }
                    } else {
                        HStack(alignment: .top, spacing: gap) { column(0, side); column(1, side) }
                    }
                    plaque
                        .frame(height: plaqueH)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let announcement {
                    Text(announcement)
                        .font(.system(size: 44, weight: .heavy, design: .serif))
                        .tracking(3)
                        .foregroundStyle(CardStyle.gold)
                        .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
                        .padding(.horizontal, 36).padding(.vertical, 14)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .zIndex(5)
                }

                GameHUD(title: "Battleship", onExit: onClose, toggles: [])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(10)
            }
        }
        .onChange(of: log.last?.serial) { _, _ in
            for batch in log where batch.serial > lastSerial { process(batch) }
            lastSerial = log.last?.serial ?? lastSerial
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: snapshot.turnSeat)
    }

    // MARK: one admiral's chart

    private func column(_ seat: Int, _ side: CGFloat) -> some View {
        let enemy = 1 - seat
        let shots = snapshot.shotsBy[seat] ?? []
        let sunk = snapshot.sunk[enemy] ?? []
        let sunkKinds = Set(sunk.map(\.kind))
        var ships = sunk.map { BattleshipChartView.Ship(ship: $0, style: .sunk, appearDelay: 0.95) }
        for (i, s) in (snapshot.revealedShips[enemy] ?? []).enumerated() where !sunkKinds.contains(s.kind) {
            ships.append(.init(ship: s, style: .revealed, appearDelay: 1.6 + Double(i) * 0.45))
        }
        let hasTurn = snapshot.phase == .battle && snapshot.turnSeat == seat
        let won = snapshot.winnerSeat == seat
        return VStack(spacing: 8) {
            plate(seat, shots: shots, hasTurn: hasTurn, won: won)
                .frame(height: plateH)
            BattleshipChartView(
                side: side, ships: ships, shots: shots, effects: effects[seat] ?? [],
                accessibilitySummary: "\(name(seat))'s chart: \(shots.count) shots, \(shots.filter { $0.result.isHit }.count) hits, \(sunk.count) ships sunk")
                .shadow(color: hasTurn ? PlayerPalette.color(seat).opacity(0.55) : .black.opacity(0.35),
                        radius: hasTurn ? 22 : 10, y: hasTurn ? 0 : 6)
                .overlay { stateStamp(seat, side: side) }
                .overlay(alignment: .bottom) {
                    if let text = callouts[seat] {
                        Text(text)
                            .font(.system(size: max(20, side * 0.06), weight: .heavy, design: .serif))
                            .foregroundStyle(CardStyle.stockTop)
                            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.62))
                                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 1)))
                            .padding(.bottom, side * 0.05)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
            fleetRow(enemy: enemy, sunk: sunkKinds)
                .frame(height: fleetH)
        }
        .frame(width: side)
    }

    private func plate(_ seat: Int, shots: [BattleshipShot], hasTurn: Bool, won: Bool) -> some View {
        let color = PlayerPalette.color(seat)
        let hits = shots.filter { $0.result.isHit }.count
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 14, height: 14)
            Image(systemName: botSeats.contains(seat) ? "gearshape.2.fill" : "person.fill")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
            Text(name(seat))
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
                .lineLimit(1)
            Spacer(minLength: 8)
            if won {
                Image(systemName: "star.fill").foregroundStyle(CardStyle.gold)
            }
            if snapshot.phase != .placement {
                Text("\(hits) hit\(hits == 1 ? "" : "s") of \(shots.count)")
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                   bottomTrailingRadius: 4, topTrailingRadius: 15, style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CardStyle.gold.opacity(0.55)).frame(height: 2).padding(.horizontal, 3)
                }
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15, style: .continuous)
                        .strokeBorder(hasTurn ? color : .white.opacity(0.08), lineWidth: hasTurn ? 2.5 : 1))
                .shadow(color: hasTurn ? color.opacity(0.6) : .clear, radius: 10)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name(seat)), \(hits) hits of \(shots.count) shots\(hasTurn ? ", firing now" : "")")
    }

    private func fleetRow(enemy: Int, sunk: Set<BattleshipShipKind>) -> some View {
        VStack(spacing: 3) {
            Text("\(name(enemy).uppercased())'S FLEET")
                .font(.system(size: 10, weight: .bold, design: .serif)).tracking(1.8)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            BattleshipFleetRow(sunk: sunk, pitch: 7.5, spacing: 12)
        }
    }

    /// Placement phase: a stamp on each chart while its admiral deploys.
    @ViewBuilder
    private func stateStamp(_ seat: Int, side: CGFloat) -> some View {
        if snapshot.phase == .placement {
            let ready = snapshot.ready.contains(seat)
            Text(ready ? "FLEET READY" : "DEPLOYING…")
                .font(.system(size: side * 0.075, weight: .black, design: .serif))
                .tracking(3)
                .foregroundStyle((ready ? BattleshipPalette.danger : BattleshipPalette.ink).opacity(ready ? 0.82 : 0.45))
                .padding(.horizontal, 16).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder((ready ? BattleshipPalette.danger : BattleshipPalette.ink).opacity(ready ? 0.82 : 0.45), lineWidth: 3))
                .rotationEffect(.degrees(ready ? -9 : 0))
                .transition(.scale(scale: 1.5).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.55), value: ready)
                .id(ready)
        }
    }

    // MARK: plaque

    @ViewBuilder
    private var plaque: some View {
        switch snapshot.phase {
        case .placement:
            BrassPlaque {
                VStack(spacing: 2) {
                    Text("The admirals are deploying their fleets")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.stockTop)
                    Text("\(snapshot.ready.count) of 2 ready")
                        .font(.system(.footnote, design: .serif).italic())
                        .foregroundStyle(CardStyle.gold)
                }
            }
        case .battle:
            BrassPlaque {
                HStack(spacing: 16) {
                    if let turn = snapshot.turnSeat {
                        Circle().fill(PlayerPalette.color(turn)).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                        Text("\(name(turn)) to fire")
                            .font(.system(.title2, design: .serif).weight(.bold))
                            .foregroundStyle(CardStyle.stockTop)
                            .id(turn)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .opacity))
                        if snapshot.salvo {
                            salvoPips
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .gameOver:
            let winner = snapshot.winnerSeat ?? 0
            BrassPlaque {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name(winner)) wins the battle")
                            .font(.system(.title, design: .serif).weight(.heavy))
                            .foregroundStyle(CardStyle.gold)
                        Text("\((snapshot.shotsBy[winner] ?? []).count) shots to sink the fleet")
                            .font(.system(.footnote, design: .serif).italic())
                            .foregroundStyle(CardStyle.stockTop.opacity(0.8))
                    }
                    Button("Rematch") { onRematch() }
                        .buttonStyle(BrassButtonStyle(tone: .gold, large: true))
                    Button("Back to menu") { onClose() }
                        .buttonStyle(BrassButtonStyle(tone: .brass))
                }
            }
        }
    }

    private var salvoPips: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(snapshot.shotsRemaining, 0), id: \.self) { _ in
                Circle()
                    .fill(RadialGradient(colors: [BattleshipPalette.brassLight, CardStyle.gold, BattleshipPalette.brassDark],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 12))
                    .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: snapshot.shotsRemaining)
        .accessibilityLabel("\(snapshot.shotsRemaining) shots left this turn")
    }

    // MARK: events

    private func process(_ batch: BattleshipEventBatch) {
        for event in batch.events {
            switch event {
            case .shotFired(let seat, let cell, let result, _):
                impact(seat: seat, cell: cell, result: result)
            case .battleBegan:
                announce("BATTLE STATIONS", seconds: 2.0)
                TableSFX.shared.play(.softChime)
            case .placementConfirmed:
                TableSFX.shared.play(.chipPlace, intensity: 0.6)
            case .gameWon:
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    TableSFX.shared.play(.fanfareWin)
                }
            default:
                break
            }
        }
    }

    /// The beat sheet for one shot, tuned to the peg's 0.28s drop:
    /// 0.00 peg starts falling; 0.28 lands (knock + splash/burst);
    /// 0.95 a sunk ship is laid on the chart (+ callout).
    private func impact(seat: Int, cell: BattleshipCell, result: BattleshipShotResult) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.30)) {
            TableSFX.shared.play(.tableKnock, intensity: 0.9)
            if result.isHit {
                TableSFX.shared.playDiceContact(.die, strength: 0.8)
            } else {
                TableSFX.shared.playDiceContact(.rail, strength: 0.32)
            }
            let effect = ChartEffect(cell: cell, kind: result.isHit ? .burst : .splash)
            effects[seat, default: []].append(effect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                effects[seat]?.removeAll { $0.id == effect.id }
            }
        }
        if case .sunk(let kind) = result {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.3 : 0.95)) {
                TableSFX.shared.play(.trickSweep, intensity: 0.7)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { TableSFX.shared.play(.softChime) }
                let text = "\(kind.displayName) sunk!"
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { callouts[seat] = text }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    if callouts[seat] == text { withAnimation(.easeOut(duration: 0.3)) { callouts[seat] = nil } }
                }
            }
        }
    }

    private func announce(_ text: String, seconds: Double) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { announcement = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if announcement == text { withAnimation(.easeOut(duration: 0.3)) { announcement = nil } }
        }
    }
}

// MARK: - Brass-and-walnut plaque

private struct BrassPlaque<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 34)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [BattleshipPalette.walnutLight, BattleshipPalette.walnut],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Image("WalnutTexture")
                            .resizable(resizingMode: .tile)
                            .opacity(0.4)
                            .blendMode(.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [BattleshipPalette.brassLight, CardStyle.gold, BattleshipPalette.brassDark],
                                               startPoint: .top, endPoint: .bottom), lineWidth: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.black.opacity(0.45), lineWidth: 1).padding(5))
                    .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
            )
    }
}
