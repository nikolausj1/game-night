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
                if let bid {
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
                // its own shadow. A turn glow replaces it in the seat color.
                shape.strokeBorder(
                    isTheirTurn
                        ? AnyShapeStyle(color)
                        : AnyShapeStyle(LinearGradient(
                            colors: [TableLamp.brassLit.opacity(0.62 * k),
                                     CardStyle.gold.opacity(0.22),
                                     TableLamp.brassShade.opacity(0.75)],
                            startPoint: lit, endPoint: far)),
                    lineWidth: isTheirTurn ? 2.5 : 1.4)
            )
            .shadow(color: isTheirTurn ? color.opacity(0.65) : .clear, radius: 10)
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
                Text("zero")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.gold.opacity(0.8))
            }
        }
    }
}
