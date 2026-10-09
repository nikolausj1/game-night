import SwiftUI
import UIKit

// The lobby's felt stage: a SET table (place settings + a deck waiting by
// the dealer's elbow) that comes quietly alive when nobody is touching it.
//
// MENU INTEGRATION (for whoever edits MenuView next): the whole thing is one
// mount, `LobbyStage(seats:minSeats:capacity:suspended:)`, sitting at the
// bottom of MenuView's ZStack UNDER the scroll content. It owns no menu
// state; MenuView only feeds it who is seated. Everything else in this file
// is private to it.

/// One occupied seat as the lobby sees it (humans first, then bots).
struct LobbySeat: Equatable {
    let name: String
    let colorIndex: Int
}

struct LobbyStage: View {
    /// Occupied seats, in seat order.
    let seats: [LobbySeat]
    /// Seats the selected game NEEDS (open seats up to here read "required";
    /// the rest of `capacity` are fainter, "room for more").
    let minSeats: Int
    /// Seats the selected game allows.
    let capacity: Int
    /// True while a sheet / full-screen cover sits over the menu.
    var suspended = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // MARK: attract state

    /// Bumped by every touch and every seat change: restarts the idle
    /// clock and (via `.task(id:)`) cancels whatever event was in flight.
    @State private var epoch = 0
    @State private var riffleTrigger = 0
    @State private var roll: DiceGameController.Roll?
    @State private var rollAnchor = CGPoint(x: 0.97, y: 0.5)
    @State private var diceSweep: CGFloat = 0
    @State private var diceVisible = true
    @State private var slide: CardSlide?
    @State private var slideA: CGFloat = 0
    @State private var slideB: CGFloat = 0
    @State private var nextRollID = 1

    private var enabled: Bool { !reduceMotion && !suspended && scenePhase == .active }

    /// -attractFast: 3s idle, 4-6s between events (sim verification only).
    private static let fast = CommandLine.arguments.contains("-attractFast")

    var body: some View {
        GeometryReader { geo in
            ZStack {
                places(size: geo.size)
                deck(size: geo.size)
                diceLayer(size: geo.size)
                slideLayer(size: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(TouchSniffer { interrupt() })
        .onChange(of: seats) { _, _ in interrupt() }
        .task(id: RunKey(epoch: epoch, enabled: enabled)) { await run() }
    }

    private struct RunKey: Hashable { let epoch: Int; let enabled: Bool }

    // MARK: place settings

    /// Every seat the game could field, laid along the near rim like a
    /// table that's been set: lit when a phone (or bot) has taken it.
    private func places(size: CGSize) -> some View {
        let count = min(max(capacity, seats.count, 1), 8)
        let spacing = min(150, size.width * 0.8 / CGFloat(count))
        let y = size.height - 86
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let x = size.width / 2 + (CGFloat(i) - CGFloat(count - 1) / 2) * spacing
                PlaceSetting(index: i,
                             occupant: i < seats.count ? seats[i] : nil,
                             required: i < minSeats,
                             light: TableLamp.light(at: CGPoint(x: x, y: y), in: size))
                    .position(x: x, y: y)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: seats)
    }

    // MARK: deck

    private func deck(size: CGSize) -> some View {
        LobbyDeckView(cardWidth: 104, riffleTrigger: riffleTrigger)
            .opacity(0.9)
            .position(x: size.width * 0.84, y: size.height * 0.70)
    }

    // MARK: dice

    /// Mounted only while an event is live. The pool is built and thrown in
    /// one pass (the roll is handed over on first update), so no resting
    /// dice ever flash at the middle of the zone.
    @ViewBuilder
    private func diceLayer(size: CGSize) -> some View {
        if let roll {
            let w = size.width * 0.46, h = size.height * 0.26
            DiceTableSceneView(roll: roll, anchor: rollAnchor, diceCount: 2, faceStyle: .pips) { _, _ in }
                .frame(width: w, height: h)
                .opacity(diceVisible ? 1 - Double(diceSweep) : 0)
                // The sweep: a hand brushing the dice off toward the rail.
                .offset(x: diceSweep * w * 0.4, y: diceSweep * 10)
                .position(x: size.width * 0.755, y: size.height * 0.50)
                .allowsHitTesting(false)
        }
    }

    // MARK: sliding cards

    struct CardSlide: Equatable {
        let fromLeft: Bool
        let y: CGFloat      // unit
        let tilt: Double
        let count: Int
    }

    /// Cards that slide out from UNDER the walnut rail and back: masked to
    /// the felt rect, so they emerge from beneath the rail's lip.
    @ViewBuilder
    private func slideLayer(size: CGSize) -> some View {
        if let slide {
            let cw: CGFloat = 92
            let ch = cw / CardStyle.aspectRatio
            let edge: CGFloat = 14
            ZStack {
                ForEach(0..<slide.count, id: \.self) { i in
                    let t = i == 0 ? slideA : slideB
                    let dir: CGFloat = slide.fromLeft ? 1 : -1
                    let hiddenX = slide.fromLeft ? edge - ch / 2 : size.width - edge + ch / 2
                    let x = hiddenX + dir * ch * 0.74 * t
                    let y = size.height * slide.y + CGFloat(i) * 22
                    let at = CGPoint(x: x, y: y)
                    CardBackView()
                        .frame(width: cw, height: ch)
                        .overlay(DeckTopShade(width: cw, lamp: .at(at, in: size)))
                        .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 3)
                        .rotationEffect(.degrees(slide.fromLeft ? -90 : 90 + (i == 0 ? 0 : 6)))
                        .rotationEffect(.degrees(slide.tilt + Double(i) * 5))
                        .position(at)
                }
            }
            .frame(width: size.width, height: size.height)
            .mask(
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .padding(edge)
            )
        }
    }

    // MARK: director

    private func interrupt() {
        epoch += 1
        // Wind any live event down at once (a quarter second, not a snap).
        if roll != nil {
            withAnimation(.easeOut(duration: 0.25)) { diceVisible = false } completion: {
                roll = nil
                diceSweep = 0
                diceVisible = true
            }
        }
        if slide != nil {
            withAnimation(.easeIn(duration: 0.35)) { slideA = 0; slideB = 0 } completion: { slide = nil }
        }
    }

    private enum Event: CaseIterable { case riffle, dice, slide }

    @MainActor
    private func run() async {
        guard enabled else { return }
        let fast = Self.fast
        try? await Task.sleep(for: .seconds(fast ? 3 : 8))
        var last: Event?
        while !Task.isCancelled {
            let pool = Event.allCases.filter { $0 != last }
            let event = pool[AttractRNG.shared.int(0..<pool.count)]
            last = event
            switch event {
            case .riffle: await riffleEvent()
            case .dice: await diceEvent()
            case .slide: await slideEvent()
            }
            if Task.isCancelled { break }
            let gap = fast ? AttractRNG.shared.double(4...6) : AttractRNG.shared.double(10...20)
            try? await Task.sleep(for: .seconds(gap))
        }
    }

    /// Event 1: the deck gives one riffle (0.7s).
    @MainActor private func riffleEvent() async {
        riffleTrigger += 1
        try? await Task.sleep(for: .seconds(1.0))
    }

    /// Event 2: a pair of pip dice tumble in from the right edge, settle,
    /// sit a while, and are brushed away. ~12s on screen end to end.
    @MainActor private func diceEvent() async {
        diceSweep = 0
        diceVisible = true
        rollAnchor = CGPoint(x: 0.97, y: AttractRNG.shared.double(0.35...0.65))
        roll = DiceGameController.Roll(id: nextRollID, seat: 0, count: 2,
                                       intensity: AttractRNG.shared.double(0.35...0.6))
        nextRollID += 1
        try? await Task.sleep(for: .seconds(AttractRNG.shared.double(7...10)))
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 1.6)) { diceSweep = 1 }
        try? await Task.sleep(for: .seconds(1.7))
        guard !Task.isCancelled else { return }
        roll = nil
        diceSweep = 0
    }

    /// Event 3: one or two cards slide out from under the rail, rest, and
    /// slide back. Slow: 2.4s out, ~1.8s rest, 2.2s back.
    @MainActor private func slideEvent() async {
        let rng = AttractRNG.shared
        slideA = 0; slideB = 0
        slide = CardSlide(fromLeft: rng.int(0..<2) == 0,
                          y: rng.double(0.62...0.86),
                          tilt: rng.double(-6...6),
                          count: rng.int(1..<3))
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut(duration: 2.4)) { slideA = 1 }
        if slide?.count == 2 {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeInOut(duration: 2.4)) { slideB = 1 }
            try? await Task.sleep(for: .seconds(2.0))
        } else {
            try? await Task.sleep(for: .seconds(2.6))
        }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(1.4))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 2.2)) { slideA = 0; slideB = 0 }
        try? await Task.sleep(for: .seconds(2.4))
        guard !Task.isCancelled else { return }
        slide = nil
    }
}

// MARK: - Lamp sample for a known position

extension LampSample {
    /// What the lamp looks like from a point whose container position we know.
    static func at(_ p: CGPoint, in size: CGSize) -> LampSample {
        LampSample(toward: TableLamp.direction(from: p, in: size),
                   light: TableLamp.light(at: p, in: size))
    }
}

// MARK: - Place setting

/// One open (or taken) seat as a real place setting: a felt coaster ring
/// and, beneath it, a small brass plaque with the seat name engraved in
/// serif. Dim and empty until someone sits; then the coaster takes the
/// player's color and glows, the brass catches the lamp at full strength,
/// and the plaque is engraved with their name.
private struct PlaceSetting: View {
    let index: Int
    let occupant: LobbySeat?
    let required: Bool
    /// 0...1 from `TableLamp` at this seat's position.
    let light: Double

    private var lit: Bool { occupant != nil }
    private var color: Color { PlayerPalette.color(occupant?.colorIndex ?? index) }
    /// How present the setting is: empty-but-needed < empty-extra is fainter still.
    private var presence: Double { lit ? 1 : (required ? 0.62 : 0.36) }

    var body: some View {
        VStack(spacing: 9) {
            coaster
            plaque
        }
        .opacity(presence)
        .animation(.easeInOut(duration: 0.5), value: lit)
    }

    private var coaster: some View {
        let k = 0.55 + 0.45 * light
        return ZStack {
            // The felt coaster: a slightly lifted disc with a sewn edge.
            Circle()
                .fill(lit ? AnyShapeStyle(RadialGradient(colors: [color.opacity(0.85), color.opacity(0.45)],
                                                         center: UnitPoint(x: 0.4, y: 0.32),
                                                         startRadius: 2, endRadius: 46))
                          : AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.07 * k), .black.opacity(0.20)],
                                                         center: UnitPoint(x: 0.42, y: 0.34),
                                                         startRadius: 2, endRadius: 46)))
            // Recess: a blurred dark ring clipped to the disc reads as a
            // dished well, not a sticker.
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: 6)
                .blur(radius: 3)
                .clipShape(Circle())
            Circle()
                .inset(by: 7)
                .strokeBorder(CardStyle.gold.opacity(lit ? 0.7 : 0.30),
                              style: StrokeStyle(lineWidth: 1.2, dash: [2.6, 3.2]))
            // The bound rim, brass catching the lamp from above.
            Circle()
                .strokeBorder(LinearGradient(colors: [TableLamp.brassLit.opacity(0.85 * k),
                                                      CardStyle.gold.opacity(0.45),
                                                      TableLamp.brassShade.opacity(0.85)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 2.6)
            if let occupant {
                Text(String(occupant.name.prefix(1)).uppercased())
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            }
        }
        .frame(width: 78, height: 78)
        .shadow(color: lit ? color.opacity(0.55) : .black.opacity(0.28),
                radius: lit ? 14 : 4, y: lit ? 0 : 2)
    }

    private var plaque: some View {
        let k = 0.55 + 0.45 * light
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [TableLamp.brassLit.opacity(0.95 * k + 0.05),
                                               CardStyle.gold,
                                               Color(red: 0.55, green: 0.42, blue: 0.20)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55 * k), .clear,
                                                       .black.opacity(0.5)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 1)
            HStack {
                screw
                Spacer(minLength: 0)
                screw
            }
            .padding(.horizontal, 6)
            // Engraved: dark ink with a hairline highlight just below, as
            // if cut into the metal.
            Text(occupant?.name ?? "Seat \(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .tracking(occupant == nil ? 1.6 : 0.4)
                .textCase(occupant == nil ? .uppercase : nil)
                .foregroundStyle(Color(red: 0.22, green: 0.15, blue: 0.06).opacity(0.92))
                .shadow(color: .white.opacity(0.45), radius: 0, x: 0, y: 0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 15)
        }
        .frame(width: 104, height: 26)
        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [TableLamp.brassLit.opacity(0.9), TableLamp.brassShade],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 4))
            .frame(width: 4, height: 4)
    }
}

// MARK: - Seeded randomness

/// SplitMix64, seeded once per launch (or by `-attractSeed N`): the
/// ambient schedule differs between launches but stays reproducible when
/// you hand it a seed.
final class AttractRNG {
    static let shared = AttractRNG()
    private var state: UInt64

    private init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-attractSeed"), args.indices.contains(i + 1),
           let seed = UInt64(args[i + 1]) {
            state = seed
        } else {
            state = UInt64.random(in: UInt64.min...UInt64.max)
        }
    }

    private func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }

    func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(max(range.count, 1)))
    }
}

// MARK: - Touch sniffer

/// Reports the START of any touch anywhere in the window without taking
/// part in it: a window-level recognizer that fails at once, never cancels
/// or delays touches, and so never disturbs scrolling, buttons or sheets.
private struct TouchSniffer: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> SnifferView {
        let view = SnifferView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: SnifferView, context: Context) { view.onTouch = onTouch }

    static func dismantleUIView(_ view: SnifferView, coordinator: ()) { view.detach() }

    final class SnifferView: UIView {
        var onTouch: (() -> Void)?
        private var recognizer: Recognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let r = Recognizer { [weak self] in self?.onTouch?() }
            window.addGestureRecognizer(r)
            recognizer = r
        }

        func detach() {
            if let r = recognizer { r.view?.removeGestureRecognizer(r) }
            recognizer = nil
        }
    }

    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let handler: () -> Void
        init(handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            handler()
            state = .failed
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
