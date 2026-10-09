import SwiftUI

/// Canned Liar's Dice states for `#Preview`s (and any future demo harness).
/// Nothing here auto-plays: hosts are built with `autoplay: false` so a
/// preview stays exactly where it was put.
enum LiarsDiceDemo {
    static let names = ["Vinny", "Chase", "Hank", "Ruthie", "Marco", "Mae"]

    enum Moment {
        /// Mid-round: a few bids on the ledger, someone to act.
        case bidding
        /// The turn seat just called LIAR! on the standing bid.
        case liar
        /// The turn seat just called SPOT ON.
        case spotOn
    }

    /// An engine mid-round at the requested moment. Round dice come from the
    /// engine's own deterministic `rollAll`.
    static func engine(seats: Int, moment: Moment, seed: UInt64 = 7) -> LiarsDiceEngine {
        let engine = LiarsDiceEngine(seed: seed, seatCount: seats)
        engine.rollAll(seed: seed &+ 1)
        let bids: [(Int, Int)] = [(2, 3), (3, 3), (3, 5), (4, 5), (5, 5)]
        for (q, f) in bids {
            _ = engine.apply(.bid(quantity: q, face: f), from: engine.state.turnSeat)
        }
        switch moment {
        case .bidding: break
        case .liar: _ = engine.apply(.challenge, from: engine.state.turnSeat)
        case .spotOn: _ = engine.apply(.spotOn, from: engine.state.turnSeat)
        }
        return engine
    }

    /// `seats` players; seat 0 is the human at this phone, the rest are bots.
    static func host(seats: Int = 5, moment: Moment = .bidding, shaken: Bool = true) -> LiarsDiceHost {
        LiarsDiceHost(restoring: engine(seats: seats, moment: moment),
                      names: Array(names.prefix(seats)),
                      botSeats: Set(1..<seats),
                      shaken: shaken ? [0] : [])
    }

    /// The phone payload for `seat`, decoded the way the real client does.
    static func phoneState(_ host: LiarsDiceHost, seat: Int) -> LiarsDicePhoneState {
        host.state(for: seat)!.decode(LiarsDicePhoneState.self)!
    }
}

// MARK: - Previews

#Preview("Table - bidding, 5 seats", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        LiarsDiceTableScene(game: LiarsDiceDemo.host(seats: 5))
    }
}

#Preview("Table - 6 seats, count beat", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        LiarsDiceTableScene(game: LiarsDiceDemo.host(seats: 6, moment: .liar),
                            previewStage: .count, previewCount: 3)
    }
}

#Preview("Table - 3 seats, LIAR slam", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        LiarsDiceTableScene(game: LiarsDiceDemo.host(seats: 3, moment: .liar),
                            previewStage: .slam)
    }
}

#Preview("Table - 4 seats, verdict", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        LiarsDiceTableScene(game: LiarsDiceDemo.host(seats: 4, moment: .liar),
                            previewStage: .verdict)
    }
}

#Preview("Table - 2 seats, spot on", traits: .fixedLayout(width: 1194, height: 834)) {
    ZStack {
        TableSurface()
        LiarsDiceTableScene(game: LiarsDiceDemo.host(seats: 2, moment: .spotOn),
                            previewStage: .verdict)
    }
}

#Preview("Phone - shake to roll", traits: .fixedLayout(width: 390, height: 844)) {
    let host = LiarsDiceDemo.host(shaken: false)
    return LiarsDicePhoneScreen(state: LiarsDiceDemo.phoneState(host, seat: 0))
}

#Preview("Phone - cup down, waiting", traits: .fixedLayout(width: 390, height: 844)) {
    let host = LiarsDiceDemo.host()
    return LiarsDicePhoneScreen(state: LiarsDiceDemo.phoneState(host, seat: 0), previewRolled: true)
}

#Preview("Phone - peeking, my turn", traits: .fixedLayout(width: 390, height: 844)) {
    let host = LiarsDiceDemo.host()
    let turn = host.engine.state.turnSeat
    return LiarsDicePhoneScreen(state: LiarsDiceDemo.phoneState(host, seat: turn),
                                previewRolled: true, previewPeek: true)
}

#Preview("Phone - my turn, cup down", traits: .fixedLayout(width: 390, height: 844)) {
    let host = LiarsDiceDemo.host()
    let turn = host.engine.state.turnSeat
    return LiarsDicePhoneScreen(state: LiarsDiceDemo.phoneState(host, seat: turn), previewRolled: true)
}

#Preview("Phone - reveal", traits: .fixedLayout(width: 390, height: 844)) {
    let host = LiarsDiceDemo.host(moment: .liar)
    return LiarsDicePhoneScreen(state: LiarsDiceDemo.phoneState(host, seat: 0), previewRolled: true)
}
