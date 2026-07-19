import Foundation

/// Maps engine events to the announcer's voice and the table's sound
/// effects. Lives on the table only — phones stay quiet in your pocket.
final class AnnouncerDirector {
    static let shared = AnnouncerDirector()

    private let announcer = Announcer.shared
    private let sfx = TableSFX.shared

    private init() {}

    func handle(events: [GameEvent], state: GameState?) {
        guard let state else { return }
        for event in events {
            switch event {
            case .dealt:
                sfx.play(.cardDeal)

            case .bidPlaced(let seat, let bid):
                sfx.play(.chipPlace)
                announcer.announceBid(playerName: state.seats[seat].playerName, bid: bid)

            case .biddingComplete:
                if let round = state.round {
                    let total = round.bids.values.reduce(0, +)
                    announcer.announceBiddingComplete(totalBids: total,
                                                     tricksAvailable: round.cardsPerPlayer)
                }

            case .trumpRevealed(_, let suit):
                sfx.play(.cardFlip)
                announcer.announceTrumpReveal(suitName: suit?.rawValue)

            case .cardPlayed(_, let card, _):
                sfx.play(.cardSlide)
                if case .wizard = card.kind { announcer.announceWizardPlayed() }
                if case .jester = card.kind { announcer.announceJesterPlayed() }

            case .trickWon(let seat):
                sfx.play(.trickSweep)
                announcer.announceTrickWon(playerName: state.seats[seat].playerName)

            case .roundScored:
                let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
                let standings = state.seats
                    .map { (name: $0.playerName, score: totals[$0.id] ?? 0) }
                    .sorted { $0.score > $1.score }
                announcer.announceRoundScored(standings: standings)

            case .gameWon(let seat):
                sfx.play(.fanfareWin)
                let totals = Scoring.totals(history: state.roundHistory, kind: state.gameKind, missScoresTricks: state.rules.missScoresTricks)
                let sorted = totals.values.sorted(by: >)
                let margin = sorted.count >= 2 ? sorted[0] - sorted[1] : 0
                announcer.announceGameWon(winnerName: state.seats[seat].playerName, margin: margin)

            case .illegalAttempt, .undone, .suitDeclared:
                break // private moments; the table doesn't call them out
            }
        }
    }
}
