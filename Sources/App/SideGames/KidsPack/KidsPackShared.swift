import SwiftUI

// Shared building blocks for the kids' card pack (Go Fish, Old Maid, War).
// Everything here is prefixed `Kids` so it can never collide with another
// side game's helpers. Nothing in this file touches a shared type.

// MARK: - Wire helpers

/// A numbered batch of engine events. The sequence number exists because
/// `SideGamePayload` is `Equatable`: two consecutive batches with identical
/// events (a hand shuffled twice in a row) would otherwise compare equal and
/// never trigger a phone's `onChange`.
struct KidsEventBatch<E: Codable & Equatable>: Codable, Equatable {
    let seq: Int
    let events: [E]
}

enum KidsWire {
    static func payload<T: Encodable>(_ kind: String, _ value: T) -> SideGamePayload? {
        try? SideGamePayload(kind: kind, value: value)
    }
}

// MARK: - Words

enum KidsRank {
    static func symbol(_ rank: Int) -> String {
        switch rank {
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        case 14: return "A"
        default: return "\(rank)"
        }
    }

    static func singular(_ rank: Int) -> String {
        let names = [2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
                     8: "eight", 9: "nine", 10: "ten", 11: "jack", 12: "queen",
                     13: "king", 14: "ace"]
        return names[rank] ?? "\(rank)"
    }

    static func countWord(_ n: Int) -> String {
        let words = [1: "one", 2: "two", 3: "three", 4: "four"]
        return words[n] ?? "\(n)"
    }

    /// "Chase", "Chase and Mae", "Chase, Mae and Vinny".
    static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

enum KidsCards {
    /// A stand-in used wherever only a card BACK is drawn.
    static let back = Card(id: "kids-back", kind: .standard(suit: .spades, rank: 2))

    /// The four cards of a rank, for drawing a laid book.
    static func book(rank: Int) -> [Card] {
        [(Suit.clubs, "c"), (.diamonds, "d"), (.hearts, "h"), (.spades, "s")].map {
            Card(id: "\($0.1)\(rank)", kind: .standard(suit: $0.0, rank: rank))
        }
    }
}

// MARK: - Sequencing

/// Runs presentation jobs one after another on the main actor. The table's
/// narration is a queue of "beats" (ask, hand over, go fish, lay a book...)
/// that must never overlap, however fast the host's bots play.
@MainActor
final class KidsBeatQueue {
    private var jobs: [@MainActor () async -> Void] = []
    private var task: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Fired once the queue has been empty for `idleDelay` - long enough
    /// that a result batch arriving a heartbeat after the previous one
    /// continues the show instead of tearing the stage down in between.
    var onIdle: (@MainActor () -> Void)?
    var idleDelay = 0.35

    var isBusy: Bool { task != nil }

    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        idleTask?.cancel()
        idleTask = nil
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while let strong = self, !Task.isCancelled, !strong.jobs.isEmpty {
                let next = strong.jobs.removeFirst()
                await next()
            }
            guard let strong = self, !Task.isCancelled else { return }
            strong.task = nil
            strong.scheduleIdle()
        }
    }

    private func scheduleIdle() {
        idleTask = Task { @MainActor [weak self] in
            await kidsWait(self?.idleDelay ?? 0)
            guard let self, !Task.isCancelled, self.task == nil, self.jobs.isEmpty else { return }
            self.idleTask = nil
            self.onIdle?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        idleTask?.cancel()
        idleTask = nil
        jobs.removeAll()
    }
}

@MainActor
func kidsWait(_ seconds: Double) async {
    guard seconds > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Flights (a card travelling between two points on the felt)

enum KidsFace {
    /// Back the whole way.
    case back
    /// Face-up the whole way.
    case face
    /// Starts as a back, turns over mid-flight.
    case flipUp
    /// Starts face-up, turns to a back mid-flight.
    case flipDown
}

struct KidsFlightSpec: Identifiable {
    let id = UUID()
    var card: Card?
    var face: KidsFace
    var from: CGPoint
    var to: CGPoint
    var width: CGFloat
    var fromAngle: Double = 0
    var toAngle: Double = 0
    var fromScale: CGFloat = 1
    var toScale: CGFloat = 1
    var lift: CGFloat = 46
    var duration: Double = 0.6
    var delay: Double = 0

    /// Calm-mode variant: no arc, no flip theatrics, quicker.
    func calmed(_ reduce: Bool) -> KidsFlightSpec {
        guard reduce else { return self }
        var copy = self
        copy.lift = 0
        copy.duration = duration * 0.6
        copy.delay = delay * 0.6
        if card != nil {
            if face == .flipUp { copy.face = .face }
            if face == .flipDown { copy.face = .back }
        }
        return copy
    }
}

/// One card mid-flight. It is `Animatable` on a single progress value, so
/// SwiftUI re-evaluates the body on every frame and the arc, the turn-over,
/// the rotation, and the shadow all ride the same 0...1 clock (the house
/// pattern: one progress, everything derived from it).
struct KidsFlightView: View, Animatable {
    let spec: KidsFlightSpec
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func smooth(_ p: Double, _ lo: Double, _ hi: Double) -> Double {
        let t = min(1, max(0, (p - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let p = Double(progress)
        let arc = sin(.pi * p)
        let x = spec.from.x + (spec.to.x - spec.from.x) * progress
        let y = spec.from.y + (spec.to.y - spec.from.y) * progress - spec.lift * CGFloat(arc)
        let angle = spec.fromAngle + (spec.toAngle - spec.fromAngle) * p
        let scale = (spec.fromScale + (spec.toScale - spec.fromScale) * progress) * (1 + 0.08 * CGFloat(arc))
        // theta is the card's turn about its vertical axis: 0 = back
        // showing, 180 = face showing (and mirrored, which the inner
        // counter-rotation undoes).
        let theta: Double = {
            switch spec.face {
            case .back, .face: return 0
            case .flipUp: return 180 * smooth(p, 0.12, 0.78)
            case .flipDown: return 180 - 180 * smooth(p, 0.22, 0.88)
            }
        }()
        let turning = spec.face == .flipUp || spec.face == .flipDown
        let showFace = spec.card != nil && (spec.face == .face || (turning && theta > 90))
        ZStack {
            if showFace, let card = spec.card {
                CardView(card: card, faceUp: true, elevation: CGFloat(arc) * 0.8)
                    .rotation3DEffect(.degrees(turning ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            } else {
                CardView(card: KidsCards.back, faceUp: false, elevation: CGFloat(arc) * 0.8)
            }
        }
        .frame(width: spec.width)
        .rotation3DEffect(.degrees(theta), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .rotationEffect(.degrees(angle))
        .scaleEffect(scale)
        .position(x: x, y: y)
        .opacity(progress <= 0.0001 ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// Drives one flight's clock. The OWNER (a stage) removes the spec from its
/// list once `delay + duration` has elapsed.
struct KidsFlightHost: View {
    let spec: KidsFlightSpec
    @State private var progress: CGFloat = 0

    var body: some View {
        KidsFlightView(spec: spec, progress: progress)
            .onAppear {
                withAnimation(.timingCurve(0.30, 0.0, 0.18, 1.0, duration: spec.duration).delay(spec.delay)) {
                    progress = 1
                }
            }
    }
}

struct KidsFlightLayer: View {
    let flights: [KidsFlightSpec]
    var body: some View {
        ZStack {
            ForEach(flights) { KidsFlightHost(spec: $0) }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Seat geometry

/// Where everything about a seat sits in table (felt) coordinates, so the
/// views AND the card flights agree on the same points. A seat is a rotated
/// container: [plate + rail hand], with laid stacks placed inboard of it.
struct KidsSeatGeometry {
    let size: CGSize
    let count: Int

    static let plateHeight: CGFloat = 44

    var railCardWidth: CGFloat { TableGeometry.tableCardWidth(for: size) * 0.88 }
    var railPeek: CGFloat { railCardWidth * 1.45 * 0.25 }
    /// Height of the [plate over rail-hand] container.
    var containerHeight: CGFloat { Self.plateHeight + 2 + railPeek }

    private var anchors: [CGPoint] { TableGeometry.seatAnchors(count: count) }

    func anchorPoint(_ seat: Int) -> CGPoint {
        let a = anchors[min(max(seat, 0), anchors.count - 1)]
        return CGPoint(x: a.x * size.width, y: a.y * size.height)
    }

    /// Reading orientation for the person sitting at that edge (same rule
    /// `TableGameView` uses: bottom normal, top flipped, sides turned).
    func angle(_ seat: Int) -> Angle {
        let p = anchors[min(max(seat, 0), anchors.count - 1)]
        let dLeft = p.x, dRight = 1 - p.x, dTop = p.y, dBottom = 1 - p.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        if nearest == dBottom { return .degrees(0) }
        if nearest == dTop { return .degrees(180) }
        if nearest == dLeft { return .degrees(90) }
        return .degrees(-90)
    }

    /// A point in the seat container's own frame (origin = container
    /// center, +y = toward the rim) mapped to table coordinates.
    func world(_ seat: Int, local: CGPoint) -> CGPoint {
        let a = angle(seat).radians
        let anchor = anchorPoint(seat)
        return CGPoint(x: anchor.x + local.x * CGFloat(cos(a)) - local.y * CGFloat(sin(a)),
                       y: anchor.y + local.x * CGFloat(sin(a)) + local.y * CGFloat(cos(a)))
    }

    /// Where cards enter and leave a seat's hand: the rail fan.
    func handPoint(_ seat: Int) -> CGPoint {
        world(seat, local: CGPoint(x: 0, y: containerHeight / 2 - railPeek * 0.45))
    }

    /// Unit-ish direction from the felt toward the rim for this seat (used
    /// for small nudges like the "Safe" glow).
    func outward(_ seat: Int) -> CGPoint {
        let a = angle(seat).radians
        return CGPoint(x: -CGFloat(sin(a)), y: CGFloat(cos(a)))
    }
}

/// How a seat's laid stacks (books, pairs) tile inboard of its plate.
struct KidsLaidLayout {
    var cols: Int
    var cellW: CGFloat
    var cellH: CGFloat
    var rowPitch: CGFloat

    /// Container-local center of stack `index` out of `total`.
    func local(index: Int, total: Int, containerHeight: CGFloat) -> CGPoint {
        let row = index / cols
        let col = index % cols
        let inRow = min(cols, total - row * cols)
        let x = (CGFloat(col) - CGFloat(inRow - 1) / 2) * cellW
        let y = -containerHeight / 2 - 12 - cellH / 2 - CGFloat(row) * rowPitch
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Seat plate

/// The kids' pack rim plate: the same rim-tab language as `SeatPlateView`
/// (rounded toward the felt, squared at the rail, brass seam, turn glow),
/// rebuilt standalone because the shared plates are keyed to `Seat` /
/// `GameState`, which side games don't have.
struct KidsSeatPlate: View {
    let name: String
    let colorIndex: Int
    var isTurn = false
    /// A softer ring than the turn glow: "this seat is being asked".
    var isFocus = false
    /// Short gold stat on the right ("3 books", "12 cards").
    var stat: String?
    /// Replaces the stat with a calm status ("Safe").
    var status: String?

    private var color: Color { PlayerPalette.color(colorIndex) }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15,
                                           style: .continuous)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 14, height: 14)
            Text(name)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.86, blue: 0.62))
            } else if let stat {
                Text(stat)
                    .font(.system(.subheadline, design: .serif).weight(.semibold).monospacedDigit())
                    .foregroundStyle(CardStyle.gold)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: KidsSeatGeometry.plateHeight)
        .background(
            shape
                .fill(.black.opacity(0.42))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CardStyle.gold.opacity(0.55)).frame(height: 2).padding(.horizontal, 3)
                }
                .overlay(
                    shape.strokeBorder(isTurn ? color : (isFocus ? CardStyle.gold : .white.opacity(0.08)),
                                       lineWidth: isTurn ? 2.5 : (isFocus ? 2 : 1))
                )
                .shadow(color: isTurn ? color.opacity(0.65) : (isFocus ? CardStyle.gold.opacity(0.5) : .clear),
                        radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTurn)
        .animation(.easeInOut(duration: 0.3), value: isFocus)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)\(stat.map { ", \($0)" } ?? "")\(status.map { ", \($0)" } ?? "")\(isTurn ? ", their turn" : "")")
    }
}

/// [plate over rail-hand], rotated to face its edge. Positioned by the
/// caller at `geometry.anchorPoint(seat)`.
struct KidsSeatContainer: View {
    let geometry: KidsSeatGeometry
    let seat: Int
    let name: String
    var isTurn = false
    var isFocus = false
    var stat: String?
    var status: String?
    let handCount: Int

    var body: some View {
        VStack(spacing: 2) {
            KidsSeatPlate(name: name, colorIndex: seat, isTurn: isTurn, isFocus: isFocus,
                          stat: stat, status: status)
            RailHandFan(count: handCount, cardWidth: geometry.railCardWidth)
        }
        .rotationEffect(geometry.angle(seat))
        .position(geometry.anchorPoint(seat))
        .zIndex(1)
    }
}

// MARK: - Laid stacks

/// A few cards laid together: a four-card book (tight stack) or a pair
/// (two cards fanned a little). Drawn face-up at table scale.
struct KidsCardStack: View {
    let cards: [Card]
    let width: CGFloat
    /// Horizontal advance per card.
    var spread: CGFloat = 2
    /// Degrees of splay per card away from the middle.
    var fanStep: Double = 0
    var glow = false

    var body: some View {
        let n = cards.count
        let height = width * 1.4
        ZStack {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                let centered = CGFloat(i) - CGFloat(n - 1) / 2
                CardView(card: card, faceUp: true)
                    .frame(width: width)
                    .rotationEffect(.degrees(Double(centered) * fanStep
                                             + TableGeometry.jitterDegrees(cardID: card.id) * 0.18))
                    .offset(x: centered * spread, y: -abs(centered) * (fanStep > 0 ? 1.5 : 0) + CGFloat(i) * -0.8)
                    .zIndex(Double(i))
            }
        }
        .frame(width: width + CGFloat(max(0, n - 1)) * spread, height: height)
        .shadow(color: CardStyle.gold.opacity(glow ? 0.95 : 0), radius: glow ? 14 : 0)
        .animation(.easeOut(duration: 0.6), value: glow)
    }
}

// MARK: - Callouts

struct KidsCallout: Identifiable, Equatable {
    enum Tone { case ask, good, big, soft, book }
    let id = UUID()
    var title: String
    var subtitle: String?
    var rank: Int?
    var tone: Tone = .ask
}

/// The serif narration card. Rank medallion at the left when the moment is
/// about a rank ("sevens"), so a child can READ what is being asked for.
struct KidsCalloutView: View {
    let callout: KidsCallout

    var body: some View {
        HStack(spacing: 16) {
            if let rank = callout.rank {
                Text(KidsRank.symbol(rank))
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(CardStyle.ink)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle()
                            .fill(RadialGradient(colors: [Color(red: 0.99, green: 0.92, blue: 0.72), CardStyle.gold,
                                                          Color(red: 0.52, green: 0.39, blue: 0.19)],
                                                 center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 40))
                    )
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            }
            VStack(alignment: callout.rank == nil ? .center : .leading, spacing: 3) {
                Text(callout.title)
                    .font(.system(callout.tone == .big ? .largeTitle : .title2, design: .serif).weight(.bold))
                    .foregroundStyle(callout.tone == .big || callout.tone == .book ? CardStyle.gold : CardStyle.stockTop)
                    .multilineTextAlignment(callout.rank == nil ? .center : .leading)
                if let subtitle = callout.subtitle {
                    Text(subtitle)
                        .font(.system(.body, design: .serif).italic())
                        .foregroundStyle(CardStyle.stockTop.opacity(0.78))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(callout.tone == .soft ? 0.18 : 0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        )
        .frame(maxWidth: 640)
        .transition(.scale(scale: 0.86).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(callout.title). \(callout.subtitle ?? "")")
    }
}

// MARK: - Pool / stock pile

struct KidsPoolPile: View {
    let count: Int
    let cardWidth: CGFloat
    var label = "Pool"

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if count == 0 {
                    RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: cardWidth), style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .frame(width: cardWidth, height: cardWidth * 1.4)
                } else {
                    ForEach(0..<min(7, max(1, (count + 5) / 6)), id: \.self) { i in
                        CardView(card: KidsCards.back, faceUp: false)
                            .frame(width: cardWidth)
                            .offset(x: CGFloat(i) * 1.3, y: -CGFloat(i) * 1.6)
                            .rotationEffect(.degrees((Double(i % 3) - 1) * 0.6))
                    }
                }
            }
            .frame(width: cardWidth + 12, height: cardWidth * 1.4 + 12)
            Text(count == 0 ? "\(label) empty" : "\(label) · \(count)")
                .font(.system(.subheadline, design: .serif).weight(.semibold).monospacedDigit())
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.45))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1)))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(count) cards")
    }
}

// MARK: - Motion

enum KidsMotion {
    /// Multiplies every HOST-side delay (bot thinking time, narration
    /// dwell). Always 1 in the app; a logic harness shrinks it to run whole
    /// games in seconds.
    static var hostScale: Double = 1

    /// Pause lengths shrink in calm mode so narration doesn't crawl.
    static func pause(_ seconds: Double, reduce: Bool) -> Double { reduce ? seconds * 0.7 : seconds }
}
