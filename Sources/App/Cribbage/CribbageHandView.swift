import SwiftUI

/// The phone during a cribbage hand — routed from `HandRootView` whenever
/// `client.cribbageSnapshot` is non-nil, the same shape as dice mode's
/// `DiceCupView` routing on `client.diceState`.
///
/// Four phases, one screen: discarding (pick 2 for the crib, lift-select
/// then confirm), pegging (flick a legal card up to play; cards that would
/// bust 31 dim out), the show (passive — "Count's on the table", the drama
/// plays out on the iPad), and game over (a quiet recap). Reuses
/// `HandFanLayout`'s pure geometry and `CardDragState`'s play-progress math
/// from the trick-game hand (both file-scope, non-private) rather than
/// duplicating them — a 4-6 card cribbage hand never crosses
/// `HandFanLayout`'s wide-hand threshold, so the browse/scroll machinery
/// `HandView` needs for a 20-card Wizard hand simply never engages here;
/// only a plain flick-to-play gesture is needed on top.
struct CribbageHandView: View {
    @Bindable var client: GameClientController
    var onLeave: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var motionReduced

    @State private var selectedForCrib: Set<String> = []
    @State private var pegSelectedID: String?
    @State private var pegDragState = CardDragState()
    @State private var departingIDs: Set<String> = []

    private var snap: CribbageSnapshot? { client.cribbageSnapshot }
    private var hand: [Card] { snap?.myHand ?? [] }
    private var isMyPegTurn: Bool {
        guard let snap else { return false }
        return snap.phase == .pegging && snap.turnSeat == snap.mySeat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()
                VStack(spacing: 0) {
                    header
                    Spacer()
                    banner
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: snap?.phase)
                    Spacer()
                    fan(in: geo.size)
                        .frame(height: geo.size.height * 0.42)
                }
            }
        }
        .statusBarHidden()
        .onChange(of: snap?.phase) { _, _ in
            selectedForCrib = []
            pegSelectedID = nil
            pegDragState = CardDragState()
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            if let onLeave {
                Button(action: onLeave) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Leave table")
            }
            Text("Cribbage")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
            Spacer()
            if let snap {
                Text("\(snap.scores[snap.mySeat] ?? 0) – \(snap.scores[1 - snap.mySeat] ?? 0)")
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var banner: some View {
        switch snap?.phase {
        case .discarding:
            if snap?.iHaveDiscarded == true {
                statusPill("Waiting for your opponent to discard…")
            } else {
                discardBanner
            }
        case .pegging:
            if isMyPegTurn {
                yourTurnBanner
            } else {
                statusPill("Waiting for your opponent…")
            }
        case .handComplete:
            statusPill("Count's on the table")
        case .gameOver:
            gameOverBanner
        case nil:
            EmptyView()
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .serif))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.3)))
    }

    private var discardBanner: some View {
        VStack(spacing: 8) {
            Text(selectedForCrib.count == 2 ? "Ready to send to the crib" : "Pick 2 cards for the crib")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            if selectedForCrib.count == 2 {
                Button(action: confirmDiscard) {
                    Text("To the crib")
                        .font(.headline.weight(.bold))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
            }
        }
    }

    private var yourTurnBanner: some View {
        VStack(spacing: 4) {
            Text("YOUR TURN")
                .font(.system(.headline, design: .serif).weight(.heavy))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
            Text(pegHintText)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(.black.opacity(0.3))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1.5))
        )
    }

    private var pegHintText: String {
        guard let snap else { return "" }
        return "Count's at \(snap.pegCount) — flick up to play"
    }

    @ViewBuilder
    private var gameOverBanner: some View {
        if let snap {
            let won = snap.winnerSeat == snap.mySeat
            VStack(spacing: 6) {
                Text(won ? "You win the crib!" : "Opponent wins the crib")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(won ? CardStyle.gold : .white)
                if snap.skunk == true {
                    Text("A skunk!")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text("\(snap.scores[snap.mySeat] ?? 0) – \(snap.scores[1 - snap.mySeat] ?? 0)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: fan

    private func fanCardWidth(in size: CGSize) -> CGFloat { min(size.width * 0.30, 130) }

    private func fan(in size: CGSize) -> some View {
        let cardWidth = fanCardWidth(in: size)
        let layout = HandFanLayout(cardCount: hand.count, containerWidth: size.width, cardWidth: cardWidth)
        let phase = snap?.phase
        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.element.id) { index, card in
                cardView(card: card, index: index, layout: layout, cardWidth: cardWidth, size: size, phase: phase)
            }
        }
        .frame(maxWidth: .infinity)
        .offset(y: 30)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: hand.count)
    }

    @ViewBuilder
    private func cardView(card: Card, index: Int, layout: HandFanLayout, cardWidth: CGFloat,
                          size: CGSize, phase: CribbagePhase?) -> some View {
        switch phase {
        case .discarding:
            let isSelected = selectedForCrib.contains(card.id)
            let slot = layout.slot(for: index, selected: isSelected)
            let flyingOff: CGFloat = departingIDs.contains(card.id) ? -size.height : 0
            CardView(card: card, faceUp: true, elevation: isSelected ? 0.5 : 0)
                .frame(width: cardWidth)
                .rotationEffect(slot.angle)
                .offset(x: slot.offset.width, y: slot.offset.height + flyingOff)
                .opacity(departingIDs.contains(card.id) ? 0 : 1)
                .zIndex(isSelected ? 100 : slot.zIndex)
                .onTapGesture { toggleCribSelection(card.id) }
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isSelected)
                .accessibilityLabel(card.accessibleName)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isSelected ? "Selected for the crib. Double-tap to deselect."
                                              : "Double-tap to select for the crib.")

        case .pegging:
            let unplayable = isUnplayable(card)
            let isSelected = pegSelectedID == card.id
            let slot = layout.slot(for: index, selected: isSelected)
            let dragOffset = isSelected ? pegDragState.translation : .zero
            let elevation = isSelected ? pegDragState.elevation(handHeight: size.height) : 0
            CardView(card: card, faceUp: true, elevation: elevation)
                .frame(width: cardWidth)
                .opacity(unplayable ? 0.4 : (departingIDs.contains(card.id) ? 0 : 1))
                .rotationEffect(slot.angle)
                .offset(x: slot.offset.width + dragOffset.width, y: slot.offset.height + dragOffset.height)
                .zIndex(isSelected ? 100 : slot.zIndex)
                .gesture(pegGesture(for: card, in: size))
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isSelected)
                .accessibilityLabel(card.accessibleName)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(unplayable ? "Would put the count over 31"
                                              : (isMyPegTurn ? "Flick up to play" : ""))

        default:
            let slot = layout.slot(for: index)
            CardView(card: card, faceUp: true)
                .frame(width: cardWidth)
                .rotationEffect(slot.angle)
                .offset(x: slot.offset.width, y: slot.offset.height)
                .zIndex(slot.zIndex)
                .accessibilityLabel(card.accessibleName)
        }
    }

    private func isUnplayable(_ card: Card) -> Bool {
        guard let snap else { return false }
        return CribbageScoring.pegValue(card) + snap.pegCount > 31
    }

    // MARK: discard-phase gesture

    private func toggleCribSelection(_ id: String) {
        guard snap?.iHaveDiscarded != true else { return }
        Haptics.tick()
        if selectedForCrib.contains(id) {
            selectedForCrib.remove(id)
        } else if selectedForCrib.count < 2 {
            selectedForCrib.insert(id)
        }
    }

    private func confirmDiscard() {
        guard selectedForCrib.count == 2 else { return }
        Haptics.play()
        let ids = Array(selectedForCrib)
        withAnimation(.easeIn(duration: 0.28)) {
            departingIDs.formUnion(ids)
        }
        client.discardToCrib(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            selectedForCrib = []
            departingIDs.subtract(ids)
        }
    }

    // MARK: pegging-phase gesture (mirrors HandView.playGesture, minus the
    // browse/fisheye machinery a 4-card hand never needs)

    private func pegGesture(for card: Card, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isMyPegTurn, !isUnplayable(card) else { return }
                if pegSelectedID != card.id {
                    pegSelectedID = card.id
                    Haptics.tick()
                }
                let wasArmed = pegDragState.playProgress(handHeight: size.height) >= 1
                pegDragState.isDragging = true
                pegDragState.translation = value.translation
                let isArmed = pegDragState.playProgress(handHeight: size.height) >= 1
                if isArmed != wasArmed { Haptics.arm() }
            }
            .onEnded { value in
                guard isMyPegTurn, !isUnplayable(card), pegSelectedID == card.id else { return }
                let progress = pegDragState.playProgress(handHeight: size.height)
                let flicked = value.predictedEndTranslation.height < -size.height * 0.35
                    && value.translation.height < -20
                if progress >= 1 || flicked {
                    playPegCard(card)
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                        pegDragState = CardDragState()
                        pegSelectedID = nil
                    }
                }
            }
    }

    private func playPegCard(_ card: Card) {
        Haptics.play()
        withAnimation(.easeIn(duration: 0.22)) {
            pegDragState.translation.height = -600
            departingIDs.insert(card.id)
        }
        client.playCribbageCard(card.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pegDragState = CardDragState()
            pegSelectedID = nil
            departingIDs.remove(card.id)
        }
    }
}
