import SwiftUI

/// End of a round: the scorepad moment. Standings with round deltas,
/// then the host taps onward.
///
/// Three scorepads share one parchment panel: the bid-and-hit games
/// (Wizard / Oh Hell) rank highest-first off bid-vs-tricks; Hearts ranks
/// LOWEST-first off the engine's recorded deltas with a shot-the-moon
/// callout; Spades rows are teams (N/S vs E/W) with bid, tricks, bags and
/// nil results, falling back to one row per seat for cutthroat.
struct RoundRecapOverlay: View {
    @Bindable var host: GameHostController
    let state: GameState

    var body: some View {
        switch state.gameKind {
        case .hearts:
            HeartsRecapPanel(state: state, isFinal: false) { dealButton }
        case .spades:
            SpadesRecapPanel(state: state, isFinal: false) { dealButton }
        default:
            standardRecap
        }
    }

    private var dealButton: some View {
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

    // MARK: bid-and-hit games

    private var standings: [(seat: Seat, total: Int, delta: Int)] {
        let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
        let lastRound = state.roundHistory.last
        let deltas = lastRound.map {
            Scoring.roundScores(for: $0, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
        } ?? [:]
        return state.seats
            .map { seat in (seat, totals[seat.id] ?? 0, deltas[seat.id] ?? 0) }
            .sorted { $0.1 > $1.1 }
    }

    private var standardRecap: some View {
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
                    DeltaText(delta: row.delta, lowerIsBetter: false)
                        .frame(width: 60, alignment: .trailing)
                    Text("\(row.total)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                }
                .foregroundStyle(CardStyle.stockTop)
            }
        } action: {
            dealButton
        }
    }
}

/// The last card has fallen: crown the winner properly.
struct GameOverOverlay: View {
    @Bindable var host: GameHostController
    let state: GameState
    /// Back to the menu (the game is over — no save needed).
    var onMenu: (() -> Void)? = nil

    var body: some View {
        switch state.gameKind {
        case .hearts:
            HeartsRecapPanel(state: state, isFinal: true) { endButtons }
        case .spades:
            SpadesRecapPanel(state: state, isFinal: true) { endButtons }
        default:
            standardFinal
        }
    }

    private var endButtons: some View {
        HStack(spacing: 14) {
            Button {
                host.tableAction(.newDeal)
            } label: {
                Text("Play again")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)

            Button {
                onMenu?()
            } label: {
                Text("Back to menu")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(CardStyle.stockTop)
        }
    }

    private var finalStandings: [(seat: Seat, total: Int)] {
        let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
        return state.seats.map { ($0, totals[$0.id] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    private var standardFinal: some View {
        ScorecardPanel(title: "🏆 \(finalStandings.first?.seat.playerName ?? "") wins the night!") {
            ForEach(Array(finalStandings.enumerated()), id: \.element.seat.id) { index, row in
                HStack {
                    Text(RecapMedal.text(index))
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
            endButtons
        }
    }
}

// MARK: - Hearts

/// Hearts scorepad: lowest total on top (it's golf), this round's points
/// in the delta column, a shot-the-moon callout when it happened, and the
/// target the table is playing to.
struct HeartsRecapPanel<Action: View>: View {
    let state: GameState
    let isFinal: Bool
    @ViewBuilder let action: Action

    private var lastRound: CompletedRound? { state.roundHistory.last }

    private var rows: [(seat: Seat, total: Int, delta: Int, place: Int)] {
        let totals = Scoring.totals(history: state.roundHistory, kind: .hearts)
        let deltas = lastRound.map { Scoring.roundScores(for: $0, kind: .hearts) } ?? [:]
        let places = Dictionary(uniqueKeysWithValues:
            Scoring.placements(totals: totals, lowerIsBetter: true).map { ($0.seat, $0.place) })
        return state.seats
            .map { seat in (seat, totals[seat.id] ?? 0, deltas[seat.id] ?? 0, places[seat.id] ?? 1) }
            .sorted { $0.place == $1.place ? $0.seat.id < $1.seat.id : $0.place < $1.place }
    }

    private var moonShooter: Seat? {
        guard let shooter = lastRound?.moonShooter else { return nil }
        return state.seats.first { $0.id == shooter }
    }

    private var title: String {
        if isFinal, let winner = rows.first?.seat {
            return "🏆 \(winner.playerName) wins the night!"
        }
        return "Round \(state.roundHistory.count) complete"
    }

    private var target: Int { state.rules.heartsTargetScore }

    var body: some View {
        ScorecardPanel(title: title) {
            if let shooter = moonShooter {
                MoonCallout(name: shooter.playerName,
                            color: PlayerPalette.color(shooter.colorIndex),
                            subtracts: state.rules.heartsMoonSubtracts)
            }
            ForEach(Array(rows.enumerated()), id: \.element.seat.id) { index, row in
                HStack {
                    if isFinal {
                        Text(RecapMedal.text(index))
                            .font(.title2)
                            .frame(width: 40)
                    } else {
                        Text("\(row.place).")
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .foregroundStyle(CardStyle.gold)
                            .frame(width: 34, alignment: .leading)
                    }
                    Circle().fill(PlayerPalette.color(row.seat.colorIndex))
                        .frame(width: 12, height: 12)
                    Text(row.seat.playerName)
                        .font(.system(.title3, design: .serif).weight(isFinal && index == 0 ? .bold : .regular))
                    if row.seat.id == lastRound?.moonShooter {
                        Image(systemName: "moon.stars.fill")
                            .font(.caption)
                            .foregroundStyle(CardStyle.gold)
                            .accessibilityLabel("shot the moon")
                    }
                    Spacer()
                    DeltaText(delta: row.delta, lowerIsBetter: true)
                        .frame(width: 60, alignment: .trailing)
                    Text("\(row.total)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(row.total >= target ? RecapInk.bad : CardStyle.stockTop)
                        .frame(width: 70, alignment: .trailing)
                }
                .foregroundStyle(CardStyle.stockTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.seat.playerName), \(row.delta) this round, \(row.total) total")
            }
            Text(isFinal ? "Lowest score wins · played to \(target)"
                         : "Lowest score wins · game ends at \(target)")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.top, 4)
        } action: {
            action
        }
    }
}

/// "Mae shot the moon!" — the one Hearts moment worth a fanfare.
private struct MoonCallout: View {
    let name: String
    let color: Color
    let subtracts: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.title3)
                .foregroundStyle(CardStyle.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) shot the moon!")
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                Text(subtracts ? "26 off \(name)'s score" : "26 to everyone else")
                    .font(.footnote)
                    .foregroundStyle(CardStyle.stockTop.opacity(0.75))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(color.opacity(0.35))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.5), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Spades

/// Spades scorepad. Partnership: one row per team (N/S, E/W) with bid,
/// tricks, bags carried and the round's score; nil bets get their own
/// line underneath. Cutthroat: the same row per seat.
struct SpadesRecapPanel<Action: View>: View {
    let state: GameState
    let isFinal: Bool
    @ViewBuilder let action: Action

    private struct TeamRow: Identifiable {
        let id: Int
        let members: [Seat]
        let label: String
        let tag: String?
        let contract: Int
        let tricks: Int
        let bagsGained: Int
        let bagsAfter: Int
        let delta: Int
        let total: Int
        let nilLines: [(text: String, made: Bool)]
    }

    private var lastRound: CompletedRound? { state.roundHistory.last }
    private var isPartnership: Bool {
        SpadesRules.isPartnership(seatCount: state.seats.count, cutthroat: state.rules.spadesCutthroat)
    }

    private var rows: [TeamRow] {
        let teams = SpadesRules.teams(for: state)
        let totals = Scoring.totals(history: state.roundHistory, kind: .spades)
        let deltas = lastRound.map { Scoring.roundScores(for: $0, kind: .spades) } ?? [:]
        let blindSeats = state.round?.blindNilSeats ?? []
        let built: [TeamRow] = teams.enumerated().map { index, members in
            let seats = members.compactMap { id in state.seats.first { $0.id == id } }
            let bids = lastRound?.bids ?? [:]
            let taken = lastRound?.tricksWon ?? [:]
            let contract = members.reduce(0) { $0 + max(bids[$1] ?? 0, 0) }
            let tricks = members.reduce(0) { $0 + (taken[$1] ?? 0) }
            let bagsGained = tricks >= contract ? tricks - contract : 0
            let nilLines: [(text: String, made: Bool)] = members.compactMap { seat in
                guard let made = lastRound?.nilMade[seat],
                      let name = seats.first(where: { $0.id == seat })?.playerName else { return nil }
                let blind = blindSeats.contains(seat)
                let stake = blind ? SpadesRules.blindNilBonus : SpadesRules.nilBonus
                let kind = blind ? "blind nil" : "nil"
                return made ? ("\(name) made \(kind) · +\(stake)", true)
                            : ("\(name) set on \(kind) · −\(stake)", false)
            }
            let first = members.first ?? 0
            return TeamRow(
                id: index,
                members: seats,
                label: seats.map(\.playerName).joined(separator: " & "),
                tag: isPartnership ? (index == 0 ? "N/S" : "E/W") : nil,
                contract: contract,
                tricks: tricks,
                bagsGained: bagsGained,
                bagsAfter: lastRound?.bagsAfter[first] ?? 0,
                delta: deltas[first] ?? 0,
                total: totals[first] ?? 0,
                nilLines: nilLines
            )
        }
        return built.sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }
    }

    private var title: String {
        if isFinal, let top = rows.first {
            return "🏆 \(top.label) \(top.members.count > 1 ? "win" : "wins") the night!"
        }
        return "Round \(state.roundHistory.count) complete"
    }

    var body: some View {
        ScorecardPanel(title: title) {
            columnHeader
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isFinal {
                            Text(RecapMedal.text(index))
                                .font(.title3)
                                .frame(width: 32)
                        }
                        HStack(spacing: -4) {
                            ForEach(row.members) { seat in
                                Circle().fill(PlayerPalette.color(seat.colorIndex))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.label)
                                .font(.system(.title3, design: .serif).weight(isFinal && index == 0 ? .bold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if let tag = row.tag {
                                Text(tag)
                                    .font(.caption2.weight(.semibold))
                                    .tracking(1)
                                    .foregroundStyle(CardStyle.gold.opacity(0.8))
                            }
                        }
                        Spacer(minLength: 6)
                        Text(row.contract == 0 && !row.nilLines.isEmpty ? "nil" : "\(row.contract)")
                            .frame(width: 44, alignment: .trailing)
                        Text("\(row.tricks)")
                            .frame(width: 44, alignment: .trailing)
                        Text(row.bagsGained > 0 ? "\(row.bagsAfter) (+\(row.bagsGained))" : "\(row.bagsAfter)")
                            .foregroundStyle(row.bagsAfter >= 7 ? RecapInk.bad : CardStyle.stockTop.opacity(0.9))
                            .frame(width: 64, alignment: .trailing)
                        DeltaText(delta: row.delta, lowerIsBetter: false)
                            .frame(width: 64, alignment: .trailing)
                        Text("\(row.total)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.headline.monospacedDigit())
                    ForEach(Array(row.nilLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Image(systemName: line.made ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(line.made ? RecapInk.good : RecapInk.bad)
                            Text(line.text)
                                .font(.footnote)
                                .foregroundStyle(CardStyle.stockTop.opacity(0.85))
                        }
                        .padding(.leading, isFinal ? 52 : 20)
                    }
                }
                .foregroundStyle(CardStyle.stockTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(row))
            }
            Text(isFinal ? "First to \(state.rules.spadesTargetScore) · 10 bags cost 100"
                         : "Playing to \(state.rules.spadesTargetScore) · 10 bags cost 100")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.top, 4)
        } action: {
            action
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            if isFinal { Spacer().frame(width: 32) }
            Spacer()
            Text("Bid").frame(width: 44, alignment: .trailing)
            Text("Took").frame(width: 44, alignment: .trailing)
            Text("Bags").frame(width: 64, alignment: .trailing)
            Text("Round").frame(width: 64, alignment: .trailing)
            Text("Total").frame(width: 64, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(CardStyle.gold.opacity(0.8))
        .accessibilityHidden(true)
    }

    private func accessibilitySummary(_ row: TeamRow) -> String {
        var parts = ["\(row.label): bid \(row.contract), took \(row.tricks), \(row.bagsAfter) bags",
                     "\(row.delta >= 0 ? "plus" : "minus") \(abs(row.delta)) this round",
                     "\(row.total) total"]
        parts += row.nilLines.map(\.text)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Shared bits

/// Signed round delta. For lowest-wins games a positive number is bad
/// news, so the colouring flips with `lowerIsBetter`.
struct DeltaText: View {
    let delta: Int
    let lowerIsBetter: Bool

    var body: some View {
        let good = lowerIsBetter ? delta <= 0 : delta >= 0
        Text(delta > 0 ? "+\(delta)" : "\(delta)")
            .font(.headline.monospacedDigit())
            .foregroundStyle(delta == 0 ? CardStyle.stockTop.opacity(0.6) : (good ? RecapInk.good : RecapInk.bad))
    }
}

enum RecapInk {
    static let good = Color(red: 0.4, green: 0.75, blue: 0.45)
    static let bad = Color(red: 0.85, green: 0.35, blue: 0.3)
}

enum RecapMedal {
    static func text(_ index: Int) -> String {
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
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(CardStyle.stockTop)
            VStack(spacing: 14) { rows }
                .padding(.horizontal, 8)
            action
        }
        .padding(36)
        .frame(maxWidth: 640)
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
