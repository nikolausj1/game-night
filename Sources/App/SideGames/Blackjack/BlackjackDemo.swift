import SwiftUI

/// Launch helpers and scripted demo states for blackjack. Nothing here is
/// needed by the game itself: it is how the lead starts a table from the
/// menu / the `-autoStartBlackjack` harness, and how the previews get
/// deterministic, hand-picked moments (stacked shoes) to look at.
enum BlackjackLaunch {
    /// Three bots and one table-only human ("You", no phone: acts by tapping
    /// the felt), or four bots when `allBots`.
    static func harnessSeats(allBots: Bool = false) -> [SeatSpec] {
        let bots = BotRoster.random(count: allBots ? 4 : 3).map(\.name)
        let names = allBots ? bots : ["You"] + bots
        return names.enumerated().map { SeatSpec(id: $0.offset, name: $0.element, isBot: allBots || $0.offset > 0) }
    }

    /// Start blackjack on the table. `seats` come from the lobby/menu in the
    /// real flow; the default is the harness table above.
    static func start(on host: GameHostController, seats: [SeatSpec]? = nil,
                      config: BlackjackConfig = BlackjackConfig(), allBots: Bool = false) {
        let specs = seats ?? harnessSeats(allBots: allBots)
        host.startSideGame(seats: specs, seed: UInt64.random(in: UInt64.min...UInt64.max)) { specs, seed in
            BlackjackHost(seats: specs, seed: seed, config: config)
        }
    }
}

enum BlackjackDemo {
    enum Moment {
        /// Fresh table, nobody has bet.
        case betting
        /// Everyone dealt in; seat 2 has split and is on its first hand.
        case midHand
        /// The round played out and settled (win, lose, push, blackjack).
        case settled
        /// A natural for the dealer: the dealer's blackjack ended the round.
        case dealerBlackjack
    }

    static let names = ["Justin", "Hank", "Ruthie", "Mae"]

    static func specs(bots: Set<Int> = [1, 2, 3]) -> [SeatSpec] {
        names.enumerated().map { SeatSpec(id: $0.offset, name: $0.element, isBot: bots.contains($0.offset)) }
    }

    private static func card(_ suit: Suit, _ rank: Int, _ copy: Int = 0) -> Card {
        let initial = String(suit.rawValue.prefix(1))
        return Card(id: "\(initial)\(rank)" + (copy > 0 ? "#\(copy)" : ""), kind: .standard(suit: suit, rank: rank))
    }

    /// A paused (un-paced) host carried to a hand-picked moment.
    static func host(_ moment: Moment, config: BlackjackConfig = BlackjackConfig()) -> BlackjackHost {
        let host = BlackjackHost(seats: specs(), seed: 7, config: config, paced: false)
        var shoe: [Card] = []
        switch moment {
        case .betting:
            return host
        case .midHand, .settled:
            // Deal: s0 10h/7c (17), s1 As/6d (soft 17), s2 8s/8h (pair), s3 Kd/Ac (21),
            // dealer 9d up, Ks hole (19).
            shoe = [card(.hearts, 10), card(.spades, 14), card(.spades, 8), card(.diamonds, 13),
                    card(.diamonds, 9),
                    card(.clubs, 7), card(.diamonds, 6), card(.hearts, 8), card(.clubs, 14),
                    card(.spades, 13),
                    card(.clubs, 5), card(.hearts, 9),            // s1: hit 5c, hit 9h -> 21
                    card(.diamonds, 3), card(.spades, 12),        // s2 split: h0 3d (11), double -> Qs (21)
                    card(.hearts, 2), card(.clubs, 9)]            // s2 h1: 2h (10), double -> 9c (19)
        case .dealerBlackjack:
            // Dealer Ah up, Kd hole -> peeks, blackjack ends the round.
            shoe = [card(.hearts, 10), card(.spades, 9), card(.spades, 8), card(.diamonds, 7),
                    card(.hearts, 14),
                    card(.clubs, 7), card(.diamonds, 6), card(.hearts, 8), card(.clubs, 12),
                    card(.diamonds, 13)]
        }
        shoe += (2...14).map { card(.clubs, $0, 1) } + (2...14).map { card(.hearts, $0, 1) }
        host.engine.stackShoe(shoe)
        for (seat, bet) in [(0, 20), (1, 10), (2, 50), (3, 30)] {
            host.scripted(.placeBet(bet), from: seat)
        }
        switch moment {
        case .betting, .dealerBlackjack:
            break
        case .midHand:
            host.scripted(.stand, from: 0)
            host.scripted(.hit, from: 1)
            host.scripted(.hit, from: 1)
            host.scripted(.split, from: 2)
        case .settled:
            host.scripted(.stand, from: 0)
            host.scripted(.hit, from: 1)
            host.scripted(.hit, from: 1)
            host.scripted(.split, from: 2)
            host.scripted(.doubleDown, from: 2)
            host.scripted(.doubleDown, from: 2)
        }
        return host
    }

    static func phone(_ host: BlackjackHost, seat: Int) -> BlackjackPhoneState {
        BlackjackPhoneState(snapshot: host.engine.state.snapshot(for: seat), names: host.names)
    }
}

// MARK: - Sim harness

extension BlackjackDemo {
    /// `-demoBlackjack [betting|midHand|settled|dealerBlackjack|live]` (default
    /// `live`) and, on a phone, `-demoSeat N`.
    static var wantsDemo: Bool { CommandLine.arguments.contains("-demoBlackjack") }

    static var argMoment: String {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-demoBlackjack"), a.indices.contains(i + 1),
              !a[i + 1].hasPrefix("-") else { return "live" }
        return a[i + 1]
    }

    static var argSeat: Int {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-demoSeat"), a.indices.contains(i + 1), let n = Int(a[i + 1]) else { return 0 }
        return n
    }
}

/// Mounts the blackjack table (iPad) or the action pad (phone) with no
/// network and no lobby, for simulator verification. `live` runs a real
/// paced game: seat 0 is the human (table taps on the iPad, the pad on the
/// phone), the rest are bots.
struct BlackjackDemoRoot: View {
    var body: some View {
        let moment = BlackjackDemo.argMoment
        if UIDevice.current.userInterfaceIdiom == .pad {
            if moment == "live" {
                BlackjackLiveTable()
            } else {
                BlackjackStaticTable(moment: moment)
            }
        } else if moment == "live" {
            BlackjackLivePad()
        } else {
            let host = BlackjackDemo.host(Self.moment(moment))
            BlackjackPadView(state: BlackjackDemo.phone(host, seat: BlackjackDemo.argSeat),
                             events: nil, send: { _ in }, holds: false)
        }
    }

    static func moment(_ name: String) -> BlackjackDemo.Moment {
        switch name {
        case "betting": return .betting
        case "settled": return .settled
        case "dealerBlackjack": return .dealerBlackjack
        default: return .midHand
        }
    }
}

private struct BlackjackStaticTable: View {
    let moment: String
    @State private var host: BlackjackHost?
    var body: some View {
        ZStack {
            TableSurface()
            if let host {
                BlackjackTableStage(bj: host, botSeats: host.botSeats,
                                    tapSeats: moment == "betting" ? [0] : [])
            }
        }
        .onAppear { host = BlackjackDemo.host(BlackjackDemoRoot.moment(moment)) }
        .statusBarHidden()
    }
}

private struct BlackjackLiveTable: View {
    @State private var host = BlackjackHost(seats: BlackjackDemo.specs(), seed: UInt64.random(in: 1...UInt64.max))
    var body: some View {
        ZStack {
            TableSurface()
            BlackjackTableStage(
                bj: host, botSeats: host.botSeats, tapSeats: [0],
                onTableTap: { seat, action in
                    if let p = try? SideGamePayload(kind: BlackjackEngine.kind,
                                                    value: BlackjackTableTap(seat: seat, action: action)) {
                        host.handle(action: p, from: -1)
                    }
                })
        }
        .statusBarHidden()
    }
}

/// The phone pad wired straight to an in-process host (seat 0 human).
private struct BlackjackLivePad: View {
    @State private var host = BlackjackHost(seats: BlackjackDemo.specs(), seed: UInt64.random(in: 1...UInt64.max))
    @State private var state: BlackjackPhoneState?
    @State private var batch: BlackjackEventBatch?

    var body: some View {
        Group {
            if let state {
                BlackjackPadView(state: state, events: batch) { action in
                    if let p = try? SideGamePayload(kind: BlackjackEngine.kind, value: action) {
                        host.handle(action: p, from: 0)
                    }
                }
            } else {
                Color.black
            }
        }
        .onAppear {
            host.onChanged = {
                state = host.state(for: 0)?.decode(BlackjackPhoneState.self)
                if let b = host.drainEvents()?.decode(BlackjackEventBatch.self) { batch = b }
            }
            state = host.state(for: 0)?.decode(BlackjackPhoneState.self)
        }
    }
}

// MARK: - Previews

private struct StagePreview: View {
    let host: BlackjackHost
    var tapSeats: Set<Int> = [0]
    var body: some View {
        ZStack {
            TableSurface()
            BlackjackTableStage(bj: host, botSeats: host.botSeats, tapSeats: tapSeats)
        }
    }
}

#Preview("Table - betting", traits: .landscapeLeft) {
    StagePreview(host: BlackjackDemo.host(.betting))
}

#Preview("Table - mid hand (split, hit, blackjack)", traits: .landscapeLeft) {
    StagePreview(host: BlackjackDemo.host(.midHand), tapSeats: [])
}

#Preview("Table - settled", traits: .landscapeLeft) {
    StagePreview(host: BlackjackDemo.host(.settled), tapSeats: [])
}

#Preview("Table - dealer blackjack", traits: .landscapeLeft) {
    StagePreview(host: BlackjackDemo.host(.dealerBlackjack), tapSeats: [])
}

#Preview("Table - live, all bots", traits: .landscapeLeft) {
    StagePreview(host: BlackjackHost(seats: BlackjackDemo.specs(bots: [0, 1, 2, 3]), seed: 11), tapSeats: [])
}

#Preview("Phone - place a bet") {
    let h = BlackjackDemo.host(.betting)
    return BlackjackPadView(state: BlackjackDemo.phone(h, seat: 0), events: nil, send: { _ in }, holds: false)
}

#Preview("Phone - split, my turn") {
    let h = BlackjackDemo.host(.midHand)
    return BlackjackPadView(state: BlackjackDemo.phone(h, seat: 2), events: nil, send: { _ in }, holds: false)
}

#Preview("Phone - waiting on another seat") {
    let h = BlackjackDemo.host(.midHand)
    return BlackjackPadView(state: BlackjackDemo.phone(h, seat: 0), events: nil, send: { _ in }, holds: false)
}

#Preview("Phone - settled, I won big") {
    let h = BlackjackDemo.host(.settled)
    return BlackjackPadView(state: BlackjackDemo.phone(h, seat: 3), events: nil, send: { _ in }, holds: false)
}
