import Foundation

/// Sim-verify hooks for the two classic trick-takers: an all-bot table
/// that plays itself, reachable without MenuView. Mirrors the
/// `-autoStartUno` shape (four bots, random roster order, default rules).
///
/// Integration (one line in `TableRootView.onAppear`, alongside the other
/// `autoStartIfRequested` hooks):
///
///     HeartsSpadesLaunch.autoStartIfRequested(host: host)
///
/// Launch arguments:
/// - `-autoStartHearts`: 4-seat hearts, passing on (round 1 passes left).
/// - `-autoStartSpades`: 4-seat partnership spades.
/// - `-spadesBlindNil`: with `-autoStartSpades`, turns the blind-nil rule on
///   so the bots' bidding exercises `round.blindNilSeats` plumbing.
/// - `-spadesCutthroat`: with `-autoStartSpades`, individual play (no
///   partnerships), for the per-seat recap rows.
/// - `-heartsNoPassing`: with `-autoStartHearts`, every round is a hold, so
///   the table skips straight from the deal into play.
enum HeartsSpadesLaunch {
    static func autoStartIfRequested(host: GameHostController) {
        guard host.state == nil, host.sideGame == nil, host.cribbageEngine == nil else { return }
        let args = CommandLine.arguments
        let kind: GameKind
        if args.contains("-autoStartHearts") {
            kind = .hearts
        } else if args.contains("-autoStartSpades") {
            kind = .spades
        } else {
            return
        }
        var rules = RulesConfig()
        rules.heartsPassing = !args.contains("-heartsNoPassing")
        rules.spadesBlindNil = args.contains("-spadesBlindNil")
        rules.spadesCutthroat = args.contains("-spadesCutthroat")
        let seats = BotRoster.random(count: 4).enumerated().map {
            SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
        }
        host.startGame(kind: kind, rules: rules, seats: seats)
    }
}
