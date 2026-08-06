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
    /// Threaded straight through from HandRootView so the Menu sheet's
    /// "Leave table" (via HandStatusStrip) can pop navigation. See
    /// HandRootView's doc comment for the RoleRouter wiring.
    var onLeave: (() -> Void)? = nil

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
    // Browse → pause → play, one stroke: the finger holds still mid-browse,
    // the card under it arms for play, and the rest of the same drag plays
    // it — no need to lift the finger and touch down again. See
    // trackBrowseStationary / armFromBrowse / cancelArmedPlayBackToBrowse.
    @State private var isPlayArmedFromBrowse = false
    @State private var armAnchorTranslation: CGSize = .zero
    @State private var browseStationaryAnchor: CGPoint?
    @State private var browseStationaryWorkItem: DispatchWorkItem?
    // Deal-in / draw-in animation: card ids currently flying down from the
    // top edge into their fan slot. See handleHandArrivals.
    @State private var arrivingCardIDs: Set<String> = []
    // Gyroscope parallax: tiny, silky, never touches gesture math. See
    // HandMotion for the baseline-recentering + low-pass model.
    @State private var motion = HandMotion()
    @AppStorage("gn.handSort") private var sortModeRaw: String = HandSortMode.asDealt.rawValue
    // Dev tool, free play only: mirrors ThrowStyleChip's stored value —
    // read here so playSelectedCard knows which animation to request.
    @AppStorage("gn.devThrowStyle") private var throwStyleRaw: String = "slide"
    // The illegal-play banner's "play it anyway" link escalates to this —
    // the real confirm dialog, shown on demand instead of automatically.
    @State private var showForceConfirm = false

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

    private var showYourTurnBanner: Bool {
        isMyTurn && client.pendingIllegal == nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()

                VStack(spacing: 0) {
                    HandStatusStrip(client: client, onLeave: onLeave)
                    Spacer()
                    if showYourTurnBanner {
                        TurnBanner(hint: turnHintText)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
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
                    VStack {
                        Spacer()
                        IllegalPlayBanner(
                            reason: pending.reason,
                            onPlayAnyway: { showForceConfirm = true },
                            onDismiss: cancelIllegalPlay
                        )
                        .padding(.bottom, 14)
                    }
                    .padding(.bottom, geo.size.height * 0.42)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showForceConfirm, let pending = client.pendingIllegal {
                    IllegalPlaySheet(
                        reason: pending.reason,
                        onPlayAnyway: {
                            showForceConfirm = false
                            client.forcePlayPendingCard()
                        },
                        onCancel: {
                            showForceConfirm = false
                            cancelIllegalPlay()
                        }
                    )
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isChoosingUnoColor)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: client.pendingIllegal?.cardID)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showYourTurnBanner)
            .onAppear { motion.start() }
            .onDisappear { motion.stop() }
            .onChange(of: client.snapshot?.myHand.map(\.id) ?? []) { oldIDs, newIDs in
                handleHandArrivals(oldIDs: oldIDs, newIDs: newIDs)
            }
        }
    }

    /// The soft-enforcement moment, step two: dismisses the banner AND
    /// restores the card that had visually started leaving the fan.
    private func cancelIllegalPlay() {
        client.cancelPendingPlay()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            departingCardID = nil
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

    // MARK: turn + illegal-play messaging

    /// Plain-words nudge for what a legal play looks like right now, shown
    /// under the "YOUR TURN" banner — different per game family since
    /// "legal" means something different in each.
    private var turnHintText: String {
        guard let snap = client.snapshot else { return "" }
        switch snap.gameKind {
        case .wizard, .ohHell:
            if let leadSuit = snap.round?.currentTrick.first?.card.suit {
                return "Follow \(leadSuit.symbol) if you can"
            }
            return "You lead — play anything"
        case .crazyEights:
            if let suit = snap.round?.trumpSuit {
                return "Match \(suit.symbol), or play an eight"
            }
            if let top = snap.discardPile.last, let suit = top.suit, let rank = top.rank {
                return "Match \(suit.symbol) or \(rankLabel(rank)), or play an eight"
            }
            return "Match the top card, or play an eight"
        case .uno:
            if let color = snap.round?.trumpSuit?.unoColor {
                return "Match \(color.rawValue.capitalized), or the symbol"
            }
            return "Match the color or the symbol"
        case .freePlay:
            return "House rules apply"
        }
    }

    private func rankLabel(_ rank: Int) -> String {
        switch rank {
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        case 14: return "A"
        default: return "\(rank)"
        }
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
                // Deal-in / draw-in: a newly arrived card starts above the
                // top edge and lands into its slot once its stagger delay
                // elapses (see handleHandArrivals).
                let isArriving = arrivingCardIDs.contains(card.id)
                let arrivalOffset: CGFloat = isArriving ? -(size.height * 0.7) : 0

                CardView(card: card, faceUp: true, elevation: elevation)
                    .frame(width: cardWidth)
                    .rotationEffect(isSelected && dragState.isDragging
                        ? tiltWhileDragging(slot.angle, handHeight: size.height)
                        : slot.angle)
                    .offset(x: slot.offset.width + dragOffset.width + cardParallax.width + fisheye.x,
                            y: slot.offset.height + dragOffset.height + cardParallax.height + fisheye.y + arrivalOffset)
                    .zIndex(isSelected ? 100 : (isArriving ? 95 : slot.zIndex + fisheye.zBoost))
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

    // MARK: deal-in / draw-in animation

    /// New cards fly in from the top edge instead of popping into the fan —
    /// covers both a multi-card deal (2+ at once) and a single draw.
    /// Detected as a diff against the previous hand's ids, so reordering
    /// (sort mode) and removals (a play) never trigger it — only genuinely
    /// new cards do. Staggered 70ms apart with a soft tick as each lands.
    private func handleHandArrivals(oldIDs: [String], newIDs: [String]) {
        let oldSet = Set(oldIDs)
        let addedIDs = newIDs.filter { !oldSet.contains($0) }
        guard !addedIDs.isEmpty else { return }
        for id in addedIDs { arrivingCardIDs.insert(id) }
        for (i, id) in addedIDs.enumerated() {
            let delay = Double(i) * 0.07
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Haptics.tick()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                    arrivingCardIDs.remove(id)
                }
            }
        }
    }

    // MARK: gesture

    /// Gesture arbitration, all in one place: the first ~12pt of a drag
    /// decides its shape. Mostly horizontal (|dx| > |dy|) commits to a
    /// BROWSE scrub of the whole fan; mostly vertical commits to the
    /// existing PLAY drag (threshold + flick), unchanged. Below 12pt we
    /// don't know yet, so it behaves like the old play-drag/tap did —
    /// including the immediate select+haptic on touch-down — and unwinds
    /// cleanly into whichever mode wins.
    ///
    /// Browse can ALSO convert to play mid-drag, without lifting the
    /// finger: if it pauses over a card for ~0.35s (see
    /// trackBrowseStationary), that card arms and the rest of the drag
    /// plays it (armFromBrowse). Resuming horizontal motion before release
    /// cancels back to browse (cancelArmedPlayBackToBrowse).
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
                        browseStationaryAnchor = nil
                        browseStationaryWorkItem?.cancel()
                    }
                }

                switch gestureIntent {
                case .browse:
                    updateBrowse(value: value, index: index, in: size)
                case .play:
                    if isPlayArmedFromBrowse {
                        let armedDX = dx - armAnchorTranslation.width
                        let armedDY = dy - armAnchorTranslation.height
                        // Moving horizontally again, before release, cancels
                        // the arm and resumes browsing.
                        if abs(armedDX) > 10 && abs(armedDX) > abs(armedDY) {
                            cancelArmedPlayBackToBrowse(value: value, index: index, in: size)
                            return
                        }
                        applyPlayTranslation(CGSize(width: armedDX, height: armedDY), handHeight: size.height)
                    } else {
                        if selectedCardID != card.id {
                            selectedCardID = card.id
                            Haptics.tick()
                        }
                        applyPlayTranslation(value.translation, handHeight: size.height)
                    }
                case .undetermined:
                    if selectedCardID != card.id {
                        selectedCardID = card.id
                        Haptics.tick()
                    }
                    applyPlayTranslation(value.translation, handHeight: size.height)
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
                    // velocity. When armed from a browse, the translation
                    // used for that check is measured from the arm point,
                    // not the original touch-down (which may carry a lot
                    // of horizontal browse motion that isn't part of the
                    // play gesture at all).
                    let effectiveTranslation: CGSize
                    let effectivePredicted: CGSize
                    if isPlayArmedFromBrowse {
                        effectiveTranslation = CGSize(
                            width: value.translation.width - armAnchorTranslation.width,
                            height: value.translation.height - armAnchorTranslation.height)
                        effectivePredicted = CGSize(
                            width: value.predictedEndTranslation.width - armAnchorTranslation.width,
                            height: value.predictedEndTranslation.height - armAnchorTranslation.height)
                    } else {
                        effectiveTranslation = value.translation
                        effectivePredicted = value.predictedEndTranslation
                    }
                    let playingCard = isPlayArmedFromBrowse
                        ? (hand.first { $0.id == selectedCardID } ?? card)
                        : card
                    let progress = dragState.playProgress(handHeight: size.height)
                    let flicked = effectivePredicted.height < -size.height * 0.35
                        && effectiveTranslation.height < -20
                    if progress >= 1 || flicked {
                        playSelectedCard(playingCard, in: size, velocity: value.velocity)
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                            dragState = CardDragState()
                            selectedCardID = nil
                        }
                    }
                }
                gestureIntent = .undetermined
                isPlayArmedFromBrowse = false
                browseStationaryWorkItem?.cancel()
                browseStationaryWorkItem = nil
                browseStationaryAnchor = nil
            }
    }

    /// The shared "lift toward playing" bookkeeping: progress/elevation
    /// derive from `dragState.translation`, so both a plain play-drag and
    /// one armed mid-browse (which measures from the arm point, not the
    /// original touch-down) go through the same math.
    private func applyPlayTranslation(_ translation: CGSize, handHeight: CGFloat) {
        let wasArmed = dragState.playProgress(handHeight: handHeight) >= 1
        dragState.isDragging = true
        dragState.translation = translation
        let isArmed = dragState.playProgress(handHeight: handHeight) >= 1
        if isArmed != wasArmed { Haptics.arm() }
    }

    /// Shared by a fresh browse frame and a bounce-back from an armed play
    /// (see cancelArmedPlayBackToBrowse) — both need the exact same scroll
    /// math relative to the ORIGINAL touch-down, which `browseAnchorScroll`
    /// stays fixed against for the whole gesture regardless of how intent
    /// flip-flops mid-drag.
    private func updateBrowse(value: DragGesture.Value, index: Int, in size: CGSize) {
        let dx = value.translation.width
        let layout = fanLayout(in: size)
        let bounds = layout.scrollBounds()
        let anchorX = layout.slot(for: index, scrollOffset: browseAnchorScroll).offset.width
        // Direct manipulation: the fan scrubs 1:1 with the finger, clamped
        // so you can't scroll an end clean off screen past center.
        let newScroll = min(max(browseAnchorScroll + dx, bounds.lowerBound), bounds.upperBound)
        fanScroll = newScroll
        let fingerX = anchorX + dx
        browseFingerX = fingerX
        let newFocus = layout.nearestIndex(toDisplayedX: fingerX, scrollOffset: newScroll)
        if newFocus != focusedCardIndex {
            Haptics.tick()
            focusedCardIndex = newFocus
        }
        trackBrowseStationary(value: value)
    }

    /// If the finger holds still (within ~6pt) for 0.35s while browsing,
    /// the card under it arms for play. A wall-clock timer, not gesture-
    /// callback cadence — a truly still finger may not keep generating
    /// onChanged events to time against.
    private func trackBrowseStationary(value: DragGesture.Value) {
        let point = value.location
        if let anchor = browseStationaryAnchor,
           hypot(point.x - anchor.x, point.y - anchor.y) <= 6 {
            return // still resting — let the pending timer keep counting
        }
        browseStationaryAnchor = point
        let anchorTranslation = value.translation
        browseStationaryWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            armFromBrowse(anchorTranslation: anchorTranslation)
        }
        browseStationaryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /// The finger paused over `focusedCardIndex` long enough — that card
    /// lifts as if a fresh play-drag had started right here, no need to
    /// lift the finger and touch down again.
    private func armFromBrowse(anchorTranslation: CGSize) {
        guard gestureIntent == .browse,
              let index = focusedCardIndex, hand.indices.contains(index) else { return }
        let card = hand[index]
        Haptics.arm()
        gestureIntent = .play
        isPlayArmedFromBrowse = true
        armAnchorTranslation = anchorTranslation
        selectedCardID = card.id
        dragState = CardDragState()
        dragState.isDragging = true
        browseFingerX = nil
    }

    /// The other half of the arm/cancel pair: horizontal motion resumes
    /// before release, so the armed play reverts to a browse — resuming
    /// exactly where the finger is, since `browseAnchorScroll` never
    /// changed while armed.
    private func cancelArmedPlayBackToBrowse(value: DragGesture.Value, index: Int, in size: CGSize) {
        gestureIntent = .browse
        isPlayArmedFromBrowse = false
        selectedCardID = nil
        dragState = CardDragState()
        updateBrowse(value: value, index: index, in: size)
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
            // host said "illegal", the illegal-play banner is already up
            // and its dismiss/cancel path restores the departing card.
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

/// Gold, gently pulsing "it's your move" banner shown above the fan
/// whenever it's this player's turn. A fresh instance mounts each time it
/// appears (it's behind an `if`), so the pulse cycle always restarts clean.
private struct TurnBanner: View {
    let hint: String

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 4) {
            Text("YOUR TURN")
                .font(.system(.headline, design: .serif).weight(.heavy))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.black.opacity(0.3))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(pulse ? 0.75 : 0.4), lineWidth: 1.5))
        )
        .shadow(color: CardStyle.gold.opacity(pulse ? 0.5 : 0.15), radius: pulse ? 16 : 6)
        .scaleEffect(pulse ? 1.035 : 1.0)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// The soft-enforcement moment, step one: a quiet inline note near the fan
/// instead of a full-screen block — the hand stays visible and playable.
/// Tapping "play it anyway" escalates to IllegalPlaySheet, the real confirm.
struct IllegalPlayBanner: View {
    let reason: String
    let onPlayAnyway: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CardStyle.gold)
            Text(reason)
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onPlayAnyway) {
                Text("play it anyway")
                    .font(.footnote.weight(.semibold))
                    .underline()
                    .foregroundStyle(CardStyle.gold)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }
}

/// The deliberate second step after an illegal warning — now reached by
/// tapping the inline banner's "play it anyway" link rather than shown
/// automatically. Same "do it on purpose" framing as before.
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
