import Foundation

// MARK: - Wire types
//
// Blackjack rides the generic `SideGamePayload` wire (kind "blackjack").
// Phone -> host: a bare `BlackjackAction` (the host knows the seat from the
// device). Table -> host (seat -1): a `BlackjackTableTap`, because a
// table-only human seat has no phone and the table has to say WHOSE hand
// it is acting for. Host -> phone: a `BlackjackPhoneState` (state) and a
// `BlackjackEventBatch` (events).

/// A tap on the table's own felt on behalf of a seat that has no phone.
struct BlackjackTableTap: Codable, Equatable {
    var seat: Int
    var action: BlackjackAction
}

/// Everything the engine said in one mutation (or several, merged when the
/// transport drained late). `seq` rises by one per batch the HOST produced,
/// so a consumer can tell "new" from "already seen".
struct BlackjackEventBatch: Codable, Equatable {
    var seq: Int
    var events: [BlackjackEvent]
}

/// One seat's view: blackjack is public except the hole card, so this is the
/// engine's own snapshot (personalized `mySeat`/`legalActions`) plus the
/// seat names so the phone can talk about the table by name.
struct BlackjackPhoneState: Codable, Equatable {
    var snapshot: BlackjackSnapshot
    var names: [String]
}

// MARK: - Pacing + timeline
//
// The engine resolves a whole round-step in one `apply` (the entire deal,
// the dealer's whole turn, every settlement), so the table has to REPLAY the
// events as theater. `BlackjackTimeline` turns an event list into beats with
// start offsets; the table schedules its animation from them and the host
// uses the same durations to hold bots back until the felt has caught up.
// One pure function, shared by both sides, so they cannot drift apart.

struct BlackjackBeat: Equatable {
    /// Seconds after the batch's start at which this event is enacted.
    let at: Double
    let event: BlackjackEvent
}

struct BlackjackSchedule {
    let beats: [BlackjackBeat]
    /// When the NEXT batch may begin (sum of beat advances).
    let advance: Double
    /// When everything this batch started has finished (flights, flips).
    let total: Double
}

enum BlackjackTimeline {
    /// (advance, tail): how long this event holds the queue, and how much
    /// longer its animation keeps running after the queue moves on.
    static func timing(_ e: BlackjackEvent) -> (advance: Double, tail: Double) {
        switch e {
        case .roundStarted: return (0.6, 0)
        case .shoeReshuffled: return (1.6, 0)
        case .betPlaced: return (0.35, 0.2)
        case .satOut: return (0.25, 0)
        case .cardDealt, .dealerUpCard, .dealerHoleDealt: return (0.40, 0.25)
        case .playerBlackjack: return (1.3, 0)
        case .insuranceOffered: return (0.8, 0)
        case .insuranceTaken: return (0.4, 0.2)
        case .insuranceDeclined: return (0.1, 0)
        case .insuranceSettled: return (0.5, 0.6)
        case .dealerPeek: return (1.1, 0)
        case .turnStarted: return (0.15, 0)
        case .hit: return (0.5, 0.25)
        case .stand(_, _, let auto): return (auto ? 0.3 : 0.45, 0)
        case .doubled: return (0.8, 0.3)
        case .split: return (0.95, 0.3)
        case .surrendered: return (0.7, 0)
        case .bust: return (1.1, 0)
        case .dealerRevealed: return (1.0, 0)
        case .dealerDrew: return (0.8, 0.2)
        case .dealerStands: return (0.6, 0)
        case .dealerBust: return (1.2, 0)
        case .dealerBlackjack: return (1.3, 0)
        case .handSettled: return (0.5, 1.4)
        case .roundComplete: return (0.3, 0)
        case .seatBroke: return (1.2, 0)
        case .sessionOver: return (0.8, 0)
        case .illegalAttempt: return (0, 0)
        }
    }

    static func schedule(_ events: [BlackjackEvent], speed: Double = 1) -> BlackjackSchedule {
        var t = 0.0
        var total = 0.0
        var beats: [BlackjackBeat] = []
        for e in events {
            let (adv, tail) = timing(e)
            beats.append(BlackjackBeat(at: t / speed, event: e))
            total = max(total, (t + adv + tail) / speed)
            t += adv
        }
        return BlackjackSchedule(beats: beats, advance: t / speed, total: total)
    }

    /// Does this batch contain anything the felt will animate? (An
    /// illegal-attempt-only batch is silent.)
    static func isVisible(_ events: [BlackjackEvent]) -> Bool {
        events.contains { if case .illegalAttempt = $0 { return false }; return true }
    }
}

// MARK: - Display helpers shared by table + phone

enum BlackjackText {
    /// "7/17" for a soft hand, "17" for a hard one, "BUST" over 21.
    static func total(_ cards: [Card]) -> String {
        guard !cards.isEmpty else { return "" }
        let v = BlackjackRules.value(of: cards)
        if v.isBust { return "BUST" }
        if cards.count == 1 { return "\(v.total)" }   // a lone ace reads 11, not 1/11
        if v.isSoft && v.total < 21 { return "\(v.total - 10)/\(v.total)" }
        return "\(v.total)"
    }

    static func outcomeWord(_ o: BlackjackOutcome) -> String {
        switch o {
        case .blackjack: return "BLACKJACK"
        case .win: return "WIN"
        case .push: return "PUSH"
        case .lose: return "LOSE"
        case .bust: return "BUST"
        case .surrender: return "SURRENDER"
        }
    }

    /// "WIN +20", "LOSE -10", "PUSH".
    static func outcomeTag(_ o: BlackjackOutcome, net: Int) -> String {
        switch o {
        case .push: return "PUSH"
        case .bust: return "BUST -\(abs(net))"
        case .surrender: return "SURRENDER \(net >= 0 ? "+" : "-")\(abs(net))"
        default: return "\(outcomeWord(o)) \(net >= 0 ? "+" : "-")\(abs(net))"
        }
    }
}
