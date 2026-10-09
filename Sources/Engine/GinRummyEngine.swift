import Foundation

/// The authoritative Gin Rummy reducer: `apply(action, from: seat) -> [events]`,
/// seeded deals, Codable `state`, per-seat redacted snapshots.
///
/// ## Rules implemented
/// - Deal 10 each, one upcard, 31-card stock. `seed % 2` is the first dealer;
///   the dealer alternates every hand (drawn hands included). Non-dealer acts first.
/// - First-upcard rule: the non-dealer may take or pass the upcard; if they
///   pass, the dealer may take or pass; if both pass, the non-dealer must
///   draw from the stock (`upcardRefused`).
/// - A turn is draw (stock or upcard) then discard or knock. You cannot
///   discard the card you just took from the discard pile.
/// - Knock: after discarding, deadwood <= 10 (aces 1, faces 10, melds sets
///   3-4 / runs 3+, ace low only). Deadwood 0 is gin (opponent may not lay off).
/// - Layoff (non-gin knock): the defender may lay cards onto the knocker's
///   melds (`layOff`, or `autoLayoff` for the optimal play). The layoff phase
///   is skipped when no card could be laid off, and ends by itself once none
///   can be.
/// - Scoring: knocker < defender -> knocker scores the difference. Gin -> 25
///   + defender's deadwood. Defender <= knocker (undercut) -> defender scores
///   25 + the difference.
/// - Draw: a non-knocking discard that leaves <= 2 stock cards voids the hand.
/// - Game to 100 (first hand-score total >= 100). Then game bonus 100 (200
///   if the loser won no hand) to the winner, +25 per hand won to each seat.
///
/// `kind` is the side-game seam key.
public final class GinRummyEngine {
    public static let kind = "ginRummy"

    public private(set) var state: GinRummyState

    public init(seed: UInt64) {
        let dealer = Int(seed % 2)
        state = GinRummyState(
            seed: seed, scores: [0: 0, 1: 0], handsWon: [0: 0, 1: 0], dealerSeat: dealer, phase: .firstUpcard,
            turnSeat: 1 - dealer, hands: [:], stock: [], discardPile: [], firstPasses: [], upcardRefused: false,
            drawnFromDiscardID: nil, moves: [], knock: nil, layoffs: [], lastResult: nil, handNumber: 0,
            winnerSeat: nil, gameResult: nil
        )
        deal()
    }

    public init(restoring state: GinRummyState) {
        self.state = state
    }

    public func snapshot(for seat: Int) -> GinRummySnapshot { state.snapshot(for: seat) }
    public func tableSnapshot() -> GinRummyTableSnapshot { state.tableSnapshot() }

    // MARK: - Dispatch

    public func apply(_ action: GinRummyAction, from seat: Int) -> [GinRummyEvent] {
        guard seat == 0 || seat == 1 else { return reject(seat, "Gin Rummy only has two seats") }
        guard state.phase != .gameOver else { return reject(seat, "The game is over") }
        switch action {
        case .advance:
            return handleAdvance(from: seat)
        case .passUpcard:
            return handlePass(from: seat)
        case .drawStock:
            return handleDrawStock(from: seat)
        case .drawUpcard:
            return handleDrawUpcard(from: seat)
        case .discard(let id):
            return handleDiscard(id, from: seat)
        case .knock(let discard, let melds):
            return handleKnock(discard: discard, melds: melds, from: seat)
        case .layOff(let id, let idx):
            return handleLayOff(id, idx, from: seat)
        case .autoLayoff:
            return handleAutoLayoff(from: seat)
        case .finishLayoff:
            return handleFinishLayoff(from: seat)
        }
    }

    // MARK: - Deal

    private func deal() {
        state.handNumber += 1
        let deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: state.seed &+ UInt64(state.handNumber))
        state.hands = [0: Array(deck[0..<10]), 1: Array(deck[10..<20])]
        state.discardPile = [deck[20]]
        state.stock = Array(deck[21...])
        state.phase = .firstUpcard
        state.turnSeat = 1 - state.dealerSeat
        state.firstPasses = []
        state.upcardRefused = false
        state.drawnFromDiscardID = nil
        state.moves = []
        state.knock = nil
        state.layoffs = []
    }

    private func handleAdvance(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .handComplete else { return reject(seat, "The hand isn't finished") }
        state.dealerSeat = 1 - state.dealerSeat
        deal()
        return [.dealt(dealerSeat: state.dealerSeat, upcard: state.discardPile[0])]
    }

    // MARK: - Draw

    private func handlePass(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .firstUpcard else { return reject(seat, "Passing the upcard is only allowed at the start") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        state.firstPasses.insert(seat)
        state.moves.append(GinMove(seat: seat, kind: .passedUpcard))
        if state.firstPasses.count == 2 {
            state.upcardRefused = true
            state.phase = .draw
            state.turnSeat = 1 - state.dealerSeat // non-dealer must draw the stock
        } else {
            state.turnSeat = 1 - seat
        }
        return [.upcardPassed(seat: seat)]
    }

    private func handleDrawStock(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .draw else { return reject(seat, "You can't draw right now") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        guard !state.stock.isEmpty else { return reject(seat, "The stock is empty") }
        let card = state.stock.removeFirst()
        state.hands[seat, default: []].append(card)
        state.drawnFromDiscardID = nil
        state.moves.append(GinMove(seat: seat, kind: .drewStock))
        state.phase = .discard
        return [.drewStock(seat: seat)]
    }

    private func handleDrawUpcard(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .draw || state.phase == .firstUpcard else { return reject(seat, "You can't draw right now") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        if state.phase == .draw && state.upcardRefused {
            return reject(seat, "Both players passed the upcard - draw from the stock")
        }
        guard let card = state.discardPile.popLast() else { return reject(seat, "No upcard") }
        state.hands[seat, default: []].append(card)
        state.drawnFromDiscardID = card.id
        state.moves.append(GinMove(seat: seat, kind: .tookUpcard(card)))
        state.phase = .discard
        return [.tookUpcard(seat: seat, card: card)]
    }

    // MARK: - Discard / knock

    private func handleDiscard(_ id: String, from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .discard else { return reject(seat, "You can't discard right now") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        guard let idx = state.hands[seat]?.firstIndex(where: { $0.id == id }) else {
            return reject(seat, "That card isn't in your hand")
        }
        if id == state.drawnFromDiscardID { return reject(seat, "You can't discard the card you just took from the pile") }
        let card = state.hands[seat]!.remove(at: idx)
        state.discardPile.append(card)
        state.moves.append(GinMove(seat: seat, kind: .discarded(card)))
        state.drawnFromDiscardID = nil
        state.upcardRefused = false
        var events: [GinRummyEvent] = [.discarded(seat: seat, card: card)]
        if state.stock.count <= GinRummyRules.stockFloor {
            let result = GinHandResult(
                handNumber: state.handNumber, outcome: .drawn, knockerSeat: nil, winnerSeat: nil, points: 0,
                deadwoodDifference: 0, ginBonus: 0, undercutBonus: 0, knockerMelds: [], knockerDeadwood: [],
                knockerDeadwoodPoints: 0, defenderMelds: [], defenderDeadwood: [], defenderDeadwoodPoints: 0,
                layoffs: [], scoresAfter: state.scores
            )
            state.lastResult = result
            state.phase = .handComplete
            events.append(.handDrawn(handNumber: state.handNumber))
            return events
        }
        state.turnSeat = 1 - seat
        state.phase = .draw
        return events
    }

    private func handleKnock(discard id: String, melds ids: [[String]]?, from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .discard else { return reject(seat, "You can't knock right now") }
        guard state.turnSeat == seat else { return reject(seat, "Not your turn") }
        guard let hand = state.hands[seat], hand.count == GinRummyRules.handSize + 1,
              let idx = hand.firstIndex(where: { $0.id == id }) else {
            return reject(seat, "That card isn't in your hand")
        }
        if id == state.drawnFromDiscardID { return reject(seat, "You can't discard the card you just took from the pile") }
        var rest = hand
        let discard = rest.remove(at: idx)
        let defender = 1 - seat
        let defenderHand = state.hands[defender] ?? []

        let arrangement: GinArrangement
        if let ids {
            var used = Set<String>()
            var melds: [GinMeld] = []
            for group in ids {
                var cards: [Card] = []
                for cid in group {
                    guard let c = rest.first(where: { $0.id == cid }), !used.contains(cid) else {
                        return reject(seat, "A meld uses a card you don't have (or twice)")
                    }
                    used.insert(cid)
                    cards.append(c)
                }
                guard let meld = GinMelds.makeMeld(cards) else { return reject(seat, "That isn't a valid meld") }
                melds.append(meld)
            }
            arrangement = GinArrangement(melds: melds, deadwood: GinRummyCards.sorted(rest.filter { !used.contains($0.id) }))
        } else {
            // Among minimum-deadwood arrangements, pick the one that leaves the
            // defender the least layoff relief (ties: first found).
            let options = GinMelds.optimalArrangements(rest, limit: 64)
            var best = options[0]
            if options.count > 1 {
                var bestDefense = -1
                for option in options {
                    let d = GinMelds.optimalLayoff(hand: defenderHand, knockerMelds: option.melds).deadwood
                    if d > bestDefense { bestDefense = d; best = option }
                }
            }
            arrangement = best
        }
        let dw = arrangement.deadwoodPoints
        guard dw <= GinRummyRules.knockMax else {
            return reject(seat, "Deadwood is \(dw) - you need \(GinRummyRules.knockMax) or less to knock")
        }

        state.hands[seat] = GinRummyCards.sorted(rest)
        state.discardPile.append(discard)
        state.moves.append(GinMove(seat: seat, kind: .discarded(discard)))
        state.drawnFromDiscardID = nil
        let info = GinKnockInfo(
            knockerSeat: seat, discard: discard, melds: arrangement.melds, deadwood: arrangement.deadwood,
            deadwoodPoints: dw, isGin: dw == 0
        )
        state.knock = info
        state.layoffs = []
        var events: [GinRummyEvent] = [.discarded(seat: seat, card: discard), .knocked(seat: seat, info: info)]

        if info.isGin || GinMelds.layoffCandidates(hand: defenderHand, melds: info.melds).isEmpty {
            events += resolveKnock()
        } else {
            state.phase = .layoff
            state.turnSeat = defender
        }
        return events
    }

    // MARK: - Layoff

    private func handleLayOff(_ id: String, _ meldIndex: Int, from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .layoff, let info = state.knock else { return reject(seat, "No layoff is open") }
        guard seat == 1 - info.knockerSeat else { return reject(seat, "Only the defender lays off") }
        guard let card = state.hands[seat]?.first(where: { $0.id == id }) else {
            return reject(seat, "That card isn't in your hand")
        }
        guard info.melds.indices.contains(meldIndex), GinMelds.canLayOff(card, onto: info.melds[meldIndex]) else {
            return reject(seat, "That card doesn't fit that meld")
        }
        state.hands[seat]!.removeAll { $0 == card }
        state.knock!.melds[meldIndex] = GinMelds.extend(info.melds[meldIndex], with: card)
        state.layoffs.append(GinLayoff(seat: seat, card: card, meldIndex: meldIndex))
        var events: [GinRummyEvent] = [.laidOff(seat: seat, card: card, meldIndex: meldIndex)]
        if GinMelds.layoffCandidates(hand: state.hands[seat] ?? [], melds: state.knock!.melds).isEmpty {
            events += resolveKnock()
        }
        return events
    }

    private func handleAutoLayoff(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .layoff, let info = state.knock else { return reject(seat, "No layoff is open") }
        guard seat == 1 - info.knockerSeat else { return reject(seat, "Only the defender lays off") }
        let plan = GinMelds.optimalLayoff(hand: state.hands[seat] ?? [], knockerMelds: info.melds)
        var events: [GinRummyEvent] = []
        for p in plan.placements {
            state.hands[seat]!.removeAll { $0 == p.card }
            state.knock!.melds[p.meldIndex] = GinMelds.extend(state.knock!.melds[p.meldIndex], with: p.card)
            state.layoffs.append(GinLayoff(seat: seat, card: p.card, meldIndex: p.meldIndex))
            events.append(.laidOff(seat: seat, card: p.card, meldIndex: p.meldIndex))
        }
        events += resolveKnock()
        return events
    }

    private func handleFinishLayoff(from seat: Int) -> [GinRummyEvent] {
        guard state.phase == .layoff, let info = state.knock else { return reject(seat, "No layoff is open") }
        guard seat == 1 - info.knockerSeat else { return reject(seat, "Only the defender lays off") }
        return resolveKnock()
    }

    // MARK: - Scoring

    private func resolveKnock() -> [GinRummyEvent] {
        guard let info = state.knock else { return [] }
        let knocker = info.knockerSeat
        let defender = 1 - knocker
        let defenderHand = state.hands[defender] ?? []
        let arrangement = GinMelds.bestArrangement(defenderHand)
        let k = info.deadwoodPoints
        let d = arrangement.deadwoodPoints

        var outcome: GinHandOutcome
        var winner: Int
        var points: Int
        var diff = 0, gin = 0, under = 0
        if info.isGin {
            outcome = .gin
            winner = knocker
            gin = GinRummyRules.ginBonus
            diff = d
            points = gin + d
        } else if k < d {
            outcome = .knock
            winner = knocker
            diff = d - k
            points = diff
        } else {
            outcome = .undercut
            winner = defender
            diff = k - d
            under = GinRummyRules.undercutBonus
            points = under + diff
        }
        state.scores[winner, default: 0] += points
        state.handsWon[winner, default: 0] += 1
        let result = GinHandResult(
            handNumber: state.handNumber, outcome: outcome, knockerSeat: knocker, winnerSeat: winner, points: points,
            deadwoodDifference: diff, ginBonus: gin, undercutBonus: under, knockerMelds: info.melds,
            knockerDeadwood: info.deadwood, knockerDeadwoodPoints: k, defenderMelds: arrangement.melds,
            defenderDeadwood: arrangement.deadwood, defenderDeadwoodPoints: d, layoffs: state.layoffs,
            scoresAfter: state.scores
        )
        state.lastResult = result
        state.hands[defender] = GinRummyCards.sorted(defenderHand)
        var events: [GinRummyEvent] = [.showdown(result)]

        if state.scores[winner, default: 0] >= GinRummyRules.targetScore {
            let loser = 1 - winner
            let shutout = (state.handsWon[loser] ?? 0) == 0
            let bonus = GinRummyRules.gameBonus * (shutout ? 2 : 1)
            let box = [0: (state.handsWon[0] ?? 0) * GinRummyRules.boxBonus, 1: (state.handsWon[1] ?? 0) * GinRummyRules.boxBonus]
            var totals = state.scores
            totals[winner, default: 0] += bonus
            for s in [0, 1] { totals[s, default: 0] += box[s] ?? 0 }
            let game = GinGameResult(
                winnerSeat: winner, handScores: state.scores, handsWon: state.handsWon, gameBonus: bonus,
                shutout: shutout, boxBonus: box, finalTotals: totals
            )
            state.gameResult = game
            state.winnerSeat = winner
            state.phase = .gameOver
            events.append(.gameWon(game))
        } else {
            state.phase = .handComplete
        }
        return events
    }

    private func reject(_ seat: Int, _ reason: String) -> [GinRummyEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }
}
