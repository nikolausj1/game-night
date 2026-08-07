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
    @Environment(\.accessibilityReduceMotion) private var motionReduced

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
    // Draw-penalty banner (UNO stacked draw-two/draw-four): bumped each time
    // a play is rejected while a draw is owed, so DrawPenaltyBanner's shake
    // has a fresh trigger value to animate on (see the pendingIllegal
    // onChange below) instead of the illegal-play sheet escalating.
    @State private var drawShakeTrigger = 0

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

    // UNO's active color after a wild — shown as a swatch integrated into
    // the turn banner (see TurnBanner below) rather than the unlabeled
    // upper-right tag nobody noticed (see HandStatusStrip, which no longer
    // renders it for UNO). `trumpSuit` is UNO's wire format for the
    // declared color (see Card.swift's Suit↔UnoColor mapping); non-UNO
    // games never populate this.
    private var activeUnoColor: UnoColor? {
        guard client.snapshot?.gameKind == .uno else { return nil }
        return client.snapshot?.round?.trumpSuit?.unoColor
    }

    // `ClientSnapshot.myPendingDraw` (0 = no pending draw penalty owed)
    // lands from a parallel engine change; wrapped in its own helper so if
    // that ever regresses to not compiling, the fix is a one-line swap to
    // `0` here instead of hunting every call site.
    private var pendingDraw: Int {
        client.snapshot?.myPendingDraw ?? 0
    }

    private var showDrawPenaltyBanner: Bool { pendingDraw > 0 }

    private var showYourTurnBanner: Bool {
        isMyTurn && client.pendingIllegal == nil && !showDrawPenaltyBanner
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FeltBackground()

                VStack(spacing: 0) {
                    HandStatusStrip(client: client, onLeave: onLeave)
                    Spacer()
                    if showDrawPenaltyBanner {
                        DrawPenaltyBanner(count: pendingDraw,
                                          shakeTrigger: drawShakeTrigger,
                                          onTapDraw: { client.drawCard() })
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    } else if showYourTurnBanner {
                        TurnBanner(hint: turnHintText, unoColor: activeUnoColor)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    playZoneHint
                    Spacer()
                    // First time it's your turn with cards to play — a
                    // one-shot TipKit nudge toward the flick gesture.
                    GhostHintTipView(tip: HandFlickTip())
                        .padding(.bottom, 4)
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

                // Suppressed while a draw is owed (see the pendingIllegal
                // onChange below) — the draw instruction IS the feedback
                // for a rejected play there, via the banner's shake.
                if pendingDraw == 0, let pending = client.pendingIllegal {
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

                if pendingDraw == 0, showForceConfirm, let pending = client.pendingIllegal {
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
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showDrawPenaltyBanner)
            .onAppear {
                motion.start()
                HandFlickTip.isEligible = showYourTurnBanner && !hand.isEmpty
                applyDemoGestureIfAsked(size: geo.size)
            }
            .onDisappear { motion.stop() }
            .onChange(of: showYourTurnBanner) { _, newValue in
                HandFlickTip.isEligible = newValue && !hand.isEmpty
            }
            .onChange(of: client.pendingIllegal?.cardID) { _, newID in
                // A play was rejected while a draw is owed: no illegal-play
                // banner/sheet (suppressed above) — pulse the draw banner
                // instead and restore the card immediately, same as
                // cancelIllegalPlay's second step.
                guard newID != nil, pendingDraw > 0 else { return }
                drawShakeTrigger += 1
                client.cancelPendingPlay()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    departingCardID = nil
                }
            }
            .onChange(of: client.snapshot?.myHand.map(\.id) ?? []) { oldIDs, newIDs in
                handleHandArrivals(oldIDs: oldIDs, newIDs: newIDs)
            }
            .onChange(of: hand.count) { oldCount, newCount in
                handleHandSizeChange(oldCount: oldCount, newCount: newCount, in: geo.size)
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
            // With an active color, TurnBanner already shows it as a
            // swatch + "Play <Color>" — restating it in the hint too would
            // be the same information twice in the same banner.
            if snap.round?.trumpSuit?.unoColor != nil {
                return "Or match the symbol"
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

    /// A fraction of the DEVICE width, capped at 130pt — and deliberately
    /// independent of `hand.count`. A 3-card hand and a 7-card hand get the
    /// identical card size; only the arc's spread (see
    /// HandFanLayout.totalSpreadDegrees) and the wide-hand scroll threshold
    /// vary with count. If a small hand ever looks like it has bigger
    /// cards than a bigger one, that's a new bug here, not a fix — the
    /// "1-3 cards look modest" goal is met by tightening the arc, not by
    /// touching this.
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
                // Reduce Motion: a short slide from just above the slot
                // instead of a long flight in from off the top edge.
                let arrivalOffset: CGFloat = isArriving
                    ? (motionReduced ? -(size.height * 0.06) : -(size.height * 0.7))
                    : 0
                // Wide-hand edge cue: fades toward the screen edges instead
                // of the old mask-based crop (see edgeFadeOpacity's doc
                // comment for why this replaced it). A card mid-play must
                // never fade, no matter where it's dragged to.
                let edgeOpacity = edgeFadeOpacity(displayedX: slot.offset.width,
                                                   containerWidth: size.width,
                                                   cardWidth: cardWidth,
                                                   isWide: layout.isWide,
                                                   exempt: isSelected)

                CardView(card: card, faceUp: true, elevation: elevation)
                    .frame(width: cardWidth)
                    .rotationEffect(isSelected && dragState.isDragging
                        ? tiltWhileDragging(slot.angle, handHeight: size.height)
                        : slot.angle)
                    .offset(x: slot.offset.width + dragOffset.width + cardParallax.width + fisheye.x,
                            y: slot.offset.height + dragOffset.height + cardParallax.height + fisheye.y + arrivalOffset)
                    .zIndex(isSelected ? 100 : (isArriving ? 95 : slot.zIndex + fisheye.zBoost))
                    .opacity(departingCardID == card.id ? 0 : edgeOpacity)
                    .gesture(playGesture(for: card, index: index, in: size))
                    .animation(.spring(response: 0.34, dampingFraction: 0.72),
                               value: selectedCardID)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7),
                               value: browseFingerX)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(card.accessibleName)
                    .accessibilityHint(isMyTurn ? "Flick up to play" : "")
                    .accessibilityAddTraits(.isButton)
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
        // Re-saturates the arc smoothly when the hand crosses the wide
        // threshold in either direction (a play shrinking it back down, or
        // a big deal pushing it past) instead of the spread snapping.
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: hand.count)
    }

    /// Wide-hand edge cue, per-card opacity — replaces a wave-4 `.mask()`
    /// on the whole fan ZStack that turned out to be a REGRESSION, not a
    /// nicety: SwiftUI's `.mask()` doesn't just fade, it clips the masked
    /// view to its own rendered layer bounds. The fan's frame is only the
    /// bottom ~42% of the screen (see `fan(in:)`'s call site), so that mask
    /// cut wing cards off at the bottom AND made a card being swiped up
    /// toward the play zone vanish the instant it left the fan's frame —
    /// exactly the "slides under a green layer of felt" the field report
    /// described. Even the identity (`active: false`) gradient still
    /// clipped, since a mask forces layer compositing regardless of its
    /// own content.
    ///
    /// Per-card opacity has no such bounds problem — each card's own
    /// `.opacity()` is independent of every other view's frame, so a card
    /// can fade near the fan's horizontal edges while still rendering
    /// full-height all the way up the screen during a play.
    ///
    /// `displayedX` is the card's slot offset (pre-drag, pre-parallax,
    /// pre-fisheye — those are small perturbations that would only add
    /// jitter to the fade point, not correctness) relative to the fan's
    /// horizontal center. `containerWidth` is the actual screen width, so
    /// the ramp targets the true screen edge, not some inner fan boundary.
    /// Ramps smoothly (smoothstep, matching the fisheye easing elsewhere in
    /// this file) from fully opaque to ~25% over the outer half a
    /// card-width, then holds at 25% for anything further off-edge — never
    /// fully invisible, so the "there's more hand here" cue stays legible.
    /// Narrow hands never overflow the screen, so they're always opaque.
    /// A card that's selected/dragged (mid-play) is exempt unconditionally
    /// — it must never fade, no matter where the gesture carries it.
    private func edgeFadeOpacity(displayedX: CGFloat, containerWidth: CGFloat,
                                  cardWidth: CGFloat, isWide: Bool, exempt: Bool) -> Double {
        guard isWide, !exempt else { return 1 }
        let halfWidth = containerWidth / 2
        let rampDistance = max(cardWidth * 0.5, 1)
        let rampStart = halfWidth - rampDistance
        let distance = abs(displayedX)
        guard distance > rampStart else { return 1 }
        let t = min(1, (distance - rampStart) / rampDistance)
        let eased = t * t * (3 - 2 * t) // smoothstep
        return 1 - eased * 0.75 // 1.0 → 0.25
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

    /// A hand that shrinks back under `wideThreshold` (cards played down)
    /// must condense cleanly: without this, `fanScroll` keeps whatever
    /// value browsing last left it at, and although the render-time clamp
    /// in `fan(in:)` already pins the DISPLAYED position to 0 once
    /// `scrollBounds()` collapses to `0...0`, the underlying state var
    /// stays stale — the next browse or the next time the hand grows wide
    /// again would anchor against that leftover offset instead of a clean
    /// slate. Explicitly resetting it here, with animation, is what makes
    /// the arc's re-saturation (a separate `.animation(value: hand.count)`
    /// on the fan) read as a smooth condense rather than a silent snap.
    /// Growing past the threshold is left alone — a freshly dealt hand
    /// should already start centered.
    private func handleHandSizeChange(oldCount: Int, newCount: Int, in size: CGSize) {
        guard newCount < oldCount, fanScroll != 0 else { return }
        let shrunkLayout = HandFanLayout(cardCount: newCount, containerWidth: size.width, cardWidth: fanCardWidth(in: size))
        guard !shrunkLayout.isWide else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            fanScroll = 0
        }
        focusedCardIndex = nil
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
        // Reduce Motion: the same stagger (still useful — a deal reads as
        // discrete cards, not a pop), but each lands with a quick short
        // slide instead of the springy flight-in.
        for (i, id) in addedIDs.enumerated() {
            let delay = Double(i) * 0.07
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Haptics.tick()
                withAnimation(motionReduced ? .easeOut(duration: 0.12)
                                            : .spring(response: 0.5, dampingFraction: 0.75)) {
                    arrivingCardIDs.remove(id)
                }
            }
        }
    }

    // MARK: gesture

    /// Sim-verify hook, wave 5: turns `-demoDragProgress <0...1>` (plus the
    /// optional `-demoDragX <0...1>`, see DemoData) into the exact same
    /// state a real mid-play drag would leave behind — `selectedCardID` and
    /// `dragState.translation` — so a screenshot taken any time after
    /// launch is a frozen, deterministic frame of "a card N% of the way to
    /// the play zone," no timer or gesture simulation needed. Uses the
    /// inverse of `CardDragState.playProgress`'s own math (progress =
    /// -translation.height / (handHeight * 0.26)) so `1.0` really does land
    /// exactly at the commit threshold, not an eyeballed approximation of
    /// it. `-demoDragX` picks which card by lateral position rather than
    /// raw index (0 = leftmost, 1 = rightmost, 0.5 default = the middle
    /// card) so it stays meaningful across `-demoHandCount` sizes and can
    /// target a wide hand's edge cards. No-op unless both `-demoHand` and
    /// `-demoDragProgress` are present — real play never touches this path.
    private func applyDemoGestureIfAsked(size: CGSize) {
        guard DemoData.wantsHandDemo,
              let rawProgress = DemoData.demoDragProgress,
              !hand.isEmpty else { return }
        let progress = min(1, max(0, rawProgress))
        let dragX = min(1, max(0, DemoData.demoDragX))
        let index = hand.count > 1 ? Int((dragX * Double(hand.count - 1)).rounded()) : 0
        selectedCardID = hand[index].id
        dragState = CardDragState()
        dragState.isDragging = true
        let threshold = size.height * 0.26
        dragState.translation = CGSize(width: 0, height: -CGFloat(progress) * threshold)
    }

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
    /// UNO's active color after a wild, integrated right into this banner —
    /// the one place a player is actually deciding what to play, unlike the
    /// old unlabeled upper-right tag (see HandStatusStrip). Nil for every
    /// other game and for UNO before any wild has been played.
    var unoColor: UnoColor? = nil

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 4) {
            Text("YOUR TURN")
                .font(.system(.headline, design: .serif).weight(.heavy))
                .tracking(3)
                .foregroundStyle(CardStyle.gold)
            if let unoColor {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(UnoStyle.field(for: unoColor))
                        .frame(width: 15, height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                        )
                    Text("Play \(unoColor.rawValue.capitalized)")
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
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

/// UNO's manual stacked draw (draw-two/draw-four with no card to answer
/// it): takes over the turn banner's spot as the instruction itself — "DRAW
/// 4" then a live "3 to go" as each tap lands — and doubles as the draw
/// affordance. Drawing is normally a table-side (public) interaction (see
/// HandView.playZoneHint's doc comment), but a personal penalty is the one
/// case a private per-card tap on the phone makes sense: the table can't
/// know which of your taps is "for the penalty" vs. an ordinary draw.
/// Illegal-play feedback is suppressed while this is up (see the
/// `pendingIllegal` onChange in HandView.body) — `shakeTrigger` pulses this
/// banner instead so a rejected play still gets an answer.
private struct DrawPenaltyBanner: View {
    let count: Int
    let shakeTrigger: Int
    let onTapDraw: () -> Void

    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        Button(action: onTapDraw) {
            VStack(spacing: 4) {
                Text(count == 1 ? "DRAW" : "DRAW \(count)")
                    .font(.system(.headline, design: .serif).weight(.heavy))
                    .tracking(3)
                    .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.35))
                Text(count == 1 ? "Tap to draw" : "\(count) to go — tap to draw")
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(.black.opacity(0.3))
                    .overlay(Capsule().strokeBorder(Color(red: 0.9, green: 0.4, blue: 0.35).opacity(0.55), lineWidth: 1.5))
            )
        }
        .buttonStyle(.plain)
        .offset(x: shakeOffset)
        .onChange(of: shakeTrigger) { _, _ in
            Haptics.tick()
            withAnimation(.interpolatingSpring(stiffness: 900, damping: 12)) {
                shakeOffset = -10
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.interpolatingSpring(stiffness: 900, damping: 10)) {
                    shakeOffset = 0
                }
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
            .accessibilityLabel("Dismiss")
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
            // Mirror-tiled, still `.tile`: FeltTexture.png has baked
            // lighting, so a plain tile stamps a seam at every repeat —
            // but stretching one crop to fill is WORSE here: an
            // aspectRatio(.fill) image with no frame changes the layout
            // proposal itself (it inflated the whole hand screen to a
            // 860×860 square — blowing up the fan geometry and pushing
            // the status strip offscreen) and magnifies the bake into
            // huge dark bands. Mirroring 2×2 once at load makes every
            // tile boundary self-matching, keeps grain at native scale,
            // and keeps .tile's layout-neutral sizing.
            Image(uiImage: FeltTile.mirrored)
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

/// FeltTexture, pre-mirrored 2×2 so tiling it is seamless by construction
/// (each edge meets its own reflection). Built once, cached for the app's
/// lifetime.
enum FeltTile {
    static let mirrored: UIImage = {
        guard let base = UIImage(named: "FeltTexture") else { return UIImage() }
        let w = base.size.width, h = base.size.height
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w * 2, height: h * 2))
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            base.draw(in: rect)
            cg.saveGState(); cg.translateBy(x: w * 2, y: 0); cg.scaleBy(x: -1, y: 1)
            base.draw(in: rect); cg.restoreGState()
            cg.saveGState(); cg.translateBy(x: 0, y: h * 2); cg.scaleBy(x: 1, y: -1)
            base.draw(in: rect); cg.restoreGState()
            cg.saveGState(); cg.translateBy(x: w * 2, y: h * 2); cg.scaleBy(x: -1, y: -1)
            base.draw(in: rect); cg.restoreGState()
        }
    }()
}

/// Light haptic vocabulary; one voice for the whole app.
enum Haptics {
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func arm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func play() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
