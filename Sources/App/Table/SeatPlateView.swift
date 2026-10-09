import SwiftUI

/// One player's presence on the table rim: name, color, bid target, tricks
/// taken as chips, turn glow, connection state.
struct SeatPlateView: View {
    let seat: Seat
    let state: GameState
    /// The parent rotates the whole plate to face its edge; inside the
    /// plate, local "down" is therefore always the table's rim.
    var edgeAngle: Angle = .degrees(0)

    /// Where the table lamp sits relative to this plate (see `TableLamp`).
    @State private var lamp = LampSample()
    @Environment(\.accessibilityReduceMotion) private var motionReduced
    /// Hearts passing: the "still to pass" breathing glow. Reduce Motion
    /// pins it to a steady highlight instead.
    @State private var passPulse = false

    private var isTheirTurn: Bool {
        guard let round = state.round else { return false }
        switch state.phase {
        case .bidding, .playing: return round.turnSeat == seat.id
        case .choosingTrump(let chooser): return chooser == seat.id
        default: return false
        }
    }

    private var bid: Int? { state.round?.bids[seat.id] }
    private var taken: Int { state.round?.tricksWon[seat.id] ?? 0 }
    private var color: Color { PlayerPalette.color(seat.colorIndex) }

    // Hearts passing: everyone picks at once, so the plate shows where each
    // seat stands instead of a single turn glow.
    private var isPassingPhase: Bool { state.phase == .passing }
    private var hasPassed: Bool { isPassingPhase && state.round?.passSelections[seat.id] != nil }
    private var isAwaitingPass: Bool { isPassingPhase && !hasPassed }

    /// Hearts: point cards this seat has taken so far this round (1 per
    /// heart, 13 for the queen of spades), straight off the completed tricks.
    private var heartsRoundPoints: Int {
        guard state.gameKind == .hearts, let round = state.round else { return 0 }
        return HeartsRules.pointsTaken(in: round.completedTricks)[seat.id] ?? 0
    }

    private var heartsTotal: Int {
        Scoring.totals(history: state.roundHistory, kind: .hearts)[seat.id] ?? 0
    }

    private var showsHeartsPoints: Bool {
        guard state.gameKind == .hearts else { return false }
        switch state.phase {
        case .playing, .trickComplete, .passing: return true
        default: return false
        }
    }

    /// Spades: a bid of 0 is nil (or blind nil).
    private var nilLabel: String? {
        guard state.gameKind == .spades, bid == 0 else { return nil }
        return (state.round?.blindNilSeats.contains(seat.id) ?? false) ? "blind nil" : "nil"
    }

    /// The glow colour and width for the bevel: the seat colour on its
    /// turn, a soft gold breath while a pass is owed, brass otherwise.
    private var isHighlighted: Bool { isTheirTurn || isAwaitingPass }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                Text(seat.playerName)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                if state.round?.dealerSeat == seat.id {
                    DealerBadge()
                }
                if !seat.isConnected {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 5) {
                if isPassingPhase {
                    passStatus
                } else if showsHeartsPoints {
                    heartsPointsChips
                } else if let bid {
                    trickChips(bid: bid, taken: taken)
                } else if state.phase == .bidding {
                    Text("…")
                        .font(.headline)
                        .foregroundStyle(CardStyle.stockTop.opacity(0.5))
                }
            }
            .frame(minHeight: 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(plateBackground)
        .lampSample($lamp)
        .animation(.easeInOut(duration: 0.3), value: isTheirTurn)
        .animation(.easeInOut(duration: 0.3), value: hasPassed)
        .onAppear { syncPassPulse() }
        .onChange(of: isAwaitingPass) { _, _ in syncPassPulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func syncPassPulse() {
        guard isAwaitingPass, !motionReduced else {
            passPulse = false
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            passPulse = true
        }
    }

    /// Hearts passing: a brass check once this seat has committed its
    /// three, a quiet "picking…" while it hasn't.
    private var passStatus: some View {
        HStack(spacing: 4) {
            if hasPassed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(CardStyle.gold)
                Text("passed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.9))
            } else {
                Text("picking…")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.55))
            }
        }
        .transition(.opacity)
    }

    /// Hearts: this round's penalty points (crimson once any land) and the
    /// running total, so the table reads like a scorepad mid-round.
    private var heartsPointsChips: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Text("♥")
                    .font(.caption.weight(.bold))
                Text("\(heartsRoundPoints)")
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(heartsRoundPoints > 0 ? Color(red: 0.95, green: 0.45, blue: 0.40) : CardStyle.stockTop.opacity(0.55))
            if !state.roundHistory.isEmpty {
                Text("· \(heartsTotal)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(CardStyle.stockTop.opacity(0.6))
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [seat.playerName]
        if state.round?.dealerSeat == seat.id { parts.append("dealer") }
        if !seat.isConnected { parts.append("disconnected") }
        if isPassingPhase {
            parts.append(hasPassed ? "has passed" : "still picking cards to pass")
        } else if showsHeartsPoints {
            parts.append("\(heartsRoundPoints) points this round")
            if !state.roundHistory.isEmpty { parts.append("\(heartsTotal) total") }
        } else if let bid {
            parts.append(nilLabel.map { "bid \($0)" } ?? "bid \(bid)")
            parts.append("took \(taken)")
        }
        if isTheirTurn { parts.append("their turn") }
        return parts.joined(separator: ", ")
    }

    /// A rim tab, not a floating pill: rounded toward the felt, squared
    /// where it meets the rail, with a brass seam along the table edge —
    /// reads as fixed to the side of the table. The brass is lit by the
    /// table lamp: the bevel catches light on the lamp-facing edge and falls
    /// to bronze on the far one, and the drop shadow is cast away from it.
    private var plateBackground: some View {
        let toward = lamp.toward(rotatedBy: edgeAngle)
        // Gradient axis runs lamp-side -> far side, in the plate's own frame.
        let lit = UnitPoint(x: 0.5 + toward.dx * 0.5, y: 0.5 + toward.dy * 0.5)
        let far = UnitPoint(x: 0.5 - toward.dx * 0.5, y: 0.5 - toward.dy * 0.5)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15,
                                           style: .continuous)
        let k = 0.55 + 0.45 * lamp.light
        return shape
            .fill(.black.opacity(0.42))
            .overlay(
                // Lamp sheen across the tab's face, lamp-facing side first.
                shape.fill(LinearGradient(colors: [TableLamp.warmTint.opacity(0.13 * k), .clear],
                                          startPoint: lit, endPoint: far))
                    .blendMode(.plusLighter)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LinearGradient(colors: [TableLamp.brassLit.opacity(0.85 * k),
                                                  CardStyle.gold.opacity(0.55),
                                                  TableLamp.brassShade.opacity(0.9)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .padding(.horizontal, 3)
            }
            .overlay(
                // Brass bevel: bright where it faces the lamp, bronze in
                // its own shadow. A turn glow replaces it in the seat color;
                // a seat still owing its hearts pass breathes gold instead.
                shape.strokeBorder(
                    isTheirTurn
                        ? AnyShapeStyle(color)
                        : isAwaitingPass
                        ? AnyShapeStyle(CardStyle.gold.opacity(passPulse ? 0.95 : 0.55))
                        : AnyShapeStyle(LinearGradient(
                            colors: [TableLamp.brassLit.opacity(0.62 * k),
                                     CardStyle.gold.opacity(0.22),
                                     TableLamp.brassShade.opacity(0.75)],
                            startPoint: lit, endPoint: far)),
                    lineWidth: isHighlighted ? 2.5 : 1.4)
            )
            .shadow(color: isTheirTurn ? color.opacity(0.65)
                         : isAwaitingPass ? CardStyle.gold.opacity(passPulse ? 0.55 : 0.2)
                         : .clear,
                    radius: 10)
            .shadow(color: .black.opacity(0.38), radius: 4,
                    x: -toward.dx * 3, y: -toward.dy * 3)
    }

    /// A small brass dealer button: the same specular/emboss language as the
    /// app's other brass accents — a radial gold-to-bronze fill lit from the
    /// upper-left, a blurred dark ring clipped to the disc's own interior so
    /// the rim reads recessed (stamped, not stickered on), and a thin dark
    /// keyline. Replaces the old flat gold-circle-plus-letter "D".
    private struct DealerBadge: View {
        var body: some View {
            Circle()
                .fill(
                    RadialGradient(colors: [
                        Color(red: 0.99, green: 0.92, blue: 0.72),
                        CardStyle.gold,
                        Color(red: 0.52, green: 0.39, blue: 0.19)
                    ], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 13)
                )
                .overlay(
                    // Inner shadow: a dark ring blurred and clipped to the
                    // disc's own bounds — reads as a recessed rim rather
                    // than a flat outline sitting on top.
                    Circle()
                        .stroke(Color.black.opacity(0.5), lineWidth: 3)
                        .blur(radius: 1.5)
                        .clipShape(Circle())
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                .overlay(
                    Text("D")
                        .font(.system(size: 11, weight: .black, design: .serif))
                        .foregroundStyle(CardStyle.ink)
                        // A hairline light catch under the glyph is what
                        // sells "embossed into the metal" at this size.
                        .shadow(color: .white.opacity(0.35), radius: 0, x: 0, y: 0.7)
                )
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
        }
    }

    /// Bid shown as empty chip outlines that fill as tricks come in.
    /// Overtricks pile on in warning red — readable across the table.
    private func trickChips(bid: Int, taken: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<max(bid, taken, 1), id: \.self) { index in
                if index < min(taken, bid) {
                    Circle().fill(CardStyle.gold)
                        .frame(width: 11, height: 11)
                } else if index < bid {
                    Circle().strokeBorder(CardStyle.gold.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 11, height: 11)
                } else {
                    Circle().fill(Color(red: 0.85, green: 0.30, blue: 0.25))
                        .frame(width: 11, height: 11)
                }
            }
            if bid == 0 && taken == 0 {
                Text(nilLabel ?? "zero")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.8))
            } else if let nilLabel, bid == 0 {
                // A nil bidder who took a trick: the bet is lost, say so.
                Text("\(nilLabel) set")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.40))
            }
        }
    }
}
