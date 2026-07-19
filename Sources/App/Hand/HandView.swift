import SwiftUI

/// The phone screen during play: your cards, fanned, alive under your thumb.
/// Swipe a card up past the threshold and it flies to the table.
struct HandView: View {
    @Bindable var client: GameClientController

    @State private var selectedCardID: String?
    @State private var dragState = CardDragState()
    @State private var departingCardID: String?

    private var hand: [Card] { client.snapshot?.myHand ?? [] }
    private var isMyTurn: Bool {
        guard let snap = client.snapshot, let seat = client.mySeat else { return false }
        return snap.turnSeat == seat && snap.phase == .playing
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()

                VStack(spacing: 0) {
                    HandStatusStrip(client: client)
                    Spacer()
                    playZoneHint
                    Spacer()
                    fan(in: geo.size)
                        .frame(height: geo.size.height * 0.42)
                }

                if let pending = client.pendingIllegal {
                    IllegalPlaySheet(
                        reason: pending.reason,
                        onPlayAnyway: { client.forcePlayPendingCard() },
                        onCancel: {
                            client.cancelPendingPlay()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                departingCardID = nil
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: fan

    private func fan(in size: CGSize) -> some View {
        let cardWidth = min(size.width * 0.30, 130)
        let layout = HandFanLayout(cardCount: hand.count,
                                   containerWidth: size.width,
                                   cardWidth: cardWidth)
        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.element.id) { index, card in
                let isSelected = selectedCardID == card.id
                let slot = layout.slot(for: index, selected: isSelected)
                let dragOffset = isSelected ? dragState.translation : .zero
                let elevation = isSelected
                    ? dragState.elevation(handHeight: size.height)
                    : 0

                CardView(card: card, faceUp: true, elevation: elevation)
                    .frame(width: cardWidth)
                    .rotationEffect(isSelected && dragState.isDragging
                        ? tiltWhileDragging(slot.angle)
                        : slot.angle)
                    .offset(x: slot.offset.width + dragOffset.width,
                            y: slot.offset.height + dragOffset.height)
                    .zIndex(isSelected ? 100 : slot.zIndex)
                    .opacity(departingCardID == card.id ? 0 : 1)
                    .gesture(playGesture(for: card, in: size))
                    .animation(.spring(response: 0.34, dampingFraction: 0.72),
                               value: selectedCardID)
            }
        }
        .frame(maxWidth: .infinity)
        .offset(y: 30) // fan sits slightly into the bottom edge, like held cards
    }

    /// A dragged card levels out as it rises — you're pulling it free of the fan.
    private func tiltWhileDragging(_ restAngle: Angle) -> Angle {
        let progress = Double(dragState.playProgress(handHeight: 800))
        return .degrees(restAngle.degrees * (1 - progress))
    }

    // MARK: gesture

    private func playGesture(for card: Card, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if selectedCardID != card.id {
                    selectedCardID = card.id
                    Haptics.tick()
                }
                let wasArmed = dragState.playProgress(handHeight: size.height) >= 1
                dragState.isDragging = true
                dragState.translation = value.translation
                let isArmed = dragState.playProgress(handHeight: size.height) >= 1
                if isArmed != wasArmed { Haptics.arm() }
            }
            .onEnded { value in
                // Two ways to play: drag past the threshold, OR flick — a
                // fast upward snap whose momentum would have carried it
                // there. The flick is the signature move; honor velocity.
                let progress = dragState.playProgress(handHeight: size.height)
                let flicked = value.predictedEndTranslation.height < -size.height * 0.35
                    && value.translation.height < -20
                if progress >= 1 || flicked {
                    playSelectedCard(card, in: size, velocity: value.velocity)
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                        dragState = CardDragState()
                        selectedCardID = nil
                    }
                }
            }
    }

    private func playSelectedCard(_ card: Card, in size: CGSize, velocity: CGSize = .zero) {
        Haptics.play()
        withAnimation(.easeIn(duration: 0.22)) {
            dragState.translation.height = -size.height
            departingCardID = card.id
        }
        client.playCard(card.id, velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dragState = CardDragState()
            selectedCardID = nil
            // If the play was legal the snapshot removes the card; if the
            // host said "illegal", IllegalPlaySheet is already up and Cancel
            // restores the departing card.
            if client.pendingIllegal == nil { departingCardID = nil }
        }
    }

    // MARK: chrome

    private var playZoneHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "chevron.up")
                .font(.title3.weight(.semibold))
            Text(hintText)
                .font(.system(.subheadline, design: .serif))
            if (client.snapshot?.gameKind == .crazyEights && isMyTurn)
                || client.snapshot?.gameKind == .freePlay {
                Button {
                    Haptics.tick()
                    client.drawCard()
                } label: {
                    Label("Draw a card", systemImage: "square.stack.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CardStyle.gold)
            }
        }
        .foregroundStyle(.white.opacity(dragState.isDragging ? 0.9 : 0.35))
        .animation(.easeInOut(duration: 0.2), value: dragState.isDragging)
    }

    private var hintText: String {
        if client.snapshot?.gameKind == .freePlay {
            return "Swipe up to play — house rules apply"
        }
        return isMyTurn ? "Swipe a card up to play" : "Waiting for your turn…"
    }
}

/// The soft-enforcement moment: playing a bad card takes a real decision.
struct IllegalPlaySheet: View {
    let reason: String
    let onPlayAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(CardStyle.gold)
                Text(reason)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("House rules are house rules — but do it on purpose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Take it back")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive, action: onPlayAnyway) {
                        Text("Play it anyway")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial))
            .padding(.horizontal, 32)
        }
    }
}

/// Warm felt with a vignette — the app's stage, shared by hand and table.
/// Photographic felt texture with programmatic lighting over it; falls back
/// to flat color if the asset is ever missing.
struct FeltBackground: View {
    var body: some View {
        ZStack {
            CardStyle.feltGreen.ignoresSafeArea()
            Image("FeltTexture")
                .resizable(resizingMode: .tile)
                .ignoresSafeArea()
                .opacity(0.55)
                .blendMode(.overlay)
            RadialGradient(colors: [.clear, .black.opacity(0.35)],
                           center: .center, startRadius: 150, endRadius: 700)
                .ignoresSafeArea()
        }
    }
}

/// Light haptic vocabulary; one voice for the whole app.
enum Haptics {
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func arm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func play() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
