import SwiftUI

/// The live cribbage table: the pegboard front and center, the deck and
/// cut starter off to one side, played cards fanning in the pegging area
/// with a running-count chip, the crib building face-down by the dealer's
/// plate, and — at the show — a paper scorecard walking the breakdown line
/// by line while the pegs hop to match. Mounted by `TableRootView` exactly
/// like `DiceTableView`/`TableGameView`: cribbage lives outside the card
/// engine, so this is its own root, not a mode bolted onto
/// `TableGameView` (which this file never touches).
struct CribbageTableView: View {
    @Bindable var host: GameHostController
    var onClose: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    @State private var starterFlipAngle: Double = 0
    @State private var starterFaceUp = false
    @State private var pegCallout: String?

    @State private var showWalkthrough = false
    @State private var walkthroughLines: [WalkLine] = []
    @State private var visibleWalkCount = 0

    private struct WalkLine: Identifiable {
        let id = UUID()
        let text: String
        let isHeader: Bool
    }

    var body: some View {
        // Tracked read: every cribbage mutation bumps this, every bump
        // redraws the felt (same rule TableGameView follows for `engine`).
        let _ = host.stateVersion
        return GeometryReader { geo in
            if let engine = host.cribbageEngine {
                let state = engine.state
                ZStack {
                    seatPlates(state: state, size: geo.size)
                    pegboard(state: state, size: geo.size)
                    deckAndStarter(state: state, size: geo.size)
                    peggingArea(state: state, size: geo.size)
                    cribPile(state: state, size: geo.size)
                    if let banner = bannerText(state: state) {
                        TableBanner(text: banner)
                            .zIndex(10)
                    }
                    if showWalkthrough {
                        showWalkthroughOverlay(state: state, size: geo.size)
                            .zIndex(10)
                    }
                    if state.phase == .gameOver {
                        gameOverOverlay(state: state)
                            .zIndex(10)
                    }
                    // GameHUD's own two-step exit (tap to arm "Sure?", tap
                    // again to confirm) is the whole close affordance here
                    // — no separate hold-to-close dial, unlike
                    // TableGameView's felt (which needs a second,
                    // dead-felt-tap path since its HUD competes with a lot
                    // more surface).
                    GameHUD(title: "Cribbage", onExit: { onClose?() }, toggles: [])
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(10)
                }
                .onChange(of: host.stateVersion) { _, _ in
                    // Autosave, 2s after the last mutation (ResumeCatalog).
                    CribbageSave.noteChanged(host: host)
                }
                .onChange(of: host.cribbageRecentEvents) { _, events in
                    handle(events, state: host.cribbageEngine?.state ?? state)
                }
                .onChange(of: state.phase) { old, new in
                    guard old == .handComplete, new != .handComplete else { return }
                    showWalkthrough = false
                }
            }
        }
    }

    // MARK: seat plates + rail hands

    private func outwardAngle(_ p: CGPoint) -> Angle { p.y > 0.5 ? .degrees(0) : .degrees(180) }

    private func seatPlates(state: CribbageState, size: CGSize) -> some View {
        let anchors = TableGeometry.seatAnchors(count: 2)
        let railCardWidth = TableGeometry.tableCardWidth(for: size) * 0.88
        return ForEach([0, 1], id: \.self) { seat in
            let anchor = anchors[seat]
            VStack(spacing: 2) {
                CribbageSeatPlateView(
                    name: host.cribbageSeatNames[seat] ?? "Seat \(seat + 1)",
                    colorIndex: seat,
                    isDealer: state.dealerSeat == seat,
                    isTurn: state.phase == .pegging && state.pegging?.turnSeat == seat,
                    score: state.scores[seat] ?? 0,
                    edgeAngle: outwardAngle(anchor))
                RailHandFan(count: state.hands[seat]?.count ?? 0, cardWidth: railCardWidth)
            }
            .rotationEffect(outwardAngle(anchor))
            .position(x: anchor.x * size.width, y: anchor.y * size.height)
            .zIndex(1)
        }
    }

    // MARK: pegboard

    private func pegboard(state: CribbageState, size: CGSize) -> some View {
        // Centered a touch right of true middle, with a capped, slightly
        // narrower width than the felt's full 0.66 share — leaves clear
        // room on the left for the deck + starter (and the score-0 peg
        // position, which sits just left of hole 1) without the two
        // overlapping.
        let width = min(size.width * 0.56, 660)
        return CribbagePegBoardView(scores: state.scores, reduceMotion: motionReduced)
            .frame(width: width)
            .position(x: size.width * 0.58, y: size.height * 0.5)
    }

    // MARK: deck + starter cut

    private func deckAndStarter(state: CribbageState, size: CGSize) -> some View {
        let cardWidth = TableGeometry.tableCardWidth(for: size)
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                CardView(card: Card(id: "cribdeck\(i)", kind: .standard(suit: .spades, rank: 2)), faceUp: false)
                    .frame(width: cardWidth)
                    .offset(x: CGFloat(i) * 1.5, y: -CGFloat(i) * 1.5)
            }
            if let starter = state.starter {
                CardView(card: starter, faceUp: starterFaceUp)
                    .frame(width: cardWidth)
                    .rotation3DEffect(.degrees(starterFlipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                    .offset(x: cardWidth * 1.0)
                    .accessibilityLabel(starterFaceUp ? "Starter: \(starter.accessibleName)" : "Starter, about to cut")
            }
        }
        .position(x: size.width * 0.085, y: size.height * 0.5)
    }

    private func flipStarter() {
        starterFaceUp = false
        starterFlipAngle = 0
        Haptics.tick()
        if motionReduced {
            TableSFX.shared.play(.cardFlip)
            starterFaceUp = true
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { starterFlipAngle = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            TableSFX.shared.play(.cardFlip)
            starterFaceUp = true
            starterFlipAngle = -90
            withAnimation(.easeOut(duration: 0.22)) { starterFlipAngle = 0 }
        }
    }

    // MARK: pegging area

    private func peggingArea(state: CribbageState, size: CGSize) -> some View {
        let cardWidth = TableGeometry.tableCardWidth(for: size) * 0.9
        let sequence = state.pegging?.sequence ?? []
        return VStack(spacing: 10) {
            HStack(spacing: -cardWidth * 0.45) {
                ForEach(Array(sequence.enumerated()), id: \.element.card.id) { index, play in
                    CardView(card: play.card, faceUp: true)
                        .frame(width: cardWidth)
                        .rotationEffect(.degrees(TableGeometry.jitterDegrees(cardID: play.card.id) * 0.6))
                        .zIndex(Double(index))
                        .transition(.asymmetric(
                            insertion: .offset(y: -30).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .frame(minHeight: cardWidth * 1.45)
            if state.phase == .pegging {
                Text("\(state.pegging?.count ?? 0)")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(CardStyle.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(.black.opacity(0.45))
                            .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1))
                    )
                    .accessibilityLabel("Count: \(state.pegging?.count ?? 0)")
            }
            if let pegCallout {
                Text(pegCallout)
                    .font(.system(.largeTitle, design: .serif).weight(.heavy))
                    .foregroundStyle(CardStyle.gold)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sequence.map(\.card.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pegCallout)
        .position(x: size.width * 0.5, y: size.height * 0.72)
    }

    // MARK: crib

    @ViewBuilder
    private func cribPile(state: CribbageState, size: CGSize) -> some View {
        if state.crib.count == 4 {
            let anchors = TableGeometry.seatAnchors(count: 2)
            let dealerAnchor = anchors[state.dealerSeat]
            let inward = CGPoint(x: dealerAnchor.x + (0.5 - dealerAnchor.x) * 0.42,
                                 y: dealerAnchor.y + (0.5 - dealerAnchor.y) * 0.42)
            // The crib stays secret until the show even though the table
            // technically has the data — same redaction rule the phones'
            // snapshot follows, honored here on purpose.
            let revealed = state.phase == .handComplete || state.phase == .gameOver
            let cardWidth = TableGeometry.tableCardWidth(for: size) * 0.75
            ZStack {
                ForEach(Array(state.crib.enumerated()), id: \.element.id) { i, card in
                    CardView(card: card, faceUp: revealed)
                        .frame(width: cardWidth)
                        .rotationEffect(.degrees(Double(i) * 4 - 6))
                        .offset(x: CGFloat(i) * 3, y: CGFloat(i) * -2)
                }
                Text("Crib")
                    .font(.system(.caption, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold.opacity(0.85))
                    .offset(y: cardWidth * 0.85)
            }
            .position(x: inward.x * size.width, y: inward.y * size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(revealed ? "Crib, revealed" : "Crib, 4 cards, face down")
        }
    }

    // MARK: banner narration

    private func bannerText(state: CribbageState) -> String? {
        switch state.phase {
        case .discarding:
            let waitingOn = [0, 1].filter { !state.discardsSubmitted.contains($0) }
            guard !waitingOn.isEmpty else { return nil } // completeCribAndCut fires same tick
            let names = waitingOn.map { host.cribbageSeatNames[$0] ?? "Seat \($0 + 1)" }
            return "Waiting on \(names.joined(separator: " and ")) to discard to the crib…"
        case .pegging:
            guard let turn = state.pegging?.turnSeat else { return nil }
            return "\(host.cribbageSeatNames[turn] ?? "Seat \(turn + 1)") to play…"
        case .handComplete, .gameOver:
            return nil // the paper / recap panel speaks for itself
        }
    }

    // MARK: event reactions

    private func handle(_ events: [CribbageEvent], state: CribbageState) {
        for event in events {
            switch event {
            case .starterCut:
                flipStarter()
            case .cardPlayed:
                TableSFX.shared.play(.cardSlide, intensity: 0.6)
            case .pointsScored(_, let reason, _):
                if let text = calloutText(reason) {
                    pegCallout = text
                    TableSFX.shared.play(reason == .thirtyOne ? .cardFlip : .cardSlide, intensity: 0.85)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if pegCallout == text { pegCallout = nil }
                    }
                }
            case .gameWon:
                TableSFX.shared.play(.fanfareWin)
            case .dealt:
                starterFaceUp = false
                starterFlipAngle = 0
                pegCallout = nil
            default:
                break
            }
        }
        if events.contains(where: { if case .handCounted = $0 { return true }; return false }) {
            startWalkthrough(events)
        }
    }

    private func calloutText(_ reason: CribbageScoreReason) -> String? {
        switch reason {
        case .go: return "GO"
        case .thirtyOne: return "31!"
        case .lastCard: return "LAST CARD"
        default: return nil
        }
    }

    // MARK: the show — paper scorecard walkthrough

    private func startWalkthrough(_ events: [CribbageEvent]) {
        let lines = buildWalkthrough(from: events)
        guard !lines.isEmpty else { return }
        walkthroughLines = lines
        visibleWalkCount = 0
        showWalkthrough = true
        let stagger = motionReduced ? 0.3 : 0.85
        for i in 0..<lines.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stagger) {
                visibleWalkCount = i + 1
                if !lines[i].isHeader { Haptics.tick() }
            }
        }
    }

    private func buildWalkthrough(from events: [CribbageEvent]) -> [WalkLine] {
        var lines: [WalkLine] = []
        for event in events {
            guard case .handCounted(let seat, let source, let points, let breakdown) = event else { continue }
            let who: String
            switch source {
            case .hand: who = (host.cribbageSeatNames[seat] ?? "Seat \(seat + 1)") + "'s hand"
            case .crib: who = "The crib"
            }
            lines.append(WalkLine(text: who, isHeader: true))
            if breakdown.isEmpty {
                lines.append(WalkLine(text: "Nineteen — nothing there.", isHeader: false))
            } else {
                for entry in breakdown {
                    lines.append(WalkLine(text: classicPhrase(for: entry), isHeader: false))
                }
                lines.append(WalkLine(text: "= \(points)", isHeader: false))
            }
        }
        return lines
    }

    /// The classic counting cadence — "fifteen two, fifteen four…", "a
    /// pair for six", "a run of four for four" — built from the aggregate
    /// breakdown entry (one per category) rather than replaying individual
    /// combinations, which `CribbageScoring` doesn't expose separately.
    private func classicPhrase(for entry: CribbageScoreEntry) -> String {
        switch entry.reason {
        case .fifteen, .showFifteen:
            let n = max(1, entry.points / 2)
            return (1...n).map { "fifteen \($0 * 2)" }.joined(separator: ", ")
        case .pair, .showPair:
            switch entry.points {
            case 6: return "three of a kind for six"
            case 12: return "four of a kind for twelve"
            default: return "a pair for \(entry.points)"
            }
        case .run(let length), .showRun(let length):
            let combos = length > 0 ? entry.points / length : 1
            let multiple = combos == 2 ? "a double run" : (combos == 3 ? "a triple run" : (combos >= 4 ? "a double-double run" : "a run"))
            return "\(multiple) of \(length) for \(entry.points)"
        case .flush(let count):
            return "a flush of \(count) for \(entry.points)"
        case .nobs:
            return "his nobs for one"
        case .heels:
            return "two for his heels"
        case .go:
            return "go, for one"
        case .thirtyOne:
            return "thirty-one for two"
        case .lastCard:
            return "last card for one"
        }
    }

    private func showWalkthroughOverlay(state: CribbageState, size: CGSize) -> some View {
        VStack(spacing: 16) {
            Text("The Count")
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.ink)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(walkthroughLines.prefix(visibleWalkCount).enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(line.isHeader ? .title3 : .body, design: .serif)
                            .weight(line.isHeader ? .bold : .regular))
                        .foregroundStyle(CardStyle.ink.opacity(line.isHeader ? 1 : 0.82))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            if visibleWalkCount >= walkthroughLines.count, state.phase == .handComplete {
                Button {
                    Haptics.arm()
                    host.cribbageAdvance()
                } label: {
                    Text("Deal the next hand")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                .transition(.opacity)
            }
        }
        .padding(26)
        .frame(maxWidth: 420)
        .background(
            Image("PaperGraph")
                .resizable()
                .scaledToFill()
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.black.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
        .animation(.easeOut(duration: 0.3), value: visibleWalkCount)
        .position(x: size.width * 0.80, y: size.height * 0.52)
        .accessibilityElement(children: .contain)
    }

    // MARK: game over

    private func gameOverOverlay(state: CribbageState) -> some View {
        let winner = state.winnerSeat ?? 0
        let loser = 1 - winner
        func name(_ seat: Int) -> String { host.cribbageSeatNames[seat] ?? "Seat \(seat + 1)" }
        let rows = [winner, loser].map { seat in
            RecapRow(id: seat, name: name(seat), colorIndex: seat, score: "\(state.scores[seat] ?? 0)",
                     detail: seat == state.dealerSeat ? "dealt the last hand" : nil, isWinner: seat == winner)
        }
        let margin = (state.scores[winner] ?? 0) - (state.scores[loser] ?? 0)
        let hands = max(1, state.handNumber)
        let highlight = (state.skunk ?? false)
            ? "A skunk! \(name(loser)) never reached 91"
            : "Pegged out \(margin) ahead over \(hands) hand\(hands == 1 ? "" : "s")"
        return GameRecapCard(title: "\(name(winner)) wins the crib", rows: rows, highlight: highlight,
                             onRematch: { host.restartCribbage() }, onDone: { onClose?() })
    }
}
