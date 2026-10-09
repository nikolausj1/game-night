import SwiftUI

// Demo snapshots, #Previews, and a phone-only local harness for Gin Rummy.
//
// Verification notes (honest accounting):
//  - Everything here compiles with the app via `tools/build.sh`.
//  - `GinFanLayout` (the phone fan geometry) is pure math; its fit/overlap
//    numbers were checked off-device with a standalone swiftc script (11
//    cards, 4+3+4 and 3+3+3+2 groupings, widths 320...852: always inside the
//    container; card width 49-66pt on a 320-430pt phone when the hand is
//    fully grouped, up to 96pt when it isn't).
//  - The previews below are the review surface. They were NOT rendered or
//    walked through on a simulator or device in the session that wrote them
//    (the views are not mounted by any shared router yet, and the house rule
//    forbids editing the routers). Gestures, animation timing and the
//    on-glass layout are therefore unverified.

// MARK: - Demo builders

enum GinDemo {
    static func card(_ suit: Suit, _ rank: Int) -> Card {
        DeckBuilder.standard52().first { $0.suit == suit && $0.rank == rank }!
    }

    /// "7s 7h 7d 3c Kd" style shorthand: rank (A,2-10,J,Q,K) + suit letter.
    static func cards(_ text: String) -> [Card] {
        text.split(separator: " ").map { token in
            let suitChar = token.last!
            let rankText = token.dropLast()
            let rank: Int
            switch rankText {
            case "A": rank = 14
            case "K": rank = 13
            case "Q": rank = 12
            case "J": rank = 11
            default: rank = Int(rankText)!
            }
            let suit: Suit
            switch suitChar {
            case "c": suit = .clubs
            case "d": suit = .diamonds
            case "h": suit = .hearts
            default: suit = .spades
            }
            return card(suit, rank)
        }
    }

    static func meld(_ text: String) -> GinMeld { GinMelds.makeMeld(cards(text))! }

    /// A full authoritative state from hand-picked cards; the stock is filled
    /// from whatever the deck still has so counts are honest.
    static func state(phase: GinRummyPhase, turn: Int, mine: [Card], theirs: [Card], discards: [Card],
                      stockCount: Int = 24, moves: [GinMove] = [], scores: [Int: Int] = [0: 34, 1: 12],
                      handsWon: [Int: Int] = [0: 1, 1: 0], dealer: Int = 1, handNumber: Int = 2,
                      knock: GinKnockInfo? = nil, layoffs: [GinLayoff] = [], lastResult: GinHandResult? = nil,
                      upcardRefused: Bool = false, drawnFromDiscardID: String? = nil,
                      gameResult: GinGameResult? = nil) -> GinRummyState {
        let used = Set((mine + theirs + discards).map(\.id))
        let stock = Array(DeckBuilder.standard52().filter { !used.contains($0.id) }.prefix(stockCount))
        return GinRummyState(
            seed: 7, scores: scores, handsWon: handsWon, dealerSeat: dealer, phase: phase, turnSeat: turn,
            hands: [0: mine, 1: theirs], stock: stock, discardPile: discards, firstPasses: [],
            upcardRefused: upcardRefused, drawnFromDiscardID: drawnFromDiscardID, moves: moves, knock: knock,
            layoffs: layoffs, lastResult: lastResult, handNumber: handNumber,
            winnerSeat: gameResult?.winnerSeat, gameResult: gameResult)
    }

    static let names: [Int: String] = [0: "Justin", 1: "Hank"]

    static func phone(_ state: GinRummyState, seat: Int = 0) -> GinRummyPhoneState {
        GinRummyPhoneState(snapshot: state.snapshot(for: seat), names: names)
    }

    // Hands --------------------------------------------------------------

    static let drawHand = cards("7s 7h 7d 3c 4c 5c 6c Kd 9s 2h")
    static let knockHand = cards("7s 7h 7d 3c 4c 5c 6c As 2h 4d 9s")
    static let ginHand = cards("7s 7h 7d 3c 4c 5c 6c 9h 10h Jh Ks")
    static let theirTen = cards("2s 3s 4s 8c 8d 8h Qd Qc 10c Jd")

    static let drawMoves: [GinMove] = [
        GinMove(seat: 1, kind: .drewStock),
        GinMove(seat: 1, kind: .discarded(card(.clubs, 12))),
        GinMove(seat: 0, kind: .tookUpcard(card(.hearts, 9))),
        GinMove(seat: 0, kind: .discarded(card(.spades, 5))),
        GinMove(seat: 1, kind: .tookUpcard(card(.spades, 5))),
        GinMove(seat: 1, kind: .discarded(card(.diamonds, 13))),
    ]

    // Phone scenarios ----------------------------------------------------

    /// My draw: stock or the K of diamonds.
    static var phoneDraw: GinRummyPhoneState {
        phone(state(phase: .draw, turn: 0, mine: drawHand, theirs: theirTen,
                    discards: cards("Qc 5s Kd"), moves: drawMoves))
    }

    /// Discard with a legal knock (9 of spades leaves deadwood 7).
    static var phoneKnock: GinRummyPhoneState {
        phone(state(phase: .discard, turn: 0, mine: knockHand, theirs: theirTen + [card(.hearts, 2)],
                    discards: cards("Qc 5s"), moves: drawMoves + [GinMove(seat: 0, kind: .drewStock)]))
    }

    /// Gin: discarding the K of spades leaves zero deadwood.
    static var phoneGin: GinRummyPhoneState {
        phone(state(phase: .discard, turn: 0, mine: ginHand, theirs: theirTen, discards: cards("Qc 5s"),
                    moves: drawMoves + [GinMove(seat: 0, kind: .drewStock)]))
    }

    /// The opening upcard offer.
    static var phoneFirstUpcard: GinRummyPhoneState {
        phone(state(phase: .firstUpcard, turn: 0, mine: drawHand, theirs: theirTen, discards: cards("Jc"),
                    handNumber: 3))
    }

    static var phoneWaiting: GinRummyPhoneState {
        phone(state(phase: .draw, turn: 1, mine: drawHand, theirs: theirTen, discards: cards("Qc 5s Kd"),
                    moves: drawMoves + [GinMove(seat: 0, kind: .discarded(card(.diamonds, 13)))]))
    }

    /// Hank knocked; I can lay cards off onto his melds.
    static var phoneLayoff: GinRummyPhoneState {
        let melds = [meld("8s 8h 8d"), meld("3h 4h 5h"), meld("Jc Qc Kc")]
        let info = GinKnockInfo(knockerSeat: 1, discard: card(.diamonds, 9), melds: melds,
                                deadwood: cards("5s"), deadwoodPoints: 5, isGin: false)
        let mine = cards("8c 6h 2h Ad 9s 10s Js Kd 4c 5d")
        return phone(state(phase: .layoff, turn: 0, mine: mine, theirs: [], discards: cards("Qc 9d"),
                           moves: drawMoves, knock: info))
    }

    /// Hank knocked at 5; I undercut him.
    static var phoneUndercut: GinRummyPhoneState {
        let result = GinHandResult(
            handNumber: 2, outcome: .undercut, knockerSeat: 1, winnerSeat: 0, points: 28, deadwoodDifference: 3,
            ginBonus: 0, undercutBonus: 25, knockerMelds: [meld("8s 8h 8d"), meld("3h 4h 5h")],
            knockerDeadwood: cards("2c 3d"), knockerDeadwoodPoints: 5,
            defenderMelds: [meld("7s 7h 7d"), meld("3c 4c 5c 6c")], defenderDeadwood: cards("As"),
            defenderDeadwoodPoints: 1, layoffs: [], scoresAfter: [0: 62, 1: 12])
        return phone(state(phase: .handComplete, turn: 0, mine: cards("7s 7h 7d 3c 4c 5c 6c As"), theirs: cards("8s 8h 8d 3h 4h 5h 2c 3d"),
                           discards: cards("Qc 9d"), moves: drawMoves, scores: [0: 62, 1: 12],
                           handsWon: [0: 2, 1: 0], lastResult: result))
    }

    // Table scenarios ----------------------------------------------------

    static func feed(_ state: GinRummyState, seq: Int = 0, rows: [GinScoreRow] = [
        GinScoreRow(handNumber: 1, winnerSeat: 0, points: 34, outcome: .knock)
    ]) -> GinTableFeed {
        GinTableFeed(snapshot: state.tableSnapshot(), names: names, botSeats: [1], rows: rows, eventSeq: seq, events: [])
    }

    static var tablePlaying: GinTableFeed {
        feed(state(phase: .draw, turn: 0, mine: drawHand, theirs: theirTen, discards: cards("Qc 5s Kd"),
                   stockCount: 19, moves: drawMoves))
    }

    static var tableLayoff: GinTableFeed {
        let melds = [meld("8s 8h 8d"), meld("3h 4h 5h"), meld("Jc Qc Kc")]
        let info = GinKnockInfo(knockerSeat: 1, discard: card(.diamonds, 9), melds: melds,
                                deadwood: cards("5s"), deadwoodPoints: 5, isGin: false)
        return feed(state(phase: .layoff, turn: 0, mine: cards("8c 6h 2h Ad 9s 10s Js Kd 4c 5d"), theirs: [],
                          discards: cards("Qc 9d"), stockCount: 14, moves: drawMoves, knock: info))
    }

    static var tableUndercut: GinTableFeed {
        let knockerMelds = [meld("8s 8h 8d"), meld("3h 4h 5h")]
        let info = GinKnockInfo(knockerSeat: 1, discard: card(.diamonds, 9), melds: knockerMelds,
                                deadwood: cards("2c 3d"), deadwoodPoints: 5, isGin: false)
        let result = GinHandResult(
            handNumber: 2, outcome: .undercut, knockerSeat: 1, winnerSeat: 0, points: 28, deadwoodDifference: 3,
            ginBonus: 0, undercutBonus: 25, knockerMelds: knockerMelds, knockerDeadwood: cards("2c 3d"),
            knockerDeadwoodPoints: 5, defenderMelds: [meld("7s 7h 7d"), meld("3c 4c 5c 6c")],
            defenderDeadwood: cards("As"), defenderDeadwoodPoints: 1, layoffs: [], scoresAfter: [0: 62, 1: 12])
        return feed(state(phase: .handComplete, turn: 0, mine: cards("7s 7h 7d 3c 4c 5c 6c As"),
                          theirs: cards("8s 8h 8d 3h 4h 5h 2c 3d"), discards: cards("Qc 9d"), stockCount: 12,
                          moves: drawMoves, scores: [0: 62, 1: 12], handsWon: [0: 2, 1: 0], knock: info,
                          lastResult: result),
                    rows: [GinScoreRow(handNumber: 1, winnerSeat: 0, points: 34, outcome: .knock),
                           GinScoreRow(handNumber: 2, winnerSeat: 0, points: 28, outcome: .undercut)])
    }

    static var tableGameOver: GinTableFeed {
        let game = GinGameResult(winnerSeat: 0, handScores: [0: 104, 1: 61], handsWon: [0: 4, 1: 2], gameBonus: 100,
                                 shutout: false, boxBonus: [0: 100, 1: 50], finalTotals: [0: 304, 1: 111])
        var feed = tableUndercut
        let snapshot = GinRummyTableSnapshot(
            dealerSeat: 1, phase: .gameOver, turnSeat: 0, scores: [0: 104, 1: 61], handsWon: [0: 4, 1: 2],
            handCounts: [0: 8, 1: 8], stockCount: 12, upcard: nil, discardPile: cards("Qc 9d"), moves: drawMoves,
            knock: feed.snapshot.knock, layoffs: [], lastResult: feed.snapshot.lastResult, handNumber: 6,
            winnerSeat: 0, gameResult: game)
        feed.snapshot = snapshot
        return feed
    }
}

// MARK: - Phone-only harness (a local game against a bot, no iPad needed)

/// A local, in-process game: seat 0 is the phone, seat 1 a bot. Mount
/// `GinRummyPhoneHarness()` from any root behind `-autoStartGinRummyPhone`
/// to play the phone UI end to end on a simulator.
@Observable
final class GinRummyLocalGame {
    private let engine: GinRummyEngine
    private let bot = "Hank"
    private var rng: SeededGenerator
    private var version = 0
    private var scheduled = false

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        engine = GinRummyEngine(seed: seed)
        rng = SeededGenerator(seed: seed ^ 0xB07)
        pump()
    }

    var phone: GinRummyPhoneState {
        _ = version
        return GinRummyPhoneState(snapshot: engine.snapshot(for: 0), names: [0: "You", 1: bot])
    }

    func send(_ action: GinRummyAction) {
        _ = engine.apply(action, from: 0)
        version += 1
        pump()
    }

    private func pump() {
        guard !scheduled else { return }
        let s = engine.state
        var delay: Double?
        switch s.phase {
        case .handComplete: delay = 5
        case .gameOver: delay = nil
        default: delay = s.turnSeat == 1 ? Double.random(in: 0.9...1.8, using: &rng) : nil
        }
        guard let delay else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            scheduled = false
            let s = engine.state
            if s.phase == .handComplete {
                _ = engine.apply(.advance, from: 0)
            } else if s.turnSeat == 1, let action = GinRummyBot.nextAction(
                snapshot: engine.snapshot(for: 1), personality: .balanced, rng: &rng) {
                _ = engine.apply(action, from: 1)
            }
            version += 1
            pump()
        }
    }
}

struct GinRummyPhoneHarness: View {
    @State private var game = GinRummyLocalGame()

    var body: some View {
        GinRummyHandContent(state: game.phone, send: { game.send($0) })
    }
}

// MARK: - Previews

#Preview("Phone - draw") {
    GinRummyHandContent(state: GinDemo.phoneDraw, send: { _ in })
}

#Preview("Phone - first upcard") {
    GinRummyHandContent(state: GinDemo.phoneFirstUpcard, send: { _ in })
}

#Preview("Phone - discard, knock available") {
    GinRummyHandContent(state: GinDemo.phoneKnock, send: { _ in })
}

#Preview("Phone - gin") {
    GinRummyHandContent(state: GinDemo.phoneGin, send: { _ in })
}

#Preview("Phone - waiting") {
    GinRummyHandContent(state: GinDemo.phoneWaiting, send: { _ in })
}

#Preview("Phone - layoff") {
    GinRummyHandContent(state: GinDemo.phoneLayoff, send: { _ in })
}

#Preview("Phone - undercut result") {
    GinRummyHandContent(state: GinDemo.phoneUndercut, send: { _ in })
}

#Preview("Phone - landscape draw", traits: .landscapeLeft) {
    GinRummyHandContent(state: GinDemo.phoneDraw, send: { _ in })
}

#Preview("Phone - play a hand vs Hank") {
    GinRummyPhoneHarness()
}

#Preview("Table - mid hand", traits: .fixedLayout(width: 1180, height: 820)) {
    ZStack {
        TableSurface()
        GinRummyTableContent(feed: GinDemo.tablePlaying)
    }
}

#Preview("Table - layoff", traits: .fixedLayout(width: 1180, height: 820)) {
    ZStack {
        TableSurface()
        GinRummyTableContent(feed: GinDemo.tableLayoff)
    }
}

#Preview("Table - undercut showdown", traits: .fixedLayout(width: 1180, height: 820)) {
    ZStack {
        TableSurface()
        GinRummyTableContent(feed: GinDemo.tableUndercut)
    }
}

#Preview("Table - game over", traits: .fixedLayout(width: 1180, height: 820)) {
    ZStack {
        TableSurface()
        GinRummyTableContent(feed: GinDemo.tableGameOver)
    }
}

#Preview("Table - portrait iPad", traits: .fixedLayout(width: 834, height: 1194)) {
    ZStack {
        TableSurface()
        GinRummyTableContent(feed: GinDemo.tableUndercut)
    }
}
