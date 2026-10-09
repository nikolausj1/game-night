import SwiftUI

/// The phone for Battleship: YOUR SECRET BOARD. This is the architecture's
/// showcase for hidden information per device: the snapshot this view gets
/// holds your own fleet in full and the opponent's grid only as shots, so
/// nothing here could leak what it was never sent.
///
/// Placement: your chart, five ship silhouettes in a tray, drag them on
/// (snaps to cells; red when it would overlap), tap a ship to turn it,
/// Randomize, Ready (locks). Battle: swipe between the targeting chart and
/// your own fleet; aim with a tap (the reticle lifts), FIRE to commit.
struct BattleshipHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        let snapshot = client.sideGameState.flatMap { $0.kind == BattleshipEngine.kind ? $0.decode(BattleshipSnapshot.self) : nil }
        let batch = client.sideGameEvents.flatMap { $0.kind == BattleshipEngine.kind ? $0.decode(BattleshipEventBatch.self) : nil }
        BattleshipHandContent(snapshot: snapshot, batch: batch) { action in
            client.sendSideGameAction(kind: BattleshipEngine.kind, action)
        }
    }
}

/// Starting presentation for previews and the render harness: which chart
/// is showing, a pre-aimed cell, a toast, frozen impact effects.
struct BattleshipHandPreview {
    var page: BattleshipPhoneModel.Page = .targeting
    var aim: BattleshipCell?
    var toast: BattleshipPhoneModel.Toast?
    var targetEffects: [ChartEffect] = []
    var fleetEffects: [ChartEffect] = []
    var freeze = false
}

/// The view's pure core: a snapshot (+ latest event batch) in, actions out.
/// `BattleshipHandView` wires it to the client; previews wire it to demo
/// snapshots.
struct BattleshipHandContent: View {
    let snapshot: BattleshipSnapshot?
    var batch: BattleshipEventBatch?
    var send: (BattleshipAction) -> Void = { _ in }
    /// Preview/harness knobs (see `BattleshipHandPreview`).
    var preview = BattleshipHandPreview()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = BattleshipPhoneModel()

    var body: some View {
        ZStack {
            FeltBackground()
            if let snapshot {
                switch snapshot.phase {
                case .placement:
                    BattleshipPlacementView(snapshot: snapshot, model: model, send: send)
                case .battle, .gameOver:
                    BattleshipBattleView(snapshot: snapshot, model: model, send: send)
                }
            } else {
                Text("Waiting for the table…")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.7))
            }
        }
        .statusBarHidden()
        .onAppear {
            model.lastSerial = batch?.serial ?? 0
            model.page = preview.page
            model.aim = preview.aim
            model.toast = preview.toast
            model.targetEffects = preview.targetEffects
            model.fleetEffects = preview.fleetEffects
            model.freeze = preview.freeze
        }
        .onChange(of: snapshot?.phase) { old, new in
            if new == .placement, old != nil { model.reset() }
        }
        .onChange(of: batch?.serial) { _, _ in
            guard let batch, let snapshot else { return }
            model.ingest(batch, mySeat: snapshot.mySeat, reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Shared chrome

private struct HandHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.95))
            if let subtitle {
                Text(subtitle)
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 10)
    }
}

private struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(.black.opacity(0.32)))
    }
}

private struct ToastView: View {
    let toast: BattleshipPhoneModel.Toast

    private var color: Color {
        switch toast.tone {
        case .hit: return Color(red: 1.0, green: 0.58, blue: 0.30)
        case .miss: return Color(red: 0.72, green: 0.84, blue: 0.96)
        case .sunk: return CardStyle.gold
        case .info: return CardStyle.stockTop
        case .warning: return Color(red: 1.0, green: 0.62, blue: 0.55)
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(toast.text)
                .font(.system(toast.tone == .sunk ? .title2 : .title3, design: .serif).weight(.heavy))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
            if let detail = toast.detail {
                Text(detail)
                    .font(.system(.caption, design: .serif).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(.black.opacity(0.72))
                .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        )
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Placement

private struct ChartFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct BattleshipPlacementView: View {
    let snapshot: BattleshipSnapshot
    @Bindable var model: BattleshipPhoneModel
    let send: (BattleshipAction) -> Void

    private struct Drag {
        var kind: BattleshipShipKind
        /// Set when the ship was picked up off the board (vs. the tray).
        var origin: BattleshipShip?
        var orientation: BattleshipOrientation
        var location: CGPoint
        var start: CGPoint
        var moved = false
    }

    private struct Target {
        var ship: BattleshipShip
        var inRegion: Bool
        var legal: Bool
    }

    @State private var fleetOverride: [BattleshipShip]?
    @State private var trayVertical: Set<BattleshipShipKind> = []
    @State private var drag: Drag?
    @State private var touchBegan = false
    @State private var chartFrame: CGRect = .zero
    @State private var note: String?
    @State private var readySent = false
    @State private var noteToken = UUID()

    private var fleet: [BattleshipShip] { fleetOverride ?? snapshot.myShips }
    private var locked: Bool { snapshot.iAmReady || readySent }
    private var placedKinds: Set<BattleshipShipKind> { Set(fleet.map(\.kind)) }
    private var unplaced: [BattleshipShipKind] { BattleshipRules.fleet.filter { !placedKinds.contains($0) } }

    var body: some View {
        GeometryReader { geo in
            let side = max(240, min(geo.size.width - 24, geo.size.height - 360))
            let chartGeo = BattleshipChartGeometry(side: side)
            let current = drag.flatMap { $0.moved ? target(for: $0, side: side) : nil }
            VStack(spacing: 10) {
                HandHeader(title: locked ? "Fleet locked in" : "Deploy your fleet", subtitle: instruction)
                chart(side: side, current: current)
                if locked {
                    lockedPanel
                } else {
                    tray(chartGeo)
                    buttons
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: "place")
            .overlay(alignment: .topLeading) {
                // Out past the chart: the ship rides your finger so you can
                // see exactly what dropping there would do (put it back).
                if let d = drag, d.moved, let current, !current.inRegion {
                    floatingSprite(d, chartGeo)
                }
            }
            .onPreferenceChange(ChartFrameKey.self) { chartFrame = $0 }
            .onChange(of: snapshot.myShips) { _, _ in fleetOverride = nil }
        }
    }

    private var instruction: String? {
        if let note { return note }
        if locked { return snapshot.opponentReady ? "Both fleets are ready." : "Waiting for the other admiral…" }
        if unplaced.isEmpty { return "Drag to adjust. Tap a ship to turn it." }
        return "Drag each ship onto the chart. Tap to turn it."
    }

    // MARK: pieces

    private func chart(side: CGFloat, current: Target?) -> some View {
        let hidden: Set<BattleshipShipKind> = {
            if let d = drag, d.moved, d.origin != nil { return [d.kind] }
            return []
        }()
        let ghost = current.flatMap { t -> BattleshipChartView.Ghost? in
            guard t.inRegion else { return nil }
            return .init(kind: t.ship.kind, row: t.ship.row, col: t.ship.col, orientation: t.ship.orientation, legal: t.legal)
        }
        return BattleshipChartView(
            side: side,
            ships: fleet.map { .init(ship: $0) },
            hiddenKinds: hidden,
            ghost: ghost,
            accessibilitySummary: "Your chart, \(fleet.count) of 5 ships placed")
            .overlay {
                if !locked {
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("place"))
                                .onChanged { chartChanged($0, side: side) }
                                .onEnded { _ in endDrag(side: side) })
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: ChartFrameKey.self, value: g.frame(in: .named("place")))
            })
    }

    private func tray(_ geo: BattleshipChartGeometry) -> some View {
        VStack(spacing: 6) {
            if unplaced.isEmpty {
                Text("All five ships are on the chart")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ForEach(unplaced, id: \.self) { kind in
                    trayRow(kind, geo)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.28), lineWidth: 1))
        )
        .padding(.horizontal, 12)
    }

    private func trayRow(_ kind: BattleshipShipKind, _ geo: BattleshipChartGeometry) -> some View {
        let beingDragged = drag?.kind == kind && drag?.origin == nil
        let vertical = trayVertical.contains(kind)
        return HStack(spacing: 12) {
            BattleshipSprite(kind: kind, alongPitch: geo.pitchX, acrossPitch: geo.pitchY)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                .frame(width: CGFloat(5) * geo.pitchX, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.displayName)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop)
                Text("\(kind.length) squares")
                    .font(.system(.caption2, design: .serif))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.3)))
                .accessibilityLabel(vertical ? "Will place vertically" : "Will place horizontally")
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .opacity(beingDragged ? 0.3 : 1)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("place"))
                .onChanged { value in
                    if !touchBegan {
                        touchBegan = true
                        drag = Drag(kind: kind, origin: nil, orientation: vertical ? .vertical : .horizontal,
                                    location: value.location, start: value.startLocation)
                    }
                    updateDrag(value)
                }
                .onEnded { _ in endDrag(side: chartFrame.width) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName), \(kind.length) squares")
        .accessibilityHint("Drag onto the chart. Use Randomize for an automatic fleet.")
    }

    private func floatingSprite(_ d: Drag, _ geo: BattleshipChartGeometry) -> some View {
        let vertical = d.orientation == .vertical
        return BattleshipSprite(kind: d.kind, alongPitch: geo.pitchX, acrossPitch: geo.pitchY)
            .opacity(0.75)
            .rotationEffect(.degrees(vertical ? -90 : 0))
            .shadow(color: .black.opacity(0.5), radius: 8, x: 3, y: 8)
            .position(x: d.location.x, y: d.location.y - lift(geo.side))
            .allowsHitTesting(false)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button {
                let seed = UInt64.random(in: UInt64.min ... UInt64.max)
                fleetOverride = BattleshipRules.randomPlacement(seed: seed)
                Haptics.arm()
                send(.randomizeFleet(seed: seed))
                scheduleOverrideClear()
            } label: {
                Label("Randomize", systemImage: "dice")
            }
            .buttonStyle(BrassButtonStyle(tone: .brass))

            Button {
                readySent = true
                Haptics.play()
                send(.confirmPlacement)
            } label: {
                Label("Ready", systemImage: "checkmark.seal")
            }
            .buttonStyle(BrassButtonStyle(tone: .gold))
            .disabled(fleet.count < BattleshipRules.fleet.count)
        }
        .padding(.top, 2)
    }

    private var lockedPanel: some View {
        VStack(spacing: 10) {
            ProgressView().tint(CardStyle.gold)
            StatusPill(text: snapshot.opponentReady ? "Battle begins…" : "Waiting for the other admiral…")
        }
        .padding(.top, 14)
    }

    // MARK: drag math

    /// How far above the finger the ship rides, so a thumb never hides it.
    private func lift(_ side: CGFloat) -> CGFloat { side * BattleshipChartGeometry.unitPitchY * 1.6 }

    private func target(for d: Drag, side: CGFloat) -> Target {
        let geo = BattleshipChartGeometry(side: side)
        let local = CGPoint(x: d.location.x - chartFrame.minX,
                            y: d.location.y - chartFrame.minY - lift(side))
        let (u, v) = geo.units(at: local)
        let n = d.kind.length
        let horizontal = d.orientation == .horizontal
        var col = horizontal ? Int((u - CGFloat(n) / 2).rounded()) : Int(floor(u))
        var row = horizontal ? Int(floor(v)) : Int((v - CGFloat(n) / 2).rounded())
        col = max(0, min(col, horizontal ? 10 - n : 9))
        row = max(0, min(row, horizontal ? 9 : 10 - n))
        let region = u > -1.6 && u < 11.6 && v > -1.6 && v < 11.6
        let ship = BattleshipShip(kind: d.kind, row: row, col: col, orientation: d.orientation)
        let legal = BattleshipRules.validatePlacement(ship, existing: fleet) == nil
        return Target(ship: ship, inRegion: region, legal: legal)
    }

    private func chartChanged(_ value: DragGesture.Value, side: CGFloat) {
        if !touchBegan {
            touchBegan = true
            let local = CGPoint(x: value.startLocation.x - chartFrame.minX, y: value.startLocation.y - chartFrame.minY)
            if let cell = BattleshipChartGeometry(side: side).cell(at: local),
               let ship = fleet.first(where: { $0.cells.contains(cell) }) {
                drag = Drag(kind: ship.kind, origin: ship, orientation: ship.orientation,
                            location: value.location, start: value.startLocation)
                Haptics.tick()
            }
        }
        updateDrag(value)
    }

    private func updateDrag(_ value: DragGesture.Value) {
        guard var d = drag else { return }
        d.location = value.location
        if !d.moved, hypot(value.translation.width, value.translation.height) > 8 {
            d.moved = true
            Haptics.tick()
        }
        drag = d
    }

    private func endDrag(side: CGFloat) {
        defer { drag = nil; touchBegan = false }
        guard let d = drag else { return }
        guard d.moved else {
            // A tap: turn the ship (on the board) or flip its tray default.
            if let origin = d.origin {
                rotate(origin)
            } else if trayVertical.contains(d.kind) {
                trayVertical.remove(d.kind)
                Haptics.tick()
            } else {
                trayVertical.insert(d.kind)
                Haptics.tick()
            }
            return
        }
        let t = target(for: d, side: side)
        if !t.inRegion {
            if d.origin != nil { remove(d.kind) }
        } else if t.legal {
            place(t.ship)
        } else {
            flag("Ships can't overlap")
        }
    }

    private func place(_ ship: BattleshipShip) {
        fleetOverride = fleet.filter { $0.kind != ship.kind } + [ship]
        Haptics.arm()
        send(.placeShip(kind: ship.kind, row: ship.row, col: ship.col, orientation: ship.orientation))
        scheduleOverrideClear()
    }

    private func remove(_ kind: BattleshipShipKind) {
        fleetOverride = fleet.filter { $0.kind != kind }
        Haptics.tick()
        send(.removeShip(kind: kind))
        scheduleOverrideClear()
    }

    /// Turn a placed ship 90 degrees, pivoting on whichever of its cells
    /// leaves it legal (bow first, then the middle, then the rest).
    private func rotate(_ ship: BattleshipShip) {
        let newOrientation: BattleshipOrientation = ship.orientation == .horizontal ? .vertical : .horizontal
        let n = ship.kind.length
        let order = ([0, n / 2] + Array(0..<n)).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for k in order {
            let pivot = ship.cells[k]
            let row = newOrientation == .vertical ? pivot.row - k : pivot.row
            let col = newOrientation == .horizontal ? pivot.col - k : pivot.col
            let candidate = BattleshipShip(kind: ship.kind, row: row, col: col, orientation: newOrientation)
            if BattleshipRules.validatePlacement(candidate, existing: fleet) == nil {
                place(candidate)
                return
            }
        }
        flag("No room to turn that ship")
    }

    private func flag(_ text: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        note = text
        let token = UUID()
        noteToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if noteToken == token { note = nil }
        }
    }

    private func scheduleOverrideClear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { fleetOverride = nil }
    }
}

// MARK: - Battle

struct BattleshipBattleView: View {
    let snapshot: BattleshipSnapshot
    @Bindable var model: BattleshipPhoneModel
    let send: (BattleshipAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0

    private var over: Bool { snapshot.phase == .gameOver }
    private var iWon: Bool { snapshot.winnerSeat == snapshot.mySeat }
    private var firedCells: Set<BattleshipCell> { Set(snapshot.myShots.map(\.cell)) }

    var body: some View {
        GeometryReader { geo in
            let side = max(240, min(geo.size.width - 24, geo.size.height - 330))
            VStack(spacing: 8) {
                header
                banner
                pager(side: side)
                pageTabs
                actionArea
                fleetStatus
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: snapshot.isMyTurn) { _, mine in
            model.aim = nil
            let token = UUID()
            model.turnToken = token
            guard mine, !over else { return }
            // Let their last shot play out on your board, then swing over.
            // (The token, not `snapshot`, is the freshness check: this
            // closure captured an older copy of the view.)
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 1.0 : 2.0)) { [model] in
                if model.turnToken == token { withAnimation { model.page = .targeting } }
            }
        }
        .onChange(of: snapshot.myShots.count) { _, _ in
            model.aim = nil
            model.awaitingFire = false
        }
        .onChange(of: snapshot.phase) { _, phase in
            if phase == .gameOver {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { model.page = .targeting }
                }
            }
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            Text("Battleship")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Spacer()
            Text("You \(snapshot.myShipsAfloat)  |  Them \(snapshot.opponentShipsAfloat)")
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.gold)
                .monospacedDigit()
                .accessibilityLabel("Ships afloat: you \(snapshot.myShipsAfloat), them \(snapshot.opponentShipsAfloat)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var banner: some View {
        if over {
            Text(iWon ? "VICTORY" : "DEFEAT")
                .font(.system(.title2, design: .serif).weight(.heavy))
                .tracking(4)
                .foregroundStyle(iWon ? CardStyle.gold : Color(red: 1, green: 0.6, blue: 0.55))
                .frame(height: 30)
        } else if snapshot.isMyTurn {
            VStack(spacing: 0) {
                Text(snapshot.salvo ? "YOUR TURN  ·  \(snapshot.shotsRemaining) SHOT\(snapshot.shotsRemaining == 1 ? "" : "S")" : "YOUR TURN")
                    .font(.system(.headline, design: .serif).weight(.heavy))
                    .tracking(3)
                    .foregroundStyle(CardStyle.gold)
            }
            .frame(height: 30)
        } else {
            Text("Opponent is taking aim…")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 30)
        }
    }

    // MARK: charts

    /// Two charts side by side; swipe (or use the tabs) to switch. A plain
    /// offset pager rather than `TabView(.page)`: it renders everywhere
    /// (previews, `ImageRenderer`) and never fights the chart's tap gesture.
    private func pager(side: CGFloat) -> some View {
        GeometryReader { pg in
            let w = pg.size.width
            HStack(spacing: 0) {
                targetingChart(side: side).frame(width: w, height: side + 8)
                fleetChart(side: side).frame(width: w, height: side + 8)
            }
            .frame(width: w * 2, alignment: .leading)
            .offset(x: (model.page == .fleet ? -w : 0) + dragX)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.page)
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        dragX = model.page == .targeting ? min(0, v.translation.width) : max(0, v.translation.width)
                    }
                    .onEnded { v in
                        let threshold = w * 0.18
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            if model.page == .targeting, v.translation.width < -threshold {
                                model.page = .fleet
                                Haptics.tick()
                            } else if model.page == .fleet, v.translation.width > threshold {
                                model.page = .targeting
                                Haptics.tick()
                            }
                            dragX = 0
                        }
                    })
        }
        .frame(height: side + 8)
        .clipped()
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.top, 10)
                    .id(toast.id)
            }
        }
    }

    private func targetingChart(side: CGFloat) -> some View {
        let sunkIDs = Set(snapshot.opponentSunk.map(\.kind))
        var ships = snapshot.opponentSunk.map { BattleshipChartView.Ship(ship: $0, style: .sunk, appearDelay: 0.55) }
        for (i, s) in snapshot.revealedOpponentShips.enumerated() where !sunkIDs.contains(s.kind) {
            ships.append(.init(ship: s, style: .revealed, appearDelay: 0.5 + Double(i) * 0.3))
        }
        return BattleshipChartView(
            side: side, ships: ships, shots: snapshot.myShots, effects: model.targetEffects,
            aim: model.aim,
            accessibilitySummary: "Targeting chart: \(snapshot.myShots.count) shots fired, \(snapshot.myShots.filter { $0.result.isHit }.count) hits",
            freeze: model.freeze)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tapTarget($0.location, side: side) })
            }
    }

    private func fleetChart(side: CGFloat) -> some View {
        let sunk = Set(snapshot.mySunk.map(\.kind))
        let ships = snapshot.myShips.map {
            BattleshipChartView.Ship(ship: $0, style: sunk.contains($0.kind) ? .sunk : .plain)
        }
        let last = snapshot.shotsAtMe.last
        return BattleshipChartView(
            side: side, ships: ships, shots: snapshot.shotsAtMe, effects: model.fleetEffects,
            markedCell: (!snapshot.isMyTurn && !over) ? last?.cell : nil,
            accessibilitySummary: "Your fleet: \(snapshot.myShipsAfloat) of 5 ships afloat, \(snapshot.shotsAtMe.count) shots against you",
            freeze: model.freeze)
            .modifier(BattleshipShake(animatableData: model.shakeCount))
    }

    private var pageTabs: some View {
        HStack(spacing: 0) {
            tab("Targeting", icon: "scope", page: .targeting)
            tab("My Fleet", icon: "shield.lefthalf.filled", page: .fleet)
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.3)))
    }

    private func tab(_ title: String, icon: String, page: BattleshipPhoneModel.Page) -> some View {
        let selected = model.page == page
        return Button {
            Haptics.tick()
            withAnimation(.easeInOut(duration: 0.25)) { model.page = page }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(selected ? CardStyle.ink : .white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? CardStyle.gold : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: fire control

    @ViewBuilder
    private var actionArea: some View {
        Group {
            if over {
                Text(iWon ? "Their fleet is on the bottom. Rematch from the table."
                          : "Your fleet is lost. Rematch from the table.")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            } else if snapshot.isMyTurn {
                if model.page != .targeting {
                    Button {
                        withAnimation { model.page = .targeting }
                    } label: {
                        Label("To the targeting chart", systemImage: "scope")
                    }
                    .buttonStyle(BrassButtonStyle(tone: .brass))
                } else if let aim = model.aim {
                    Button {
                        fire(aim)
                    } label: {
                        Label("FIRE  \(battleshipCellName(aim))", systemImage: "burst.fill")
                    }
                    .buttonStyle(BrassButtonStyle(tone: .gold, large: true))
                    .disabled(model.awaitingFire)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    Text("Tap a square to aim")
                        .font(.system(.subheadline, design: .serif).italic())
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                VStack(spacing: 3) {
                    if let last = snapshot.shotsAtMe.last {
                        Text(incomingLine(last))
                            .font(.system(.subheadline, design: .serif).weight(.semibold))
                            .foregroundStyle(last.result.isHit ? Color(red: 1, green: 0.62, blue: 0.4) : .white.opacity(0.8))
                    } else {
                        Text("Hold tight. Their first shot is coming.")
                            .font(.system(.subheadline, design: .serif).italic())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .frame(minHeight: 54)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.aim)
    }

    private func incomingLine(_ shot: BattleshipShot) -> String {
        let name = battleshipCellName(shot.cell)
        switch shot.result {
        case .miss: return "Their last shot: \(name), a miss"
        case .hit: return "Their last shot: \(name), a hit!"
        case .sunk(let kind): return "Their last shot: \(name), sank your \(kind.displayName)!"
        }
    }

    private var fleetStatus: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 3) {
                Text("THEIR FLEET")
                    .font(.system(size: 9, weight: .bold, design: .serif)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))
                BattleshipFleetRow(sunk: Set(snapshot.opponentSunk.map(\.kind)), pitch: 5.5, spacing: 6)
            }
            VStack(spacing: 3) {
                Text("YOUR FLEET")
                    .font(.system(size: 9, weight: .bold, design: .serif)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))
                BattleshipFleetRow(sunk: Set(snapshot.mySunk.map(\.kind)), pitch: 5.5, spacing: 6)
            }
        }
        .padding(.top, 2)
    }

    // MARK: taps

    private func tapTarget(_ point: CGPoint, side: CGFloat) {
        guard snapshot.isMyTurn, !over, !model.awaitingFire else { return }
        guard let cell = BattleshipChartGeometry(side: side).cell(at: point) else { return }
        guard !firedCells.contains(cell) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            model.show(.init(text: "Already fired there", tone: .warning, detail: battleshipCellName(cell)), for: 1.4)
            return
        }
        if model.aim == cell {
            fire(cell) // second tap on the reticle commits
        } else {
            model.aim = cell
            Haptics.tick()
        }
    }

    private func fire(_ cell: BattleshipCell) {
        guard snapshot.isMyTurn, !model.awaitingFire else { return }
        model.awaitingFire = true
        Haptics.arm()
        send(.fire(row: cell.row, col: cell.col))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.awaitingFire = false }
    }
}
