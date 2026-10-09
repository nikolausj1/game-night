import SwiftUI

/// The shared felt for Gin Rummy: stock and discard pile in the middle, each
/// seat's plate and rail-held hand, a serif ledger of the public moves on the
/// left, and a paper score pad on the right. At the knock both hands are laid
/// face up in meld groups with the deadwood circled in pencil, the points
/// travel onto the pad, and an undercut gets its moment. The host deals the
/// next hand on its own after the beat; a tap deals it sooner.
///
/// Mounted by the `SideGameRegistry` (kind `ginRummy`). Reads `GinRummyHost`
/// through `host.sideGame`; the table never sees a phone's cards.
struct GinRummyTableView: View {
    @Bindable var host: GameHostController
    var onClose: (() -> Void)? = nil

    var body: some View {
        // Tracked read: every side-game mutation bumps this, every bump redraws.
        let _ = host.stateVersion
        if let gin = host.sideGame as? GinRummyHost {
            GinRummyTableContent(
                feed: GinTableFeed(
                    snapshot: gin.tableSnapshot,
                    names: [0: gin.name(0), 1: gin.name(1)],
                    botSeats: Set([0, 1].filter { gin.isBot($0) }),
                    rows: gin.scoreRows,
                    eventSeq: gin.eventSeq,
                    events: gin.recentEvents),
                advance: { gin.tableAdvance() },
                rematch: { host.restartSideGame() },
                onClose: { onClose?() })
            .id(ObjectIdentifier(gin))
        }
    }
}

/// Everything the table draws, as plain values (so previews can feed it).
struct GinTableFeed {
    var snapshot: GinRummyTableSnapshot
    var names: [Int: String]
    var botSeats: Set<Int>
    var rows: [GinScoreRow]
    var eventSeq: Int
    var events: [GinRummyEvent]

    func name(_ seat: Int) -> String { names[seat].flatMap { $0.isEmpty ? nil : $0 } ?? GinSeat.fallbackName(seat) }
}

struct GinRummyTableContent: View {
    let feed: GinTableFeed
    var advance: () -> Void = {}
    var rematch: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Showdown choreography flags (all driven by `after`, cancelled on a new hand).
    @State private var knockerFlipped = false
    @State private var defenderVisible = false
    @State private var defenderFlipped = false
    @State private var circlesShown = false
    @State private var callout: Callout?
    @State private var padRows = 0
    @State private var padScores: [Int: Int] = [:]
    @State private var settled = false
    @State private var gameOverShown = false
    @State private var laidOffIDs: Set<String> = []
    @State private var chip: PointsChip?
    @State private var chipAtPad = false
    @State private var fliers: [Flier] = []
    @State private var underCard: Card?
    @State private var work: [DispatchWorkItem] = []
    @State private var lastSeq = -1

    private struct Callout: Equatable {
        let text: String
        let sub: String?
        let hot: Bool
    }

    private struct PointsChip: Equatable {
        let text: String
        let from: CGPoint
        let to: CGPoint
    }

    private struct Flier: Identifiable {
        let id = UUID()
        let card: Card?
        let from: CGPoint
        let to: CGPoint
        let width: CGFloat
    }

    private var snap: GinRummyTableSnapshot { feed.snapshot }
    private var scoring: Bool { snap.phase == .handComplete || snap.phase == .gameOver }

    // MARK: layout

    private struct Metrics {
        let size: CGSize
        var pileCW: CGFloat { TableGeometry.tableCardWidth(for: size) }
        var centerX: CGFloat { size.width * 0.49 }
        var pileY: CGFloat { size.height * 0.5 }
        var stockPos: CGPoint { CGPoint(x: centerX - pileCW * 0.68, y: pileY) }
        var discardPos: CGPoint { CGPoint(x: centerX + pileCW * 0.68, y: pileY) }
        func handPos(_ seat: Int) -> CGPoint { CGPoint(x: size.width * 0.47, y: size.height * (seat == 0 ? 0.775 : 0.225)) }
        var handCW: CGFloat { min(pileCW * 0.72, size.width * 0.56 / 7.6) }
        var handMaxWidth: CGFloat { size.width * 0.58 }
        var sideWidth: CGFloat { max(150, size.width * 0.20) }
        var sideHeight: CGFloat { min(size.height * 0.52, size.width > size.height ? 470 : size.height * 0.34) }
        var padPos: CGPoint { CGPoint(x: size.width - sideWidth / 2 - 14, y: size.height * 0.5) }
        var ledgerPos: CGPoint { CGPoint(x: sideWidth / 2 + 14, y: size.height * 0.5) }
        func seatPos(_ seat: Int) -> CGPoint {
            let a = TableGeometry.seatAnchors(count: 2)[seat]
            return CGPoint(x: a.x * size.width, y: a.y * size.height)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack {
                ledger(m)
                piles(m)
                handRows(m)
                seatPlates(m)
                pad(m)
                ForEach(fliers) { flier in
                    GinFlight(card: flier.card, width: flier.width, from: flier.from, to: flier.to,
                              reduceMotion: reduceMotion)
                        .zIndex(8)
                }
                if let chip {
                    Text(chip.text)
                        .font(.system(.title, design: .serif).weight(.heavy))
                        .foregroundStyle(CardStyle.gold)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .position(chipAtPad ? chip.to : chip.from)
                        .opacity(chipAtPad ? 0.2 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: chipAtPad)
                        .zIndex(9)
                }
                if let callout {
                    calloutView(callout)
                        .position(x: m.size.width * 0.49, y: m.size.height * 0.5)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .zIndex(10)
                }
                if settled, snap.phase == .handComplete {
                    Button {
                        Haptics.arm()
                        advance()
                    } label: {
                        Text("Deal the next hand")
                            .font(.system(.headline, design: .serif).weight(.bold))
                            .padding(.horizontal, 22).padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                    .position(x: m.size.width * 0.49, y: m.size.height * 0.64)
                    .transition(.opacity)
                    .zIndex(9)
                }
                if gameOverShown, snap.phase == .gameOver, let game = snap.gameResult {
                    gameOverPanel(game)
                        .position(x: m.size.width * 0.5, y: m.size.height * 0.5)
                        .zIndex(20)
                }
                GameHUD(title: "Gin Rummy", onExit: onClose, toggles: [])
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(30)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: callout)
            .animation(.easeOut(duration: 0.3), value: settled)
            .onAppear { syncToState(m) }
            .onChange(of: feed.eventSeq) { _, seq in
                guard seq != lastSeq else { return }
                lastSeq = seq
                handle(feed.events, m)
            }
            .onChange(of: snap.discardPile.last) { old, new in
                // Keep the card that was on top visible under the one landing on it.
                if let old, let new, old != new, snap.discardPile.count > 1,
                   snap.discardPile.dropLast().last == old {
                    underCard = old
                    after(0.6) { underCard = nil }
                } else {
                    underCard = nil
                }
            }
        }
        .onDisappear { cancelWork() }
    }

    // MARK: seats

    private func outwardAngle(_ seat: Int) -> Angle { seat == 0 ? .degrees(0) : .degrees(180) }

    private func seatPlates(_ m: Metrics) -> some View {
        let railWidth = TableGeometry.tableCardWidth(for: m.size) * 0.88
        return ForEach([0, 1], id: \.self) { seat in
            let name = feed.name(seat)
            let hidden = revealed(seat: seat)
            VStack(spacing: 2) {
                CribbageSeatPlateView(
                    name: name,
                    colorIndex: GinSeat.colorIndex(name: name, seat: seat),
                    isDealer: snap.dealerSeat == seat,
                    isTurn: !scoring && snap.turnSeat == seat,
                    score: padScores[seat] ?? snap.scores[seat] ?? 0,
                    edgeAngle: outwardAngle(seat))
                RailHandFan(count: hidden ? 0 : (snap.handCounts[seat] ?? 0), cardWidth: railWidth)
            }
            .rotationEffect(outwardAngle(seat))
            .position(m.seatPos(seat))
            .zIndex(1)
        }
    }

    /// Whether a seat's cards are laid face up (so the rail fan empties).
    private func revealed(seat: Int) -> Bool {
        if let knock = snap.knock, knock.knockerSeat == seat { return true }
        if scoring, snap.lastResult?.outcome != .drawn, snap.lastResult?.knockerSeat != seat { return defenderVisible }
        return false
    }

    // MARK: piles

    private func piles(_ m: Metrics) -> some View {
        let cw = m.pileCW
        return ZStack {
            // Stock
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    CardView(card: Card(id: "ginstock\(i)", kind: .standard(suit: .spades, rank: 2)), faceUp: false)
                        .frame(width: cw)
                        .offset(x: CGFloat(i) * 1.4, y: -CGFloat(i) * 1.6)
                        .opacity(snap.stockCount > i * 3 ? 1 : 0)
                }
                stockChip
                    .offset(y: cw * 0.70 + 22)
            }
            .position(m.stockPos)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stock, \(snap.stockCount) cards")

            // Discard pile: a few backs for thickness, the previous top while a
            // new one lands, then the top card face up.
            ZStack {
                ForEach(Array(snap.discardPile.dropLast().suffix(3).enumerated()), id: \.element.id) { i, card in
                    CardView(card: card, faceUp: false)
                        .frame(width: cw)
                        .rotationEffect(.degrees(TableGeometry.jitterDegrees(cardID: card.id) * 0.7))
                        .offset(x: CGFloat(i) * 1.2, y: CGFloat(i) * -1.2)
                }
                if let underCard {
                    CardView(card: underCard, faceUp: true)
                        .frame(width: cw)
                        .rotationEffect(.degrees(TableGeometry.jitterDegrees(cardID: underCard.id) * 0.9))
                }
                if let top = snap.discardPile.last {
                    GinDiscardTop(card: top, width: cw, from: landingOffset(for: top, m),
                                  rotation: TableGeometry.jitterDegrees(cardID: top.id) * 0.9,
                                  reduceMotion: reduceMotion)
                        .id(top.id)
                        .accessibilityLabel("Discard pile, top card \(top.accessibleName)")
                }
            }
            .position(m.discardPos)
            Text("Discard")
                .font(.system(.caption, design: .serif).weight(.bold))
                .tracking(2)
                .foregroundStyle(CardStyle.gold.opacity(0.7))
                .position(x: m.discardPos.x, y: m.discardPos.y + cw * 0.70 + 22)
            Text("Stock")
                .font(.system(.caption, design: .serif).weight(.bold))
                .tracking(2)
                .foregroundStyle(CardStyle.gold.opacity(0.7))
                .position(x: m.stockPos.x, y: m.stockPos.y - cw * 0.70 - 18)
        }
        .opacity(scoring ? 0.5 : 1)
        .animation(.easeOut(duration: 0.4), value: scoring)
    }

    private var stockChip: some View {
        let low = snap.stockCount <= 6
        return Text("\(snap.stockCount)")
            .font(.system(.callout, design: .serif).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(low ? Color(red: 1, green: 0.72, blue: 0.66) : CardStyle.gold)
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(
                Capsule().fill(.black.opacity(0.45))
                    .overlay(Capsule().strokeBorder((low ? CardStyle.crimson : CardStyle.gold).opacity(0.55), lineWidth: 1))
            )
            .contentTransition(.numericText(value: Double(snap.stockCount)))
            .animation(.easeOut(duration: 0.3), value: snap.stockCount)
    }

    /// Where a freshly discarded card comes from, relative to its rest spot.
    private func landingOffset(for card: Card, _ m: Metrics) -> CGSize? {
        if let move = snap.moves.last(where: {
            if case .discarded(let c) = $0.kind { return c == card }
            return false
        }) {
            let from = m.seatPos(move.seat)
            return CGSize(width: (from.x - m.discardPos.x) * 0.8, height: (from.y - m.discardPos.y) * 0.8)
        }
        if snap.moves.isEmpty, snap.discardPile.count == 1 {
            // The opening upcard is turned over off the stock.
            return CGSize(width: m.stockPos.x - m.discardPos.x, height: 0)
        }
        return nil
    }

    // MARK: revealed hands

    @ViewBuilder
    private func handRows(_ m: Metrics) -> some View {
        if let knock = snap.knock {
            let seat = knock.knockerSeat
            row(m, seat: seat, melds: knock.melds, deadwood: knock.deadwood, points: knock.deadwoodPoints,
                flipped: knockerFlipped, showCircle: circlesShown && scoring)
        }
        if scoring, let r = snap.lastResult, r.outcome != .drawn, let knocker = r.knockerSeat, defenderVisible {
            row(m, seat: 1 - knocker, melds: r.defenderMelds, deadwood: r.defenderDeadwood,
                points: r.defenderDeadwoodPoints, flipped: defenderFlipped, showCircle: circlesShown)
        }
    }

    private func row(_ m: Metrics, seat: Int, melds: [GinMeld], deadwood: [Card], points: Int,
                     flipped: Bool, showCircle: Bool) -> some View {
        let cw = m.handCW
        func hand(_ scale: CGFloat) -> some View {
            GinRevealedHand(melds: melds, deadwood: deadwood, laidOffIDs: laidOffIDs,
                            cardWidth: cw * scale, flipped: flipped, showDeadwoodCircle: showCircle,
                            deadwoodPoints: points, reduceMotion: reduceMotion)
        }
        return ViewThatFits(in: .horizontal) {
            hand(1.0)
            hand(0.86)
            hand(0.72)
            hand(0.6)
        }
        .frame(maxWidth: m.handMaxWidth)
        .position(m.handPos(seat))
        .transition(.opacity)
        .zIndex(2)
    }

    // MARK: ledger

    private func ledger(_ m: Metrics) -> some View {
        let moves = Array(snap.moves.suffix(8))
        return VStack(alignment: .leading, spacing: 7) {
            Text("HAND \(snap.handNumber)")
                .font(.system(.caption, design: .serif).weight(.bold))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
            Text(statusLine)
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(CardStyle.stockTop.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(CardStyle.gold.opacity(0.35)).frame(height: 1)
            if moves.isEmpty {
                Text("\(feed.name(snap.dealerSeat)) deals")
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.8))
            }
            ForEach(Array(moves.enumerated()), id: \.offset) { index, move in
                Text(GinText.ledgerLine(move, name: feed.name(move.seat), onDark: true))
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(CardStyle.stockTop)
                    .opacity(0.38 + 0.62 * Double(index + 1) / Double(moves.count))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: m.sideWidth, height: m.sideHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.18), lineWidth: 1))
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: snap.moves.count)
        .position(m.ledgerPos)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Move ledger. \(statusLine)")
    }

    /// Both seats passed the opening upcard and nothing has covered it yet
    /// (the table snapshot doesn't carry the flag; the public move log does).
    private var upcardRefused: Bool {
        snap.phase == .draw
            && snap.moves.filter { if case .passedUpcard = $0.kind { return true }; return false }.count >= 2
            && !snap.moves.contains { if case .discarded = $0.kind { return true }; return false }
    }

    private var statusLine: String {
        let turn = feed.name(snap.turnSeat)
        switch snap.phase {
        case .firstUpcard: return "\(turn) may take the upcard, or pass."
        case .draw: return upcardRefused ? "\(turn) must draw from the stock." : "\(turn) to draw."
        case .discard: return "\(turn) to discard."
        case .layoff: return "\(turn) may lay off on \(feed.name(snap.knock?.knockerSeat ?? 0))'s melds."
        case .handComplete: return snap.lastResult?.outcome == .drawn ? "The stock ran out." : "Counting up."
        case .gameOver: return "Game over."
        }
    }

    // MARK: score pad

    private func pad(_ m: Metrics) -> some View {
        let rows = Array(feed.rows.prefix(padRows).suffix(9))
        return ZStack {
            Image("PaperGraph")
                .resizable()
                .scaledToFill()
            VStack(spacing: 8) {
                Text("Gin")
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.ink)
                HStack(spacing: 0) {
                    ForEach([0, 1], id: \.self) { seat in
                        VStack(spacing: 3) {
                            Circle()
                                .fill(PlayerPalette.color(GinSeat.colorIndex(name: feed.name(seat), seat: seat)))
                                .frame(width: 10, height: 10)
                            Text(feed.name(seat))
                                .font(.system(.footnote, design: .serif).weight(.bold))
                                .foregroundStyle(CardStyle.ink)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Rectangle().fill(CardStyle.ink.opacity(0.7)).frame(height: 1.5)
                VStack(spacing: 5) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            ForEach([0, 1], id: \.self) { seat in
                                padCell(row, seat: seat)
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: -8)))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: padRows)
                Spacer(minLength: 0)
                Rectangle().fill(CardStyle.ink.opacity(0.7)).frame(height: 1.5)
                Rectangle().fill(CardStyle.ink.opacity(0.7)).frame(height: 1.5).padding(.top, -6)
                HStack(spacing: 0) {
                    ForEach([0, 1], id: \.self) { seat in
                        let total = padScores[seat] ?? snap.scores[seat] ?? 0
                        Text("\(total)")
                            .font(.system(.title, design: .serif).weight(.heavy))
                            .monospacedDigit()
                            .foregroundStyle(CardStyle.ink)
                            .contentTransition(.numericText(value: Double(total)))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: total)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 0) {
                    ForEach([0, 1], id: \.self) { seat in
                        HStack(spacing: 3) {
                            ForEach(0..<min(snap.handsWon[seat] ?? 0, 6), id: \.self) { _ in
                                Capsule().fill(CardStyle.ink.opacity(0.75)).frame(width: 3, height: 11)
                            }
                            if (snap.handsWon[seat] ?? 0) == 0 {
                                Text("no hands yet")
                                    .font(.system(size: 9, design: .serif).italic())
                                    .foregroundStyle(CardStyle.ink.opacity(0.45))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .frame(width: m.sideWidth, height: m.sideHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .rotationEffect(.degrees(1.2))
        .position(m.padPos)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Score pad. \(feed.name(0)) \(padScores[0] ?? snap.scores[0] ?? 0), \(feed.name(1)) \(padScores[1] ?? snap.scores[1] ?? 0)")
    }

    private func padCell(_ row: GinScoreRow, seat: Int) -> some View {
        let mine = row.winnerSeat == seat
        return HStack(spacing: 3) {
            if mine {
                Text("\(row.points)")
                    .font(.system(.body, design: .serif).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(CardStyle.ink)
                if row.outcome == .gin || row.outcome == .undercut {
                    Text(row.outcome == .gin ? "G" : "U")
                        .font(.system(size: 9, weight: .heavy, design: .serif))
                        .foregroundStyle(CardStyle.crimson)
                        .baselineOffset(7)
                }
            } else if row.outcome == .drawn && seat == 0 {
                Text("drawn")
                    .font(.system(size: 10, design: .serif).italic())
                    .foregroundStyle(CardStyle.ink.opacity(0.5))
            } else {
                Text(" ")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: callouts

    private func calloutView(_ c: Callout) -> some View {
        VStack(spacing: 6) {
            Text(c.text)
                .font(.system(size: 54, weight: .heavy, design: .serif))
                .tracking(c.text.count > 9 ? 1 : 4)
                .foregroundStyle(c.hot ? Color(red: 1, green: 0.78, blue: 0.70) : CardStyle.gold)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let sub = c.sub {
                Text(sub)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.92))
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder((c.hot ? CardStyle.crimson : CardStyle.gold).opacity(0.65), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        )
        .accessibilityElement(children: .combine)
    }

    private func gameOverPanel(_ game: GinGameResult) -> some View {
        let winner = game.winnerSeat
        let loser = 1 - winner
        let rows = [winner, loser].map { seat in
            RecapRow(id: seat, name: feed.name(seat),
                     colorIndex: GinSeat.colorIndex(name: feed.name(seat), seat: seat),
                     score: "\(game.finalTotals[seat] ?? 0)",
                     detail: "\(game.handScores[seat] ?? 0) hand points · \(game.handsWon[seat] ?? 0) hands won · box +\(game.boxBonus[seat] ?? 0)",
                     isWinner: seat == winner)
        }
        let hands = max(1, feed.snapshot.handNumber)
        let highlight = game.shutout
            ? "A shutout: \(feed.name(loser)) never won a hand, game bonus doubled to \(game.gameBonus)"
            : "Took \(game.handsWon[winner] ?? 0) of \(hands) hands, game bonus \(game.gameBonus)"
        return GameRecapCard(title: "\(feed.name(winner)) wins Gin Rummy", rows: rows, highlight: highlight,
                             onRematch: { rematch() }, onDone: { onClose() })
    }

    // MARK: event choreography

    private func handle(_ events: [GinRummyEvent], _ m: Metrics) {
        for event in events {
            switch event {
            case .dealt:
                resetHandState()
                TableSFX.shared.play(.cardDeal)
            case .upcardPassed:
                break
            case .drewStock(let seat):
                TableSFX.shared.play(.cardSlide, intensity: 0.5)
                launch(card: nil, from: m.stockPos, to: m.seatPos(seat), width: m.pileCW)
            case .tookUpcard(let seat, let card):
                TableSFX.shared.play(.cardFlip)
                launch(card: card, from: m.discardPos, to: m.seatPos(seat), width: m.pileCW)
            case .discarded:
                TableSFX.shared.play(.cardSlide, intensity: 0.7)
            case .knocked(let seat, let info):
                TableSFX.shared.play(.tableKnock)
                Haptics.arm()
                showCallout(Callout(text: info.isGin ? "GIN!" : "KNOCK!",
                                    sub: "\(feed.name(seat)) · deadwood \(info.deadwoodPoints)", hot: false), for: 1.8)
                after(0.35) { knockerFlipped = true }
            case .laidOff(_, let card, _):
                TableSFX.shared.play(.cardSlide, intensity: 0.5)
                laidOffIDs.insert(card.id)
            case .showdown(let result):
                playShowdown(result, m)
            case .handDrawn:
                showCallout(Callout(text: "NO SCORE", sub: "The stock ran out. Hand \(snap.handNumber) is drawn.", hot: false), for: 2.6)
                padRows = feed.rows.count
                padScores = snap.scores
                settled = true
            case .gameWon:
                TableSFX.shared.play(.fanfareWin)
            case .illegalAttempt:
                break
            }
        }
    }

    private func playShowdown(_ result: GinHandResult, _ m: Metrics) {
        let s = reduceMotion ? 0.35 : 1.0
        let winner = result.winnerSeat
        let knocker = result.knockerSeat ?? 0
        if !knockerFlipped { after(0.2 * s) { knockerFlipped = true } }
        after(0.9 * s) { defenderVisible = true }
        after(1.3 * s) { defenderFlipped = true; TableSFX.shared.play(.cardFlip, intensity: 0.8) }
        after(2.7 * s) { circlesShown = true; TableSFX.shared.play(.cardSlide, intensity: 0.4) }
        after(3.9 * s) {
            switch result.outcome {
            case .gin:
                showCallout(Callout(text: "GIN!", sub: "\(feed.name(knocker)) goes out · 25 bonus + \(result.deadwoodDifference)", hot: false), for: 2.4)
            case .knock:
                showCallout(Callout(text: "\(result.knockerDeadwoodPoints) beats \(result.defenderDeadwoodPoints)",
                                    sub: "\(feed.name(knocker)) wins the hand by \(result.deadwoodDifference)", hot: false), for: 2.2)
            case .undercut:
                TableSFX.shared.play(.tableKnock, intensity: 1)
                showCallout(Callout(text: "UNDERCUT!",
                                    sub: "\(feed.name(1 - knocker)) takes it · 25 bonus + \(result.deadwoodDifference)", hot: true), for: 3.0)
            case .drawn:
                break
            }
        }
        after(5.0 * s) {
            guard let winner else { return }
            let from = m.handPos(winner)
            let to = CGPoint(x: m.padPos.x, y: m.padPos.y + m.sideHeight * 0.30)
            chip = PointsChip(text: "+\(result.points)", from: from, to: to)
            chipAtPad = false
            DispatchQueue.main.async { chipAtPad = true }
            after(0.8) {
                chip = nil
                chipAtPad = false
            }
            after(0.7) {
                withAnimation { padRows = feed.rows.count }
                padScores = result.scoresAfter
                TableSFX.shared.play(.softChime)
            }
        }
        after(6.4 * s) {
            settled = true
            if snap.phase == .gameOver { after(0.9) { gameOverShown = true } }
        }
    }

    private func showCallout(_ c: Callout, for seconds: Double) {
        callout = c
        after(seconds) { if callout == c { callout = nil } }
    }

    private func launch(card: Card?, from: CGPoint, to: CGPoint, width: CGFloat) {
        guard !reduceMotion else { return }
        let flier = Flier(card: card, from: from, to: to, width: width)
        fliers.append(flier)
        after(0.6) { fliers.removeAll { $0.id == flier.id } }
    }

    private func resetHandState() {
        cancelWork()
        knockerFlipped = false
        defenderVisible = false
        defenderFlipped = false
        circlesShown = false
        callout = nil
        settled = false
        gameOverShown = false
        laidOffIDs = []
        chip = nil
        chipAtPad = false
        padRows = feed.rows.count
        padScores = snap.scores
    }

    /// Mounting mid-hand (or re-mounting after a hiccup): jump straight to the
    /// state the choreography would have reached, no replay.
    private func syncToState(_ m: Metrics) {
        lastSeq = feed.eventSeq
        padRows = feed.rows.count
        padScores = snap.scores
        laidOffIDs = Set(snap.layoffs.map(\.card.id))
        if snap.knock != nil { knockerFlipped = true }
        if scoring {
            if snap.lastResult?.outcome != .drawn {
                defenderVisible = true
                defenderFlipped = true
                circlesShown = true
            }
            settled = true
            gameOverShown = snap.phase == .gameOver
        }
    }

    // MARK: timers

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelWork() {
        work.forEach { $0.cancel() }
        work = []
    }
}

// MARK: - Discard top card (the house landing)

/// The top of the discard pile. A card that has just been thrown slides in
/// from its seat on the house ease-out curve (the friction toss), twisting
/// down to its rest angle with a lifting shadow, then sits. Reduce Motion:
/// it simply appears.
private struct GinDiscardTop: View {
    let card: Card
    let width: CGFloat
    let from: CGSize?
    let rotation: Double
    let reduceMotion: Bool
    @State private var progress: Double = 0

    var body: some View {
        GinLanding(card: card, width: width, from: from ?? .zero, rest: rotation, progress: progress)
            .onAppear {
                if from == nil || reduceMotion {
                    progress = 1
                } else {
                    withAnimation(.timingCurve(0.25, 0.10, 0.30, 1.0, duration: 0.55)) { progress = 1 }
                }
            }
    }
}

private struct GinLanding: View, Animatable {
    let card: Card
    let width: CGFloat
    let from: CGSize
    let rest: Double
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = CGFloat(progress)
        let arc = sin(Double(p) * .pi)
        let twist: Double = (TableGeometry.jitterDegrees(cardID: card.id) >= 0 ? 1 : -1) * 16
        CardView(card: card, faceUp: true, elevation: CGFloat(arc) * 0.8)
            .frame(width: width)
            .rotationEffect(.degrees(rest + (1 - Double(p)) * twist))
            .scaleEffect(1 + 0.07 * CGFloat(arc))
            .offset(x: from.width * (1 - p), y: from.height * (1 - p))
            .opacity(Double(min(1, p * 5)))
    }
}

/// A card (or a back) travelling from a pile to a seat: shrinking and fading
/// as it is gathered into the unseen hand.
private struct GinFlight: View {
    let card: Card?
    let width: CGFloat
    let from: CGPoint
    let to: CGPoint
    let reduceMotion: Bool
    @State private var progress: Double = 0

    var body: some View {
        GinFlightBody(card: card, width: width, from: from, to: to, progress: progress)
            .onAppear {
                withAnimation(.timingCurve(0.45, 0.0, 0.85, 0.6, duration: 0.5)) { progress = 1 }
            }
            .allowsHitTesting(false)
    }
}

private struct GinFlightBody: View, Animatable {
    let card: Card?
    let width: CGFloat
    let from: CGPoint
    let to: CGPoint
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = CGFloat(progress)
        CardView(card: card ?? Card(id: "ginflight", kind: .standard(suit: .spades, rank: 2)),
                 faceUp: card != nil, elevation: CGFloat(sin(Double(p) * .pi)) * 0.6)
            .frame(width: width)
            .scaleEffect(1 - 0.35 * p)
            .rotationEffect(.degrees(Double(p) * (to.y > from.y ? 12 : -12)))
            .opacity(Double(1 - 0.85 * max(0, p - 0.55) / 0.45))
            .position(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
    }
}
