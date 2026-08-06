import SwiftUI

/// "Say what just happened" — three small, independent felt widgets that
/// narrate table state without needing to know anything about how the felt
/// itself is laid out. None of these reference TableGameView; the caller
/// feeds them plain values (text, a direction, a color) and positions them
/// however the table wants.

// MARK: - TableCalloutCenter

/// Transient serif callouts on the felt: "Mae draws 2", "Reverse!", "Chase
/// says Red" — gold text on a dark translucent lozenge that rises and fades
/// in, holds a couple seconds, then fades back out. A fast run of events
/// (a reverse right after a stacked draw) queues instead of stomping itself,
/// so each beat gets read in turn rather than flickering.
///
/// This is the state object; `TableCalloutView` below is the view that
/// renders it. Own one `TableCalloutCenter` instance per table session
/// (e.g. `@State private var callouts = TableCalloutCenter()`), call
/// `post(_:)` or `post(event:seatName:)` whenever something worth
/// announcing happens, and mount `TableCalloutView(center: callouts)`
/// wherever the felt wants the lozenge to appear.
@Observable
final class TableCalloutCenter {
    struct Callout: Identifiable {
        let id = UUID()
        let text: String
    }

    /// The lozenge currently on screen, or nil between beats.
    private(set) var current: Callout?
    /// Drives the rise/fade animation from the view side: false = hidden
    /// (below rest position, transparent), true = settled (in place, opaque).
    private(set) var isSettled = false

    private var queue: [Callout] = []
    private var advancing = false

    /// How long a callout holds fully visible before it starts fading —
    /// matches the ~2s the brief calls for.
    private let holdDuration: Double = 2.0
    private let riseFadeDuration: Double = 0.28

    /// Post free-form text directly.
    func post(_ text: String) {
        queue.append(Callout(text: text))
        advanceIfNeeded()
    }

    private func advanceIfNeeded() {
        guard !advancing, !queue.isEmpty else { return }
        advancing = true
        let next = queue.removeFirst()
        current = next
        isSettled = false
        // One tick so the view mounts hidden before animating to settled —
        // starting both at once would skip the animation entirely.
        DispatchQueue.main.async { [weak self] in
            self?.isSettled = true
        }
        let holdUntil = riseFadeDuration + holdDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + holdUntil) { [weak self] in
            self?.isSettled = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdUntil + riseFadeDuration) { [weak self] in
            guard let self else { return }
            self.current = nil
            self.advancing = false
            self.advanceIfNeeded()
        }
    }
}

extension TableCalloutCenter {
    /// Maps the "obvious" GameEvents to callout text, given a seat-name
    /// lookup so this file never needs GameHostController/GameState.
    /// Events with no felt-worthy moment (bids, scoring, the game-over
    /// fanfare — all already carried by banners or the announcer) post
    /// nothing.
    ///
    /// `declaringSeat` is a rare exception: `GameEvent.suitDeclared` (UNO's
    /// wild-color call) carries no seat of its own — the engine resolves it
    /// from `state.phase`'s `.choosingTrump(seat:)` case, which has already
    /// moved on by the time the event fires. Pass the seat the caller was
    /// waiting on (captured from that phase just before it changed) to get
    /// "Chase says Red" instead of the seatless fallback "Red called!".
    func post(event: GameEvent, seatName: (Int) -> String, declaringSeat: Int? = nil) {
        switch event {
        case .cardsDrawn(let seat, let count):
            post("\(seatName(seat)) draws \(count)")

        case .unoCalled(let seat):
            post("\(seatName(seat)) calls UNO!")

        case .cardPlayed(let seat, let card, _):
            if let text = actionCalloutText(seat: seat, card: card, seatName: seatName) {
                post(text)
            }

        case .suitDeclared(let suit):
            let colorName = suit.unoColor.displayName
            if let declaringSeat {
                post("\(seatName(declaringSeat)) says \(colorName)")
            } else {
                post("\(colorName) called!")
            }

        case .penaltyCardDrawn(let seat, let remaining):
            // One event per card as a stacked draw-2/draw-4 penalty pays
            // out — only the last one (remaining == 0) gets a callout, so a
            // four-card penalty reads as one beat, not a flicker of four.
            if remaining == 0 {
                post("\(seatName(seat)) draws the penalty")
            }

        case .dealt, .bidPlaced, .biddingComplete, .trumpRevealed, .trickWon,
             .roundScored, .gameWon, .illegalAttempt, .undone, .cardDealt,
             .topCardFlipped:
            break
        }
    }

    /// UNO's action cards — the reverse/skip/draw plays the brief calls out
    /// by name. Plain numbers and a bare wild (no color chosen yet) don't
    /// get a callout; the wild's own color pick lands as `suitDeclared`.
    private func actionCalloutText(seat: Int, card: Card, seatName: (Int) -> String) -> String? {
        guard case .uno(_, let symbol) = card.kind else { return nil }
        let name = seatName(seat)
        switch symbol {
        case .reverse: return "Reverse!"
        case .skip: return "\(name) skips the next player"
        case .drawTwo: return "\(name) plays Draw Two"
        case .wildDrawFour: return "\(name) plays Wild Draw Four"
        case .wild, .number: return nil
        }
    }
}

/// The view half of `TableCalloutCenter` — reads its state and renders the
/// lozenge. Pure display; `allowsHitTesting(false)` so it never steals a
/// tap from the felt underneath.
struct TableCalloutView: View {
    var center: TableCalloutCenter

    var body: some View {
        Group {
            if let callout = center.current {
                Text(callout.text)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.gold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.55))
                            .overlay(
                                Capsule().strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .id(callout.id) // fresh identity per beat: no text crossfade
                    .offset(y: center.isSettled ? 0 : 14)
                    .opacity(center.isSettled ? 1 : 0)
                    .animation(.easeOut(duration: 0.28), value: center.isSettled)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - DirectionOfPlayArc

/// A slow, ambient brass/gold arc with an arrowhead, orbiting whatever
/// center it's placed at — the table's quiet "which way we're going"
/// indicator. Reversing the game direction eases the spin through a stop
/// and back out the other way, rather than snapping.
struct DirectionOfPlayArc: View {
    var clockwise: Bool

    /// Interpolates -1...1; the sign (not the raw boolean) drives the
    /// spin, so a direction change reads as a deceleration and reversal.
    @State private var directionSign: Double = 1

    /// One full lap, deliberately slow — this is scenery, not a spinner
    /// asking to be watched.
    private let lapDuration: Double = 18
    private let sweepDegrees: Double = 56

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let fraction = (elapsed.truncatingRemainder(dividingBy: lapDuration)) / lapDuration
            let baseAngle = fraction * 360

            // The arrowhead sits at whichever end is actually leading for
            // the CURRENT target direction — swapped on the (rare) direction
            // change, not animated, since it's imperceptible while the eased
            // spin is passing through ~zero speed anyway.
            let headAtHighEnd = clockwise
            DirectionArcShape(startAngle: headAtHighEnd ? 0 : sweepDegrees,
                              endAngle: headAtHighEnd ? sweepDegrees : 0,
                              thicknessRatio: 0.16)
                .fill(
                    LinearGradient(colors: [CardStyle.gold.opacity(0.12), CardStyle.gold.opacity(0.62)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .rotationEffect(.degrees(baseAngle * directionSign))
        }
        .allowsHitTesting(false)
        .onAppear { directionSign = clockwise ? 1 : -1 }
        .onChange(of: clockwise) { _, newValue in
            withAnimation(.easeInOut(duration: 0.7)) {
                directionSign = newValue ? 1 : -1
            }
        }
    }
}

/// A partial ring (annulus segment) with a flared triangular head at
/// `endAngle` — the same "sample the arc, flare a head" technique as UNO's
/// reverse glyph, sized to whatever square-ish frame the caller gives it.
private struct DirectionArcShape: Shape {
    /// Degrees, tail end.
    let startAngle: Double
    /// Degrees, head end.
    let endAngle: Double
    /// Ring thickness as a fraction of the radius.
    let thicknessRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = Double(radius)
        let inner = Double(radius * (1 - thicknessRatio))
        let thickness = outer - inner
        let headLength = thickness * 2.1
        let flare = thickness * 0.55
        let samples = 18
        let start = startAngle * .pi / 180
        let end = endAngle * .pi / 180

        func point(_ r: Double, _ theta: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(theta) * r), y: center.y + CGFloat(sin(theta) * r))
        }

        var points: [CGPoint] = []
        for i in 0...samples {
            let t = start + (end - start) * Double(i) / Double(samples)
            points.append(point(outer, t))
        }
        let tangent = (x: -sin(end), y: cos(end))
        let radial = (x: cos(end), y: sin(end))
        let mid = point((outer + inner) / 2, end)
        let halfSpan = thickness / 2 + flare
        points.append(CGPoint(x: mid.x + CGFloat(radial.x * halfSpan), y: mid.y + CGFloat(radial.y * halfSpan)))
        points.append(CGPoint(x: mid.x + CGFloat(tangent.x * headLength), y: mid.y + CGFloat(tangent.y * headLength)))
        points.append(CGPoint(x: mid.x - CGFloat(radial.x * halfSpan), y: mid.y - CGFloat(radial.y * halfSpan)))
        for i in stride(from: samples, through: 0, by: -1) {
            let t = start + (end - start) * Double(i) / Double(samples)
            points.append(point(inner, t))
        }

        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }
}

// MARK: - ActiveColorChip

/// UNO's called color, felt-friendly: a small swatch + serif label ("Red"),
/// styled like the rest of the brass/gold chip language. Renders nothing
/// when there's no color to show — safe to mount unconditionally.
struct ActiveColorChip: View {
    var color: UnoColor?

    var body: some View {
        if let color {
            HStack(spacing: 8) {
                Circle()
                    .fill(UnoStyle.field(for: color))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
                Text(color.displayName)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.black.opacity(0.42))
                    .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1))
            )
        }
    }
}

private extension UnoColor {
    /// Capitalized print name — "Red", "Yellow", "Green", "Blue".
    var displayName: String { rawValue.capitalized }
}

#Preview("Table signage") {
    VStack(spacing: 28) {
        TableCalloutView(center: {
            let c = TableCalloutCenter()
            c.post("Mae draws 2")
            return c
        }())
        DirectionOfPlayArc(clockwise: true)
            .frame(width: 120, height: 120)
        HStack(spacing: 14) {
            ActiveColorChip(color: .red)
            ActiveColorChip(color: .blue)
            ActiveColorChip(color: nil) // renders nothing
        }
    }
    .padding(40)
    .background(CardStyle.feltGreen)
}
