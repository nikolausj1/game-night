import SwiftUI

/// The draw pile and the flipped trump card, sitting together on the felt
/// like a dealer left them: stacked backs with visible depth, trump turned
/// beside the pile.
struct DeckAndTrumpView: View {
    let state: GameState
    /// The felt's full size — used only to size the deck/trump to the
    /// SAME `TableGeometry.tableCardWidth` every other table card uses
    /// (deck, shed pile, trick plays, free-play cards: one object class,
    /// one size). The draw pile grows to match rather than everything
    /// shrinking to meet it.
    let tableSize: CGSize

    private var deckCount: Int { state.drawPile.count }
    private var cardWidth: CGFloat { TableGeometry.tableCardWidth(for: tableSize) }

    // MARK: - Trump reveal (3D flip)

    /// Tracks the id of the trump card whose reveal we've already animated,
    /// so a re-render (same round, same card) never replays the flip.
    @State private var lastAnimatedTrumpID: String?
    /// Content side currently rendered — flips at the edge-on (90°) point
    /// of the rotation, mirroring `TableGameView.flipCard`.
    @State private var trumpFaceUp = true
    /// 180 = face-down/reversed pose at the deck, 0 = settled face-up in
    /// the trump slot. Swept in two phases (180→90, then -90→0) so the
    /// content swap at 90° never renders mirrored.
    @State private var trumpFlipAngle: Double = 0
    /// Horizontal slide from the deck's position (negative) to the trump
    /// slot (0).
    @State private var trumpSlideOffset: CGFloat = 0
    /// Small vertical lift at the apex of the flip.
    @State private var trumpLift: CGFloat = 0
    /// Small scale bump at the apex of the flip.
    @State private var trumpScale: CGFloat = 1

    // MARK: - Riffle shuffle flourish

    /// Guards against overlapping flourishes if the pile jumps again
    /// mid-animation.
    @State private var shuffleActive = false
    /// ±pt the two half-stacks slide apart.
    @State private var shuffleSplitOffset: CGFloat = 0
    /// ±degrees the two half-stacks angle apart.
    @State private var shuffleSplitAngle: Double = 0
    /// Small alternating jitter layered on top of the split during the
    /// flutter phase.
    @State private var shuffleFlutterJitter: Double = 0

    /// Where the table lamp sits relative to the pile (see `TableLamp`).
    @State private var lamp = LampSample()

    var body: some View {
        HStack(spacing: 26) {
            deckStack
            if let trump = state.round?.trumpCard {
                trumpCard(trump)
            } else if state.round != nil, state.gameKind.isTrickTaking {
                Text("No trump")
                    .font(.system(.caption, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.4)))
            }
        }
        .lampSample($lamp)
        .onChange(of: state.round?.trumpCard) { _, newCard in
            handleTrumpChange(newCard)
        }
        .onChange(of: state.drawPile.count) { old, new in
            handleDrawPileChange(old: old, new: new)
        }
    }

    private var deckStack: some View {
        let isFreePlay = state.gameKind == .freePlay
        let width: CGFloat = cardWidth
        let layers = min(isFreePlay ? 5 : 3, max(deckCount, 1))
        return ZStack {
            // The pile's cast shadow, thrown away from the lamp.
            DeckCastShadow(width: width, layers: layers, lamp: lamp)
            // Buried cards show only their paper EDGES — plain stock, no
            // art — so the pile reads as one deck, not interleaved cards.
            // Only the top card wears the printed back.
            ForEach(0..<layers, id: \.self) { layer in
                if layer == layers - 1 {
                    if shuffleActive {
                        shuffleTopCard(width: width, layer: layer)
                    } else {
                        CardView(card: Card(id: "deck\(layer)", kind: .standard(suit: .spades, rank: 2)),
                                 faceUp: false)
                            .frame(width: width)
                            .overlay(DeckTopShade(width: width, lamp: lamp))
                            .offset(x: CGFloat(layer) * -2.0, y: CGFloat(layer) * -2.5)
                            .rotationEffect(.degrees(Double(layer) * -0.8))
                    }
                } else {
                    DeckEdgeLayer(width: width, lamp: lamp)
                        .offset(x: CGFloat(layer) * -2.0, y: CGFloat(layer) * -2.5)
                        .rotationEffect(.degrees(Double(layer) * -0.8))
                }
            }
            if deckCount > 0 {
                VStack(spacing: 4) {
                    Text("\(deckCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45)))
                    if isFreePlay {
                        Text("Drag to a player to deal")
                            .font(.system(.caption2, design: .serif).italic())
                            .foregroundStyle(CardStyle.gold.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.4)))
                    }
                }
                // Scales with the card width so the count/hint labels
                // clear the bottom edge of the (now-uniform-sized) stack
                // the same way regardless of how big `width` ends up.
                .offset(y: width * (isFreePlay ? 0.79 : 0.65))
            }
        }
        .opacity(deckCount == 0 ? 0.25 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFreePlay ? "Draw pile, \(deckCount) cards, drag to a player to deal"
                                       : "Draw pile, \(deckCount) cards")
    }

    /// The top-of-deck back, split into two angled half-stacks for the
    /// riffle-shuffle flourish. Same base offset/rotation as the plain top
    /// card, plus the split/flutter deltas layered symmetrically on top.
    private func shuffleTopCard(width: CGFloat, layer: Int) -> some View {
        let baseX = CGFloat(layer) * -2.0
        let baseY = CGFloat(layer) * -2.5
        let baseRotation = Double(layer) * -0.8
        let jitter = shuffleFlutterJitter
        return ZStack {
            CardView(card: Card(id: "deck\(layer)a", kind: .standard(suit: .spades, rank: 2)),
                     faceUp: false)
                .frame(width: width)
                .offset(x: baseX - shuffleSplitOffset, y: baseY)
                .rotationEffect(.degrees(baseRotation - shuffleSplitAngle - jitter))
            CardView(card: Card(id: "deck\(layer)b", kind: .standard(suit: .spades, rank: 2)),
                     faceUp: false)
                .frame(width: width)
                .offset(x: baseX + shuffleSplitOffset, y: baseY)
                .rotationEffect(.degrees(baseRotation + shuffleSplitAngle + jitter))
        }
    }

    private func trumpCard(_ trump: Card) -> some View {
        VStack(spacing: 8) {
            CardView(card: trump, faceUp: trumpFaceUp)
                .frame(width: cardWidth)
                // A real flip along the card's own long axis: swept in two
                // phases by animateTrumpReveal(), content swapped at the
                // edge-on (90°) midpoint — mirrors TableGameView.flipCard.
                .rotation3DEffect(.degrees(trumpFlipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .scaleEffect(trumpScale)
                .rotationEffect(.degrees(90))
                .offset(x: trumpSlideOffset, y: trumpLift)
            Text(trumpLabel)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.4)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trumpLabel)
    }

    private var trumpLabel: String {
        if let suit = state.round?.trumpSuit { return "Trump \(suit.symbol)" }
        return "No trump"
    }

    // MARK: - Trump reveal animation

    private func handleTrumpChange(_ newCard: Card?) {
        guard let newCard else {
            lastAnimatedTrumpID = nil
            return
        }
        guard newCard.id != lastAnimatedTrumpID else { return }
        lastAnimatedTrumpID = newCard.id
        animateTrumpReveal()
    }

    private func animateTrumpReveal() {
        // Start face-down, reversed, sitting back near the deck.
        trumpFaceUp = false
        trumpFlipAngle = 180
        trumpSlideOffset = -64
        trumpLift = -10
        trumpScale = 1
        withAnimation(.easeIn(duration: 0.22)) {
            // Slide most of the way in and rise to the apex as it turns
            // edge-on.
            trumpFlipAngle = 90
            trumpSlideOffset = -22
            trumpLift = -16
            trumpScale = 1.08
        } completion: {
            TableSFX.shared.play(.cardFlip)
            trumpFaceUp = true
            // Jump to the mirrored equivalent so the second half of the
            // turn reveals the face un-mirrored (same trick as flipCard).
            trumpFlipAngle = -90
            withAnimation(.easeOut(duration: 0.26)) {
                trumpFlipAngle = 0
                trumpSlideOffset = 0
                trumpLift = 0
                trumpScale = 1
            }
        }
    }

    // MARK: - Riffle shuffle animation

    private func handleDrawPileChange(old: Int, new: Int) {
        guard new - old > 10 else { return }
        runShuffleFlourish()
    }

    /// Split → flutter (3 quick alternating rocks) → snap together.
    /// ~0.7s total: 0.12s split + 3×0.12s flutter + 0.22s snap.
    private func runShuffleFlourish() {
        guard !shuffleActive else { return }
        shuffleActive = true
        TableSFX.shared.play(.shuffle)
        shuffleSplitOffset = 0
        shuffleSplitAngle = 0
        shuffleFlutterJitter = 0
        withAnimation(.easeOut(duration: 0.12)) {
            shuffleSplitOffset = 14
            shuffleSplitAngle = 12
        } completion: {
            shuffleFlutterStep(remaining: 3)
        }
    }

    private func shuffleFlutterStep(remaining: Int) {
        guard remaining > 0 else {
            snapShuffleTogether()
            return
        }
        let sign: Double = remaining.isMultiple(of: 2) ? 1 : -1
        withAnimation(.easeInOut(duration: 0.12)) {
            shuffleFlutterJitter = sign * 4
        } completion: {
            shuffleFlutterStep(remaining: remaining - 1)
        }
    }

    private func snapShuffleTogether() {
        TableSFX.shared.play(.cardFlip)
        withAnimation(.easeIn(duration: 0.22)) {
            shuffleSplitOffset = 0
            shuffleSplitAngle = 0
            shuffleFlutterJitter = 0
        } completion: {
            shuffleActive = false
        }
    }
}


// MARK: - Lamp shading (shared by the game deck and the lobby deck)

/// A buried card's paper edge: plain stock lit by the table lamp. The face
/// toward the lamp warms, the far one falls to shade, so a three-high stack
/// reads as a block of paper under a light instead of three flat tans.
struct DeckEdgeLayer: View {
    let width: CGFloat
    let lamp: LampSample

    var body: some View {
        let r = CardStyle.cornerRadius(width: width)
        let lit = UnitPoint(x: 0.5 + lamp.toward.dx * 0.5, y: 0.5 + lamp.toward.dy * 0.5)
        let far = UnitPoint(x: 0.5 - lamp.toward.dx * 0.5, y: 0.5 - lamp.toward.dy * 0.5)
        let k = 0.5 + 0.5 * lamp.light
        return RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(CardStyle.stockBottom)
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(LinearGradient(colors: [TableLamp.warmTint.opacity(0.22 * k),
                                                  .black.opacity(0.10 + 0.22 * (1 - lamp.light))],
                                         startPoint: lit, endPoint: far))
            )
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(.black.opacity(0.14), lineWidth: 0.5)
            )
            .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
            .frame(width: width)
            .shadow(color: .black.opacity(0.20), radius: 1.5,
                    x: -lamp.toward.dx * 1.2, y: -lamp.toward.dy * 1.2)
    }
}

/// The top card's face-down back, graded by the lamp: a warm cast on the
/// lamp-facing side, a soft darkening on the far side.
struct DeckTopShade: View {
    let width: CGFloat
    let lamp: LampSample

    var body: some View {
        let r = CardStyle.cornerRadius(width: width)
        let lit = UnitPoint(x: 0.5 + lamp.toward.dx * 0.5, y: 0.5 + lamp.toward.dy * 0.5)
        let far = UnitPoint(x: 0.5 - lamp.toward.dx * 0.5, y: 0.5 - lamp.toward.dy * 0.5)
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(LinearGradient(colors: [TableLamp.warmTint.opacity(0.10 * (0.5 + 0.5 * lamp.light)),
                                          .black.opacity(0.06 + 0.16 * (1 - lamp.light))],
                                 startPoint: lit, endPoint: far))
            .allowsHitTesting(false)
    }
}

/// Soft contact shadow under the pile, cast away from the lamp.
struct DeckCastShadow: View {
    let width: CGFloat
    let layers: Int
    let lamp: LampSample

    var body: some View {
        let r = CardStyle.cornerRadius(width: width)
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(.black.opacity(0.34))
            .aspectRatio(CardStyle.aspectRatio, contentMode: .fit)
            .frame(width: width)
            .blur(radius: 5 + CGFloat(layers))
            .offset(x: -lamp.toward.dx * (4 + CGFloat(layers)),
                    y: -lamp.toward.dy * (4 + CGFloat(layers)) + 2)
            .allowsHitTesting(false)
    }
}

/// A standalone draw pile for the lobby (no `GameState` needed): the same
/// stack and lamp shading as the table's, with the same riffle flourish
/// (split, three flutters, snap) driven by bumping `riffleTrigger`.
struct LobbyDeckView: View {
    var cardWidth: CGFloat = 104
    /// Bump to run one riffle.
    var riffleTrigger: Int = 0

    @State private var lamp = LampSample()
    @State private var active = false
    @State private var split: CGFloat = 0
    @State private var splitAngle: Double = 0
    @State private var jitter: Double = 0

    private let layers = 4

    var body: some View {
        ZStack {
            DeckCastShadow(width: cardWidth, layers: layers, lamp: lamp)
            ForEach(0..<layers, id: \.self) { layer in
                let dx = CGFloat(layer) * -2.0
                let dy = CGFloat(layer) * -2.5
                let rot = Double(layer) * -0.8
                if layer == layers - 1 {
                    if active {
                        halves(dx: dx, dy: dy, rot: rot)
                    } else {
                        top(id: "lobbyDeck")
                            .offset(x: dx, y: dy)
                            .rotationEffect(.degrees(rot))
                    }
                } else {
                    DeckEdgeLayer(width: cardWidth, lamp: lamp)
                        .offset(x: dx, y: dy)
                        .rotationEffect(.degrees(rot))
                }
            }
        }
        .lampSample($lamp)
        .onChange(of: riffleTrigger) { _, _ in riffle() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func top(id: String) -> some View {
        CardView(card: Card(id: id, kind: .standard(suit: .spades, rank: 2)), faceUp: false)
            .frame(width: cardWidth)
            .overlay(DeckTopShade(width: cardWidth, lamp: lamp))
    }

    private func halves(dx: CGFloat, dy: CGFloat, rot: Double) -> some View {
        ZStack {
            top(id: "lobbyDeckA")
                .offset(x: dx - split, y: dy)
                .rotationEffect(.degrees(rot - splitAngle - jitter))
            top(id: "lobbyDeckB")
                .offset(x: dx + split, y: dy)
                .rotationEffect(.degrees(rot + splitAngle + jitter))
        }
    }

    /// Same beats as the table deck: 0.12s split, 3 x 0.12s flutter, 0.22s snap.
    private func riffle() {
        guard !active else { return }
        active = true
        TableSFX.shared.play(.shuffle)
        split = 0; splitAngle = 0; jitter = 0
        withAnimation(.easeOut(duration: 0.12)) {
            split = 14; splitAngle = 12
        } completion: { flutter(remaining: 3) }
    }

    private func flutter(remaining: Int) {
        guard remaining > 0 else {
            TableSFX.shared.play(.cardFlip)
            withAnimation(.easeIn(duration: 0.22)) {
                split = 0; splitAngle = 0; jitter = 0
            } completion: { active = false }
            return
        }
        let sign: Double = remaining.isMultiple(of: 2) ? 1 : -1
        withAnimation(.easeInOut(duration: 0.12)) {
            jitter = sign * 4
        } completion: { flutter(remaining: remaining - 1) }
    }
}
