import SwiftUI

// MARK: - Layout

/// Where everything sits on the iPad felt. The casino arc: the dealer at
/// the top edge (chip rack, shoe on the right, discard tray on the left),
/// one engraved betting spot per seat on a smile-shaped arc along the
/// bottom. Pure geometry from `size` + seat count, so the toss math, the
/// chip flights, and the static furniture can never disagree about where
/// a spot is.
struct BJLayout {
    let size: CGSize
    let n: Int
    let cw: CGFloat        // card width for a full-size hand and the dealer
    let chipW: CGFloat
    let spotD: CGFloat
    private let xSpan: CGFloat

    init(size: CGSize, seats: Int) {
        self.size = size
        n = min(max(seats, 1), 5)
        let spans: [CGFloat] = [0, 0.32, 0.52, 0.66, 0.76]
        xSpan = spans[n - 1] * size.width
        let spacing = n > 1 ? xSpan / CGFloat(n - 1) : size.width * 0.3
        cw = max(40, min(size.width * 0.086, 104, spacing * 0.52))
        chipW = cw * 0.5
        spotD = cw * 1.12
    }

    // seats
    private func u(_ seat: Int) -> CGFloat { n > 1 ? (CGFloat(seat) / CGFloat(n - 1) - 0.5) * 2 : 0 }

    func spot(_ seat: Int) -> CGPoint {
        let uu = u(seat)
        let drop = 0.095 * (size.width > 0 ? xSpan / (0.76 * size.width) : 0)
        return CGPoint(x: size.width * 0.5 + uu * xSpan / 2,
                       y: size.height * (0.745 - drop * uu * uu))
    }

    /// The player's chip rack / name plate; chips fly to and from here.
    func plate(_ seat: Int) -> CGPoint {
        let s = spot(seat)
        return CGPoint(x: s.x, y: s.y + spotD / 2 + cw * 0.46)
    }

    func handScale(_ handCount: Int) -> CGFloat { handCount > 1 ? 0.84 : 1 }

    func handX(seat: Int, hand: Int, of count: Int) -> CGFloat {
        let hs = cw * 1.32
        return spot(seat).x + (CGFloat(hand) - CGFloat(count - 1) / 2) * (count > 1 ? hs : 0)
    }

    func cardAnchorY(_ seat: Int) -> CGFloat { spot(seat).y - cw * 1.58 }

    func betPoint(seat: Int, hand: Int, of count: Int) -> CGPoint {
        CGPoint(x: handX(seat: seat, hand: hand, of: count), y: spot(seat).y)
    }

    /// A player card's resting pose: cascaded up and to the right, each card
    /// landing a little off-square, the way a dealer's hand drops them.
    func playerRest(seat: Int, hand: Int, of count: Int, index: Int, id: String) -> (point: CGPoint, rotation: Double) {
        let cws = cw * handScale(count)
        let dx = cws * 0.32
        let jy = CGFloat(TableGeometry.jitterDegrees(cardID: id + "y")) * 0.22
        let jx = CGFloat(TableGeometry.jitterDegrees(cardID: id + "x")) * 0.18
        let x = handX(seat: seat, hand: hand, of: count) + (CGFloat(index) - 0.5) * dx + jx
        let y = cardAnchorY(seat) - CGFloat(index) * cws * 0.07 + jy
        return (CGPoint(x: x, y: y), TableGeometry.jitterDegrees(cardID: id) * 0.33)
    }

    func cardWidth(handCount: Int) -> CGFloat { cw * handScale(handCount) }

    /// Dealer cards land squared and evenly spaced.
    func dealerRest(index: Int, id: String) -> (point: CGPoint, rotation: Double) {
        let x0 = size.width * 0.5 - cw * 0.39
        return (CGPoint(x: x0 + CGFloat(index) * cw * 0.78, y: size.height * 0.26),
                TableGeometry.jitterDegrees(cardID: id) * 0.04)
    }

    // dealer furniture
    var shoeWidth: CGFloat { min(size.width * 0.16, 200) }
    var shoeCenter: CGPoint { CGPoint(x: size.width * 0.80, y: size.height * 0.165) }
    /// Where a dealt card leaves the shoe (the brass-lipped slot).
    var shoeSlot: CGPoint {
        CGPoint(x: shoeCenter.x - shoeWidth * 0.27, y: shoeCenter.y + shoeWidth * 0.9 * 0.26)
    }
    var trayWidth: CGFloat { size.width * 0.15 }
    var trayCenter: CGPoint { CGPoint(x: size.width * 0.17, y: size.height * 0.14) }
    var rackCenter: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.07) }
    var rackSize: CGSize { CGSize(width: size.width * 0.25, height: size.height * 0.082) }
    var dealerLabel: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.138) }
    var dealerTotal: CGPoint {
        CGPoint(x: size.width * 0.5 - cw * 0.39 - cw * 0.78, y: size.height * 0.26)
    }

    func point(_ a: BJAnchor, handCounts: [Int]) -> CGPoint {
        switch a {
        case .dealerRack: return rackCenter
        case .playerRack(let s): return plate(s)
        case .spot(let s, let h):
            let c = handCounts.indices.contains(s) ? max(1, handCounts[s]) : 1
            return betPoint(seat: s, hand: h, of: c)
        }
    }

    // MARK: toss geometry (reuses FeltPhysics.pileToss — see note)

    /// The house pile-toss solve, launched from the shoe slot (or a card's
    /// old slot, for a split) instead of a seat's rim. `FeltPhysics.pileToss`
    /// derives its entry point from a seat anchor as `0.5 + (a - 0.5) * 1.22`
    /// (and 0.47 for y); the inverse of that maps the desired launch point
    /// to the anchor to hand it, so the math is reused, not forked. Only the
    /// rotations (squared dealer cards vs. tossed player cards) and the apex
    /// (a card dealt from a shoe skims, it does not lob) are adjusted.
    func toss(id: String, from launch: CGPoint, to rest: CGPoint, rotation: Double, dealer: Bool) -> FeltPhysics.PileToss {
        let ex = launch.x / max(size.width, 1), ey = launch.y / max(size.height, 1)
        let anchor = CGPoint(x: 0.5 + (ex - 0.5) / 1.22, y: 0.47 + (ey - 0.47) / 1.22)
        let base = FeltPhysics.pileToss(
            cardID: id, seatAnchor: anchor,
            restPoint: CGPoint(x: rest.x / max(size.width, 1), y: rest.y / max(size.height, 1)),
            tableSize: size)
        let spin: Double = TableGeometry.jitterDegrees(cardID: id) >= 0 ? 1 : -1
        return FeltPhysics.PileToss(
            entry: base.entry, control: base.control, touchdown: base.touchdown, rest: base.rest,
            entryRotation: rotation + spin * (dealer ? 10 : 24), restRotation: rotation,
            settleTwist: spin * (dealer ? 0.5 : 1.3), apex: base.apex * 0.45,
            duration: base.duration, touchdownFraction: base.touchdownFraction)
    }
}

// MARK: - One card, one motion

/// A blackjack card on the felt, in flight or at rest. The same
/// single-progress design as `PileTossCardView`: `progress` is the ONE
/// animated scalar and position, height, rotation, scale and the separated
/// ground shadow all come from `FeltPhysics.evaluate` at the same instant.
/// Additions over the pile card: it can ride face-down and turn face-up in
/// flight (a dealer turning a card as it leaves the shoe), it can be the
/// hole card that later does a real 3D flip (`flip` 0 -> 180), it can lie
/// sideways (a doubled hand), and it can tilt for a peek.
struct BJCardView: View, Animatable {
    var progress: CGFloat
    /// 0 = face down, 180 = face up. Changing it under an `.animation`
    /// is a real 3D flip.
    var flip: Double
    var peek: Double
    let card: Card
    let toss: FeltPhysics.PileToss
    let cardWidth: CGFloat
    let tableSize: CGSize
    let sideways: Bool
    /// Cards leaving the shoe turn over in the air; a card sliding from one
    /// slot to another (a split) is already face-up and stays that way.
    var turnsInFlight = true

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, Double>, Double> {
        get { AnimatablePair(AnimatablePair(progress, flip), peek) }
        set {
            progress = newValue.first.first
            flip = newValue.first.second
            peek = newValue.second
        }
    }

    private func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let frame = FeltPhysics.evaluate(toss, progress: progress, tableSize: tableSize)
        let airborne = frame.heightPoints > 0.5
        // Face-up cards leave the shoe face-down and turn over in the air.
        let inFlight = progress < 0.999
        let angle: Double = (turnsInFlight && inFlight && flip >= 179.9)
            ? 180 * smooth((Double(progress) - 0.10) / 0.5) : flip
        let bump: CGFloat = 1 + 0.07 * CGFloat(sin(angle * .pi / 180))
        ZStack {
            if airborne {
                FeltGroundShadow(lift: frame.heightPoints, cardWidth: cardWidth)
                    .position(frame.position)
            }
            faceStack(angle)
                .frame(width: cardWidth)
                .rotation3DEffect(.degrees(peek), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
                .rotationEffect(.degrees(frame.rotation + (sideways ? 90 : 0)))
                .scaleEffect(frame.scale * bump)
                .position(x: frame.position.x, y: frame.position.y - frame.heightPoints)
        }
    }

    private func faceStack(_ angle: Double) -> some View {
        ZStack {
            if angle < 90 {
                CardView(card: card, faceUp: false)
            } else {
                CardView(card: card, faceUp: true)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
    }
}

// MARK: - Furniture

/// Engraved text laid along a circular arc (the felt's "BLACKJACK PAYS 3 TO 2").
struct BJArcText: View {
    let text: String
    let radius: CGFloat
    let center: CGPoint        // the arc's circle center
    let fontSize: CGFloat
    var tracking: CGFloat = 1.0

    var body: some View {
        let chars = Array(text)
        let step = (fontSize * 0.74 * tracking) / radius
        let start = -step * CGFloat(chars.count - 1) / 2
        ZStack {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                let theta = start + step * CGFloat(i)
                glyph(ch)
                    .rotationEffect(.radians(Double(-theta)))
                    .position(x: center.x + radius * sin(theta), y: center.y + radius * cos(theta))
            }
        }
        .accessibilityHidden(true)
    }

    private func glyph(_ ch: Character) -> some View {
        ZStack {
            Text(String(ch))
                .foregroundStyle(.black.opacity(0.5))
                .offset(y: 1.4)
            Text(String(ch))
                .foregroundStyle(CardStyle.gold.opacity(0.62))
        }
        .font(.system(size: fontSize, weight: .semibold, design: .serif))
    }
}

/// The felt's printed rules, concentric arcs bowed toward the players.
struct BJRulesArc: View {
    let layout: BJLayout
    let config: BlackjackConfig

    var body: some View {
        let w = layout.size.width, h = layout.size.height
        let baseY = h * 0.478
        let r = w * 0.62
        let center = CGPoint(x: w * 0.5, y: baseY - r)
        let f = max(11, min(20, w * 0.0165))
        let pay = "BLACKJACK PAYS \(config.blackjackPayoutNumerator) TO \(config.blackjackPayoutDenominator)"
        let rule = config.dealerHitsSoft17 ? "DEALER HITS SOFT 17" : "DEALER MUST STAND ON ALL 17s"
        ZStack {
            BJArcText(text: pay, radius: r, center: center, fontSize: f * 1.15, tracking: 1.25)
            BJArcText(text: rule, radius: r + f * 1.9, center: center, fontSize: f * 0.82, tracking: 1.2)
            if config.insuranceEnabled {
                BJArcText(text: "INSURANCE PAYS 2 TO 1", radius: r + f * 3.5, center: center, fontSize: f * 0.7, tracking: 1.2)
            }
        }
    }
}

/// One engraved betting spot.
struct BJSpotMarking: View {
    let number: Int
    let diameter: CGFloat
    let active: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.10))
            Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1.6).offset(y: 1.4)
            Circle().strokeBorder(CardStyle.gold.opacity(0.62), lineWidth: 1.5)
            Circle().strokeBorder(CardStyle.gold.opacity(0.18), lineWidth: 1).padding(diameter * 0.09)
            Text("\(number)")
                .font(.system(size: diameter * 0.36, weight: .semibold, design: .serif))
                .foregroundStyle(CardStyle.gold.opacity(0.20))
            if active {
                Circle().strokeBorder(CardStyle.gold, lineWidth: 3)
                    .shadow(color: CardStyle.gold.opacity(0.9), radius: pulse ? 14 : 6)
                    .scaleEffect(pulse ? 1.07 : 1.0)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeInOut(duration: 0.25), value: active)
        .accessibilityHidden(true)
    }
}

/// The dealer's chip rack: the house bank the payouts come from.
struct BJRackView: View {
    let size: CGSize
    let chipWidth: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.18, blue: 0.10),
                                              Color(red: 0.16, green: 0.09, blue: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.black.opacity(0.55))
                .padding(5)
            HStack(spacing: chipWidth * 0.18) {
                ForEach(BJChipDenom.allCases) { d in
                    BJChipColumn(denom: d, count: d == .hundred ? 5 : 6, width: chipWidth)
                }
            }
            .padding(.top, 2)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.45), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

/// The discard tray: the dealer sweeps finished hands into it.
struct BJTrayView: View {
    let width: CGFloat
    let count: Int

    var body: some View {
        let h = width * 0.62
        let layers = min(9, count / 5 + (count > 0 ? 1 : 0))
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.18, blue: 0.10),
                                              Color(red: 0.15, green: 0.085, blue: 0.045)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.black.opacity(0.6))
                .padding(6)
            ForEach(0..<max(layers, 0), id: \.self) { i in
                CardBackView()
                    .frame(width: width * 0.36)
                    .rotationEffect(.degrees(Double(i % 3) * 1.6 - 1.6))
                    .offset(x: CGFloat(i) * 1.1, y: -CGFloat(i) * 1.6)
            }
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1)
        }
        .frame(width: width, height: h)
        .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Discard tray, \(count) cards")
    }
}

/// The dealing shoe. A cream card edge sits in the brass-lipped slot and
/// slides out a little with every card dealt.
struct BJShoeView: View {
    let width: CGFloat
    let kick: Int

    var body: some View {
        ZStack {
            if BJChipDenom.hasAsset("BlackjackShoe") {
                Image("BlackjackShoe").resizable().interpolation(.high)
                    .aspectRatio(220.0 / 198.0, contentMode: .fit)
            } else {
                fallbackShoe
            }
            // The edge of the next card, nudged out on every deal.
            Capsule()
                .fill(LinearGradient(colors: [CardStyle.stockTop, CardStyle.stockBottom],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.27, height: width * 0.034)
                .rotationEffect(.degrees(-24))
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                .offset(x: -width * 0.25, y: width * 0.115)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: kick) { content, v in
                    content.offset(x: -v * width * 0.045, y: v * width * 0.032)
                } keyframes: { _ in
                    LinearKeyframe(1, duration: 0.07)
                    SpringKeyframe(0, duration: 0.3, spring: .init(response: 0.28, dampingRatio: 0.55))
                }
        }
        .frame(width: width, height: width * 198.0 / 220.0)
        .shadow(color: .black.opacity(0.5), radius: 9, x: 0, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dealing shoe")
    }

    private var fallbackShoe: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.21, blue: 0.11),
                                          Color(red: 0.19, green: 0.10, blue: 0.05)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 2))
            .padding(width * 0.06)
    }
}

// MARK: - Labels

/// The small felt chip that shows a hand's total ("17", "7/17", "BUST").
struct BJTotalChip: View {
    let text: String
    var bust = false
    var diameter: CGFloat = 34

    var body: some View {
        Text(text)
            .font(.system(size: diameter * (text.count > 3 ? 0.30 : 0.42), weight: .bold, design: .serif))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(bust ? Color(red: 1, green: 0.78, blue: 0.74) : CardStyle.stockTop)
            .frame(minWidth: diameter, minHeight: diameter)
            .padding(.horizontal, text.count > 3 ? 6 : 0)
            .background(
                Capsule()
                    .fill(RadialGradient(colors: [Color(red: 0.13, green: 0.27, blue: 0.20), Color(red: 0.06, green: 0.14, blue: 0.10)],
                                         center: .topLeading, startRadius: 1, endRadius: diameter * 1.1))
                    .overlay(Capsule().strokeBorder(bust ? CardStyle.crimson : CardStyle.gold.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
            )
            .accessibilityLabel("Total \(text)")
    }
}

struct BJTagView: View {
    let tag: BJTag
    var size: CGFloat = 14

    private var fill: Color {
        switch tag.style {
        case .blackjack: return CardStyle.gold
        case .win: return Color(red: 0.10, green: 0.32, blue: 0.20)
        case .lose: return Color(red: 0.42, green: 0.12, blue: 0.10)
        case .push: return Color(red: 0.22, green: 0.24, blue: 0.26)
        case .neutral: return .black.opacity(0.55)
        }
    }
    private var ink: Color { tag.style == .blackjack ? CardStyle.ink : CardStyle.stockTop }

    var body: some View {
        Text(tag.text)
            .font(.system(size: size, weight: .bold, design: .serif))
            .monospacedDigit()
            .foregroundStyle(ink)
            .padding(.horizontal, size * 0.8)
            .padding(.vertical, size * 0.34)
            .background(
                Capsule().fill(fill)
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(tag.style == .blackjack ? 1 : 0.5), lineWidth: 1))
                    .shadow(color: tag.style == .blackjack ? CardStyle.gold.opacity(0.7) : .black.opacity(0.4),
                            radius: tag.style == .blackjack ? 9 : 3, y: 1)
            )
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// A seat's name plate: colored dot, name, bankroll, and what they just did.
struct BJPlateView: View {
    let name: String
    let colorIndex: Int
    let chips: Int
    let isBot: Bool
    let active: Bool
    let sittingOut: Bool
    let isOut: Bool
    let actionTag: String?

    var body: some View {
        VStack(spacing: 3) {
            if let actionTag {
                Text(actionTag)
                    .font(.system(.caption, design: .serif).weight(.heavy))
                    .foregroundStyle(CardStyle.ink)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Capsule().fill(CardStyle.gold))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            HStack(spacing: 7) {
                Circle().fill(PlayerPalette.color(colorIndex)).frame(width: 11, height: 11)
                Text(name)
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                    .lineLimit(1)
                Text(isOut ? "OUT" : (sittingOut ? "sitting out" : "\(chips)"))
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isOut ? CardStyle.crimson.opacity(0.9) : CardStyle.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(.black.opacity(0.46))
                    .overlay(Capsule().strokeBorder(active ? CardStyle.gold : .white.opacity(0.10), lineWidth: active ? 2 : 1))
                    .shadow(color: active ? CardStyle.gold.opacity(0.6) : .clear, radius: 8)
            )
        }
        .opacity(isOut ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: actionTag)
    }
}

/// Big serif moment text ("BUST", "BLACKJACK!").
struct BJCalloutView: View {
    let callout: BJCallout
    let size: CGFloat

    private var color: Color {
        switch callout.style {
        case .gold: return CardStyle.gold
        case .crimson: return Color(red: 0.93, green: 0.36, blue: 0.30)
        case .ivory: return CardStyle.stockTop
        }
    }

    var body: some View {
        Text(callout.text)
            .font(.system(size: size, weight: .heavy, design: .serif))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.75), radius: 1, y: 2)
            .shadow(color: .black.opacity(0.5), radius: 8)
            .overlay {
                if callout.style == .gold {
                    Text(callout.text)
                        .font(.system(size: size, weight: .heavy, design: .serif))
                        .foregroundStyle(.white.opacity(0.35))
                        .blur(radius: 6)
                }
            }
            .transition(.scale(scale: 0.4).combined(with: .opacity))
            .accessibilityLabel(callout.text)
    }
}

// MARK: - Brass buttons (table taps)

struct BJBrassButton: View {
    let title: String
    var prominent = true
    var width: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.arm()
            action()
        } label: {
            Text(title)
                .font(.system(.footnote, design: .serif).weight(.heavy))
                .foregroundStyle(CardStyle.ink)
                .frame(width: width, height: 30)
                .background(
                    Capsule()
                        .fill(LinearGradient(colors: prominent
                                             ? [Color(red: 0.92, green: 0.78, blue: 0.46), CardStyle.gold, Color(red: 0.55, green: 0.42, blue: 0.20)]
                                             : [Color(red: 0.72, green: 0.66, blue: 0.54), Color(red: 0.5, green: 0.45, blue: 0.36)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
