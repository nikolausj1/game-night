import SwiftUI

/// End of a round: the scorepad moment. Standings with round deltas,
/// then the host taps onward.
struct RoundRecapOverlay: View {
    @Bindable var host: GameHostController
    let state: GameState

    private var standings: [(seat: Seat, total: Int, delta: Int)] {
        let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
        let lastRound = state.roundHistory.last
        return state.seats
            .map { seat in
                let delta = lastRound.map {
                    Scoring.roundScore(kind: state.gameKind,
                                       bid: $0.bids[seat.id] ?? 0,
                                       tricksTaken: $0.tricksWon[seat.id] ?? 0,
                                       missScoresTricks: state.rules.missScoresTricks)
                } ?? 0
                return (seat, totals[seat.id] ?? 0, delta)
            }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ScorecardPanel(title: "Round \(state.roundHistory.count) complete") {
            ForEach(Array(standings.enumerated()), id: \.element.seat.id) { index, row in
                HStack {
                    Text("\(index + 1).")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(CardStyle.gold)
                        .frame(width: 34, alignment: .leading)
                    Circle().fill(PlayerPalette.color(row.seat.colorIndex))
                        .frame(width: 12, height: 12)
                    Text(row.seat.playerName)
                        .font(.system(.title3, design: .serif))
                    Spacer()
                    Text(row.delta >= 0 ? "+\(row.delta)" : "\(row.delta)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(row.delta >= 0
                            ? Color(red: 0.4, green: 0.75, blue: 0.45)
                            : Color(red: 0.85, green: 0.35, blue: 0.3))
                        .frame(width: 60, alignment: .trailing)
                    Text("\(row.total)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                }
                .foregroundStyle(CardStyle.stockTop)
            }
        } action: {
            Button {
                host.tableAction(.nextRound)
            } label: {
                Text("Deal round \(state.roundHistory.count + 1)")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }
}

/// The last card has fallen: crown the winner properly.
struct GameOverOverlay: View {
    @Bindable var host: GameHostController
    let state: GameState

    private var finalStandings: [(seat: Seat, total: Int)] {
        let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
        return state.seats.map { ($0, totals[$0.id] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ScorecardPanel(title: "🏆 \(finalStandings.first?.seat.playerName ?? "") wins the night!") {
            ForEach(Array(finalStandings.enumerated()), id: \.element.seat.id) { index, row in
                HStack {
                    Text(medal(index))
                        .font(.title2)
                        .frame(width: 40)
                    Circle().fill(PlayerPalette.color(row.seat.colorIndex))
                        .frame(width: 12, height: 12)
                    Text(row.seat.playerName)
                        .font(.system(.title2, design: .serif).weight(index == 0 ? .bold : .regular))
                    Spacer()
                    Text("\(row.total)")
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(CardStyle.stockTop)
            }
        } action: {
            Button {
                host.tableAction(.newDeal)
            } label: {
                Text("Play again")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 34)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
        }
    }

    private func medal(_ index: Int) -> String {
        switch index {
        case 0: return "🥇"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return " "
        }
    }
}

/// Shared parchment scorecard panel floating over the felt.
struct ScorecardPanel<Rows: View, Action: View>: View {
    let title: String
    @ViewBuilder let rows: Rows
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(CardStyle.stockTop)
            VStack(spacing: 14) { rows }
                .padding(.horizontal, 8)
            action
        }
        .padding(36)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        )
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}
