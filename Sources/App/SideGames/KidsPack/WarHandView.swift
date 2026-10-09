import SwiftUI

/// The phone during War: one big Flip button, both piles' sizes, and the
/// last battle's cards turning over. War has no decisions, so the phone is
/// optional (the table also has a tap-to-flip zone) but makes the game feel
/// like yours.
struct WarHandView: View {
    @Bindable var client: GameClientController

    var body: some View {
        let wire = client.sideGameState.flatMap { payload in
            payload.kind == WarEngine.kind ? payload.decode(WarWireState.self) : nil
        }
        WarHandContent(wire: wire) { action in
            client.sendSideGameAction(kind: WarEngine.kind, action)
        }
    }
}

struct WarHandContent: View {
    let wire: WarWireState?
    let send: (WarAction) -> Void

    @State private var flipped = false
    @State private var faceUp = true
    @State private var shownRound = -1
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    private var snap: WarSnapshot? { wire?.snapshot }
    private var me: Int { snap?.seat ?? 0 }
    private func name(_ seat: Int) -> String { wire?.names[seat] ?? "Player \(seat + 1)" }
    private var ready: Bool { (wire?.ready ?? false) && snap?.phase == .playing && !flipped }

    /// My and their last face-up card of the most recent battle.
    private var finalCards: (mine: Card?, theirs: Card?) {
        guard let battle = snap?.lastBattle else { return (nil, nil) }
        let faceUps = battle.flips.filter { !$0.faceDown }
        return (faceUps.last(where: { $0.seat == me })?.card, faceUps.last(where: { $0.seat != me })?.card)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 6)
                    battleView(in: geo.size)
                    Spacer(minLength: 6)
                    resultLine
                    Spacer(minLength: 10)
                    flipButton
                        .padding(.bottom, 26)
                }
            }
        }
        .statusBarHidden()
        .onAppear { shownRound = snap?.round ?? -1 }
        .onChange(of: snap?.round) { _, new in
            flipped = false
            guard let new, new != shownRound else { return }
            shownRound = new
            // New battle: cards arrive face-down, then turn over.
            faceUp = false
            withAnimation(.easeInOut(duration: motionReduced ? 0.01 : 0.5).delay(motionReduced ? 0 : 0.25)) { faceUp = true }
            Haptics.tick()
        }
        .onChange(of: wire?.ready) { _, now in if now == true { flipped = false } }
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            Text("War")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Spacer()
            if let snap {
                Text("Battle \(snap.round) of \(snap.maxRounds)")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func countChip(seat: Int, count: Int, mine: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(PlayerPalette.color(seat)).frame(width: 12, height: 12)
            Text(mine ? "You" : name(seat))
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
            Text("\(count)")
                .font(.system(.subheadline, design: .serif).weight(.bold).monospacedDigit())
                .foregroundStyle(CardStyle.gold)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You have" : "\(name(seat)) has") \(count) cards")
    }

    private func battleView(in size: CGSize) -> some View {
        let width = min(size.width * 0.34, 130)
        let cards = finalCards
        let battle = snap?.lastBattle
        let mineWon = battle?.winner == me
        let theirsWon = battle?.winner != nil && battle?.winner != me
        return VStack(spacing: 14) {
            if let snap {
                countChip(seat: 1 - me, count: snap.opponentCount, mine: false)
            }
            HStack(spacing: 18) {
                battleCard(cards.mine, width: width, won: mineWon, label: "You")
                battleCard(cards.theirs, width: width, won: theirsWon, label: snap.map { name(1 - $0.seat) } ?? "")
            }
            if let snap {
                countChip(seat: me, count: snap.myCount, mine: true)
            }
        }
    }

    private func battleCard(_ card: Card?, width: CGFloat, won: Bool, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if let card {
                    CardView(card: card, faceUp: true, elevation: won && faceUp ? 0.4 : 0)
                        .opacity(faceUp ? 1 : 0)
                    CardView(card: KidsCards.back, faceUp: false)
                        .opacity(faceUp ? 0 : 1)
                } else {
                    RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: width), style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
                }
            }
            .frame(width: width)
            .rotation3DEffect(.degrees(faceUp ? 0 : 180), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .shadow(color: CardStyle.gold.opacity(won && faceUp ? 0.85 : 0), radius: won && faceUp ? 14 : 0)
            Text(label)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.map { "\(label): \($0.accessibleName)" } ?? "\(label): no card yet")
    }

    @ViewBuilder
    private var resultLine: some View {
        if let snap {
            if snap.phase == .gameOver {
                gameOverText(snap)
            } else if let battle = snap.lastBattle, faceUp {
                VStack(spacing: 3) {
                    if battle.wars > 0 {
                        Text(battle.wars == 1 ? "WAR!" : "WAR! x\(battle.wars)")
                            .font(.system(.title3, design: .serif).weight(.heavy))
                            .tracking(2)
                            .foregroundStyle(CardStyle.gold)
                    }
                    Text(battle.winner == nil ? "A split pot"
                         : (battle.winner == me ? "You take \(battle.captured) cards" : "\(name(battle.winner ?? 0)) takes \(battle.captured) cards"))
                        .font(.system(.headline, design: .serif).weight(.bold))
                        .foregroundStyle(battle.winner == me ? CardStyle.gold : CardStyle.stockTop)
                }
                .transition(.opacity)
            } else if !faceUp {
                Text(" ").font(.headline)
            } else {
                Text("Ready when you are")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func gameOverText(_ snap: WarSnapshot) -> some View {
        let title: String
        let detail: String
        if snap.endReason == .roundCap {
            if let w = snap.winner {
                title = w == me ? "You win on cards!" : "\(name(w)) wins on cards"
                detail = "Time's up after \(snap.round) battles."
            } else {
                title = "It's a draw!"
                detail = "Time's up after \(snap.round) battles."
            }
        } else {
            title = snap.winner == me ? "You win every card!" : "\(name(snap.winner ?? 0)) wins every card"
            detail = "All 52 cards in \(snap.round) battles."
        }
        return VStack(spacing: 4) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(snap.winner == me ? CardStyle.gold : .white)
            Text(detail)
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var flipButton: some View {
        if snap?.phase == .playing {
            Button {
                guard ready else { return }
                Haptics.play()
                flipped = true
                send(.flip)
                // If the table never answers (a dropped link), hand the button back.
                Task { @MainActor in
                    await kidsWait(5)
                    flipped = false
                }
            } label: {
                Text(ready ? "FLIP" : "…")
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .tracking(3)
                    .foregroundStyle(CardStyle.ink.opacity(ready ? 1 : 0.5))
                    .frame(width: 168, height: 168)
                    .background(
                        Circle()
                            .fill(RadialGradient(colors: [Color(red: 0.99, green: 0.92, blue: 0.72), CardStyle.gold,
                                                          Color(red: 0.52, green: 0.39, blue: 0.19)],
                                                 center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 150))
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1.5))
                            .shadow(color: CardStyle.gold.opacity(ready ? 0.6 : 0), radius: ready ? 18 : 0)
                            .shadow(color: .black.opacity(0.45), radius: 8, y: 5)
                    )
                    .opacity(ready ? 1 : 0.55)
                    .scaleEffect(flipped ? 0.94 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: flipped)
            .accessibilityLabel("Flip")
            .accessibilityHint("Both players flip their top card")
        } else {
            Color.clear.frame(height: 168)
        }
    }
}

// MARK: - Previews

private func warDemoCard(_ suit: Suit, _ rank: Int) -> Card {
    let prefix = ["c", "d", "h", "s"][Suit.allCases.firstIndex(of: suit) ?? 0]
    return Card(id: "\(prefix)\(rank)", kind: .standard(suit: suit, rank: rank))
}

private func warDemoWire(ready: Bool, over: Bool = false) -> WarWireState {
    let battle = WarBattle(round: 12, flips: [
        WarFlip(seat: 0, card: warDemoCard(.hearts, 9), faceDown: false, depth: 0),
        WarFlip(seat: 1, card: warDemoCard(.spades, 9), faceDown: false, depth: 0),
        WarFlip(seat: 0, card: nil, faceDown: true, depth: 1),
        WarFlip(seat: 1, card: nil, faceDown: true, depth: 1),
        WarFlip(seat: 0, card: warDemoCard(.clubs, 13), faceDown: false, depth: 1),
        WarFlip(seat: 1, card: warDemoCard(.diamonds, 6), faceDown: false, depth: 1),
    ], wars: 1, winner: 0, captured: 10)
    let snapshot = WarSnapshot(seat: 0, myCount: over ? 52 : 31, opponentCount: over ? 0 : 21, round: 12,
                               maxRounds: 200, phase: over ? .gameOver : .playing,
                               winner: over ? 0 : nil, endReason: over ? .allCards : nil, lastBattle: battle)
    return WarWireState(snapshot: snapshot, names: [0: "Chase", 1: "Vinny"], ready: ready)
}

#Preview("War hand - ready") {
    WarHandContent(wire: warDemoWire(ready: true), send: { _ in })
}

#Preview("War hand - table busy") {
    WarHandContent(wire: warDemoWire(ready: false), send: { _ in })
}

#Preview("War hand - won") {
    WarHandContent(wire: warDemoWire(ready: false, over: true), send: { _ in })
}
