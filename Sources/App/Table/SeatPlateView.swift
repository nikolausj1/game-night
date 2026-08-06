import SwiftUI

/// One player's presence on the table rim: name, color, bid target, tricks
/// taken as chips, turn glow, connection state.
struct SeatPlateView: View {
    let seat: Seat
    let state: GameState
    /// The parent rotates the whole plate to face its edge; inside the
    /// plate, local "down" is therefore always the table's rim.
    var edgeAngle: Angle = .degrees(0)

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
                    Text("D")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(CardStyle.ink)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(CardStyle.gold))
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
        .background(
            // A rim tab, not a floating pill: rounded toward the felt,
            // squared where it meets the rail, with a brass seam along
            // the table edge — reads as fixed to the side of the table.
            UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                   bottomTrailingRadius: 4, topTrailingRadius: 15,
                                   style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CardStyle.gold.opacity(0.55))
                        .frame(height: 2)
                        .padding(.horizontal, 3)
                }
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 4, topTrailingRadius: 15,
                                           style: .continuous)
                        .strokeBorder(isTheirTurn ? color : .white.opacity(0.08),
                                      lineWidth: isTheirTurn ? 2.5 : 1)
                )
                .shadow(color: isTheirTurn ? color.opacity(0.65) : .clear, radius: 10)
        )
        .animation(.easeInOut(duration: 0.3), value: isTheirTurn)
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
