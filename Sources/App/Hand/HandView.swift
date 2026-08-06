import SwiftUI

/// Which shape a fan-card drag has committed to. Undetermined for the first
/// ~12pt (see HandView.playGesture), then locked for the rest of the drag.
private enum GestureIntent {
    case undetermined, browse, play
}

/// The phone screen during play: your cards, fanned, alive under your thumb.
/// Swipe a card up past the threshold and it flies to the table.
struct HandView: View {
    @Bindable var client: GameClientController

    @State private var selectedCardID: String?
    @State private var dragState = CardDragState()
    @State private var departingCardID: String?
    // Browse gesture (big hands): horizontal scrub across the fan. See the
    // gesture arbitration in playGesture and the geometry in HandFanLayout.
    @State private var fanScroll: CGFloat = 0
    @State private var gestureIntent = GestureIntent.undetermined
    @State private var browseAnchorScroll: CGFloat = 0
    @State private var browseFingerX: CGFloat?
    @State private var focusedCardIndex: Int?
    // Gyroscope parallax: tiny, silky, never touches gesture math. See
    // HandMotion for the baseline-recentering + low-pass model.
    @State private var motion = HandMotion()
    @AppStorage("gn.handSort") private var sortModeRaw: String = HandSortMode.asDealt.rawValue
    // Dev tool, free play only: mirrors ThrowStyleChip's stored value —
    // read here so playSelectedCard knows which animation to request.
    @AppStorage("gn.devThrowStyle") private var throwStyleRaw: String = "slide"

    private var sortMode: HandSortMode { HandSortMode(rawValue: sortModeRaw) ?? .asDealt }
    private var hand: [Card] { sortMode.sorted(client.snapshot?.myHand ?? []) }
    private var isMyTurn: Bool {
        guard let snap = client.snapshot, let seat = client.mySeat else { return false }
        return snap.round?.turnSeat == seat && snap.phase == .playing
    }

    // UNO after a wild: HandRootView routes .choosingTrump(mySeat) straight
    // to HandView (instead of the full-screen TrumpChooserView) so your hand
    // stays visible and browsable while you pick the color. This drives the
    // compact overlay strip below.
    private var isChoosingUnoColor: Bool {
        guard let snap = client.snapshot, let seat = client.mySeat else { return false }
        return snap.gameKind == .uno && snap.phase == .choosingTrump(seat: seat)
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

                if isChoosingUnoColor {
                    VStack {
                        Spacer()
                        unoColorChoiceStrip
                            .padding(.bottom, 14)
                    }
                    .padding(.bottom, geo.size.height * 0.42)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isChoosingUnoColor)
            .onAppear { motion.start() }
            .onDisappear { motion.stop() }
        }
    }

    /// Compact "pick a color" strip for UNO's post-wild color choice: a
    /// scrim only behind the strip itself (not the whole screen), docked
    /// just above the fan so the hand stays fully visible and browsable.
    private var unoColorChoiceStrip: some View {
        HStack(spacing: 14) {
            Text("Pick a color")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            UnoColorSwatchRow(swatchSize: 40) { color in
                client.declareSuit(color.suit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 24)
    }

    // MARK: fan

    private func fanCardWidth(in size: CGSize) -> CGFloat { min(size.width * 0.30, 130) }

    private func fanLayout(in size: CGSize) -> HandFanLayout {
        HandFanLayout(cardCount: hand.count, containerWidth: size.width, cardWidth: fanCardWidth(in: size))
    }

    private func fan(in size: CGSize) -> some View {
        let cardWidth = fanCardWidth(in: size)
        let layout = fanLayout(in: size)
        let bounds = layout.scrollBounds()
        let clampedScroll = min(max(fanScroll, bounds.lowerBound), bounds.upperBound)

        // Gyroscope parallax, applied to rendering offsets only — driven
        // straight off HandMotion's already-low-passed values, no
        // animation wrapper needed (that would double-smooth and add lag).
        let parallaxX = CGFloat(motion.tiltX) * 10   // ±10pt horizontal
        let parallaxY = CGFloat(motion.tiltY) * 4    // ±4pt vertical
        let parallaxRoll = Angle.degrees(motion.tiltX * 1.5) // ±1.5° fan roll

        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.element.id) { index, card in
                let isSelected = selectedCardID == card.id
                let slot = layout.slot(for: index, selected: isSelected, scrollOffset: clampedScroll)
                let dragOffset = isSelected ? dragState.translation : .zero
                let elevation = isSelected
                    ? dragState.elevation(handHeight: size.height)
                    : 0
                // Parallax depth: cards toward the wings of the fan drift
                // ~20% more than the center card, so the fan reads as a
                // curved surface tilting rather than a flat sticker.
                let depth = layout.normalizedDistanceFromCenter(for: index) * 0.2
                let cardParallax = CGSize(width: parallaxX * depth, height: parallaxY * depth)
                // Browse fisheye: cards near the finger's x fan apart and
                // lift slightly so whichever one is under the touch reads
                // clearly, even packed into a 20-card hand. See
                // fisheyeAdjustment for the falloff math.
                let fisheye = fisheyeAdjustment(displayedX: slot.offset.width, cardWidth: cardWidth)

                CardView(card: card, faceUp: true, elevation: elevation)
                    .frame(width: cardWidth)
                    .rotationEffect(isSelected && dragState.isDragging
                        ? tiltWhileDragging(slot.angle, handHeight: size.height)
                        : slot.angle)
                    .offset(x: slot.offset.width + dragOffset.width + cardParallax.width + fisheye.x,
                            y: slot.offset.height + dragOffset.height + cardParallax.height + fisheye.y)
                    .zIndex(isSelected ? 100 : slot.zIndex + fisheye.zBoost)
                    .opacity(departingCardID == card.id ? 0 : 1)
                    .gesture(playGesture(for: card, index: index, in: size))
                    .animation(.spring(response: 0.34, dampingFraction: 0.72),
                               value: selectedCardID)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7),
                               value: browseFingerX)
            }
        }
        .frame(maxWidth: .infinity)
        // fan sits slightly into the bottom edge, like held cards, plus
        // the whole-fan parallax shift and a subtle roll from tilting.
        .offset(x: parallaxX, y: 30 + parallaxY)
        .rotationEffect(parallaxRoll)
        // Reflows the whole fan when the sort chip (in HandStatusStrip) cycles
        // modes — it shares this @AppStorage key, so this is the local
        // guarantee that reordering animates rather than jumping.
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: sortModeRaw)
    }

    /// Extra separation + lift for cards near the browsing finger, falling
    /// off smoothly within ~1.5 card widths (smoothstep, not linear — reads
    /// as an organic parting rather than a hard-edged bubble). Zero when not
    /// browsing. `displayedX` and `browseFingerX` are both in the fan's
    /// displayed (post-scroll, post-clamp) coordinate space, so this is
    /// correct for both a scrolling wide hand and a static narrow one.
    private func fisheyeAdjustment(displayedX: CGFloat, cardWidth: CGFloat) -> (x: CGFloat, y: CGFloat, zBoost: Double) {
        guard let fingerX = browseFingerX else { return (0, 0, 0) }
        let distance = displayedX - fingerX
        let radius = cardWidth * 1.5
        let absDistance = abs(distance)
        guard absDistance < radius else { return (0, 0, 0) }
        let t = 1 - (absDistance / radius)
        let eased = t * t * (3 - 2 * t) // smoothstep
        let direction: CGFloat = distance >= 0 ? 1 : -1
        let xBoost = direction * eased * cardWidth * 0.4   // up to +40% of a card width apart
        let yLift = -eased * 10                             // up to 10pt lift
        return (xBoost, yLift, Double(eased) * 50)
    }

    /// A dragged card levels out as it rises — you're pulling it free of the
    /// fan. Must use the SAME dimension as the play-progress threshold
    /// (the container's actual height) or the tilt and the play gesture
    /// disagree — this used to hardcode a portrait-sized 800pt, which broke
    /// in landscape (and on any device shorter than that).
    private func tiltWhileDragging(_ restAngle: Angle, handHeight: CGFloat) -> Angle {
        let progress = Double(dragState.playProgress(handHeight: handHeight))
        return .degrees(restAngle.degrees * (1 - progress))
    }

    // MARK: gesture

    /// Gesture arbitration, all in one place: the first ~12pt of a drag
    /// decides its shape. Mostly horizontal (|dx| > |dy|) commits to a
    /// BROWSE scrub of the whole fan; mostly vertical commits to the
    /// existing PLAY drag (threshold + flick), unchanged. Below 12pt we
    /// don't know yet, so it behaves like the old play-drag/tap did —
    /// including the immediate select+haptic on touch-down — and unwinds
    /// cleanly into whichever mode wins.
    private func playGesture(for card: Card, index: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if gestureIntent == .undetermined && max(abs(dx), abs(dy)) >= 12 {
                    gestureIntent = abs(dx) > abs(dy) ? .browse : .play
                    if gestureIntent == .browse {
                        // A drag that turns out to be a browse un-selects
                        // whatever the provisional touch-down armed.
                        browseAnchorScroll = fanScroll
                        selectedCardID = nil
                        dragState = CardDragState()
                    }
                }

                switch gestureIntent {
                case .browse:
                    let layout = fanLayout(in: size)
                    let bounds = layout.scrollBounds()
                    let anchorX = layout.slot(for: index, scrollOffset: browseAnchorScroll).offset.width
                    // Direct manipulation: the fan scrubs 1:1 with the
                    // finger, clamped so you can't scroll an end clean off
                    // screen past center.
                    let newScroll = min(max(browseAnchorScroll + dx, bounds.lowerBound), bounds.upperBound)
                    fanScroll = newScroll
                    let fingerX = anchorX + dx
                    browseFingerX = fingerX
                    let newFocus = layout.nearestIndex(toDisplayedX: fingerX, scrollOffset: newScroll)
                    if newFocus != focusedCardIndex {
                        Haptics.tick()
                        focusedCardIndex = newFocus
                    }
                case .undetermined, .play:
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
            }
            .onEnded { value in
                switch gestureIntent {
                case .browse:
                    endBrowse(value: value, in: size)
                case .undetermined, .play:
                    // Two ways to play: drag past the threshold, OR flick —
                    // a fast upward snap whose momentum would have carried
                    // it there. The flick is the signature move; honor
                    // velocity.
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
                gestureIntent = .undetermined
            }
    }

    /// Release from a browse drag: momentum carries `fanScroll` on to a
    /// projected, clamped resting point (using SwiftUI's own
    /// `predictedEndTranslation`, the same momentum projection the play
    /// gesture's flick detection relies on — no separate physics needed).
    /// A haptic tick fires for every card crossed on the way there, spaced
    /// across the settle, so a big flick reads like a dial ratcheting past
    /// each card rather than one dull thud.
    private func endBrowse(value: DragGesture.Value, in size: CGSize) {
        let layout = fanLayout(in: size)
        let bounds = layout.scrollBounds()
        let projected = browseAnchorScroll + value.predictedEndTranslation.width
        let target = min(max(projected, bounds.lowerBound), bounds.upperBound)
        let fromIndex = focusedCardIndex
        let toIndex = layout.nearestIndex(toScroll: target)

        withAnimation(.interpolatingSpring(stiffness: 170, damping: 26)) {
            fanScroll = target
        }
        browseFingerX = nil

        if let fromIndex, fromIndex != toIndex {
            let step = toIndex > fromIndex ? 1 : -1
            let crossed = Array(stride(from: fromIndex + step, through: toIndex, by: step))
            let settleDuration = 0.4
            for (i, _) in crossed.enumerated() {
                let delay = settleDuration * Double(i + 1) / Double(crossed.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Haptics.tick() }
            }
        }
        focusedCardIndex = toIndex
    }

    private func playSelectedCard(_ card: Card, in size: CGSize, velocity: CGSize = .zero) {
        Haptics.play()
        withAnimation(.easeIn(duration: 0.22)) {
            dragState.translation.height = -size.height
            departingCardID = card.id
        }
        let pileDrop: Bool? = client.snapshot?.gameKind == .freePlay ? (throwStyleRaw == "pile") : nil
        client.playCard(card.id, velocity: velocity, pileDrop: pileDrop)
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

    // Drawing is an iPad-side (table) affordance only — the phone is
    // hand-only, so this hint no longer offers a draw button for any game
    // kind, including Crazy Eights and Free Play.
    private var playZoneHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "chevron.up")
                .font(.title3.weight(.semibold))
            Text(hintText)
                .font(.system(.subheadline, design: .serif))
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
