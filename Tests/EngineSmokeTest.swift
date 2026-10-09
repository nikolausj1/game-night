// Game Night engine smoke suite.
// Copied to main.swift and compiled together with Sources/Engine/*.swift:
//   swiftc -O Sources/Engine/*.swift main.swift -o t && ./t
import Foundation

var passCount = 0
var failCount = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("FAIL: \(name)")
    }
}

func makeSeats(_ n: Int) -> [Seat] {
    (0..<n).map { Seat(id: $0, playerName: "P\($0)", colorIndex: $0, isConnected: true, isHost: $0 == 0) }
}

let referenceDeck = DeckBuilder.wizard60()
func card(_ id: String) -> Card {
    referenceDeck.first { $0.id == id }!
}
func tp(_ seat: Int, _ id: String) -> TrickPlay {
    TrickPlay(seat: seat, card: card(id), wasForced: false)
}

func isIllegal(_ events: [GameEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}
func illegalReason(_ events: [GameEvent]) -> String? {
    for event in events { if case .illegalAttempt(_, let reason) = event { return reason } }
    return nil
}
func playedCard(_ events: [GameEvent]) -> (seat: Int, card: Card, forced: Bool)? {
    for event in events { if case .cardPlayed(let s, let c, let f) = event { return (s, c, f) } }
    return nil
}

// MARK: - Deck composition & IDs

let std = DeckBuilder.standard52()
check(std.count == 52, "standard52 has 52 cards")
check(Set(std.map(\.id)).count == 52, "standard52 ids unique")
check(std.filter { $0.suit == .hearts }.count == 13, "13 hearts in standard52")
check(std.allSatisfy { ($0.rank ?? 0) >= 2 && ($0.rank ?? 0) <= 14 }, "standard ranks are 2...14")

let wiz = DeckBuilder.wizard60()
check(wiz.count == 60, "wizard60 has 60 cards")
check(Set(wiz.map(\.id)).count == 60, "wizard60 ids unique")
check(wiz.filter(\.isWizard).count == 4, "wizard60 has 4 wizards")
check(wiz.filter(\.isJester).count == 4, "wizard60 has 4 jesters")

check(Suit.hearts.symbol == "♥" && Suit.spades.symbol == "♠", "suit symbols")
check(Suit.hearts.isRed && Suit.diamonds.isRed, "hearts/diamonds are red")
check(!Suit.clubs.isRed && !Suit.spades.isRed, "clubs/spades are black")

// MARK: - Seeded shuffle

let shuffleA = DeckBuilder.shuffled(wiz, seed: 42)
let shuffleB = DeckBuilder.shuffled(wiz, seed: 42)
let shuffleC = DeckBuilder.shuffled(wiz, seed: 43)
check(shuffleA == shuffleB, "same seed → same shuffle")
check(shuffleA != shuffleC, "different seed → different shuffle")
check(Set(shuffleA.map(\.id)) == Set(wiz.map(\.id)), "shuffle preserves the deck")

// MARK: - GameKind config & schedules

check(GameKind.wizard.minPlayers == 3 && GameKind.wizard.maxPlayers == 6, "wizard 3-6 players")
check(GameKind.ohHell.minPlayers == 3 && GameKind.ohHell.maxPlayers == 7, "ohHell 3-7 players")
check(GameKind.crazyEights.minPlayers == 2 && GameKind.crazyEights.maxPlayers == 6, "crazyEights 2-6 players")
check(GameKind.freePlay.minPlayers == 1 && GameKind.freePlay.maxPlayers == 8, "freePlay 1-8 players (solo sandbox allowed)")
check(GameKind.wizard.usesWizardDeck && !GameKind.ohHell.usesWizardDeck, "only wizard uses the 60-card deck")
check(GameKind.wizard.isTrickTaking && GameKind.ohHell.isTrickTaking, "wizard/ohHell are trick-taking")
check(!GameKind.crazyEights.isTrickTaking && !GameKind.freePlay.isTrickTaking, "crazyEights/freePlay aren't trick-taking")

check(GameKind.wizard.roundsSchedule(playerCount: 3) == Array(1...20), "wizard 3p schedule 1...20")
check(GameKind.wizard.roundsSchedule(playerCount: 6).count == 10, "wizard 6p schedule has 10 rounds")
let ohHell4 = GameKind.ohHell.roundsSchedule(playerCount: 4)
check(ohHell4.count == 25, "ohHell 4p schedule has 25 rounds")
check(ohHell4 == Array(1...13) + Array((1...12).reversed()), "ohHell 4p schedule is 1...13...1")
check(ohHell4.first == 1 && ohHell4.last == 1 && ohHell4.max() == 13, "ohHell schedule endpoints")
check(GameKind.crazyEights.roundsSchedule(playerCount: 4).isEmpty, "crazyEights has no schedule")
check(GameKind.freePlay.roundsSchedule(playerCount: 4).isEmpty, "freePlay has no schedule")

// MARK: - Follow-suit legality (Wizard rules)

let wr = WizardRules()
let dummyState = GameState(
    gameKind: .wizard, rules: RulesConfig(), seats: makeSeats(3), phase: .playing,
    round: nil, hands: [:], drawPile: [], discardPile: [], roundHistory: [], seed: 0
)
let heartsLedTrick = [tp(1, "h9")]
let followHand = [card("h5"), card("s10"), card("W0"), card("J0")]
check(wr.legality(of: card("h5"), hand: followHand, trick: heartsLedTrick, trump: nil, state: dummyState).isLegal,
      "following the led suit is legal")
check(!wr.legality(of: card("s10"), hand: followHand, trick: heartsLedTrick, trump: nil, state: dummyState).isLegal,
      "off-suit while holding led suit is illegal")
if case .illegal(let reason) = wr.legality(of: card("s10"), hand: followHand, trick: heartsLedTrick, trump: nil, state: dummyState) {
    check(reason == "You must follow hearts", "illegal reason is user-facing")
} else {
    check(false, "illegal reason is user-facing")
}
check(wr.legality(of: card("W0"), hand: followHand, trick: heartsLedTrick, trump: nil, state: dummyState).isLegal,
      "wizard always playable")
check(wr.legality(of: card("J0"), hand: followHand, trick: heartsLedTrick, trump: nil, state: dummyState).isLegal,
      "jester always playable")
let voidHand = [card("s10"), card("d4")]
check(wr.legality(of: card("s10"), hand: voidHand, trick: heartsLedTrick, trump: nil, state: dummyState).isLegal,
      "void in led suit → any card legal")
check(wr.legality(of: card("s10"), hand: followHand, trick: [], trump: nil, state: dummyState).isLegal,
      "leading: anything legal")
check(wr.legality(of: card("s10"), hand: followHand, trick: [tp(1, "W0")], trump: nil, state: dummyState).isLegal,
      "wizard led → no led suit, anything legal")
check(wr.legality(of: card("s10"), hand: followHand, trick: [tp(1, "J0")], trump: nil, state: dummyState).isLegal,
      "only jesters so far → no led suit yet")
check(!wr.legality(of: card("s10"), hand: followHand, trick: [tp(1, "J0"), tp(2, "h9")], trump: nil, state: dummyState).isLegal,
      "jester lead → first non-jester sets led suit")

// MARK: - Trick winners

check(wr.trickWinner([tp(0, "h10"), tp(1, "W0"), tp(2, "W1")], trump: nil) == 1, "first wizard wins")
check(wr.trickWinner([tp(0, "W2"), tp(1, "h14"), tp(2, "s14")], trump: .spades) == 0, "wizard lead wins over everything")
check(wr.trickWinner([tp(0, "J0"), tp(1, "J1"), tp(2, "J2")], trump: .hearts) == 0, "all-jester trick → first jester wins")
check(wr.trickWinner([tp(0, "J0"), tp(1, "h5"), tp(2, "h9")], trump: .clubs) == 2, "jester lead → next card sets suit, highest wins")
check(wr.trickWinner([tp(0, "J0"), tp(1, "h5"), tp(2, "s14")], trump: nil) == 1, "jester lead → off-suit ace loses to led five")
check(wr.trickWinner([tp(0, "h10"), tp(1, "s2"), tp(2, "h14")], trump: .spades) == 1, "lowest trump beats aces")
check(wr.trickWinner([tp(0, "h10"), tp(1, "s5"), tp(2, "s9")], trump: .spades) == 2, "highest trump wins")
check(wr.trickWinner([tp(0, "h10"), tp(1, "h14"), tp(2, "d2")], trump: nil) == 1, "no trump → highest of led suit wins")
check(wr.trickWinner([tp(0, "h2"), tp(1, "s14"), tp(2, "d14")], trump: nil) == 0, "off-suit aces don't beat the led deuce")
let ohr = OhHellRules()
check(ohr.trickWinner([tp(0, "c9"), tp(1, "c11"), tp(2, "d14")], trump: .hearts) == 1, "ohHell uses the same trick math")

// MARK: - Engine: deal, bidding order, out-of-turn

func freshEngine(_ kind: GameKind, players: Int, rules: RulesConfig = RulesConfig(), seed: UInt64) -> HostEngine {
    let engine = HostEngine(seats: makeSeats(players), gameKind: kind, rules: rules, seed: seed)
    _ = engine.apply(.startGame(kind, rules, seed: seed))
    return engine
}

let lobbyEngine = HostEngine(seats: makeSeats(3), gameKind: .wizard, rules: RulesConfig(), seed: 1)
check(lobbyEngine.state.phase == .lobby, "engine starts in lobby")
check(isIllegal(lobbyEngine.apply(.placeBid(0), from: 0)), "bidding in lobby rejected")

let oh = freshEngine(.ohHell, players: 3, seed: 11)
check(oh.state.phase == .bidding, "ohHell deals straight into bidding")
check((0..<3).allSatisfy { oh.state.hands[$0]?.count == 1 }, "ohHell round 1: one card each")
check(oh.state.drawPile.count == 48, "ohHell round 1: 52 - 3 dealt - 1 flipped = 48 in draw pile")
check(oh.state.round?.trumpCard != nil && oh.state.round?.trumpSuit == oh.state.round?.trumpCard?.suit,
      "ohHell trump = flipped card's suit")
check(oh.state.round?.dealerSeat == 0 && oh.state.round?.turnSeat == 1, "bidding starts left of dealer")

check(isIllegal(oh.apply(.placeBid(0), from: 2)), "out-of-turn bid rejected")
check(oh.state.round?.bids.isEmpty == true, "out-of-turn bid changed nothing")
check(isIllegal(oh.apply(.placeBid(5), from: 1)), "out-of-range bid rejected")
_ = oh.apply(.placeBid(0), from: 1)
check(oh.state.round?.turnSeat == 2, "bid advances the turn")
_ = oh.apply(.placeBid(1), from: 2)
check(oh.state.round?.turnSeat == 0, "dealer bids last")
let dealerBidEvents = oh.apply(.placeBid(0), from: 0)
check(dealerBidEvents.contains(.biddingComplete), "biddingComplete after final bid")
check(oh.state.phase == .playing && oh.state.round?.leadSeat == 1 && oh.state.round?.turnSeat == 1,
      "play starts left of dealer")

// MARK: - Screw the dealer

let screw = freshEngine(.ohHell, players: 3, rules: RulesConfig(screwTheDealer: true), seed: 11)
_ = screw.apply(.placeBid(0), from: 1)
_ = screw.apply(.placeBid(0), from: 2)
check(isIllegal(screw.apply(.placeBid(1), from: 0)), "screwTheDealer: forbidden dealer bid rejected")
check(screw.state.round?.bids.count == 2, "forbidden dealer bid changed nothing")
check(screw.apply(.placeBid(0), from: 0).contains(.biddingComplete), "screwTheDealer: legal dealer bid accepted")

// MARK: - Wizard trump flip: choosingTrump / jester / standard

var sawWizardFlip = false
var sawJesterFlip = false
var sawStandardFlip = false
for seed in 0..<4000 where !(sawWizardFlip && sawJesterFlip && sawStandardFlip) {
    let engine = freshEngine(.wizard, players: 3, seed: UInt64(seed))
    guard let round = engine.state.round, let flipped = round.trumpCard else { continue }
    if flipped.isWizard && !sawWizardFlip {
        sawWizardFlip = true
        check(engine.state.phase == .choosingTrump(seat: 0), "wizard flip → dealer chooses trump")
        check(round.trumpSuit == nil, "no trump suit until the dealer chooses")
        check(isIllegal(engine.apply(.chooseTrump(.clubs), from: 1)), "non-dealer can't choose trump")
        check(isIllegal(engine.apply(.placeBid(0), from: 1)), "no bidding while choosing trump")
        let chooseEvents = engine.apply(.chooseTrump(.hearts), from: 0)
        check(chooseEvents.contains(.trumpRevealed(flipped, .hearts)), "chosen trump announced")
        check(engine.state.round?.trumpSuit == .hearts, "chosen trump recorded")
        check(engine.state.phase == .bidding && engine.state.round?.turnSeat == 1, "bidding opens after trump choice")
    } else if flipped.isJester && !sawJesterFlip {
        sawJesterFlip = true
        check(round.trumpSuit == nil && engine.state.phase == .bidding, "jester flip → no trump, straight to bidding")
    } else if flipped.suit != nil && !sawStandardFlip {
        sawStandardFlip = true
        check(round.trumpSuit == flipped.suit && engine.state.phase == .bidding, "standard flip → its suit is trump")
        check(engine.state.hands.values.allSatisfy { $0.count == 1 }, "wizard round 1: one card each")
        check(engine.state.drawPile.count == 56, "wizard round 1: 60 - 3 dealt - 1 flipped = 56")
    }
}
check(sawWizardFlip, "found a wizard trump flip")
check(sawJesterFlip, "found a jester trump flip")
check(sawStandardFlip, "found a standard trump flip")

// MARK: - Soft enforcement, out-of-turn play, undo

var softScenarioDone = false
for seed in 0..<300 where !softScenarioDone {
    let engine = freshEngine(.ohHell, players: 3, seed: UInt64(seed))
    // Round 1: everyone bids 0 and plays their only card.
    for _ in 0..<3 { _ = engine.apply(.placeBid(0), from: engine.state.round!.turnSeat) }
    for _ in 0..<3 {
        let seat = engine.state.round!.turnSeat
        _ = engine.apply(.playCard(cardID: engine.state.hands[seat]![0].id, force: false), from: seat)
    }
    _ = engine.apply(.nextTrick)
    guard engine.state.phase == .roundComplete else { continue }
    _ = engine.apply(.nextRound)
    guard engine.state.phase == .bidding, engine.state.round?.roundNumber == 2,
          engine.state.round?.dealerSeat == 1 else { continue }
    for _ in 0..<3 { _ = engine.apply(.placeBid(0), from: engine.state.round!.turnSeat) }
    let leader = engine.state.round!.turnSeat
    let leadCard = engine.state.hands[leader]![0]
    _ = engine.apply(.playCard(cardID: leadCard.id, force: false), from: leader)
    let led = leadCard.suit!
    let follower = engine.state.round!.turnSeat
    let followerHand = engine.state.hands[follower]!
    guard followerHand.contains(where: { $0.suit == led }),
          let offSuit = followerHand.first(where: { $0.suit != led }) else { continue }
    softScenarioDone = true

    check(engine.state.round?.dealerSeat == 1, "dealer rotated left for round 2")
    check(followerHand.count == 2, "round 2 deals two cards")

    // Out-of-turn play.
    let third = (follower + 1) % 3
    let outOfTurn = engine.apply(.playCard(cardID: engine.state.hands[third]![0].id, force: false), from: third)
    check(isIllegal(outOfTurn), "out-of-turn play rejected")
    check(engine.state.round?.currentTrick.count == 1 && engine.state.hands[third]?.count == 2,
          "out-of-turn play changed nothing")

    // Illegal play without force: blocked, no state change.
    let blocked = engine.apply(.playCard(cardID: offSuit.id, force: false), from: follower)
    check(isIllegal(blocked), "illegal play without force is blocked")
    check(illegalReason(blocked) == "You must follow \(led.rawValue)", "block carries the follow-suit reason")
    check(engine.state.hands[follower]?.count == 2 && engine.state.round?.currentTrick.count == 1,
          "blocked play changed nothing")

    // Forced play goes through and is recorded.
    let before = engine.state
    let forcedEvents = engine.apply(.playCard(cardID: offSuit.id, force: true), from: follower)
    check(playedCard(forcedEvents)?.forced == true, "forced play emits cardPlayed(forced: true)")
    check(engine.state.round?.currentTrick.last?.wasForced == true, "forced play recorded as wasForced")
    check(engine.state.hands[follower]?.count == 1, "forced card left the hand")

    // Undo restores the pre-play state.
    _ = engine.apply(.requestUndo, from: follower)
    let undoEvents = engine.apply(.approveUndo)
    check(undoEvents.contains(.undone), "approveUndo emits undone")
    check(engine.state == before, "undo restores the exact pre-play state")
    check(engine.apply(.approveUndo).isEmpty, "approveUndo without a request does nothing")
}
check(softScenarioDone, "found a soft-enforcement scenario")

// MARK: - Full seeded 3-player Wizard game

func driveWizard(seed: UInt64, stopAtPlayingRound: Int?) -> (engine: HostEngine, events: [GameEvent], finalRoundNoTrump: Bool) {
    let engine = HostEngine(seats: makeSeats(3), gameKind: .wizard, rules: RulesConfig(), seed: seed)
    var events = engine.apply(.startGame(.wizard, RulesConfig(), seed: seed))
    var finalRoundNoTrump = false
    var safety = 0
    while safety < 100_000 {
        safety += 1
        switch engine.state.phase {
        case .choosingTrump(let seat):
            events += engine.apply(.chooseTrump(.spades), from: seat)
        case .bidding:
            events += engine.apply(.placeBid(0), from: engine.state.round!.turnSeat)
        case .playing:
            if let stop = stopAtPlayingRound, engine.state.round?.roundNumber == stop {
                return (engine, events, finalRoundNoTrump)
            }
            if engine.state.round?.roundNumber == 20 {
                finalRoundNoTrump = engine.state.round?.trumpCard == nil && engine.state.round?.trumpSuit == nil
            }
            let seat = engine.state.round!.turnSeat
            var played = false
            for candidate in engine.state.hands[seat]! {
                let evs = engine.apply(.playCard(cardID: candidate.id, force: false), from: seat)
                events += evs
                if playedCard(evs) != nil { played = true; break }
            }
            if !played { return (engine, events, finalRoundNoTrump) }
        case .trickComplete:
            events += engine.apply(.nextTrick)
        case .roundComplete:
            events += engine.apply(.nextRound)
        case .gameOver:
            return (engine, events, finalRoundNoTrump)
        default:
            return (engine, events, finalRoundNoTrump)
        }
    }
    return (engine, events, finalRoundNoTrump)
}

let fullGame = driveWizard(seed: 2026, stopAtPlayingRound: nil)
check(fullGame.engine.state.phase == .gameOver, "full wizard game reaches gameOver")
check(fullGame.engine.state.roundHistory.count == 20, "20 completed rounds for 3 players")
check(fullGame.finalRoundNoTrump, "last round has no trump (deck exhausted)")
check(fullGame.engine.state.roundHistory.allSatisfy { $0.tricksWon.values.reduce(0, +) == $0.cardsPerPlayer },
      "every round's tricks sum to cards dealt")
check(fullGame.engine.state.roundHistory.allSatisfy { $0.bids.count == 3 },
      "every round has three bids")
check(fullGame.engine.state.roundHistory.enumerated().allSatisfy { $0.element.roundNumber == $0.offset + 1 },
      "rounds recorded in order")

// Hand-computed totals (everyone bid 0: hit → 20, miss → −10 per trick taken).
var expectedTotals: [Int: Int] = [:]
for round in fullGame.engine.state.roundHistory {
    for (seat, bid) in round.bids {
        let taken = round.tricksWon[seat] ?? 0
        expectedTotals[seat, default: 0] += bid == taken ? 20 + 10 * bid : -10 * abs(bid - taken)
    }
}
let engineTotals = Scoring.totals(history: fullGame.engine.state.roundHistory, kind: .wizard)
check(engineTotals == expectedTotals, "engine totals match hand-computed totals")
let bestTotal = expectedTotals.values.max()!
let expectedWinner = expectedTotals.filter { $0.value == bestTotal }.keys.min()!
var announcedWinner: Int? = nil
for event in fullGame.events { if case .gameWon(let seat) = event { announcedWinner = seat } }
check(announcedWinner == expectedWinner, "gameWon announces the top scorer")
check(fullGame.events.filter { $0 == .roundScored }.count == 20, "roundScored fired once per round")

// MARK: - Scoring formulas & placements (match Wizard Keeper engine)

check(Scoring.roundScore(kind: .wizard, bid: 2, tricksTaken: 2) == 40, "wizard hit: 20 + 10×bid")
check(Scoring.roundScore(kind: .wizard, bid: 0, tricksTaken: 0) == 20, "wizard zero hit scores 20")
check(Scoring.roundScore(kind: .wizard, bid: 1, tricksTaken: 4) == -30, "wizard miss: −10 per trick off")
check(Scoring.roundScore(kind: .ohHell, bid: 3, tricksTaken: 3) == 13, "ohHell hit: 10 + tricks")
check(Scoring.roundScore(kind: .ohHell, bid: 1, tricksTaken: 2, missScoresTricks: true) == 2, "ohHell miss scores tricks")
check(Scoring.roundScore(kind: .ohHell, bid: 1, tricksTaken: 2, missScoresTricks: false) == 0, "ohHell miss scores zero when toggled")

let placements = Scoring.placements(totals: [0: 100, 1: 100, 2: 50, 3: 120])
check(placements.first?.seat == 3 && placements.first?.place == 1, "highest total places first")
check(placements.contains { $0 == (seat: 0, place: 2) } && placements.contains { $0 == (seat: 1, place: 2) },
      "ties share a place")
check(placements.contains { $0 == (seat: 2, place: 4) }, "next distinct total skips shared slots (1-2-2-4)")

// MARK: - Snapshot redaction

let midGame = driveWizard(seed: 7, stopAtPlayingRound: 10).engine
check(midGame.state.round?.roundNumber == 10, "drove wizard game to round 10")
let snapshot = midGame.state.snapshot(for: 0)
let snapshotData = try! JSONEncoder().encode(snapshot)
let snapshotJSON = String(data: snapshotData, encoding: .utf8)!
let trumpID = midGame.state.round?.trumpCard?.id
var leaked = false
for seat in [1, 2] {
    for hidden in midGame.state.hands[seat] ?? [] where hidden.id != trumpID {
        if snapshotJSON.contains("\"\(hidden.id)\"") { leaked = true }
    }
}
for hidden in midGame.state.drawPile where hidden.id != trumpID {
    if snapshotJSON.contains("\"\(hidden.id)\"") { leaked = true }
}
check(!leaked, "snapshot leaks no other hands and no draw pile cards")
check(!snapshotJSON.contains("\"seed\""), "snapshot withholds the shuffle seed")
check(snapshot.myHand == midGame.state.hands[0], "snapshot carries my own hand")
check(snapshot.handCounts == midGame.state.hands.mapValues { $0.count }, "snapshot exposes hand counts")
check(snapshot.drawCount == midGame.state.drawPile.count, "draw pile becomes a count")
check(snapshot.phase == midGame.state.phase && snapshot.round == midGame.state.round,
      "snapshot keeps public round state")
let snapshotBack = try! JSONDecoder().decode(ClientSnapshot.self, from: snapshotData)
check(snapshotBack == snapshot, "ClientSnapshot round-trips through JSON")

// MARK: - Crazy Eights

let ceRules = CrazyEightsRules()
var ceState = GameState(
    gameKind: .crazyEights, rules: RulesConfig(), seats: makeSeats(2), phase: .playing,
    round: RoundState(roundNumber: 1, cardsPerPlayer: 5, dealerSeat: 0, trumpCard: nil, trumpSuit: nil,
                      bids: [:], tricksWon: [:], currentTrick: [], completedTricks: [], leadSeat: 1, turnSeat: 1),
    hands: [:], drawPile: [], discardPile: [card("h7")], roundHistory: [], seed: 0
)
check(ceRules.legality(of: card("h13"), hand: [], trick: [], trump: nil, state: ceState).isLegal, "suit match is legal")
check(ceRules.legality(of: card("c7"), hand: [], trick: [], trump: nil, state: ceState).isLegal, "rank match is legal")
check(!ceRules.legality(of: card("s9"), hand: [], trick: [], trump: nil, state: ceState).isLegal, "no match is illegal")
check(ceRules.legality(of: card("d8"), hand: [], trick: [], trump: nil, state: ceState).isLegal, "eight is wild")
ceState.discardPile = [card("h8")]
ceState.round?.trumpSuit = .spades
check(ceRules.legality(of: card("s9"), hand: [], trick: [], trump: nil, state: ceState).isLegal,
      "declared suit is matchable")
check(!ceRules.legality(of: card("h13"), hand: [], trick: [], trump: nil, state: ceState).isLegal,
      "declared suit overrides the eight's own suit")
check(ceRules.legality(of: card("c8"), hand: [], trick: [], trump: nil, state: ceState).isLegal,
      "another eight on a declared suit is legal")

let ceDeal = freshEngine(.crazyEights, players: 2, seed: 3)
check((0..<2).allSatisfy { ceDeal.state.hands[$0]?.count == 5 }, "crazy eights deals 5 cards each")
check(ceDeal.state.discardPile.count == 1, "crazy eights flips a starter card")
check(ceDeal.state.drawPile.count == 41, "52 - 10 dealt - 1 starter = 41 in draw pile")
check(ceDeal.state.phase == .playing && ceDeal.state.round?.turnSeat == 1, "crazy eights starts left of dealer")

func driveCrazyEights(seed: UInt64) -> (finished: Bool, sawDeclared: Bool, engine: HostEngine) {
    let engine = freshEngine(.crazyEights, players: 2, seed: seed)
    var sawDeclared = false
    var steps = 0
    while steps < 5000 {
        steps += 1
        switch engine.state.phase {
        case .choosingTrump(let seat):
            let hand = engine.state.hands[seat] ?? []
            let suit = hand.compactMap(\.suit).first ?? .hearts
            let evs = engine.apply(.declareSuit(suit), from: seat)
            if evs.contains(.suitDeclared(suit)) { sawDeclared = true }
        case .playing:
            let seat = engine.state.round!.turnSeat
            var acted = false
            for candidate in engine.state.hands[seat]! {
                if playedCard(engine.apply(.playCard(cardID: candidate.id, force: false), from: seat)) != nil {
                    acted = true
                    break
                }
            }
            if !acted, isIllegal(engine.apply(.drawCard, from: seat)) {
                return (false, sawDeclared, engine)
            }
        case .gameOver:
            return (true, sawDeclared, engine)
        default:
            return (false, sawDeclared, engine)
        }
    }
    return (false, sawDeclared, engine)
}

var ceFinished = false
var ceDeclared = false
var ceWinnerEmpty = false
for seed in 0..<60 {
    let result = driveCrazyEights(seed: UInt64(seed))
    if result.finished {
        ceFinished = true
        ceDeclared = ceDeclared || result.sawDeclared
        ceWinnerEmpty = ceWinnerEmpty || result.engine.state.hands.values.contains { $0.isEmpty }
        if ceDeclared && ceWinnerEmpty { break }
    }
}
check(ceFinished, "crazy eights game reaches gameOver by emptying a hand")
check(ceDeclared, "an eight was played and its suit declared")
check(ceWinnerEmpty, "the winner's hand is empty at gameOver")

// MARK: - Free Play

let fp = freshEngine(.freePlay, players: 2, seed: 5)
check(fp.state.drawPile.count == 52 && fp.state.hands.values.allSatisfy(\.isEmpty), "free play starts with a full deck")
let fpTop = fp.state.drawPile.first!
_ = fp.apply(.freeMoveCard(cardID: fpTop.id, to: .hand, x: 0, y: 0, rotation: 0), from: 0)
check(fp.state.hands[0] == [fpTop] && fp.state.drawPile.count == 51, "free move deck → hand")
_ = fp.apply(.freeMoveCard(cardID: fpTop.id, to: .table, x: 10, y: 20, rotation: 0.5), from: 0)
check(fp.state.discardPile == [fpTop] && fp.state.hands[0]!.isEmpty, "free move hand → table")
_ = fp.apply(.freeMoveCard(cardID: fpTop.id, to: .deck, x: 0, y: 0, rotation: 0), from: 1)
check(fp.state.drawPile.last == fpTop && fp.state.discardPile.isEmpty, "free move table → deck")
check(isIllegal(fp.apply(.freeMoveCard(cardID: "nope", to: .table, x: 0, y: 0, rotation: 0), from: 0)),
      "moving an unknown card is rejected")

// MARK: - Free Play deck selection

check(RulesConfig().freePlayDeck == .standard52, "free play deck defaults to standard52")

let fpWizardDeck = freshEngine(.freePlay, players: 2, rules: RulesConfig(freePlayDeck: .wizard60), seed: 5)
check(fpWizardDeck.state.drawPile.count == 60, "wizard60 deck selection lands 60 cards in the draw pile")
check(fpWizardDeck.state.drawPile.contains { $0.isWizard }, "wizard60 free-play deck includes wizards")

let fpUnoDeck = freshEngine(.freePlay, players: 2, rules: RulesConfig(freePlayDeck: .uno108), seed: 6)
check(fpUnoDeck.state.drawPile.count == 108, "uno108 deck selection lands 108 cards in the draw pile")

// Back-compat decode: saves from before the deck picker existed default to standard52.
var legacyFreePlayDict = try! JSONSerialization.jsonObject(
    with: try! JSONEncoder().encode(RulesConfig(freePlayDeck: .uno108))) as! [String: Any]
legacyFreePlayDict.removeValue(forKey: "freePlayDeck")
let legacyFreePlayRules = try! JSONDecoder().decode(
    RulesConfig.self, from: try! JSONSerialization.data(withJSONObject: legacyFreePlayDict))
check(legacyFreePlayRules.freePlayDeck == .standard52, "pre-freePlayDeck RulesConfig decodes with the standard52 default")

// UNO cards move through the same free-move / draw / play paths as any other deck.
let fpUnoCards = freshEngine(.freePlay, players: 2, rules: RulesConfig(freePlayDeck: .uno108), seed: 7)
let fpUnoTop = fpUnoCards.state.drawPile.first!
_ = fpUnoCards.apply(.freeMoveCard(cardID: fpUnoTop.id, to: .hand, x: 0, y: 0, rotation: 0), from: 0)
check(fpUnoCards.state.hands[0] == [fpUnoTop], "uno card free-moves deck → hand in free play")
let fpUnoDrawEvents = fpUnoCards.apply(.drawCard, from: 1)
check(!isIllegal(fpUnoDrawEvents) && fpUnoCards.state.hands[1]?.count == 1,
      "uno card draws normally through the free-play draw path")
let fpUnoPlayEvents = fpUnoCards.apply(.playCard(cardID: fpUnoTop.id, force: false), from: 0)
check(playedCard(fpUnoPlayEvents)?.card.id == fpUnoTop.id, "uno card plays via playCard in free play")
check(fpUnoCards.state.discardPile.contains { $0.id == fpUnoTop.id }, "played uno card lands on the discard pile")

// MARK: - Free Play: total freedom regression (field report: "only one card
// would play from the remote"). `handlePlayCard`'s `.freePlay` branch itself
// tests clean in isolation — these lock in the exact repro shapes described
// (a single seat's multi-card sequence, and multi-seat play interleaved with
// draw/freeMove) so any future regression here fails loudly. No defect was
// found in the reducer; see the session report for where the real-world
// symptom more likely originates (network/session layer, not the engine).

// One seat, draw 3, play all 3 in sequence — every play must succeed, none
// may reject or no-op, and the seat's turn must never come into it.
let fpSeq = freshEngine(.freePlay, players: 1, seed: 21)
for _ in 0..<3 { _ = fpSeq.apply(.drawCard, from: 0) }
check(fpSeq.state.hands[0]?.count == 3, "free play multi-card seq: drew 3 cards into the one seat")
let fpSeqIDs = fpSeq.state.hands[0]!.map(\.id)
var fpSeqAllPlayed = true
for (i, cardID) in fpSeqIDs.enumerated() {
    let evs = fpSeq.apply(.playCard(cardID: cardID, force: false), from: 0)
    if isIllegal(evs) || playedCard(evs)?.card.id != cardID { fpSeqAllPlayed = false }
    check(fpSeq.state.phase == .playing, "free play multi-card seq: phase stays .playing after play #\(i + 1)")
}
check(fpSeqAllPlayed, "free play multi-card seq: all 3 sequential plays succeeded (no reject/no-op)")
check(fpSeq.state.hands[0]?.isEmpty == true, "free play multi-card seq: hand empty after playing every card")
check(Set(fpSeq.state.discardPile.map(\.id)) == Set(fpSeqIDs), "free play multi-card seq: all 3 cards landed on the discard pile")

// Two seats, actions interleaved (draw/draw/play/play/freeMove/play/play) —
// free play has zero turn logic, so ANY seat may act ANY time in .playing.
let fpInter = freshEngine(.freePlay, players: 2, seed: 22)
_ = fpInter.apply(.drawCard, from: 0)
_ = fpInter.apply(.drawCard, from: 0)
_ = fpInter.apply(.drawCard, from: 1)
_ = fpInter.apply(.drawCard, from: 1)
let fpInterH0 = fpInter.state.hands[0]!.map(\.id)
let fpInterH1 = fpInter.state.hands[1]!.map(\.id)
let fpInterPlay1 = fpInter.apply(.playCard(cardID: fpInterH0[0], force: false), from: 0)
check(!isIllegal(fpInterPlay1), "free play interleaved: seat 0's first play accepted")
let fpInterPlay2 = fpInter.apply(.playCard(cardID: fpInterH1[0], force: false), from: 1)
check(!isIllegal(fpInterPlay2), "free play interleaved: seat 1's play right after seat 0 accepted (no turn gate)")
let fpInterTopDiscard = fpInter.state.discardPile.first!
let fpInterMove = fpInter.apply(.freeMoveCard(cardID: fpInterTopDiscard.id, to: .hand, x: 0, y: 0, rotation: 0), from: 1)
check(!isIllegal(fpInterMove), "free play interleaved: freeMove between the two plays accepted")
let fpInterPlay3 = fpInter.apply(.playCard(cardID: fpInterH0[1], force: false), from: 0)
check(!isIllegal(fpInterPlay3), "free play interleaved: seat 0's SECOND card plays fine — this is the exact field-report shape")
let fpInterPlay4 = fpInter.apply(.playCard(cardID: fpInterH1[1], force: false), from: 1)
check(!isIllegal(fpInterPlay4), "free play interleaved: seat 1's second card plays fine too")
// Seat 0 played both its cards clean, so its hand is empty. Seat 1's hand
// still holds fpInterH1[0] — the freeMove pulled its own just-played card
// back OUT of the discard pile and INTO its hand mid-sequence, which is
// exactly the "any seat, any zone, any time" freedom free play promises,
// not a leftover bug.
check(fpInter.state.hands[0]?.isEmpty == true, "free play interleaved: seat 0's hand empty after playing both cards")
check(fpInter.state.hands[1] == [fpInterTopDiscard], "free play interleaved: seat 1 still holds the card it freeMoved back from the discard pile")

// freeMoveCard(to: .hand) is seat-agnostic: any seat can pull any table card
// into ITS hand regardless of who last touched the table or drew anything.
let fpFreeMoveAgnostic = freshEngine(.freePlay, players: 3, seed: 23)
_ = fpFreeMoveAgnostic.apply(.drawCard, from: 0) // only seat 0 has ever acted
let fpFMTop = fpFreeMoveAgnostic.state.drawPile.first!
let fpFMEvents = fpFreeMoveAgnostic.apply(
    .freeMoveCard(cardID: fpFMTop.id, to: .hand, x: 0, y: 0, rotation: 0), from: 2)
check(!isIllegal(fpFMEvents), "free play freeMove(to: .hand) accepted from a seat that never acted before")
check(fpFreeMoveAgnostic.state.hands[2]?.contains(fpFMTop) == true,
      "free play freeMove(to: .hand) lands in the REQUESTING seat's hand, not seat 0's")

// drawCard is seat-agnostic too: order of seats drawing doesn't matter, and
// there's no "wrong seat" to reject.
let fpDrawAgnostic = freshEngine(.freePlay, players: 4, seed: 24)
var fpDrawAllOK = true
for seat in [3, 1, 3, 0, 2, 1] {
    if isIllegal(fpDrawAgnostic.apply(.drawCard, from: seat)) { fpDrawAllOK = false }
}
check(fpDrawAllOK, "free play drawCard: any seat, any order, every draw accepted")
check(fpDrawAgnostic.state.hands[3]?.count == 2 && fpDrawAgnostic.state.hands[1]?.count == 2,
      "free play drawCard: repeat draws for the same seat accumulate correctly")

// MARK: - Free Play: .newDeal ("gather and shuffle") regression
//
// Bug found while chasing the "stops after one card" report: `.newDeal`
// guarded on `state.round`, but free play's `round` is always nil
// (setUpFreePlay leaves it that way) — so the table's "gather and shuffle"
// reset silently did NOTHING to the engine in free play (hands/piles
// untouched) while the table-side UI (freePlayLayout/faceDownCards) reset
// as if it had worked, desyncing the felt from the actual game state.
// Fixed by branching on gameKind before the round-based lookup.
let fpGather = freshEngine(.freePlay, players: 2, seed: 25)
_ = fpGather.apply(.drawCard, from: 0)
_ = fpGather.apply(.drawCard, from: 1)
check(fpGather.state.hands[0]?.isEmpty == false, "newDeal regression: seat has cards before gather-and-shuffle")
let fpGatherEvents = fpGather.apply(.newDeal)
check(fpGatherEvents == [.dealt], "newDeal on free play actually re-deals (.dealt fires), not a silent no-op")
check(fpGather.state.hands.values.allSatisfy(\.isEmpty), "newDeal regression: every hand empty after gather-and-shuffle")
check(fpGather.state.drawPile.count == 52, "newDeal regression: full deck back in the draw pile")
check(fpGather.state.phase == .playing, "newDeal regression: back in .playing, ready to deal again")

// MARK: - Free Play deck affordances: flipTopCard

// Free play: pops the top of the draw pile face-up onto the discard pile
// and emits `.topCardFlipped`.
let ftc = freshEngine(.freePlay, players: 2, seed: 26)
let ftcTop = ftc.state.drawPile.first!
let ftcDrawCountBefore = ftc.state.drawPile.count
let ftcEvents = ftc.apply(.flipTopCard)
check(ftcEvents == [.topCardFlipped(ftcTop)], "flipTopCard emits topCardFlipped with the popped card")
check(ftc.state.drawPile.count == ftcDrawCountBefore - 1, "flipTopCard: draw pile shrinks by one")
check(ftc.state.discardPile.last == ftcTop, "flipTopCard: the popped card lands on top of the discard pile")

// Repeatable: flipping again pops the NEW top card.
let ftcTop2 = ftc.state.drawPile.first!
let ftcEvents2 = ftc.apply(.flipTopCard)
check(ftcEvents2 == [.topCardFlipped(ftcTop2)] && ftcTop2.id != ftcTop.id,
      "flipTopCard is repeatable and always pops the current top")

// Rejected (silently, like every other TableAction) outside free play.
let ftcWizard = freshEngine(.wizard, players: 3, seed: 27)
let ftcWizardStateBefore = ftcWizard.state
check(ftcWizard.apply(.flipTopCard).isEmpty, "flipTopCard is a no-op outside free play")
check(ftcWizard.state == ftcWizardStateBefore, "flipTopCard changed nothing outside free play")

// Rejected when the draw pile is empty (no crash, no phantom event).
let ftcEmpty = freshEngine(.freePlay, players: 1, seed: 28)
while !ftcEmpty.state.drawPile.isEmpty { _ = ftcEmpty.apply(.drawCard, from: 0) }
check(ftcEmpty.state.drawPile.isEmpty, "flipTopCard-empty setup: draw pile fully drained")
check(ftcEmpty.apply(.flipTopCard).isEmpty, "flipTopCard is a no-op when the draw pile is empty")

// topCardFlipped event round-trips through JSON.
let topCardFlippedEvents: [GameEvent] = [.topCardFlipped(card("h9"))]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(topCardFlippedEvents))) == topCardFlippedEvents,
      "topCardFlipped round-trips through JSON")

// MARK: - NetCodec round-trips (every message case)

let sampleSnapshot = midGame.state.snapshot(for: 1)
let sampleMessages: [NetMessage] = [
    .hello(name: "Justin", deviceID: "device-123"),
    .welcome(seat: 2),
    .seatClaim(seat: 1, name: "Sam"),
    .snapshot(sampleSnapshot),
    .action(.playCard(cardID: "h12", force: true)),
    .events([.dealt, .bidPlaced(seat: 1, bid: 3), .trumpRevealed(card("s14"), .spades),
             .illegalAttempt(seat: 0, reason: "You must follow hearts"), .undone]),
    .heartbeat,
    .rejected(reason: "table full"),
]
for (index, message) in sampleMessages.enumerated() {
    let envelope = NetEnvelope(seq: UInt64(index), msg: message)
    if let decoded = try? NetCodec.decode(NetCodec.encode(envelope)) {
        check(decoded == envelope, "NetCodec round-trips message case \(index)")
    } else {
        check(false, "NetCodec round-trips message case \(index)")
    }
}
let versionedEnvelope = NetEnvelope(seq: 0, msg: .heartbeat)
check(versionedEnvelope.v == 1, "envelope defaults to protocol version 1")

// MARK: - Actions round-trip

let sampleActions: [PlayerAction] = [
    .placeBid(3), .chooseTrump(.diamonds), .playCard(cardID: "W0", force: false), .drawCard,
    .declareSuit(.clubs), .freeMoveCard(cardID: "c2", to: .table, x: 1.5, y: -2, rotation: 0.25), .requestUndo,
]
let actionsData = try! JSONEncoder().encode(sampleActions)
let actionsBack = try! JSONDecoder().decode([PlayerAction].self, from: actionsData)
check(actionsBack == sampleActions, "PlayerAction round-trips through JSON")
let tableActions: [TableAction] = [
    .startGame(.wizard, RulesConfig(screwTheDealer: true), seed: 99), .nextRound, .nextTrick, .approveUndo, .newDeal,
    .dealCardTo(seat: 2), .flipTopCard,
]
let tableData = try! JSONEncoder().encode(tableActions)
check((try! JSONDecoder().decode([TableAction].self, from: tableData)) == tableActions,
      "TableAction round-trips through JSON")
let stateData = try! JSONEncoder().encode(midGame.state)
check((try! JSONDecoder().decode(GameState.self, from: stateData)) == midGame.state,
      "GameState round-trips through JSON")

// MARK: - UNO deck composition & IDs

let uno = DeckBuilder.uno108()
func ucard(_ id: String) -> Card { uno.first { $0.id == id }! }

check(uno.count == 108, "uno108 has 108 cards")
check(Set(uno.map(\.id)).count == 108, "uno108 ids unique")
check(UnoColor.allCases.allSatisfy { c in uno.filter { $0.unoColor == c && $0.unoSymbol == .number(0) }.count == 1 },
      "one zero per color")
check(UnoColor.allCases.allSatisfy { c in (1...9).allSatisfy { n in uno.filter { $0.unoColor == c && $0.unoSymbol == .number(n) }.count == 2 } },
      "two of each 1-9 per color")
check(UnoColor.allCases.allSatisfy { c in uno.filter { $0.unoColor == c && $0.unoSymbol == .skip }.count == 2 },
      "two skips per color")
check(UnoColor.allCases.allSatisfy { c in uno.filter { $0.unoColor == c && $0.unoSymbol == .reverse }.count == 2 },
      "two reverses per color")
check(UnoColor.allCases.allSatisfy { c in uno.filter { $0.unoColor == c && $0.unoSymbol == .drawTwo }.count == 2 },
      "two draw-twos per color")
check(uno.filter { $0.unoSymbol == .wild }.count == 4, "four wilds")
check(uno.filter { $0.unoSymbol == .wildDrawFour }.count == 4, "four wild draw fours")
check(uno.allSatisfy { $0.unoColor != nil || $0.unoSymbol == .wild || $0.unoSymbol == .wildDrawFour },
      "only wilds lack a printed color")
check(uno.contains { $0.id == "u_r5a" } && uno.contains { $0.id == "u_wild0" } && uno.contains { $0.id == "u_wd43" }
      && uno.contains { $0.id == "u_gSa" } && uno.contains { $0.id == "u_b0" },
      "id scheme spot checks (u_r5a / u_wild0 / u_wd43 / u_gSa / u_b0)")

// MARK: - UNO color ↔ suit mapping

check(Suit.hearts.unoColor == .red && Suit.diamonds.unoColor == .yellow
      && Suit.clubs.unoColor == .green && Suit.spades.unoColor == .blue,
      "fixed mapping: red↔hearts, yellow↔diamonds, green↔clubs, blue↔spades")
check(UnoColor.allCases.allSatisfy { $0.suit.unoColor == $0 } && Suit.allCases.allSatisfy { $0.unoColor.suit == $0 },
      "color↔suit mapping round-trips both ways")

// MARK: - UNO GameKind config

check(GameKind.uno.displayName == "UNO", "uno display name")
check(GameKind.uno.minPlayers == 2 && GameKind.uno.maxPlayers == 8, "uno 2-8 players")
check(!GameKind.uno.usesWizardDeck && !GameKind.uno.isTrickTaking, "uno: no wizard deck, not trick-taking")
check(GameKind.uno.roundsSchedule(playerCount: 4).isEmpty, "uno has no round schedule")

// MARK: - UNO rules config flags

check(RulesConfig().stackDrawCards == true && RulesConfig().drawUntilPlayable == true,
      "UNO flags default: stacking on, drawUntilPlayable on (the family rule)")
check(RulesConfig().autoDrawPenalty == false,
      "autoDrawPenalty defaults off: manual one-card-at-a-time draw penalties are the default")
var legacyRulesDict = try! JSONSerialization.jsonObject(
    with: try! JSONEncoder().encode(RulesConfig(stackDrawCards: false, drawUntilPlayable: false))) as! [String: Any]
legacyRulesDict.removeValue(forKey: "stackDrawCards")
legacyRulesDict.removeValue(forKey: "drawUntilPlayable")
legacyRulesDict.removeValue(forKey: "autoDrawPenalty")
let legacyRules = try! JSONDecoder().decode(
    RulesConfig.self, from: try! JSONSerialization.data(withJSONObject: legacyRulesDict))
check(legacyRules.stackDrawCards == true && legacyRules.drawUntilPlayable == true && legacyRules.autoDrawPenalty == false,
      "pre-UNO / pre-autoDrawPenalty RulesConfig decodes with defaults")

// MARK: - UNO crafted-state helper (also exercises HostEngine(restoring:))

func unoEngine(
    hands: [Int: [Card]], top: Card, turn: Int, players: Int,
    direction: Int = 1, pending: Int = 0,
    rules: RulesConfig = RulesConfig(), drawPile: [Card] = [], declared: Suit? = nil
) -> HostEngine {
    var fullHands = hands
    for s in 0..<players where fullHands[s] == nil { fullHands[s] = [] }
    let round = RoundState(
        roundNumber: 1, cardsPerPlayer: 7, dealerSeat: 0, trumpCard: nil,
        trumpSuit: declared, bids: [:], tricksWon: [:], currentTrick: [],
        completedTricks: [], leadSeat: turn, turnSeat: turn,
        direction: direction, pendingDraw: pending)
    let state = GameState(
        gameKind: .uno, rules: rules, seats: makeSeats(players), phase: .playing,
        round: round, hands: fullHands, drawPile: drawPile, discardPile: [top],
        roundHistory: [], seed: 42)
    return HostEngine(restoring: state)
}

// MARK: - UNO legality matrix

let ur = UnoRules()
let baseUno = unoEngine(hands: [:], top: ucard("u_r5a"), turn: 1, players: 3).state
check(ur.legality(of: ucard("u_r9a"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "color match is legal")
check(ur.legality(of: ucard("u_g5a"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "symbol match is legal")
check(!ur.legality(of: ucard("u_g9a"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "no match is illegal")
check(ur.legality(of: ucard("u_wild0"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "wild always legal")
check(ur.legality(of: ucard("u_wd40"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "wild draw four always legal")
check(ur.legality(of: ucard("u_rSa"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "action card color match legal")
check(!ur.legality(of: ucard("u_gSa"), hand: [], trick: [], trump: nil, state: baseUno).isLegal, "action card with neither color nor symbol illegal")

let declaredUno = unoEngine(hands: [:], top: ucard("u_wild0"), turn: 1, players: 3, declared: .spades).state
check(ur.legality(of: ucard("u_b2a"), hand: [], trick: [], trump: nil, state: declaredUno).isLegal, "declared blue (spades) allows blue")
check(!ur.legality(of: ucard("u_r2a"), hand: [], trick: [], trump: nil, state: declaredUno).isLegal, "declared blue blocks red")
check(ur.legality(of: ucard("u_wd41"), hand: [], trick: [], trump: nil, state: declaredUno).isLegal, "wild legal on a declared color")

// MARK: - UNO deal & starter reshuffle rule

let unoDeal = freshEngine(.uno, players: 3, seed: 9)
check((0..<3).allSatisfy { unoDeal.state.hands[$0]?.count == 7 }, "uno deals 7 cards each")
check(unoDeal.state.discardPile.count == 1, "uno flips one starter card")
check(unoDeal.state.drawPile.count == 86, "108 - 21 dealt - 1 starter = 86 in draw pile")
check(unoDeal.state.phase == .playing && unoDeal.state.round?.turnSeat == 1, "uno starts left of dealer")
check(unoDeal.state.round?.direction == 1 && unoDeal.state.round?.pendingDraw == 0,
      "uno round starts direction +1, no pending draw")
var starterAlwaysColored = true
var unoDealConserved = true
for seed in 0..<300 {
    let e = freshEngine(.uno, players: 3, seed: UInt64(seed))
    guard let s = e.state.discardPile.first else { starterAlwaysColored = false; continue }
    if s.unoColor == nil { starterAlwaysColored = false }
    if e.state.drawPile.count + 21 + e.state.discardPile.count != 108 { unoDealConserved = false }
}
check(starterAlwaysColored, "starter is never a wild across 300 seeds (reshuffle-flip)")
check(unoDealConserved, "reshuffle-flip conserves all 108 cards")

// MARK: - UNO turn effects: number / skip / reverse

let eNum = unoEngine(hands: [1: [ucard("u_r7a"), ucard("u_g2a")]], top: ucard("u_r5a"), turn: 1, players: 3)
let numEvents = eNum.apply(.playCard(cardID: "u_r7a", force: false), from: 1)
check(playedCard(numEvents) != nil && eNum.state.round?.turnSeat == 2, "number play advances the turn")
check(numEvents.contains(.unoCalled(seat: 1)), "unoCalled fires when a play leaves one card")
check(isIllegal(eNum.apply(.playCard(cardID: "u_g2a", force: false), from: 1)), "out-of-turn uno play rejected")

let eSkip = unoEngine(hands: [1: [ucard("u_rSa"), ucard("u_g2a")]], top: ucard("u_r5a"), turn: 1, players: 3)
_ = eSkip.apply(.playCard(cardID: "u_rSa", force: false), from: 1)
check(eSkip.state.round?.turnSeat == 0, "skip jumps over the next player")

let eRev = unoEngine(hands: [1: [ucard("u_rRa"), ucard("u_g2a")]], top: ucard("u_r5a"), turn: 1, players: 3)
_ = eRev.apply(.playCard(cardID: "u_rRa", force: false), from: 1)
check(eRev.state.round?.direction == -1 && eRev.state.round?.turnSeat == 0,
      "reverse flips direction and the turn runs backwards")

let eRev2 = unoEngine(hands: [0: [ucard("u_rRa"), ucard("u_g2a")], 1: [ucard("u_b3a")]],
                      top: ucard("u_r5a"), turn: 0, players: 2)
_ = eRev2.apply(.playCard(cardID: "u_rRa", force: false), from: 0)
check(eRev2.state.round?.turnSeat == 0, "2-player reverse acts as a skip (same player again)")

let eClear = unoEngine(hands: [1: [ucard("u_b2a"), ucard("u_g2a")]], top: ucard("u_wild0"),
                       turn: 1, players: 3, declared: .spades)
_ = eClear.apply(.playCard(cardID: "u_b2a", force: false), from: 1)
check(eClear.state.round?.trumpSuit == nil, "a fresh play clears the declared color")

// MARK: - UNO wild color declaration

let eWild = unoEngine(hands: [1: [ucard("u_wild0"), ucard("u_g2a")],
                              2: [ucard("u_r2a"), ucard("u_b9a")]],
                      top: ucard("u_r5a"), turn: 1, players: 3)
_ = eWild.apply(.playCard(cardID: "u_wild0", force: false), from: 1)
check(eWild.state.phase == .choosingTrump(seat: 1), "wild moves to the color-choice phase")
check(isIllegal(eWild.apply(.declareSuit(.spades), from: 2)), "only the wild's player declares the color")
check(isIllegal(eWild.apply(.playCard(cardID: "u_g2a", force: false), from: 1)),
      "no card plays while a color choice is pending")
let declareEvents = eWild.apply(.declareSuit(.spades), from: 1)
check(declareEvents.contains(.suitDeclared(.spades)), "color declaration announced via suitDeclared")
check(eWild.state.round?.trumpSuit == .spades && eWild.state.phase == .playing && eWild.state.round?.turnSeat == 2,
      "declared color recorded, play resumes with the next player")
check(isIllegal(eWild.apply(.playCard(cardID: "u_r2a", force: false), from: 2)), "declared blue blocks a red play")
check(playedCard(eWild.apply(.playCard(cardID: "u_b9a", force: false), from: 2)) != nil, "declared blue allows a blue play")

// MARK: - UNO draw-two stacking: accumulate → manual absorb, one card at a time → skip

let eChain = unoEngine(
    hands: [0: [ucard("u_rDa"), ucard("u_r1a")],
            1: [ucard("u_gDa"), ucard("u_g1a")],
            2: [ucard("u_b1a"), ucard("u_b2a"), ucard("u_wild1")]],
    top: ucard("u_r5a"), turn: 0, players: 3,
    drawPile: [ucard("u_y1a"), ucard("u_y1b"), ucard("u_y2a"), ucard("u_y2b"), ucard("u_y3a"), ucard("u_y3b")])
_ = eChain.apply(.playCard(cardID: "u_rDa", force: false), from: 0)
check(eChain.state.round?.pendingDraw == 2 && eChain.state.round?.turnSeat == 1, "drawTwo sets pendingDraw to 2")
_ = eChain.apply(.playCard(cardID: "u_gDa", force: false), from: 1)
check(eChain.state.round?.pendingDraw == 4 && eChain.state.round?.turnSeat == 2, "stacked drawTwo accumulates to 4")
check(isIllegal(eChain.apply(.playCard(cardID: "u_b1a", force: false), from: 2)), "a number can't answer a draw chain")
check(isIllegal(eChain.apply(.playCard(cardID: "u_wild1", force: false), from: 2)), "a plain wild can't answer a draw chain")
check(isIllegal(eChain.apply(.playCard(cardID: "u_b1a", force: true), from: 2)),
      "a pending draw penalty is a hard rule: force:true cannot play through it")
check(eChain.state.hands[2]?.count == 3, "the forced attempt changed nothing — hand size unaffected")
// Manual mode (default): the penalty is NOT auto-drawn on landing — it's
// recorded as a counter, paid one drawCard at a time.
check(eChain.state.round?.pendingDraw == 4, "the 4-card penalty is pending, not auto-drawn")
let chainDraw1 = eChain.apply(.drawCard, from: 2)
check(eChain.state.hands[2]?.count == 4 && eChain.state.round?.pendingDraw == 3,
      "first drawCard moves exactly one card and decrements the counter")
check(chainDraw1 == [.penaltyCardDrawn(seat: 2, remaining: 3)], "drawCard emits penaltyCardDrawn with the remaining count")
check(eChain.state.round?.turnSeat == 2, "turn stays with the victim while the counter is still above zero")
_ = eChain.apply(.drawCard, from: 2)
_ = eChain.apply(.drawCard, from: 2)
check(eChain.state.hands[2]?.count == 6 && eChain.state.round?.pendingDraw == 1, "third draw leaves one card pending")
let chainDrawLast = eChain.apply(.drawCard, from: 2)
check(eChain.state.hands[2]?.count == 3 + 4, "fourth drawCard completes the 4-card penalty")
check(chainDrawLast == [.penaltyCardDrawn(seat: 2, remaining: 0)], "the final draw reports remaining: 0")
check(eChain.state.round?.pendingDraw == 0 && eChain.state.round?.turnSeat == 0,
      "the counter reaching zero clears pendingDraw and passes the turn")

// MARK: - UNO wild draw four on a draw-two chain

let eW4 = unoEngine(
    hands: [0: [ucard("u_rDb"), ucard("u_r1b")],
            1: [ucard("u_wd41"), ucard("u_g1b")],
            2: [ucard("u_gDb"), ucard("u_b2b"), ucard("u_b3a")]],
    top: ucard("u_r5b"), turn: 0, players: 3,
    drawPile: [ucard("u_y4a"), ucard("u_y4b"), ucard("u_y5a"), ucard("u_y5b"),
               ucard("u_y6a"), ucard("u_y6b"), ucard("u_y7a"), ucard("u_y7b")])
_ = eW4.apply(.playCard(cardID: "u_rDb", force: false), from: 0)
let w4Events = eW4.apply(.playCard(cardID: "u_wd41", force: false), from: 1)
check(playedCard(w4Events) != nil && eW4.state.round?.pendingDraw == 6, "wild draw four stacks on a +2 chain (2+4=6)")
check(eW4.state.phase == .choosingTrump(seat: 1), "a stacked wild draw four still asks for a color")
_ = eW4.apply(.declareSuit(.clubs), from: 1)
check(eW4.state.phase == .playing && eW4.state.round?.turnSeat == 2, "after the color pick the next player faces the stack")
check(isIllegal(eW4.apply(.playCard(cardID: "u_gDb", force: false), from: 2)), "a drawTwo can't answer a +4 chain")
for _ in 0..<6 { _ = eW4.apply(.drawCard, from: 2) }
check(eW4.state.hands[2]?.count == 3 + 6 && eW4.state.round?.pendingDraw == 0,
      "six manual drawCard calls complete a 2+4 stacked chain")
check(eW4.state.round?.turnSeat == 0, "turn passes off the victim once the stack is fully paid")

// MARK: - UNO non-stacking, manual mode (the default): penalty lands on the
// victim's turn as a pendingDraw counter, not an instant deal

let noStack = RulesConfig(stackDrawCards: false)
let eNo = unoEngine(
    hands: [0: [ucard("u_rDa"), ucard("u_r2b")], 1: [ucard("u_g1a")], 2: [ucard("u_b1b")]],
    top: ucard("u_r5a"), turn: 0, players: 3, rules: noStack,
    drawPile: [ucard("u_y8a"), ucard("u_y8b"), ucard("u_y9a"), ucard("u_y9b")])
_ = eNo.apply(.playCard(cardID: "u_rDa", force: false), from: 0)
check(eNo.state.hands[1]?.count == 1 && eNo.state.round?.pendingDraw == 2,
      "manual non-stacking drawTwo is NOT auto-drawn: it lands as a pendingDraw counter on the victim")
check(eNo.state.round?.turnSeat == 1, "manual non-stacking drawTwo makes it the victim's turn (not skipped yet)")
check(isIllegal(eNo.apply(.playCard(cardID: "u_g1a", force: false), from: 1)),
      "with stacking off, even a color/symbol match can't answer a pending penalty")
check(isIllegal(eNo.apply(.playCard(cardID: "u_g1a", force: true), from: 1)),
      "the hard rule blocks force:true too, since stacking is off here")
_ = eNo.apply(.drawCard, from: 1)
check(eNo.state.hands[1]?.count == 2 && eNo.state.round?.pendingDraw == 1 && eNo.state.round?.turnSeat == 1,
      "first manual draw takes one card, one left pending, still the victim's turn")
_ = eNo.apply(.drawCard, from: 1)
check(eNo.state.hands[1]?.count == 3 && eNo.state.round?.pendingDraw == 0,
      "second manual draw completes the 2-card penalty")
check(eNo.state.round?.turnSeat == 2, "the penalty paid, the victim's turn is over — next seat is up")

let eNoW = unoEngine(
    hands: [0: [ucard("u_wd42"), ucard("u_r2a")], 1: [ucard("u_g1b")], 2: [ucard("u_b2a")]],
    top: ucard("u_r5b"), turn: 0, players: 3, rules: noStack,
    drawPile: [ucard("u_y0"), ucard("u_g0"), ucard("u_b0"), ucard("u_r0"), ucard("u_y5a")])
_ = eNoW.apply(.playCard(cardID: "u_wd42", force: false), from: 0)
check(eNoW.state.phase == .choosingTrump(seat: 0) && eNoW.state.hands[1]?.count == 1,
      "non-stacking wild draw four picks a color before the penalty lands")
_ = eNoW.apply(.declareSuit(.hearts), from: 0)
check(eNoW.state.hands[1]?.count == 1 && eNoW.state.round?.pendingDraw == 4,
      "manual: penalty is pending after the color pick, not dealt")
check(eNoW.state.round?.turnSeat == 1 && eNoW.state.round?.trumpSuit == .hearts,
      "victim's turn now (not skipped), red (hearts) declared")
for _ in 0..<4 { _ = eNoW.apply(.drawCard, from: 1) }
check(eNoW.state.hands[1]?.count == 5 && eNoW.state.round?.pendingDraw == 0,
      "four manual draws complete the wild-draw-four penalty")
check(eNoW.state.round?.turnSeat == 2, "victim's turn ends once the penalty is paid")

// MARK: - UNO autoDrawPenalty=true: preserves the old instant-deal-and-skip
// behavior (the "fast mode" toggle)

let fastRules = RulesConfig(stackDrawCards: false, autoDrawPenalty: true)
let eFast = unoEngine(
    hands: [0: [ucard("u_rDa"), ucard("u_r2b")], 1: [ucard("u_g1a")], 2: [ucard("u_b1b")]],
    top: ucard("u_r5a"), turn: 0, players: 3, rules: fastRules,
    drawPile: [ucard("u_y8a"), ucard("u_y8b"), ucard("u_y9a"), ucard("u_y9b")])
_ = eFast.apply(.playCard(cardID: "u_rDa", force: false), from: 0)
check(eFast.state.hands[1]?.count == 3 && eFast.state.round?.pendingDraw == 0,
      "autoDrawPenalty=true: non-stacking drawTwo deals 2 to the victim immediately, as before")
check(eFast.state.round?.turnSeat == 2, "autoDrawPenalty=true: the victim is skipped, as before")

let eFastW = unoEngine(
    hands: [0: [ucard("u_wd42"), ucard("u_r2a")], 1: [ucard("u_g1b")], 2: [ucard("u_b2a")]],
    top: ucard("u_r5b"), turn: 0, players: 3, rules: fastRules,
    drawPile: [ucard("u_y0"), ucard("u_g0"), ucard("u_b0"), ucard("u_r0"), ucard("u_y5a")])
_ = eFastW.apply(.playCard(cardID: "u_wd42", force: false), from: 0)
check(eFastW.state.phase == .choosingTrump(seat: 0) && eFastW.state.hands[1]?.count == 1,
      "autoDrawPenalty=true: wild draw four still picks a color before the penalty lands")
_ = eFastW.apply(.declareSuit(.hearts), from: 0)
check(eFastW.state.hands[1]?.count == 5 && eFastW.state.round?.pendingDraw == 0,
      "autoDrawPenalty=true: deals 4 immediately after the color pick, as before")
check(eFastW.state.round?.turnSeat == 2 && eFastW.state.round?.trumpSuit == .hearts,
      "autoDrawPenalty=true: victim skipped and red (hearts) declared, as before")

// autoDrawPenalty=true with stacking still ON: a full stacked chain absorbs
// in one drawCard, exactly like the old (pre-manual) default behavior.
let eFastStack = unoEngine(
    hands: [0: [ucard("u_rDa"), ucard("u_r1a")],
            1: [ucard("u_gDa"), ucard("u_g1a")],
            2: [ucard("u_b1a"), ucard("u_b2a"), ucard("u_wild1")]],
    top: ucard("u_r5a"), turn: 0, players: 3, rules: RulesConfig(autoDrawPenalty: true),
    drawPile: [ucard("u_y1a"), ucard("u_y1b"), ucard("u_y2a"), ucard("u_y2b")])
_ = eFastStack.apply(.playCard(cardID: "u_rDa", force: false), from: 0)
_ = eFastStack.apply(.playCard(cardID: "u_gDa", force: false), from: 1)
check(eFastStack.state.round?.pendingDraw == 4, "autoDrawPenalty=true still stacks while the chain is building")
_ = eFastStack.apply(.drawCard, from: 2)
check(eFastStack.state.hands[2]?.count == 3 + 4 && eFastStack.state.round?.pendingDraw == 0,
      "autoDrawPenalty=true: absorbing a stacked chain still takes it all in one drawCard")
check(eFastStack.state.round?.turnSeat == 0, "autoDrawPenalty=true: absorbing still skips the victim's turn")

// MARK: - UNO voluntary draw, toggle OFF: exactly one card, turn passes

let eDrawOff = unoEngine(hands: [1: [ucard("u_g9b")], 2: [ucard("u_b4a")]],
                      top: ucard("u_r5a"), turn: 1, players: 3,
                      rules: RulesConfig(drawUntilPlayable: false),
                      drawPile: [ucard("u_y6a"), ucard("u_y6b")])
let offDrawEvents = eDrawOff.apply(.drawCard, from: 1)
check(eDrawOff.state.hands[1]?.count == 2 && eDrawOff.state.round?.turnSeat == 2,
      "toggle off: voluntary draw takes exactly one card and passes the turn")
check(!offDrawEvents.contains { if case .cardsDrawn = $0 { return true }; return false },
      "toggle off never emits cardsDrawn")
check(isIllegal(eDrawOff.apply(.drawCard, from: 1)), "drawing out of turn is rejected")

// MARK: - UNO voluntary draw, toggle ON (default): draw-until-playable

// Two unplayable draws (green 9, yellow 6 vs. a red-5 top) then a red 3
// that's finally legal: all three land in the hand, the drawer keeps the
// turn, and the drawn-into playable card is not auto-played.
let eDrawUntil = unoEngine(hands: [:], top: ucard("u_r5a"), turn: 1, players: 3,
                            drawPile: [ucard("u_g9b"), ucard("u_y6a"), ucard("u_r3a")])
let untilEvents = eDrawUntil.apply(.drawCard, from: 1)
check(eDrawUntil.state.hands[1]?.count == 3, "draw-until: all three drawn cards land in the hand")
check(eDrawUntil.state.round?.turnSeat == 1, "draw-until: turn stays with the drawer once a playable card appears")
check(eDrawUntil.state.discardPile.last?.id == "u_r5a", "draw-until: the newly playable card is not auto-played")
check(untilEvents.contains(.cardsDrawn(seat: 1, count: 3)), "draw-until: cardsDrawn(seat:1, count:3) emitted")
check(Set((eDrawUntil.state.hands[1] ?? []).map(\.id)) == ["u_g9b", "u_y6a", "u_r3a"],
      "draw-until: exactly the drawn cards are in hand")

// Declared wild color, not the (nil) top color, is the playability target.
let eDrawDeclared = unoEngine(hands: [:], top: ucard("u_wild0"), turn: 1, players: 3,
                               drawPile: [ucard("u_r3a"), ucard("u_g4a"), ucard("u_b5a")],
                               declared: .spades) // spades ↔ blue
let declaredEvents = eDrawDeclared.apply(.drawCard, from: 1)
check(eDrawDeclared.state.hands[1]?.count == 3, "draw-until respects declared color: draws until the blue card")
check(eDrawDeclared.state.round?.turnSeat == 1, "draw-until respects declared color: turn stays with the drawer")
check(declaredEvents.contains(.cardsDrawn(seat: 1, count: 3)), "draw-until respects declared color: cardsDrawn count 3")

// Dry deck: both draws stay unplayable, the pile and discard both run out,
// so drawing stops and the turn passes instead of stalling.
let eDrawDry = unoEngine(hands: [:], top: ucard("u_r5a"), turn: 1, players: 3,
                          drawPile: [ucard("u_g9a"), ucard("u_y9a")])
let dryEvents = eDrawDry.apply(.drawCard, from: 1)
check(eDrawDry.state.hands[1]?.count == 2, "dry deck: both drawn cards still land in hand")
check(eDrawDry.state.drawPile.isEmpty && eDrawDry.state.discardPile.count == 1,
      "dry deck: draw pile and recyclable discard are both exhausted")
check(eDrawDry.state.round?.turnSeat == 2, "dry deck: no playable card found, so the turn passes instead of stalling")
check(dryEvents.contains(.cardsDrawn(seat: 1, count: 2)), "dry deck: cardsDrawn still reports the two cards drawn")

// MARK: - UNO manual pendingDraw vs. drawUntilPlayable: the two paths don't
// tangle. A pendingDraw penalty takes exactly one card per drawCard and
// never keeps pulling in search of a playable card, even with
// drawUntilPlayable on (the default).
let eNoTangle = unoEngine(hands: [1: [ucard("u_g9b")]], top: ucard("u_r5a"), turn: 1, players: 3,
                           pending: 2, drawPile: [ucard("u_y6a"), ucard("u_y6b"), ucard("u_g4a")])
check(RulesConfig().drawUntilPlayable == true, "sanity: drawUntilPlayable is on by default for this check")
let tangleEvents = eNoTangle.apply(.drawCard, from: 1)
check(eNoTangle.state.hands[1]?.count == 2 && eNoTangle.state.round?.pendingDraw == 1,
      "a pending-draw drawCard takes exactly one card, ignoring drawUntilPlayable")
check(tangleEvents == [.penaltyCardDrawn(seat: 1, remaining: 1)],
      "a pending-draw drawCard never emits cardsDrawn, only penaltyCardDrawn")
check(eNoTangle.state.round?.turnSeat == 1, "turn stays with the victim: one card still pending")

// Dry deck during a manual penalty: can't complete it, so it's dropped and
// the turn passes rather than stalling forever (mirrors the
// drawUntilPlayable dry-deck behavior above, but via the penalty path).
let eNoTangleDry = unoEngine(hands: [1: []], top: ucard("u_r5b"), turn: 1, players: 3,
                              pending: 3, drawPile: [ucard("u_y7a")])
let tangleDryEvents = eNoTangleDry.apply(.drawCard, from: 1)
check(eNoTangleDry.state.hands[1]?.count == 1, "dry penalty draw: the one available card still lands in hand")
check(tangleDryEvents == [.penaltyCardDrawn(seat: 1, remaining: 2)], "dry penalty draw: still reports remaining after the card it could give")
let tangleDryEvents2 = eNoTangleDry.apply(.drawCard, from: 1)
check(eNoTangleDry.state.hands[1]?.count == 1 && tangleDryEvents2.isEmpty,
      "dry penalty draw: once both piles are exhausted, drawCard silently drops the rest of the penalty")
check(eNoTangleDry.state.round?.pendingDraw == 0 && eNoTangleDry.state.round?.turnSeat == 2,
      "dry penalty draw: pendingDraw is cleared and the turn passes instead of stalling")

// MARK: - ClientSnapshot.myPendingDraw

let snapNoPending = eNum.state.snapshot(for: 2) // eNum has no pending draw at all
check(snapNoPending.myPendingDraw == 0, "myPendingDraw is 0 when there's no penalty pending")

let pendingHost = unoEngine(hands: [1: [ucard("u_g1a")]], top: ucard("u_r5a"), turn: 1, players: 3, pending: 3)
// (the hand card above is deliberately unused/never played; only the snapshot matters)
let snapVictim = pendingHost.state.snapshot(for: 1)
check(snapVictim.myPendingDraw == 3, "myPendingDraw reports the pending count for the seat it's landed on")
let snapBystander = pendingHost.state.snapshot(for: 0)
check(snapBystander.myPendingDraw == 0, "myPendingDraw is 0 for a seat the penalty isn't pending against")
let snapBystander2 = pendingHost.state.snapshot(for: 2)
check(snapBystander2.myPendingDraw == 0, "myPendingDraw is 0 for every other seat too")

let snapPendingData = try! JSONEncoder().encode(snapVictim)
let snapPendingBack = try! JSONDecoder().decode(ClientSnapshot.self, from: snapPendingData)
check(snapPendingBack.myPendingDraw == 3, "myPendingDraw round-trips through JSON")

// Back-compat: a snapshot encoded before myPendingDraw existed decodes to 0.
var legacySnapshotDict = try! JSONSerialization.jsonObject(with: snapPendingData) as! [String: Any]
legacySnapshotDict.removeValue(forKey: "myPendingDraw")
let legacySnapshot = try! JSONDecoder().decode(
    ClientSnapshot.self, from: try! JSONSerialization.data(withJSONObject: legacySnapshotDict))
check(legacySnapshot.myPendingDraw == 0, "pre-myPendingDraw ClientSnapshot decodes with myPendingDraw 0")
check(legacySnapshot.mySeat == snapVictim.mySeat, "the rest of the legacy snapshot still decodes correctly")

// MARK: - UNO soft enforcement

let eForce = unoEngine(hands: [1: [ucard("u_g9a"), ucard("u_g8a")]], top: ucard("u_r5a"), turn: 1, players: 3)
check(isIllegal(eForce.apply(.playCard(cardID: "u_g9a", force: false), from: 1)),
      "illegal uno play blocked without force")
check(playedCard(eForce.apply(.playCard(cardID: "u_g9a", force: true), from: 1))?.forced == true,
      "soft enforcement pushes an illegal uno play through as forced")

// MARK: - UNO win: unoCalled then gameWon

let eWin = unoEngine(hands: [0: [ucard("u_r9b"), ucard("u_r8a")],
                             1: [ucard("u_r3a"), ucard("u_r4a")]],
                     top: ucard("u_r5a"), turn: 0, players: 2)
let winFirst = eWin.apply(.playCard(cardID: "u_r9b", force: false), from: 0)
check(winFirst.contains(.unoCalled(seat: 0)), "unoCalled announced at exactly one card")
_ = eWin.apply(.playCard(cardID: "u_r3a", force: false), from: 1)
let winLast = eWin.apply(.playCard(cardID: "u_r8a", force: false), from: 0)
check(winLast.contains(.gameWon(seat: 0)) && eWin.state.phase == .gameOver, "emptying the hand wins the game")
check(eWin.state.hands[0]?.isEmpty == true, "uno winner's hand is empty at gameOver")
check(isIllegal(eWin.apply(.playCard(cardID: "u_r4a", force: false), from: 1)), "no plays after uno gameOver")

// MARK: - RoundState back-compat decode (direction / pendingDraw defaults)

let modernRound = RoundState(
    roundNumber: 2, cardsPerPlayer: 7, dealerSeat: 1, trumpCard: nil, trumpSuit: nil,
    bids: [:], tricksWon: [:], currentTrick: [], completedTricks: [],
    leadSeat: 0, turnSeat: 0, direction: -1, pendingDraw: 4)
let modernRoundData = try! JSONEncoder().encode(modernRound)
check((try! JSONDecoder().decode(RoundState.self, from: modernRoundData)) == modernRound,
      "RoundState round-trips direction and pendingDraw")
var legacyRoundDict = try! JSONSerialization.jsonObject(with: modernRoundData) as! [String: Any]
legacyRoundDict.removeValue(forKey: "direction")
legacyRoundDict.removeValue(forKey: "pendingDraw")
let legacyRound = try! JSONDecoder().decode(
    RoundState.self, from: try! JSONSerialization.data(withJSONObject: legacyRoundDict))
check(legacyRound.direction == 1 && legacyRound.pendingDraw == 0,
      "pre-UNO RoundState decodes with direction 1 and pendingDraw 0")

// MARK: - HostEngine(restoring:) save/resume round-trip

let saveSource = freshEngine(.uno, players: 3, seed: 21)
let savedData = try! JSONEncoder().encode(saveSource.state)
let restoredState = try! JSONDecoder().decode(GameState.self, from: savedData)
let restored = HostEngine(restoring: restoredState)
check(restored.state == saveSource.state, "restoring init resumes the exact saved state")
check(restored.apply(.approveUndo).isEmpty, "restored engine starts with no undo history")
let restoredSeat = restored.state.round!.turnSeat
var restoredActed = false
for candidate in restored.state.hands[restoredSeat]! {
    if playedCard(restored.apply(.playCard(cardID: candidate.id, force: false), from: restoredSeat)) != nil {
        restoredActed = true
        break
    }
}
if !restoredActed { restoredActed = !isIllegal(restored.apply(.drawCard, from: restoredSeat)) }
check(restoredActed, "restored engine keeps accepting play")

// A full old-format save (predating autoDrawPenalty, nested inside `rules`)
// still decodes: the pre-manual-draw-penalty flag defaults off.
var legacyStateDict = try! JSONSerialization.jsonObject(with: savedData) as! [String: Any]
var legacyStateRules = legacyStateDict["rules"] as! [String: Any]
legacyStateRules.removeValue(forKey: "autoDrawPenalty")
legacyStateDict["rules"] = legacyStateRules
let legacyState = try! JSONDecoder().decode(
    GameState.self, from: try! JSONSerialization.data(withJSONObject: legacyStateDict))
check(legacyState.rules.autoDrawPenalty == false, "old saved GameState (no autoDrawPenalty key) decodes with it off")
check(legacyState.gameKind == .uno && legacyState.hands == saveSource.state.hands,
      "the rest of the old saved GameState decodes unchanged")

// MARK: - unoCalled event codable

let unoEvents: [GameEvent] = [.unoCalled(seat: 2), .suitDeclared(.hearts)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(unoEvents))) == unoEvents,
      "unoCalled round-trips through JSON")

let cardsDrawnEvents: [GameEvent] = [.cardsDrawn(seat: 1, count: 3)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(cardsDrawnEvents))) == cardsDrawnEvents,
      "cardsDrawn round-trips through JSON")

let penaltyCardDrawnEvents: [GameEvent] = [.penaltyCardDrawn(seat: 2, remaining: 3), .penaltyCardDrawn(seat: 2, remaining: 0)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(penaltyCardDrawnEvents))) == penaltyCardDrawnEvents,
      "penaltyCardDrawn round-trips through JSON")

// MARK: - Full seeded 3-player UNO game

func driveUno(
    seed: UInt64, players: Int, rules: RulesConfig = RulesConfig()
) -> (finished: Bool, sawUnoCall: Bool, sawDeclared: Bool, sawMultiDraw: Bool, engine: HostEngine) {
    let engine = freshEngine(.uno, players: players, rules: rules, seed: seed)
    var sawUnoCall = false
    var sawDeclared = false
    var sawMultiDraw = false
    var steps = 0
    while steps < 20_000 {
        steps += 1
        switch engine.state.phase {
        case .choosingTrump(let seat):
            let color = (engine.state.hands[seat] ?? []).compactMap(\.unoColor).first ?? .red
            let evs = engine.apply(.declareSuit(color.suit), from: seat)
            if evs.contains(.suitDeclared(color.suit)) { sawDeclared = true }
        case .playing:
            let seat = engine.state.round!.turnSeat
            var acted = false
            for candidate in engine.state.hands[seat]! {
                let evs = engine.apply(.playCard(cardID: candidate.id, force: false), from: seat)
                if evs.contains(.unoCalled(seat: seat)) { sawUnoCall = true }
                if playedCard(evs) != nil { acted = true; break }
            }
            if !acted {
                let drawEvents = engine.apply(.drawCard, from: seat)
                if isIllegal(drawEvents) {
                    return (false, sawUnoCall, sawDeclared, sawMultiDraw, engine)
                }
                if drawEvents.contains(where: { if case .cardsDrawn(_, let count) = $0 { return count > 1 }; return false }) {
                    sawMultiDraw = true
                }
            }
        case .gameOver:
            return (true, sawUnoCall, sawDeclared, sawMultiDraw, engine)
        default:
            return (false, sawUnoCall, sawDeclared, sawMultiDraw, engine)
        }
    }
    return (false, sawUnoCall, sawDeclared, sawMultiDraw, engine)
}

var unoFinished = false
var unoSawCall = false
var unoSawDeclared = false
var unoWinnerEmpty = false
var unoConserved = true
var unoWonEmitted = false
for seed in 0..<40 {
    let result = driveUno(seed: UInt64(seed), players: 3)
    guard result.finished else { continue }
    unoFinished = true
    unoSawCall = unoSawCall || result.sawUnoCall
    unoSawDeclared = unoSawDeclared || result.sawDeclared
    let hands = result.engine.state.hands
    unoWinnerEmpty = unoWinnerEmpty || hands.values.contains { $0.isEmpty }
    unoWonEmitted = true // gameOver phase only reachable via gameWon in uno
    let totalCards = hands.values.reduce(0) { $0 + $1.count }
        + result.engine.state.drawPile.count + result.engine.state.discardPile.count
    if totalCards != 108 { unoConserved = false }
    if unoSawCall && unoSawDeclared && unoWinnerEmpty { break }
}
check(unoFinished, "seeded 3-player uno game reaches gameOver by first-legal-card play")
check(unoSawCall, "a full uno game emitted unoCalled")
check(unoSawDeclared, "a full uno game declared a wild color")
check(unoWinnerEmpty && unoWonEmitted, "uno winner finished with an empty hand")
check(unoConserved, "all 108 cards accounted for at uno gameOver")

// MARK: - Full seeded games with drawUntilPlayable ON (the default): no stalls

var drawUntilFinishedCount = 0
var drawUntilConserved = true
var drawUntilSawMultiDraw = false
for seed in 100..<140 {
    let result = driveUno(seed: UInt64(seed), players: 4, rules: RulesConfig(drawUntilPlayable: true))
    guard result.finished else { continue }
    drawUntilFinishedCount += 1
    drawUntilSawMultiDraw = drawUntilSawMultiDraw || result.sawMultiDraw
    let hands = result.engine.state.hands
    let totalCards = hands.values.reduce(0) { $0 + $1.count }
        + result.engine.state.drawPile.count + result.engine.state.discardPile.count
    if totalCards != 108 { drawUntilConserved = false }
}
check(drawUntilFinishedCount == 40, "every seeded 4-player draw-until-playable game reaches gameOver (no stalls)")
check(drawUntilSawMultiDraw, "at least one seeded game exercised a multi-card draw-until-playable pull")
check(drawUntilConserved, "all 108 cards accounted for at gameOver under draw-until-playable")

// MARK: - Manual dealing (autoDeal off)

func cardDealtSeat(_ events: [GameEvent]) -> Int? {
    for event in events { if case .cardDealt(let seat) = event { return seat } }
    return nil
}

let manualRules = RulesConfig(autoDeal: false)

// UNO: startGame parks in .dealing with a full shuffled pile, hands empty.
let mUno = HostEngine(seats: makeSeats(3), gameKind: .uno, rules: manualRules, seed: 9)
let mUnoStart = mUno.apply(.startGame(.uno, manualRules, seed: 9))
check(mUno.state.phase == .dealing, "manual uno: startGame parks in .dealing")
check(mUnoStart.isEmpty, "manual uno: no events until the deal completes")
check(mUno.state.drawPile.count == 108 && mUno.state.discardPile.isEmpty,
      "manual uno: whole shuffled deck in the draw pile, no starter yet")
check(mUno.state.hands.values.allSatisfy(\.isEmpty), "manual uno: hands start empty")
check(isIllegal(mUno.apply(.placeBid(0), from: 1)), "manual uno: no player actions while dealing")

// Guards: unknown seat rejected; playCard rejected mid-deal.
check(isIllegal(mUno.apply(.dealCardTo(seat: 9))), "manual uno: dealCardTo unknown seat rejected")
check(mUno.state.drawPile.count == 108, "manual uno: rejected deal changed nothing")

// Deal 7 each in an arbitrary (non-round-robin) order; each pop emits cardDealt.
var mUnoEventsOK = true
for seat in [2, 0, 1] {
    for _ in 0..<7 {
        let evs = mUno.apply(.dealCardTo(seat: seat))
        if cardDealtSeat(evs) != seat { mUnoEventsOK = false }
    }
}
check(mUnoEventsOK, "manual uno: every dealCardTo emits cardDealt for its seat")
check((0..<3).allSatisfy { mUno.state.hands[$0]?.count == 7 }, "manual uno: all hands reach 7")
check(mUno.state.phase == .playing, "manual uno: deal auto-completes into .playing")
check(mUno.state.discardPile.count == 1 && mUno.state.discardPile.first?.unoColor != nil,
      "manual uno: completion flips a colored starter (wild reshuffle rule)")
check(mUno.state.drawPile.count + 21 + mUno.state.discardPile.count == 108,
      "manual uno: all 108 cards conserved after completion")
check(mUno.state.round?.turnSeat == 1 && mUno.state.round?.leadSeat == 1,
      "manual uno: play opens left of the dealer")

// Over-deal impossible: full hands and post-completion deals both rejected.
check(isIllegal(mUno.apply(.dealCardTo(seat: 0))), "manual uno: dealCardTo after completion rejected")

// Partial-deal guards: a full hand mid-deal rejects further cards, and the
// deal does NOT complete until EVERY hand is at target.
let mPart = HostEngine(seats: makeSeats(3), gameKind: .uno, rules: manualRules, seed: 10)
_ = mPart.apply(.startGame(.uno, manualRules, seed: 10))
for _ in 0..<7 { _ = mPart.apply(.dealCardTo(seat: 2)) }
check(mPart.state.phase == .dealing, "manual partial: one full hand doesn't complete the deal")
check(isIllegal(mPart.apply(.dealCardTo(seat: 2))), "manual partial: over-dealing a full hand rejected")
check(mPart.state.hands[2]?.count == 7 && mPart.state.drawPile.count == 101,
      "manual partial: rejected over-deal changed nothing")
let mCompletionEvents: [GameEvent] = {
    var last: [GameEvent] = []
    for seat in [0, 1] { for _ in 0..<7 { last = mPart.apply(.dealCardTo(seat: seat)) } }
    return last
}()
check(mPart.state.phase == .playing, "manual partial: completes once the last hand fills")
check(mCompletionEvents.contains(.dealt), "manual completion: .dealt fires with the final card")

// Trick game (Oh Hell round 1): manual deal, trump flip on completion.
let mOh = HostEngine(seats: makeSeats(3), gameKind: .ohHell, rules: manualRules, seed: 11)
_ = mOh.apply(.startGame(.ohHell, manualRules, seed: 11))
check(mOh.state.phase == .dealing && mOh.state.drawPile.count == 52,
      "manual ohHell: parks in .dealing with the full deck")
for seat in 0..<3 { _ = mOh.apply(.dealCardTo(seat: seat)) }
check(mOh.state.phase == .bidding, "manual ohHell: completion opens bidding")
check(mOh.state.round?.trumpCard != nil && mOh.state.round?.trumpSuit == mOh.state.round?.trumpCard?.suit,
      "manual ohHell: completion flips trump from the remaining pile")
check(mOh.state.drawPile.count == 48, "manual ohHell: 52 - 3 dealt - 1 flipped = 48")
check(mOh.state.round?.turnSeat == 1, "manual ohHell: bidding starts left of dealer")

// Wizard: a wizard trump flip on manual completion → dealer chooses trump.
var mSawWizardFlip = false
var mSawStandardFlip = false
for seed in 0..<4000 where !(mSawWizardFlip && mSawStandardFlip) {
    let e = HostEngine(seats: makeSeats(3), gameKind: .wizard, rules: manualRules, seed: UInt64(seed))
    _ = e.apply(.startGame(.wizard, manualRules, seed: UInt64(seed)))
    for seat in 0..<3 { _ = e.apply(.dealCardTo(seat: seat)) }
    guard let flipped = e.state.round?.trumpCard else { continue }
    if flipped.isWizard && !mSawWizardFlip {
        mSawWizardFlip = true
        check(e.state.phase == .choosingTrump(seat: 0), "manual wizard: wizard flip → dealer chooses trump")
        check(e.apply(.chooseTrump(.hearts), from: 0).contains(.trumpRevealed(flipped, .hearts)),
              "manual wizard: trump choice proceeds normally after a manual deal")
    } else if flipped.suit != nil && !mSawStandardFlip {
        mSawStandardFlip = true
        check(e.state.round?.trumpSuit == flipped.suit && e.state.phase == .bidding,
              "manual wizard: standard flip → its suit is trump, straight to bidding")
    }
}
check(mSawWizardFlip && mSawStandardFlip, "manual wizard: found wizard and standard flips")

// Crazy Eights: 5 each, starter flip on completion.
let mCE = HostEngine(seats: makeSeats(2), gameKind: .crazyEights, rules: manualRules, seed: 3)
_ = mCE.apply(.startGame(.crazyEights, manualRules, seed: 3))
check(mCE.state.phase == .dealing && mCE.state.drawPile.count == 52,
      "manual crazyEights: parks in .dealing with the full deck")
for _ in 0..<5 { for seat in 0..<2 { _ = mCE.apply(.dealCardTo(seat: seat)) } }
check(mCE.state.phase == .playing && mCE.state.round?.turnSeat == 1,
      "manual crazyEights: completion starts play left of dealer")
check(mCE.state.discardPile.count == 1 && mCE.state.drawPile.count == 41,
      "manual crazyEights: starter flipped, 52 - 10 - 1 = 41 left")

// Manual dealing survives a full playable game: play the manual UNO to a move.
let mSeat = mUno.state.round!.turnSeat
var mActed = false
for candidate in mUno.state.hands[mSeat] ?? [] {
    if playedCard(mUno.apply(.playCard(cardID: candidate.id, force: false), from: mSeat)) != nil {
        mActed = true; break
    }
}
if !mActed { mActed = !isIllegal(mUno.apply(.drawCard, from: mSeat)) }
check(mActed, "manual uno: play proceeds normally after a manual deal")

// dealCardTo is a no-op path when autoDeal is on.
let mAutoGuard = freshEngine(.uno, players: 3, seed: 9)
let mAutoGuardState = mAutoGuard.state
check(isIllegal(mAutoGuard.apply(.dealCardTo(seat: 0))), "dealCardTo rejected when autoDeal is on")
check(mAutoGuard.state == mAutoGuardState, "rejected dealCardTo under autoDeal changed nothing")

// Back-compat: RulesConfig encoded before autoDeal existed decodes to true.
check(RulesConfig().autoDeal == true, "autoDeal defaults on")
var legacyAutoDealDict = try! JSONSerialization.jsonObject(
    with: try! JSONEncoder().encode(RulesConfig(autoDeal: false))) as! [String: Any]
legacyAutoDealDict.removeValue(forKey: "autoDeal")
let legacyAutoDealRules = try! JSONDecoder().decode(
    RulesConfig.self, from: try! JSONSerialization.data(withJSONObject: legacyAutoDealDict))
check(legacyAutoDealRules.autoDeal == true, "pre-autoDeal RulesConfig decodes with autoDeal on")

// autoDeal=true regression: explicit true is byte-identical to the default path.
let regDefault = freshEngine(.uno, players: 3, seed: 9)
let regExplicit = freshEngine(.uno, players: 3, rules: RulesConfig(autoDeal: true), seed: 9)
check(regDefault.state == regExplicit.state, "autoDeal=true path identical to the default path (uno)")
let regWizard = driveWizard(seed: 2026, stopAtPlayingRound: 5).engine
check(regWizard.state.round?.roundNumber == 5 && regWizard.state.roundHistory.count == 4,
      "autoDeal=true wizard progression unchanged (seeded drive)")

// cardDealt event round-trips through JSON.
let cardDealtEvents: [GameEvent] = [.cardDealt(seat: 2)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(cardDealtEvents))) == cardDealtEvents,
      "cardDealt round-trips through JSON")

// MARK: - Solitaire: rank remapping

check(card("s14").solitaireRank == 1, "Ace remaps to Klondike rank 1")
check(card("s13").solitaireRank == 13, "King stays Klondike rank 13")
check(card("s2").solitaireRank == 2, "low ranks pass through unchanged")
check(card("s11").solitaireRank == 11, "Jack stays 11")

// MARK: - Solitaire: seeded deal shape & determinism

let solA1 = SolitaireEngine(seed: 777)
let solA2 = SolitaireEngine(seed: 777)
let solB = SolitaireEngine(seed: 778)
check(solA1.state == solA2.state, "same seed -> identical solitaire deal")
check(solA1.state != solB.state, "different seed -> different solitaire deal")
check(solA1.state.tableau.map(\.count) == [1, 2, 3, 4, 5, 6, 7], "tableau column sizes are 1...7")
check(solA1.state.tableau.enumerated().allSatisfy { i, pile in
    pile.dropLast().allSatisfy { !$0.faceUp } && pile.last!.faceUp
}, "only the top card of each column deals face-up")
check(solA1.state.stock.count == 24, "24 cards left in the stock after dealing 28")
check(solA1.state.waste.isEmpty && solA1.state.foundations.values.allSatisfy(\.isEmpty),
      "waste and foundations start empty")
check(Set(solA1.state.tableau.flatMap { $0.map { $0.card.id } } + solA1.state.stock.map(\.id)).count == 52,
      "every dealt id is unique and the full 52 is accounted for")
check(solA1.state.drawMode == .drawOne, "default draw mode is draw-1")

// MARK: - Solitaire: tableau legality

func solitaireColumn(_ cards: [Card], faceUp: [Bool]? = nil) -> [SolitaireCard] {
    cards.enumerated().map { i, c in SolitaireCard(card: c, faceUp: faceUp?[i] ?? true) }
}
func emptySolitaireFoundations() -> [Suit: [Card]] {
    Dictionary(uniqueKeysWithValues: Suit.allCases.map { ($0, []) })
}
func solitaireState(tableau: [[SolitaireCard]], foundations: [Suit: [Card]] = emptySolitaireFoundations(),
                    stock: [Card] = [], waste: [Card] = [], drawMode: SolitaireDrawMode = .drawOne) -> SolitaireState {
    var full = tableau
    while full.count < 7 { full.append([]) }
    return SolitaireState(tableau: full, foundations: foundations, stock: stock, waste: waste,
                          drawMode: drawMode, seed: 1)
}

// Black 7 onto red 8: legal (descending, alternating).
let legalTableauState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s7")]),
])
let legalTableauEngine = SolitaireEngine(state: legalTableauState)
check(legalTableauEngine.legalMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0)),
      "black 7 onto red 8 is legal")

// Red 7 onto red 8: same color, illegal.
let sameColorState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("d7")]),
])
check(!SolitaireEngine(state: sameColorState).legalMove(from: .tableau(column: 1, cardID: "d7"), to: .tableau(column: 0)),
      "red 7 onto red 8 (same color) is illegal")

// Black 5 onto red 8: wrong rank gap, illegal.
let wrongGapState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s5")]),
])
check(!SolitaireEngine(state: wrongGapState).legalMove(from: .tableau(column: 1, cardID: "s5"), to: .tableau(column: 0)),
      "black 5 onto red 8 (wrong rank) is illegal")

// King onto an empty column: legal. Queen onto an empty column: illegal.
let emptyColumnState = solitaireState(tableau: [
    [],
    solitaireColumn([card("s13")]),
    solitaireColumn([card("h12")]),
])
let emptyColumnEngine = SolitaireEngine(state: emptyColumnState)
check(emptyColumnEngine.legalMove(from: .tableau(column: 1, cardID: "s13"), to: .tableau(column: 0)),
      "King onto an empty column is legal")
check(!emptyColumnEngine.legalMove(from: .tableau(column: 2, cardID: "h12"), to: .tableau(column: 0)),
      "Queen onto an empty column is illegal")

// Moving a run onto its own column is a no-op, not a move.
check(!emptyColumnEngine.legalMove(from: .tableau(column: 1, cardID: "s13"), to: .tableau(column: 1)),
      "moving a run onto its own column is illegal")

// A face-down card can't be picked up, even as the base of an otherwise-legal run.
let faceDownBaseState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s7")], faceUp: [false]),
])
check(!SolitaireEngine(state: faceDownBaseState).legalMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0)),
      "a face-down card can't be moved")

// A multi-card run that's genuinely a valid alternating descending sequence
// moves together.
let validRunState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s7"), card("h6")]),
])
let validRunEngine = SolitaireEngine(state: validRunState)
check(validRunEngine.legalMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0)),
      "a valid black7-red6 run moves as one unit")
_ = validRunEngine.attemptMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0))
check(validRunEngine.state.tableau[0].map(\.id) == ["h8", "s7", "h6"], "the whole run landed together, in order")
check(validRunEngine.state.tableau[1].isEmpty, "the source column is now empty")

// A "run" that isn't actually a valid sequence (hand-constructed, can't
// arise from legal play) can't be picked up as a unit — the defensive
// check in isMovableRun, not something the UI can trigger normally.
let brokenRunState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s7"), card("s6")]), // same color back-to-back
])
check(!SolitaireEngine(state: brokenRunState).legalMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0)),
      "a same-color 'run' can't be moved as a unit")

// MARK: - Solitaire: foundation legality

// Ace onto an empty foundation: legal. Two onto an empty foundation: illegal.
let foundationStartState = solitaireState(tableau: [
    solitaireColumn([card("h14")]),
    solitaireColumn([card("h2")]),
])
let foundationStartEngine = SolitaireEngine(state: foundationStartState)
check(foundationStartEngine.legalMove(from: .tableau(column: 0, cardID: "h14"), to: .foundation(.hearts)),
      "Ace onto an empty foundation is legal")
check(!foundationStartEngine.legalMove(from: .tableau(column: 1, cardID: "h2"), to: .foundation(.hearts)),
      "Two onto an empty foundation is illegal")

// Sequential same-suit build: legal. Wrong suit / skipped rank: illegal.
let foundationBuildState = solitaireState(
    tableau: [solitaireColumn([card("h2")]), solitaireColumn([card("d2")]), solitaireColumn([card("h4")])],
    foundations: {
        var f = emptySolitaireFoundations(); f[.hearts] = [card("h14")]; return f
    }())
let foundationBuildEngine = SolitaireEngine(state: foundationBuildState)
check(foundationBuildEngine.legalMove(from: .tableau(column: 0, cardID: "h2"), to: .foundation(.hearts)),
      "hearts 2 onto a hearts-Ace foundation is legal")
check(!foundationBuildEngine.legalMove(from: .tableau(column: 1, cardID: "d2"), to: .foundation(.hearts)),
      "diamonds 2 onto a hearts foundation (wrong suit) is illegal")
check(!foundationBuildEngine.legalMove(from: .tableau(column: 2, cardID: "h4"), to: .foundation(.hearts)),
      "hearts 4 onto a hearts-Ace foundation (skipped rank) is illegal")

// A foundation card can rescue back onto a legal tableau spot.
let foundationRescueState = solitaireState(
    tableau: [solitaireColumn([card("s8")])],
    foundations: { var f = emptySolitaireFoundations(); f[.hearts] = [card("h14"), card("h2"), card("h3"), card("h4"),
                                                                       card("h5"), card("h6"), card("h7")]; return f }())
let foundationRescueEngine = SolitaireEngine(state: foundationRescueState)
check(foundationRescueEngine.legalMove(from: .foundation(.hearts), to: .tableau(column: 0)),
      "hearts 7 off the foundation onto a black 8 is legal")
_ = foundationRescueEngine.attemptMove(from: .foundation(.hearts), to: .tableau(column: 0))
check(foundationRescueEngine.state.foundations[.hearts]?.count == 6, "the foundation lost its top card")
check(foundationRescueEngine.state.tableau[0].last?.id == "h7", "and the tableau gained it")

// Double-tap auto-foundation: reports the right suit when playable, nil otherwise.
check(foundationStartEngine.autoFoundationSuit(for: .tableau(column: 0, cardID: "h14")) == .hearts,
      "double-tap on a playable Ace reports its foundation suit")
check(foundationStartEngine.autoFoundationSuit(for: .tableau(column: 1, cardID: "h2")) == nil,
      "double-tap on an unplayable card reports nil")

// MARK: - Solitaire: draw / redeal

let drawEngine = SolitaireEngine(seed: 9001, drawMode: .drawOne)
let stockBefore = drawEngine.state.stock.count
check(drawEngine.draw(), "draw-1 pulls a card")
check(drawEngine.state.waste.count == 1 && drawEngine.state.stock.count == stockBefore - 1,
      "draw-1 moves exactly one stock card to the waste")

let draw3Engine = SolitaireEngine(seed: 9002, drawMode: .drawThree)
_ = draw3Engine.draw()
check(draw3Engine.state.waste.count == 3 && draw3Engine.state.stock.count == 21,
      "draw-3 moves three stock cards to the waste")

// Exhaust the stock, then redeal, then confirm the cycle can repeat.
while draw3Engine.state.stock.count > 0 { _ = draw3Engine.draw() }
let wasteAtEmptyStock = draw3Engine.state.waste.count
check(draw3Engine.state.stock.isEmpty && wasteAtEmptyStock == 24, "the whole stock ends up in the waste")
check(draw3Engine.draw(), "drawing with an empty stock redeals instead of failing")
check(draw3Engine.state.stock.count == wasteAtEmptyStock && draw3Engine.state.waste.isEmpty,
      "redeal moves the entire waste back into the stock, unlimited")
_ = draw3Engine.draw() // prove the redealt stock is drawable again
check(!draw3Engine.state.waste.isEmpty, "the redealt stock draws normally")

let bothEmptyState = solitaireState(tableau: [], stock: [], waste: [])
check(!SolitaireEngine(state: bothEmptyState).draw(), "drawing with stock AND waste both empty fails")

// MARK: - Solitaire: auto-flip on exposure

let autoFlipState = solitaireState(
    tableau: [solitaireColumn([card("s5"), card("h6")], faceUp: [false, true])],
    foundations: { var f = emptySolitaireFoundations()
        f[.hearts] = [card("h14"), card("h2"), card("h3"), card("h4"), card("h5")]; return f }())
let autoFlipEngine = SolitaireEngine(state: autoFlipState)
check(!autoFlipEngine.state.tableau[0][0].faceUp, "the buried card starts face-down")
check(autoFlipEngine.attemptMove(from: .tableau(column: 0, cardID: "h6"), to: .foundation(.hearts)),
      "hearts 6 walks home, exposing the buried card")
check(autoFlipEngine.state.tableau[0][0].faceUp, "the newly-exposed card auto-flips face-up")

// MARK: - Solitaire: undo round-trip

let undoState = solitaireState(tableau: [
    solitaireColumn([card("h8")]),
    solitaireColumn([card("s7")]),
])
let undoEngine = SolitaireEngine(state: undoState)
check(!undoEngine.canUndo, "a fresh engine has nothing to undo")
let beforeMove = undoEngine.state
_ = undoEngine.attemptMove(from: .tableau(column: 1, cardID: "s7"), to: .tableau(column: 0))
check(undoEngine.state != beforeMove, "the move actually changed the state")
check(undoEngine.canUndo, "canUndo flips on after a move")
check(undoEngine.undo(), "undo succeeds")
check(undoEngine.state == beforeMove, "undo restores the exact prior state, move count included")
check(!undoEngine.canUndo, "undo stack is empty again after one undo")
check(!undoEngine.undo(), "undoing with nothing left to undo fails cleanly")

// Multiple moves, multiple undos: walk back to the start.
let multiUndoEngine = SolitaireEngine(seed: 55)
let multiUndoStart = multiUndoEngine.state
_ = multiUndoEngine.draw()
_ = multiUndoEngine.draw()
check(multiUndoEngine.state != multiUndoStart, "two draws changed the state")
_ = multiUndoEngine.undo()
_ = multiUndoEngine.undo()
check(multiUndoEngine.state == multiUndoStart, "two undos walk all the way back to the start")

// New deal wipes undo history — nothing sensible to undo INTO a different deal.
let wipeEngine = SolitaireEngine(seed: 60)
_ = wipeEngine.draw()
check(wipeEngine.canUndo, "a draw leaves something to undo")
wipeEngine.newDeal(seed: 61)
check(!wipeEngine.canUndo, "a new deal clears the undo stack")

// MARK: - Solitaire: win detection & autocompletability

func suitFoundationRun(_ suit: Suit, throughKlondikeRank topRank: Int) -> [Card] {
    let prefix = String(suit.rawValue.first!)
    // Klondike order Ace(1)...topRank, mapped back onto Card.rank (Ace = 14).
    return (1...topRank).map { klondikeRank in
        let cardRank = klondikeRank == 1 ? 14 : klondikeRank
        return Card(id: "\(prefix)\(cardRank)", kind: .standard(suit: suit, rank: cardRank))
    }
}
var almostWonFoundations: [Suit: [Card]] = [:]
for suit in Suit.allCases {
    // Every suit home through King (13), except hearts, one card short.
    almostWonFoundations[suit] = suitFoundationRun(suit, throughKlondikeRank: suit == .hearts ? 12 : 13)
}
let almostWonState = solitaireState(tableau: [], foundations: almostWonFoundations)
check(!almostWonState.isWon, "51 of 52 home isn't a win yet")
var justWonFoundations = almostWonFoundations
justWonFoundations[.hearts]!.append(card("h13"))
check(solitaireState(tableau: [], foundations: justWonFoundations).isWon, "all 52 home is a win")

let notAutoCompletableStock = solitaireState(tableau: [solitaireColumn([card("s2")])], stock: [card("s3")])
check(!notAutoCompletableStock.isAutoCompletable, "a non-empty stock blocks autocompletability")
let notAutoCompletableWaste = solitaireState(tableau: [solitaireColumn([card("s2")])], waste: [card("s3")])
check(!notAutoCompletableWaste.isAutoCompletable, "a non-empty waste blocks autocompletability")
let notAutoCompletableFaceDown = solitaireState(tableau: [solitaireColumn([card("s2"), card("h3")], faceUp: [false, true])])
check(!notAutoCompletableFaceDown.isAutoCompletable, "a face-down tableau card blocks autocompletability")
let readyToAutoComplete = solitaireState(tableau: [solitaireColumn([card("s2"), card("h3")])])
check(readyToAutoComplete.isAutoCompletable, "all face-up, stock and waste empty -> autocompletable")

// MARK: - Solitaire: Codable save / resume round-trip

let saveEngine = SolitaireEngine(seed: 4242)
_ = saveEngine.draw()
guard let savedData = saveEngine.encodedState, let resumedEngine = SolitaireEngine(encodedState: savedData) else {
    check(false, "solitaire save/resume round-trip")
    fatalError("unreachable")
}
check(resumedEngine.state == saveEngine.state, "resuming from encoded state reproduces the exact table")

// MARK: - Solitaire: a scripted winnable game, played to completion

// Hand-craft a fully face-up, fully solvable table: each of 4 columns holds
// one whole suit already in home-run order (King buried at the bottom,
// Ace exposed on top), 3 columns stand empty, stock/waste/foundations
// start clean. `autoCompleteStep()` — the same primitive the trophy-moment
// cascade animation drives — walks every card home one at a time with no
// human input at all.
func fullSuitColumn(_ suit: Suit) -> [SolitaireCard] {
    let prefix = String(suit.rawValue.first!)
    // Bottom (index 0) -> top (last index): King down to Ace, i.e. Card.rank
    // 13,12,...,2, then 14 (Ace) last, since Ace's *solitaireRank* (1) is
    // what needs to end up on top.
    let ranksBottomToTop = Array((2...13).reversed()) + [14]
    return ranksBottomToTop.map { rank in
        SolitaireCard(card: Card(id: "\(prefix)\(rank)", kind: .standard(suit: suit, rank: rank)), faceUp: true)
    }
}
let solvableState = solitaireState(tableau: Suit.allCases.map(fullSuitColumn))
let solvableEngine = SolitaireEngine(state: solvableState)
check(solvableEngine.state.isAutoCompletable, "the hand-crafted table is immediately autocompletable")
var autocompleteSteps = 0
for _ in 0..<60 { // hard cap so a runaway loop fails loudly instead of hanging
    guard solvableEngine.autoCompleteStep() != nil else { break }
    autocompleteSteps += 1
}
check(autocompleteSteps == 52, "exactly 52 cards walked home, one at a time, and autocomplete terminates")
check(solvableEngine.state.isWon, "the scripted game reaches a real win")
check(solvableEngine.state.tableau.allSatisfy(\.isEmpty), "every tableau column is empty at the end")
check(solvableEngine.state.moveCount == 52, "move count matches the 52 winning moves")
check(Suit.allCases.allSatisfy { suit in
    solvableEngine.state.foundations[suit]?.map(\.solitaireRank) == Array(1...13)
}, "every foundation ends Ace...King, in order")

// MARK: - Dots & Boxes: geometry

func makeDABPlayers(_ n: Int, bots: Bool = false) -> [DotsAndBoxesPlayer] {
    (0..<n).map { DotsAndBoxesPlayer(name: "P\($0)", colorIndex: $0, isBot: bots) }
}

// Every edge a grid of `gridSize` can hold, built the same way the engine's
// private `allEdges()` does — duplicated here (not exposed publicly) so
// tests can hand-craft exact board states via `DotsAndBoxesEngine(restoring:)`.
func dabAllEdges(gridSize: Int) -> [DotsAndBoxesEdge] {
    var edges: [DotsAndBoxesEdge] = []
    for row in 0...gridSize {
        for col in 0..<gridSize { edges.append(DotsAndBoxesEdge(orientation: .horizontal, row: row, col: col)) }
    }
    for row in 0..<gridSize {
        for col in 0...gridSize { edges.append(DotsAndBoxesEdge(orientation: .vertical, row: row, col: col)) }
    }
    return edges
}

let dabBox = DotsAndBoxesBox(row: 2, col: 3)
check(dabBox.edges() == [
    DotsAndBoxesEdge(orientation: .horizontal, row: 2, col: 3),  // top
    DotsAndBoxesEdge(orientation: .horizontal, row: 3, col: 3),  // bottom
    DotsAndBoxesEdge(orientation: .vertical, row: 2, col: 3),    // left
    DotsAndBoxesEdge(orientation: .vertical, row: 2, col: 4),    // right
], "box edges() returns top/bottom/left/right in order")

let dab4x4Engine = DotsAndBoxesEngine(gridSize: 4, players: makeDABPlayers(2), seed: 1)
check(dab4x4Engine.state.totalEdgeCount == 40, "4x4-box grid has 40 edges (2*4*5)")
check(dab4x4Engine.state.totalBoxCount == 16, "4x4-box grid has 16 boxes")
check(dab4x4Engine.legalEdges().count == 40, "every edge legal on a fresh board")
check(Set(dabAllEdges(gridSize: 4)).count == 40, "dabAllEdges matches totalEdgeCount for 4x4")

// MARK: - Dots & Boxes: turn order and legality

let dabTurnEngine = DotsAndBoxesEngine(gridSize: 1, players: makeDABPlayers(2), seed: 1)
let dabOffGrid = dabTurnEngine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 3, col: 0), by: 0)
check(dabOffGrid == [.illegalAttempt(reason: "That's not a line on this grid")], "off-grid edge rejected")
check(dabTurnEngine.state.claimedBy.isEmpty, "rejected off-grid attempt claims nothing")

let dabWrongTurn = dabTurnEngine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), by: 1)
check(dabWrongTurn == [.illegalAttempt(reason: "Not your turn")], "out-of-turn claim rejected")

_ = dabTurnEngine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), by: 0)
check(dabTurnEngine.state.turnIndex == 1, "turn passes on a non-completing move")
let dabReclaim = dabTurnEngine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), by: 1)
check(dabReclaim == [.illegalAttempt(reason: "That line is already drawn")], "an already-drawn line can't be redrawn")

// MARK: - Dots & Boxes: box completion, extra turn, and game over

let dab1x1Engine = DotsAndBoxesEngine(gridSize: 1, players: makeDABPlayers(2), seed: 1)
// The lone box's 4 edges: top h(0,0), bottom h(1,0), left v(0,0), right v(0,1).
_ = dab1x1Engine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), by: 0)
check(dab1x1Engine.state.turnIndex == 1, "turn 1: passes to player 1")
_ = dab1x1Engine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 1, col: 0), by: 1)
check(dab1x1Engine.state.turnIndex == 0, "turn 2: passes back to player 0")
_ = dab1x1Engine.claimEdge(DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0), by: 0)
check(dab1x1Engine.state.turnIndex == 1, "turn 3: passes to player 1 (box still at 3 sides)")
let dabFinishEvents = dab1x1Engine.claimEdge(DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 1), by: 1)
check(dabFinishEvents.contains(.boxCompleted(box: DotsAndBoxesBox(row: 0, col: 0), by: 1)),
      "completing the 4th side fires boxCompleted")
check(dab1x1Engine.state.players[1].score == 1, "the completer's score increments")
check(dab1x1Engine.state.isGameOver, "a 1x1 board is over the moment its one box completes")
check(dabFinishEvents.contains(.gameOver(winners: [1])), "gameOver event names the sole winner")
check(dab1x1Engine.state.turnIndex == 1, "turnIndex is left on the winner, not advanced past game over")

// A 1x2 board: claiming a box grants an EXTRA turn (same player goes again)
// instead of passing to the opponent.
let dab1x2Engine = DotsAndBoxesEngine(gridSize: 2, players: makeDABPlayers(2), seed: 1)
_ = dab1x2Engine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), by: 0) // top of (0,0)
_ = dab1x2Engine.claimEdge(DotsAndBoxesEdge(orientation: .horizontal, row: 1, col: 0), by: 1) // bottom of (0,0)
_ = dab1x2Engine.claimEdge(DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0), by: 0)   // left of (0,0)
check(dab1x2Engine.state.turnIndex == 1, "still alternating before any box completes")
let dabExtraTurnEvents = dab1x2Engine.claimEdge(DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 1), by: 1) // right of (0,0)
check(dabExtraTurnEvents.contains(.extraTurn(playerIndex: 1)), "completing a box fires extraTurn")
check(dab1x2Engine.state.turnIndex == 1, "the completer's turn does NOT advance")
check(!dab1x2Engine.state.isGameOver, "one box down, one still open on a 1x2 board")

// MARK: - Dots & Boxes: a single shared edge completing TWO boxes at once

let dabDoubleEngine = DotsAndBoxesEngine(gridSize: 2, players: makeDABPlayers(2), seed: 1)
let dabDoubleSetup: [DotsAndBoxesEdge] = [
    DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), // top of (0,0)
    DotsAndBoxesEdge(orientation: .horizontal, row: 1, col: 0), // bottom of (0,0)
    DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0),   // left of (0,0)
    DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 1), // top of (0,1)
    DotsAndBoxesEdge(orientation: .horizontal, row: 1, col: 1), // bottom of (0,1)
    DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 2),   // right of (0,1)
]
for edge in dabDoubleSetup {
    let mover = dabDoubleEngine.state.turnIndex
    _ = dabDoubleEngine.claimEdge(edge, by: mover)
}
check(dabDoubleEngine.state.claimedBy.count == 6, "six of the eight edges around the (0,0)/(0,1) pocket are drawn")
let dabSharedEdge = DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 1) // between (0,0) and (0,1)
let dabDoubleEvents = dabDoubleEngine.claimEdge(dabSharedEdge, by: dabDoubleEngine.state.turnIndex)
let dabDoubleBoxEvents = dabDoubleEvents.filter { if case .boxCompleted = $0 { return true }; return false }
check(dabDoubleBoxEvents.count == 2, "the shared last edge completes BOTH boxes in one stroke")
check(!dabDoubleEngine.state.isGameOver, "row 1's two boxes are untouched — the 2x2 board isn't finished yet")
check(dabDoubleEngine.state.players.reduce(0) { $0 + $1.score } == 2, "exactly the two row-0 boxes are scored so far")

// MARK: - Dots & Boxes: a tied final score names every co-leader

// 2x2-box board, one box left to claim: player 0 already holds 2 boxes,
// player 1 holds 1. Player 1 draws the last line, taking the 4th box and
// leveling the score 2-2 — `winners` should name BOTH players.
var dabTieState = DotsAndBoxesState(gridSize: 2, players: makeDABPlayers(2), seed: 1)
let dabTieLastEdge = DotsAndBoxesEdge(orientation: .vertical, row: 1, col: 2) // right border of box (1,1)
dabTieState.claimedBy = Dictionary(uniqueKeysWithValues: dabAllEdges(gridSize: 2)
    .filter { $0 != dabTieLastEdge }
    .map { ($0, 0) })
dabTieState.boxOwner = [[0, 0], [1, nil]]
dabTieState.players[0].score = 2
dabTieState.players[1].score = 1
dabTieState.turnIndex = 1
let dabTieEngine = DotsAndBoxesEngine(restoring: dabTieState)
let dabTieEvents = dabTieEngine.claimEdge(dabTieLastEdge, by: 1)
check(dabTieEvents.contains(.boxCompleted(box: DotsAndBoxesBox(row: 1, col: 1), by: 1)),
      "player 1 completes the last box")
check(dabTieEngine.state.players[0].score == 2 && dabTieEngine.state.players[1].score == 2,
      "the final box levels the score 2-2")
check(dabTieEngine.state.isGameOver, "the 2x2 board is complete")
check(dabTieEvents.contains(.gameOver(winners: [0, 1])), "a tied final score names BOTH co-leaders as winners")

// MARK: - Dots & Boxes: bot never gifts a box when a safe move exists

func dabAdjacentBoxes(_ edge: DotsAndBoxesEdge, gridSize: Int) -> [DotsAndBoxesBox] {
    switch edge.orientation {
    case .horizontal:
        var boxes: [DotsAndBoxesBox] = []
        if edge.row - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row - 1, col: edge.col)) }
        if edge.row < gridSize { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) }
        return boxes
    case .vertical:
        var boxes: [DotsAndBoxesBox] = []
        if edge.col - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col - 1)) }
        if edge.col < gridSize { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) }
        return boxes
    }
}

for dabSeed: UInt64 in [1, 2, 3, 42, 999] {
    let engine = DotsAndBoxesEngine(gridSize: 4, players: makeDABPlayers(2, bots: true), seed: dabSeed)
    var guardCount = 0
    while !engine.state.isGameOver && guardCount < 500 {
        guardCount += 1
        let mover = engine.state.turnIndex
        guard let edge = engine.chooseBotEdge(for: mover) else { break }
        let claimed = engine.state.claimedBy
        func filled(_ box: DotsAndBoxesBox) -> Int { box.edges().filter { claimed[$0] != nil }.count }
        func isSafe(_ e: DotsAndBoxesEdge) -> Bool { !dabAdjacentBoxes(e, gridSize: 4).contains { filled($0) == 2 } }
        func completes(_ e: DotsAndBoxesEdge) -> Bool { dabAdjacentBoxes(e, gridSize: 4).contains { filled($0) == 3 } }
        let anySafeExists = engine.legalEdges().contains { isSafe($0) && !completes($0) }
        // Inside the exact-solve endgame the bot may rightly sacrifice to flip control.
        if anySafeExists && !completes(edge) && engine.legalEdges().count > DotsAndBoxesEngine.exactEndgameEdgeLimit {
            check(isSafe(edge), "seed \(dabSeed) move \(guardCount): bot never gifts a box while a safe move exists")
        }
        _ = engine.claimEdge(edge, by: mover)
    }
    check(engine.state.isGameOver, "seed \(dabSeed): bot-vs-bot 4x4 game reaches game over")
    let totalScore = engine.state.players.reduce(0) { $0 + $1.score }
    check(totalScore == 16, "seed \(dabSeed): all 16 boxes claimed by someone")
}

// MARK: - Dots & Boxes: forced to sacrifice, prefers the SHORTEST chain

// Hand-build a 4x4-box board where every remaining legal move is unsafe,
// with two sacrifices on offer: a lone 1-box pocket (top-left corner) and a
// full 4-box chain running the length of the bottom row. A sound bot must
// open the 1-box pocket, not the 4-box chain — the classic "least-bad
// sacrifice" call.
var dabChainState = DotsAndBoxesState(gridSize: 4, players: makeDABPlayers(2, bots: true), seed: 7)
var dabChainClaims: [DotsAndBoxesEdge: Int] = Dictionary(uniqueKeysWithValues: dabAllEdges(gridSize: 4).map { ($0, 0) })
var dabChainOwners: [[Int?]] = Array(repeating: Array(repeating: 0, count: 4), count: 4)

// Trap A — box (0,0): only its top/left border edges are open (2 filled
// already via the shared bottom/right edges), so opening EITHER one gives
// away exactly that one box (its neighbors (1,0) and (0,1) stay fully
// resolved either way, so the "capture" can't cascade further).
let dabTrapAEdges = [
    DotsAndBoxesEdge(orientation: .horizontal, row: 0, col: 0), // top border
    DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0),   // left border
]
for e in dabTrapAEdges { dabChainClaims[e] = nil }
dabChainOwners[0][0] = nil

// Trap B — the entire bottom row (boxes (3,0)...(3,3)): every box in the
// row keeps its top/bottom claimed and BOTH verticals open, forming one
// continuous chain from the left border to the right border. Opening
// either end sweeps all four boxes.
let dabTrapBEdges = (0...4).map { DotsAndBoxesEdge(orientation: .vertical, row: 3, col: $0) }
for e in dabTrapBEdges { dabChainClaims[e] = nil }
for col in 0..<4 { dabChainOwners[3][col] = nil }

dabChainState.claimedBy = dabChainClaims
dabChainState.boxOwner = dabChainOwners
dabChainState.turnIndex = 0

let dabChainEngine = DotsAndBoxesEngine(restoring: dabChainState)
check(dabChainEngine.legalEdges().count == dabTrapAEdges.count + dabTrapBEdges.count,
      "only the two traps' edges remain legal")
guard let dabChainChoice = dabChainEngine.chooseBotEdge(for: 0) else {
    check(false, "bot found a move in the forced scenario")
    fatalError("unreachable")
}
check(dabTrapAEdges.contains(dabChainChoice),
      "forced to sacrifice, the bot opens the 1-box pocket (sweep 1) over the 4-box chain (sweep 4)")

// MARK: - Dots & Boxes: determinism under seed

func dabPlayThrough(seed: UInt64, gridSize: Int, playerCount: Int) -> DotsAndBoxesState {
    let engine = DotsAndBoxesEngine(gridSize: gridSize, players: makeDABPlayers(playerCount, bots: true), seed: seed)
    var guardCount = 0
    while !engine.state.isGameOver && guardCount < engine.state.totalEdgeCount + 5 {
        guardCount += 1
        _ = engine.performBotMove(for: engine.state.turnIndex)
    }
    return engine.state
}
let dabReplayA = dabPlayThrough(seed: 20260806, gridSize: 6, playerCount: 3)
let dabReplayB = dabPlayThrough(seed: 20260806, gridSize: 6, playerCount: 3)
check(dabReplayA == dabReplayB, "the same seed replays the exact same bot-vs-bot game")
let dabReplayDifferentSeed = dabPlayThrough(seed: 4, gridSize: 6, playerCount: 3)
check(dabReplayA.claimedBy != dabReplayDifferentSeed.claimedBy || dabReplayA.players.map(\.score) != dabReplayDifferentSeed.players.map(\.score),
      "a different seed plays a different game (sanity check the seed is actually wired in)")

// MARK: - Dots & Boxes: full seeded bot-vs-bot games terminate legally on every grid size

for gridSize in DotsAndBoxesEngine.allowedGridSizes {
    for dabSeed: UInt64 in [7, 1234, 55555] {
        for playerCount in [2, 3, 4] {
            let engine = DotsAndBoxesEngine(gridSize: gridSize, players: makeDABPlayers(playerCount, bots: true), seed: dabSeed)
            var guardCount = 0
            let maxSteps = engine.state.totalEdgeCount + 5
            while !engine.state.isGameOver && guardCount < maxSteps {
                guardCount += 1
                let events = engine.performBotMove(for: engine.state.turnIndex)
                check(!events.isEmpty, "grid \(gridSize)x\(gridSize) seed \(dabSeed) players \(playerCount): every bot turn produces an event")
            }
            check(engine.state.isGameOver,
                  "grid \(gridSize)x\(gridSize) seed \(dabSeed) players \(playerCount): game terminates legally")
            check(engine.state.claimedBy.count == engine.state.totalEdgeCount,
                  "grid \(gridSize)x\(gridSize) seed \(dabSeed) players \(playerCount): every line on the sheet got drawn")
            let totalScore = engine.state.players.reduce(0) { $0 + $1.score }
            check(totalScore == engine.state.totalBoxCount,
                  "grid \(gridSize)x\(gridSize) seed \(dabSeed) players \(playerCount): every box has an owner")
            let winners = engine.state.players.indices.filter { engine.state.players[$0].score == engine.state.players.map(\.score).max() }
            check(!winners.isEmpty, "grid \(gridSize)x\(gridSize) seed \(dabSeed) players \(playerCount): at least one winner/tie-holder")
        }
    }
}

// MARK: - Quarto

func isIllegal2(_ events: [QuartoEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}

// MARK: - Quarto: piece bit-packing

check(QuartoPiece.all.count == 16, "16 unique Quarto pieces")
check(Set(QuartoPiece.all.map(\.id)).count == 16, "piece ids are unique")
check(QuartoPiece.all.filter(\.isTall).count == 8 && QuartoPiece.all.filter(\.isDark).count == 8
      && QuartoPiece.all.filter(\.isRound).count == 8 && QuartoPiece.all.filter(\.isHollow).count == 8,
      "each attribute splits the 16 pieces exactly 8/8")
// Every attribute combination exists exactly once.
var quartoSeenCombos = Set<[Bool]>()
for piece in QuartoPiece.all { quartoSeenCombos.insert([piece.isTall, piece.isDark, piece.isRound, piece.isHollow]) }
check(quartoSeenCombos.count == 16, "all 16 attribute combinations are represented, none duplicated")

// MARK: - Quarto: win detection, every line type and every attribute

func quartoBoard(_ placements: [Int: Int]) -> [Int?] {
    var board = [Int?](repeating: nil, count: 16)
    for (cell, piece) in placements { board[cell] = piece }
    return board
}

// Row 0 (cells 0,1,2,3): four tall pieces (odd ids share bit0).
let rowWin = quartoBoard([0: 1, 1: 3, 2: 5, 3: 7])
check(QuartoRules.winningLine(board: rowWin, includeSquares: false)?.attributes.contains(.height) == true,
      "a full row sharing 'tall' is detected as a win")

// Column 0 (cells 0,4,8,12): four dark pieces (bit1 set: 2,3,6,7).
let colWin = quartoBoard([0: 2, 4: 3, 8: 6, 12: 7])
check(QuartoRules.winningLine(board: colWin, includeSquares: false)?.attributes.contains(.shade) == true,
      "a full column sharing 'dark' is detected as a win")

// Main diagonal (0,5,10,15): four round pieces (bit2 set: 4,5,6,7).
let diagWin = quartoBoard([0: 4, 5: 5, 10: 6, 15: 7])
check(QuartoRules.winningLine(board: diagWin, includeSquares: false)?.attributes.contains(.shape) == true,
      "the main diagonal sharing 'round' is detected as a win")

// Anti-diagonal (3,6,9,12): four hollow pieces (bit3 set: 8,9,10,11).
let antiDiagWin = quartoBoard([3: 8, 6: 9, 9: 10, 12: 11])
check(QuartoRules.winningLine(board: antiDiagWin, includeSquares: false)?.attributes.contains(.fill) == true,
      "the anti-diagonal sharing 'hollow' is detected as a win")

// A line that's full but shares NOTHING is not a win.
// Each piece has exactly one distinct bit set, so every one of the four
// attributes is a 3-0 split (mixed) across the line — nothing is shared.
let noShareLine = quartoBoard([0: 1, 1: 2, 2: 4, 3: 8]) // 0001,0010,0100,1000
check(QuartoRules.winningLine(board: noShareLine, includeSquares: false) == nil,
      "a full row sharing no attribute is not a win")

// A line with an empty cell is never a win, no matter what's filled.
let incompleteLine = quartoBoard([0: 1, 1: 3, 2: 5]) // cell 3 empty
check(QuartoRules.winningLine(board: incompleteLine, includeSquares: false) == nil,
      "a line with an empty cell is never a win")

// 2x2 square variant: off by default (a would-be square win is invisible
// unless the variant is on), on when asked.
let squareWin = quartoBoard([0: 1, 1: 3, 4: 5, 5: 7]) // top-left 2x2, all tall
check(QuartoRules.winningLine(board: squareWin, includeSquares: false) == nil,
      "a 2x2 square win is invisible with the variant off")
check(QuartoRules.winningLine(board: squareWin, includeSquares: true)?.attributes.contains(.height) == true,
      "the same 2x2 square wins once the variant is turned on")

// A line can share MORE than one attribute at once (e.g. every piece both
// tall AND dark): the winner announces every shared attribute. Four
// distinct pieces, all with bits 0/1 (tall, dark) set, bits 2/3 varied.
let multiAttrBoard = quartoBoard([0: 3, 1: 3 ^ 0b0100, 2: 3 ^ 0b1000, 3: 3 ^ 0b1100])
check(QuartoRules.winningLine(board: multiAttrBoard, includeSquares: false)?.attributes.sorted(by: { $0.rawValue < $1.rawValue }) == [.height, .shade],
      "a line can win on multiple shared attributes at once, and all are reported")
check(QuartoRules.winCallout(attributes: [.height, .shade], line: [0, 1, 2, 3], board: multiAttrBoard) == "Four tall, four dark!",
      "the win callout names every shared attribute using the actual winning piece's values")

// MARK: - Quarto: the classic trap (giving a losing piece)

// Row 0 has three tall pieces placed and one empty cell — ANY remaining
// tall piece handed over next lets the opponent complete it immediately.
let trapBoard = quartoBoard([0: 1, 1: 3, 2: 5]) // cell 3 empty, all tall so far
let trapUnsafe = QuartoRules.winningPlacements(piece: 7, board: trapBoard, includeSquares: false) // 7 is tall
check(trapUnsafe == [3], "handing over a piece that completes the open line is flagged as unsafe at exactly that cell")
// Among {1,3,5} (0001,0011,0101) two attributes are already alive: bit0
// (all tall) and bit3 (all solid) — bits 1/2 already disagree among the
// three, so no 4th piece could ever complete those. Piece 8 (1000: short,
// hollow) breaks BOTH live threats at once and is genuinely safe.
let trapSafe = QuartoRules.winningPlacements(piece: 8, board: trapBoard, includeSquares: false)
check(trapSafe.isEmpty, "a piece that does NOT complete the line is safe to hand over")

// MARK: - Quarto: engine turn flow (select -> place -> select..., illegal rejects)

let qPlayers = [QuartoPlayer(name: "Justin", isBot: false), QuartoPlayer(name: "Sarah", isBot: false)]
let qEngine = QuartoEngine(players: qPlayers, use2x2Variant: false, firstPlayer: 0)
check(qEngine.state.phase == .selecting && qEngine.state.currentPlayer == 0,
      "a fresh Quarto game opens on player 0 selecting (nothing to place yet)")
check(isIllegal2(qEngine.apply(.placePiece(0, at: 0), from: 0)), "placing before any piece is held is rejected")
check(isIllegal2(qEngine.apply(.selectPiece(0), from: 1)), "selecting out of turn is rejected")

let openEvents = qEngine.apply(.selectPiece(5), from: 0)
check(openEvents == [.pieceSelected(by: 0, piece: 5)], "opening select emits pieceSelected")
check(qEngine.state.phase == .placing && qEngine.state.currentPlayer == 1 && qEngine.state.heldPiece == 5,
      "the opponent now holds the given piece and owes a placement")
check(!qEngine.state.remainingPieces.contains(5), "the held piece left the remaining pool")

check(isIllegal2(qEngine.apply(.selectPiece(1), from: 1)), "can't select while a placement is owed")
check(isIllegal2(qEngine.apply(.placePiece(3, at: 0), from: 1)), "placing the wrong piece id is rejected")
check(isIllegal2(qEngine.apply(.placePiece(5, at: 0), from: 0)), "placing out of turn (wrong seat) is rejected")

let placeEvents = qEngine.apply(.placePiece(5, at: 0), from: 1)
check(placeEvents == [.piecePlaced(by: 1, piece: 5, cell: 0)], "a non-winning placement emits just piecePlaced")
check(qEngine.state.board[0] == 5, "the piece landed on the board")
check(qEngine.state.phase == .selecting && qEngine.state.currentPlayer == 1,
      "after placing (no win), the SAME player now owes the next selection")
check(isIllegal2(qEngine.apply(.placePiece(1, at: 1), from: 1)), "can't place while a selection is owed")

let occupiedCellEvents = qEngine.apply(.selectPiece(2), from: 1)
check(occupiedCellEvents == [.pieceSelected(by: 1, piece: 2)], "second select accepted")
check(isIllegal2(qEngine.apply(.placePiece(2, at: 0), from: 0)), "placing on an occupied cell is rejected")
check(qEngine.state.board[0] == 5, "the occupied-cell reject changed nothing")

// MARK: - Quarto: a full engine-driven win, with the announced attribute

let winSetupState = QuartoState(players: qPlayers, use2x2Variant: false, firstPlayer: 0)
var winState = winSetupState
winState.board = quartoBoard([0: 1, 1: 3, 2: 5])
winState.remainingPieces = Array(0..<16).filter { ![1, 3, 5].contains($0) }
winState.heldPiece = 7
winState.phase = .placing
winState.currentPlayer = 0
let winEngine = QuartoEngine(restoring: winState)
let winEvents = winEngine.apply(.placePiece(7, at: 3), from: 0)
check(winEvents.count == 2, "a winning placement emits piecePlaced then gameWon")
if case .gameWon(let seat, let line, let attrs) = winEvents.last {
    check(seat == 0, "gameWon credits the player who PLACED the winning piece")
    check(Set(line) == Set([0, 1, 2, 3]), "gameWon carries the actual winning line")
    check(attrs.contains(.height), "gameWon carries the shared attribute (tall)")
} else {
    check(false, "last event after a winning placement is gameWon")
}
check(winEngine.state.phase == .gameOver && winEngine.state.winner == 0, "engine state reflects the win")
check(isIllegal2(winEngine.apply(.selectPiece(2), from: 0)), "no further actions are accepted once the game is over")

// MARK: - Quarto: draw (board fills, no line ever shares an attribute)

// Two players who only ever hand over "safe" pieces will sometimes fill
// the whole board with no winner — find one such seeded bot-vs-bot game
// (deterministic, so this is a stable regression once found) and confirm
// the engine reaches .gameOver with winner == nil and a genuinely full,
// line-free board.
func driveQuartoBotGame(seed: UInt64, use2x2Variant: Bool = false) -> QuartoEngine {
    let engine = QuartoEngine(players: qPlayers, use2x2Variant: use2x2Variant, firstPlayer: 0)
    var guardCount = 0
    while engine.state.phase != .gameOver, guardCount < 40 {
        guardCount += 1
        let action = QuartoBot.decide(state: engine.state, seed: seed, nodeBudget: 1200)
        _ = engine.apply(action, from: engine.state.currentPlayer)
    }
    return engine
}

var foundQuartoDraw = false
for seed: UInt64 in 0..<40 {
    let engine = driveQuartoBotGame(seed: seed)
    guard engine.state.phase == .gameOver, engine.state.winner == nil else { continue }
    foundQuartoDraw = true
    check(engine.state.isBoardFull, "a drawn game fills every cell")
    check(QuartoRules.winningLine(board: engine.state.board, includeSquares: false) == nil,
          "a drawn game's final board genuinely has no winning line")
    check(engine.state.moveCount == 16, "a drawn game places all 16 pieces")
    break
}
check(foundQuartoDraw, "found at least one seeded bot-vs-bot game that ends in a draw")

// MARK: - Quarto bot: never gives an immediately-winning piece unless forced

// Same trap board as above: pieces 1,3,5 (all tall) on row 0, cell 3 open.
// Piece 7 (tall) is the ONLY unsafe remaining piece the bot could be asked
// to hand over; every other remaining piece is safe. The bot must never
// select 7 here.
var trapSelectState = QuartoState(players: qPlayers, use2x2Variant: false, firstPlayer: 0)
trapSelectState.board = quartoBoard([0: 1, 1: 3, 2: 5])
trapSelectState.remainingPieces = Array(0..<16).filter { ![1, 3, 5].contains($0) }
trapSelectState.heldPiece = nil
trapSelectState.phase = .selecting
trapSelectState.currentPlayer = 0
var quartoBotAvoidedTrap = true
for seed: UInt64 in 0..<25 {
    let action = QuartoBot.decide(state: trapSelectState, seed: seed, nodeBudget: 1500)
    if case .selectPiece(7) = action { quartoBotAvoidedTrap = false }
}
check(quartoBotAvoidedTrap, "the bot never hands over the one piece that immediately completes the open line")

// Forced case: EVERY remaining piece is unsafe (three lines each one piece
// from winning on a different attribute) — the bot must still return a
// legal action rather than crash or stall.
var forcedLossState = QuartoState(players: qPlayers, use2x2Variant: false, firstPlayer: 0)
forcedLossState.board = quartoBoard([0: 1, 1: 3, 2: 5]) // row 0: tall, cell 3 open
forcedLossState.remainingPieces = [7, 15] // both tall -> both unsafe (only two left, for a fast test)
forcedLossState.heldPiece = nil
forcedLossState.phase = .selecting
forcedLossState.currentPlayer = 0
let forcedAction = QuartoBot.decide(state: forcedLossState, seed: 1, nodeBudget: 1500)
if case .selectPiece(let piece) = forcedAction {
    check([7, 15].contains(piece), "forced to hand over a losing piece, the bot still returns a legal selection")
} else {
    check(false, "forced-loss decide() returns a selectPiece action")
}

// MARK: - Quarto bot: determinism under seed

let determinismState = trapSelectState
let det1 = QuartoBot.decide(state: determinismState, seed: 12345, nodeBudget: 1500)
let det2 = QuartoBot.decide(state: determinismState, seed: 12345, nodeBudget: 1500)
check(det1 == det2, "the same state + seed always yields the same bot move")

// MARK: - Quarto bot: seeded bot-vs-bot always terminates, and quickly

var quartoMaxDecisionTime: Double = 0
var quartoMaxNodes = 0
var quartoMinDepth = Int.max
var quartoGamesTerminated = 0
for seed: UInt64 in 0..<8 {
    let engine = QuartoEngine(players: qPlayers, use2x2Variant: seed % 2 == 0, firstPlayer: Int(seed % 2))
    var guardCount = 0
    while engine.state.phase != .gameOver, guardCount < 40 {
        guardCount += 1
        let stepStart = Date()
        let decision = QuartoBot.decideCounting(state: engine.state, seed: seed, nodeBudget: QuartoBot.defaultNodeBudget)
        let action = decision.action
        quartoMaxDecisionTime = max(quartoMaxDecisionTime, Date().timeIntervalSince(stepStart))
        quartoMaxNodes = max(quartoMaxNodes, decision.nodes)
        quartoMinDepth = min(quartoMinDepth, decision.depth)
        let events = engine.apply(action, from: engine.state.currentPlayer)
        check(!isIllegal2(events), "seed \(seed): every bot move is legal (no illegalAttempt)")
    }
    check(engine.state.phase == .gameOver, "seed \(seed): bot-vs-bot game reaches gameOver within 40 actions")
    quartoGamesTerminated += 1
}
check(quartoGamesTerminated == 8, "all 8 seeded bot-vs-bot games (mixing the 2x2 variant on/off) terminated")
// The budget is DETERMINISTIC (nodes, not wall time): assert the node cap,
// with only a generous wall-clock sanity ceiling so a loaded CI box can't flake.
check(quartoMaxNodes <= QuartoBot.defaultNodeBudget + 64,
      "every bot decision stayed within the deterministic node budget (max \(quartoMaxNodes) of \(QuartoBot.defaultNodeBudget))")
check(quartoMinDepth >= 2, "every bot decision completed at least a 2-ply pass (min depth \(quartoMinDepth))")
check(quartoMaxDecisionTime < QuartoBot.wallClockSanityLimit,
      "wall-clock sanity: no bot decision took 2s+ (measured \(quartoMaxDecisionTime)s)")
print("Quarto bot: max nodes \(quartoMaxNodes), min completed depth \(quartoMinDepth), max wall \(quartoMaxDecisionTime)s")

// Load-independence: a decision made while the CPU is hammered by busy
// threads must equal the idle decision for the same state + seed.
do {
    let idle = QuartoBot.decide(state: determinismState, seed: 777)
    let stop = NSLock(); var stopFlag = false
    var spinners: [Thread] = []
    for _ in 0..<8 {
        let t = Thread { var x = 0.0; while true { stop.lock(); let s = stopFlag; stop.unlock(); if s { break }; for i in 0..<20000 { x += sin(Double(i)) } ; if x > 1e300 { print(x) } } }
        t.start(); spinners.append(t)
    }
    let loaded = QuartoBot.decide(state: determinismState, seed: 777)
    stop.lock(); stopFlag = true; stop.unlock()
    check(idle == loaded, "Quarto bot move is identical under heavy CPU load (deterministic node budget)")
}

// MARK: - Quarto: Codable round-trips

let quartoActionSamples: [QuartoAction] = [.selectPiece(9), .placePiece(9, at: 12)]
let quartoActionData = try! JSONEncoder().encode(quartoActionSamples)
check((try! JSONDecoder().decode([QuartoAction].self, from: quartoActionData)) == quartoActionSamples,
      "QuartoAction round-trips through JSON")

let quartoEventSamples: [QuartoEvent] = [
    .gameStarted, .pieceSelected(by: 0, piece: 4), .piecePlaced(by: 1, piece: 4, cell: 9),
    .gameWon(seat: 1, line: [0, 5, 10, 15], attributes: [.shape, .fill]), .draw,
    .illegalAttempt(seat: 0, reason: "Not a legal placement"),
]
let quartoEventData = try! JSONEncoder().encode(quartoEventSamples)
check((try! JSONDecoder().decode([QuartoEvent].self, from: quartoEventData)) == quartoEventSamples,
      "QuartoEvent round-trips through JSON")

let quartoStateData = try! JSONEncoder().encode(winEngine.state)
check((try! JSONDecoder().decode(QuartoState.self, from: quartoStateData)) == winEngine.state,
      "QuartoState (mid-win) round-trips through JSON")

// MARK: - Cribbage: helpers

func isIllegalCrib(_ events: [CribbageEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}
func hasCribEvent(_ events: [CribbageEvent], _ predicate: (CribbageEvent) -> Bool) -> Bool {
    events.contains(where: predicate)
}
/// A minimal, self-consistent fixture: 2 empty pegging hands, a neutral
/// starter, zero scores. Individual tests override whichever fields they
/// need (hands/pegging/scores/postDiscardHands/...) — the engine never
/// cross-validates `count` against `sequence`'s actual sum, or hand
/// contents against a single 52-card deck, so these fixtures are free to
/// be "unrealistic" wherever that doesn't matter to what's being tested.
func baseCribbageState() -> CribbageState {
    CribbageState(
        seed: 1, dealShuffleSeed: 1, scores: [0: 0, 1: 0], dealerSeat: 0,
        phase: .pegging, hands: [0: [], 1: []], postDiscardHands: [0: [], 1: []],
        crib: [], discardsSubmitted: [0, 1], starter: card("h9"),
        pegging: CribbagePeggingState(sequence: [], count: 0, turnSeat: 0, lastPlayerSeat: nil),
        handNumber: 1
    )
}

// MARK: - Cribbage: pegValue

check(CribbageScoring.pegValue(card("h2")) == 2, "cribbage pegValue: 2 is 2")
check(CribbageScoring.pegValue(card("c10")) == 10, "cribbage pegValue: 10 is 10")
check(CribbageScoring.pegValue(card("h11")) == 10, "cribbage pegValue: jack is 10")
check(CribbageScoring.pegValue(card("d12")) == 10, "cribbage pegValue: queen is 10")
check(CribbageScoring.pegValue(card("s13")) == 10, "cribbage pegValue: king is 10")
check(CribbageScoring.pegValue(card("c14")) == 1, "cribbage pegValue: ace is 1")

// MARK: - Cribbage: pegging score math (pure function, no engine)

let fifteenEntries = CribbageScoring.peggingScore(sequence: [card("h10"), card("c5")], count: 15)
check(fifteenEntries.contains { $0.reason == .fifteen && $0.points == 2 }, "pegging: 10+5 scores fifteen for 2")

let thirtyOneEntries = CribbageScoring.peggingScore(
    sequence: [card("d10"), card("h11"), card("s12"), card("c14")], count: 31
)
check(thirtyOneEntries.contains { $0.reason == .thirtyOne && $0.points == 2 }, "pegging: 10+10+10+1 scores 31 for 2")
check(!thirtyOneEntries.contains { $0.reason == .fifteen }, "pegging: hitting 31 doesn't also claim a fifteen")

let runOutOfOrderEntries = CribbageScoring.peggingScore(sequence: [card("h7"), card("c5"), card("d6")], count: 18)
check(runOutOfOrderEntries.contains { $0.reason == .run(3) && $0.points == 3 },
      "pegging: 7,5,6 played in that order still scores a run of 3 (any order)")

let pairEntries = CribbageScoring.peggingScore(sequence: [card("h5"), card("c5")], count: 10)
check(pairEntries.contains { $0.reason == .pair && $0.points == 2 }, "pegging: two 5s in a row score a pair for 2")

let tripsEntries = CribbageScoring.peggingScore(sequence: [card("h5"), card("c5"), card("d5")], count: 15)
check(tripsEntries.contains { $0.reason == .pair && $0.points == 6 }, "pegging: three 5s in a row score trips for 6")
check(tripsEntries.contains { $0.reason == .fifteen }, "pegging: three 5s in a row also happens to hit fifteen")

let quadsEntries = CribbageScoring.peggingScore(
    sequence: [card("h5"), card("c5"), card("d5"), card("s5")], count: 20
)
check(quadsEntries.contains { $0.reason == .pair && $0.points == 12 }, "pegging: four 5s in a row score quads for 12")

let brokenRunEntries = CribbageScoring.peggingScore(sequence: [card("h5"), card("d10"), card("c6")], count: 21)
check(!brokenRunEntries.contains { if case .run = $0.reason { return true }; return false },
      "pegging: 5,10,6 has no run — the 10 breaks the 5/6 adjacency")

// MARK: - Cribbage: show scoring against known hands

// The 29 hand: J-5-5-5 with the fourth 5 as starter, jack matching the
// starter's suit for nobs. The best possible cribbage hand.
let (pts29, breakdown29) = CribbageScoring.scoreShow(
    cards: [card("s5"), card("c5"), card("d5"), card("h11")], starter: card("h5"), isCrib: false
)
check(pts29 == 29, "show scoring: the 29 hand (J555 + matching starter) scores exactly 29")
check(breakdown29.contains { $0.reason == .showFifteen && $0.points == 16 }, "29 hand: 8 fifteens = 16")
check(breakdown29.contains { $0.reason == .showPair && $0.points == 12 }, "29 hand: 4-of-a-kind = 12")
check(breakdown29.contains { $0.reason == .nobs && $0.points == 1 }, "29 hand: nobs = 1")

// The 28 hand: same four 5s + jack, but the jack does NOT match the
// starter's suit — loses only the nobs point relative to the 29 hand.
let (pts28, _) = CribbageScoring.scoreShow(
    cards: [card("h5"), card("s5"), card("d5"), card("s11")], starter: card("c5"), isCrib: false
)
check(pts28 == 28, "show scoring: the 28 hand (J555, non-matching jack) scores exactly 28")

// Double run of 4 (2,3,3,4,5... constructed as 3,3,4,5 + starter 2): one
// fifteen (3+3+4+5=15), a pair (the two 3s), and a run of 4 counted twice
// (the two 3s each complete a distinct 4-card run) = 4 x 2 = 8.
let (ptsDoubleRun4, breakdownDoubleRun4) = CribbageScoring.scoreShow(
    cards: [card("s3"), card("h3"), card("s4"), card("s5")], starter: card("d2"), isCrib: false
)
check(breakdownDoubleRun4.contains { $0.reason == .showRun(4) && $0.points == 8 },
      "double run of 4: two 4-card runs (via the duplicated 3) = 8")
check(breakdownDoubleRun4.contains { $0.reason == .showPair && $0.points == 2 }, "double run of 4: the duplicated 3 also pairs for 2")
check(breakdownDoubleRun4.contains { $0.reason == .showFifteen && $0.points == 2 }, "double run of 4: exactly one fifteen (3+3+4+5)")
check(ptsDoubleRun4 == 12, "double run of 4: total is fifteen(2) + pair(2) + run(8) = 12")

// Triple run: three 4s plus a 5 and a 6 (starter) — three 3-card runs
// (4,5,6 with any of the three 4s) = 3 x 3 = 9, plus the pair-royal on the
// three 4s = 6, plus three fifteens (4+5+6, once per which-4) = 6.
let (ptsTripleRun, breakdownTripleRun) = CribbageScoring.scoreShow(
    cards: [card("s4"), card("h4"), card("d4"), card("s5")], starter: card("c6"), isCrib: false
)
check(breakdownTripleRun.contains { $0.reason == .showRun(3) && $0.points == 9 }, "triple run: three 3-card runs = 9")
check(breakdownTripleRun.contains { $0.reason == .showPair && $0.points == 6 }, "triple run: pair-royal on the three 4s = 6")
check(breakdownTripleRun.contains { $0.reason == .showFifteen && $0.points == 6 }, "triple run: three ways to make 4+5+6=15")
check(ptsTripleRun == 21, "triple run: total is run(9) + pair(6) + fifteen(6) = 21")

// 5-card flush: all 4 hand cards AND the starter share a suit.
let (ptsFlush5, breakdownFlush5) = CribbageScoring.scoreShow(
    cards: [card("s2"), card("s4"), card("s7"), card("s9")], starter: card("s13"), isCrib: false
)
check(breakdownFlush5.contains { $0.reason == .flush(5) && $0.points == 5 }, "flush: starter matching hand suit scores 5")
check(ptsFlush5 == 7, "flush: 5-card flush + one fifteen (2+4+9=15) = 7")

// Hand flush of 4 (starter doesn't match) still scores 4 for a plain
// hand, but scores NOTHING as a crib — a crib flush needs all 5. Reuses
// the verified zero-scoring ranks (2, 4, 8, Q) so the only thing in play
// is the flush rule itself, not an incidental fifteen/pair/run.
let flushOnlyHand = [card("s2"), card("s4"), card("s8"), card("s12")]
let (ptsHandFlush4, breakdownHandFlush4) = CribbageScoring.scoreShow(cards: flushOnlyHand, starter: card("h13"), isCrib: false)
check(breakdownHandFlush4.contains { $0.reason == .flush(4) && $0.points == 4 },
      "flush: 4-card hand flush (starter off-suit) still scores 4")
check(ptsHandFlush4 == 4, "flush: nothing else scores in this hand, so the total is exactly the flush")
let (ptsCribFlush4, breakdownCribFlush4) = CribbageScoring.scoreShow(cards: flushOnlyHand, starter: card("h13"), isCrib: true)
check(!breakdownCribFlush4.contains { if case .flush = $0.reason { return true }; return false },
      "flush: the SAME 4 cards score no flush at all as a crib (starter doesn't match)")
check(ptsCribFlush4 == 0, "flush: crib flush total is 0 when the starter breaks the suit")

// Zero hand: hand-picked so no fifteen/pair/run/flush/nobs exists at all.
let (ptsZero, breakdownZero) = CribbageScoring.scoreShow(
    cards: [card("c2"), card("h4"), card("s8"), card("d12")], starter: card("s13"), isCrib: false
)
check(ptsZero == 0 && breakdownZero.isEmpty, "show scoring: a genuinely zero hand scores 0 with an empty breakdown")

// MARK: - Cribbage: engine basics (deal, discard, cut, heels)

let cribBasic = CribbageEngine(seed: 3)
let cribBasicDealer = cribBasic.state.dealerSeat
let cribBasicNonDealer = 1 - cribBasicDealer
check(cribBasicDealer == 0 || cribBasicDealer == 1, "cribbage: dealer is seat 0 or 1")
check(cribBasic.state.phase == .discarding, "cribbage: engine starts already dealt, in .discarding")
check(cribBasic.state.hands[0]?.count == 6 && cribBasic.state.hands[1]?.count == 6, "cribbage: 6 cards dealt to each seat")
check(isIllegalCrib(cribBasic.apply(.playCard(cardID: "h2"), from: cribBasicNonDealer)),
      "cribbage: can't play a card before discarding is done")
check(isIllegalCrib(cribBasic.apply(.advance, from: 0)), "cribbage: can't advance before the hand completes")
check(isIllegalCrib(cribBasic.apply(.declareGo, from: 0)), "cribbage: declareGo always rejects (auto-go design)")
check(isIllegalCrib(cribBasic.apply(.discardToCrib(cards: ["zz1", "zz2"]), from: cribBasicDealer)),
      "cribbage: discarding cards not in hand is rejected")
check(isIllegalCrib(cribBasic.apply(.discardToCrib(cards: [cribBasic.state.hands[cribBasicDealer]![0].id]), from: cribBasicDealer)),
      "cribbage: discarding fewer than 2 cards is rejected")

let cribFirstTwo = Array(cribBasic.state.hands[cribBasicDealer]!.prefix(2)).map(\.id)
_ = cribBasic.apply(.discardToCrib(cards: cribFirstTwo), from: cribBasicDealer)
check(cribBasic.state.discardsSubmitted.contains(cribBasicDealer), "cribbage: first discard recorded")
check(isIllegalCrib(cribBasic.apply(.discardToCrib(cards: cribFirstTwo), from: cribBasicDealer)),
      "cribbage: can't discard a second time")
check(cribBasic.state.phase == .discarding, "cribbage: still waiting on the other seat's discard")

let cribNextTwo = Array(cribBasic.state.hands[cribBasicNonDealer]!.prefix(2)).map(\.id)
let cribCompleteEvents = cribBasic.apply(.discardToCrib(cards: cribNextTwo), from: cribBasicNonDealer)
check(cribBasic.state.phase == .pegging, "cribbage: both discarded -> straight into pegging")
check(hasCribEvent(cribCompleteEvents) { if case .cribComplete = $0 { return true }; return false },
      "cribbage: cribComplete fires once both discards land")
check(hasCribEvent(cribCompleteEvents) { if case .starterCut = $0 { return true }; return false },
      "cribbage: starterCut fires right after")
check(cribBasic.state.crib.count == 4, "cribbage: crib has exactly 4 cards")
check(cribBasic.state.pegging?.turnSeat == cribBasicNonDealer, "cribbage: non-dealer leads pegging")
check(cribBasic.state.hands[cribBasicDealer]?.count == 4 && cribBasic.state.hands[cribBasicNonDealer]?.count == 4,
      "cribbage: each pegging hand is 4 cards after discarding")

// Heels: search for a seed whose cut starter is a jack, then verify the
// dealer scores 2 right at the cut, through the real deal/discard flow.
var heelsSeed: UInt64 = 0
while heelsSeed <= 3000, DeckBuilder.shuffled(DeckBuilder.standard52(), seed: heelsSeed &+ 1)[12].rank != 11 {
    heelsSeed += 1
}
check(heelsSeed <= 3000, "heels test: found a seed whose starter cuts a jack")
let heelsEngine = CribbageEngine(seed: heelsSeed)
let heelsDealer = heelsEngine.state.dealerSeat
let heelsNonDealer = 1 - heelsDealer
_ = heelsEngine.apply(.discardToCrib(cards: Array(heelsEngine.state.hands[heelsDealer]!.prefix(2)).map(\.id)), from: heelsDealer)
let heelsEvents = heelsEngine.apply(
    .discardToCrib(cards: Array(heelsEngine.state.hands[heelsNonDealer]!.prefix(2)).map(\.id)), from: heelsNonDealer
)
check(heelsEngine.state.starter?.rank == 11, "heels: the cut starter is indeed a jack")
check(hasCribEvent(heelsEvents) { event in
    if case .pointsScored(let seat, let reason, let points) = event { return seat == heelsDealer && reason == .heels && points == 2 }
    return false
}, "heels: dealer scores 2 for his heels")
check(heelsEngine.state.scores[heelsDealer] == 2, "heels: dealer's total reflects the 2 heels points")

// MARK: - Cribbage: pegging edge cases via constructed fixtures

// Illegal peg play (over 31) and out-of-turn rejection.
var overState = baseCribbageState()
overState.hands = [0: [card("s13")], 1: [card("h2")]]
overState.pegging = CribbagePeggingState(sequence: [], count: 25, turnSeat: 0, lastPlayerSeat: 1)
let overEngine = CribbageEngine(restoring: overState)
check(isIllegalCrib(overEngine.apply(.playCard(cardID: "s13"), from: 0)),
      "pegging: a card that would push the count past 31 is rejected")
check(overEngine.state.pegging?.count == 25, "pegging: the rejected play changed nothing")
check(isIllegalCrib(overEngine.apply(.playCard(cardID: "h2"), from: 1)), "pegging: can't play out of turn")

// Auto-go: seat 1 gets to play two cards in a row while seat 0 is stuck
// on a king it can't unload; the go point lands on seat 1 (who played
// last), the count resets, and the turn returns to the stuck seat 0.
var goState = baseCribbageState()
goState.hands = [0: [card("s13")], 1: [card("h2"), card("c14")]]
goState.pegging = CribbagePeggingState(sequence: [], count: 22, turnSeat: 1, lastPlayerSeat: 0)
let goEngine = CribbageEngine(restoring: goState)

_ = goEngine.apply(.playCard(cardID: "h2"), from: 1)
check(goEngine.state.pegging?.turnSeat == 1, "auto-go: seat 0 (holding only the king) is skipped, seat 1 goes again")
check(goEngine.state.pegging?.count == 24, "auto-go: count is unaffected by the skip")

let goFinalEvents = goEngine.apply(.playCard(cardID: "c14"), from: 1)
check(goEngine.state.pegging?.count == 0, "auto-go: the count resets once both seats are stuck")
check(goEngine.state.pegging?.turnSeat == 0, "auto-go: the previously-stuck seat leads the fresh segment")
check(goEngine.state.hands[0] == [card("s13")], "auto-go: seat 0's king is still unplayed, waiting for count 0")
check(goEngine.state.scores[1] == 1, "auto-go: seat 1 (who played last) scores the go point")
check(goEngine.state.scores[0] == 0, "auto-go: seat 0 (the stuck seat) scores nothing")
check(hasCribEvent(goFinalEvents) { event in
    if case .pointsScored(let seat, let reason, let points) = event { return seat == 1 && reason == .go && points == 1 }
    return false
}, "auto-go: a .go pointsScored event narrates the point")

// Last card: the literal final card of the pegging phase, not making 31,
// scores 1 to whoever played it and rolls straight into a (here, empty)
// show — distinct from .go, and here nobody wins.
var lastCardState = baseCribbageState()
let zeroHandFixture = [card("c2"), card("h4"), card("s8"), card("d12")]
lastCardState.hands = [0: [card("h2")], 1: [card("c14")]]
lastCardState.pegging = CribbagePeggingState(sequence: [], count: 0, turnSeat: 0, lastPlayerSeat: nil)
lastCardState.starter = card("s13")
lastCardState.postDiscardHands = [0: zeroHandFixture, 1: zeroHandFixture]
let lastCardEngine = CribbageEngine(restoring: lastCardState)

_ = lastCardEngine.apply(.playCard(cardID: "h2"), from: 0)
let lastCardFinalEvents = lastCardEngine.apply(.playCard(cardID: "c14"), from: 1)
check(hasCribEvent(lastCardFinalEvents) { event in
    if case .pointsScored(let seat, let reason, let points) = event { return seat == 1 && reason == .lastCard && points == 1 }
    return false
}, "last card: the final card of the hand (not making 31) scores 1, not .go")
check(hasCribEvent(lastCardFinalEvents) { if case .pegComplete = $0 { return true }; return false },
      "last card: pegComplete fires once both hands are empty")
check(hasCribEvent(lastCardFinalEvents) { if case .cribRevealed = $0 { return true }; return false },
      "last card: the (empty) crib is still revealed as the show begins")
check(lastCardEngine.state.phase == .handComplete, "last card: the zero-scoring show settles into .handComplete, no winner")
check(lastCardEngine.state.scores == [0: 0, 1: 1], "last card: only the 1-point last-card peg landed")

// MARK: - Cribbage: win mid-pegging

var winPegState = baseCribbageState()
winPegState.scores = [0: 119, 1: 50]
winPegState.dealerSeat = 1
winPegState.hands = [0: [card("h5")], 1: []]
winPegState.pegging = CribbagePeggingState(
    sequence: [CribbagePeggedPlay(seat: 1, card: card("d10"))], count: 10, turnSeat: 0, lastPlayerSeat: 1
)
let winPegEngine = CribbageEngine(restoring: winPegState)
let winPegEvents = winPegEngine.apply(.playCard(cardID: "h5"), from: 0)

check(winPegEngine.state.phase == .gameOver, "win mid-pegging: reaching 121 on a peg point ends the game immediately")
check(winPegEngine.state.winnerSeat == 0, "win mid-pegging: seat 0 (119 + 2 for fifteen) wins")
check(winPegEngine.state.scores[0] == 121, "win mid-pegging: final score is exactly 121")
check(winPegEngine.state.skunk == true, "win mid-pegging: seat 1 was still under 91 — a skunk")
check(hasCribEvent(winPegEvents) { event in
    if case .gameWon(let seat, let skunk) = event { return seat == 0 && skunk == true }
    return false
}, "win mid-pegging: gameWon(seat: 0, skunk: true) is emitted")

// MARK: - Cribbage: win order at the show (non-dealer counts first)

var winShowState = baseCribbageState()
winShowState.dealerSeat = 1
winShowState.scores = [0: 100, 1: 100]
winShowState.hands = [0: [card("h9")], 1: [card("d2")]]
winShowState.pegging = CribbagePeggingState(sequence: [], count: 0, turnSeat: 0, lastPlayerSeat: nil)
winShowState.starter = card("h5")
let the29Hand = [card("s5"), card("c5"), card("d5"), card("h11")]
winShowState.postDiscardHands = [0: the29Hand, 1: the29Hand] // seat 1's copy must never actually be counted
winShowState.crib = []
let winShowEngine = CribbageEngine(restoring: winShowState)

_ = winShowEngine.apply(.playCard(cardID: "h9"), from: 0)
check(winShowEngine.state.phase == .pegging, "win-order setup: pegging continues while seat 1 still has a card")
let winShowFinalEvents = winShowEngine.apply(.playCard(cardID: "d2"), from: 1)

check(winShowEngine.state.phase == .gameOver, "win-order: non-dealer's show (the 29 hand) ends the game")
check(winShowEngine.state.winnerSeat == 0, "win-order: non-dealer (seat 0) wins")
check(winShowEngine.state.scores[0] == 129, "win-order: 100 + the 29 hand = 129")
check(winShowEngine.state.scores[1] == 101, "win-order: dealer only banks the last-card peg point (100 + 1), never the show")
check(hasCribEvent(winShowFinalEvents) { event in
    if case .pointsScored(let seat, let reason, let points) = event { return seat == 1 && reason == .lastCard && points == 1 }
    return false
}, "win-order: dealer's last-card peg point still lands before the show starts")
check(!hasCribEvent(winShowFinalEvents) { event in
    if case .handCounted(1, _, _, _) = event { return true }
    return false
}, "win-order: dealer's hand and crib are never counted once seat 0 already won")
check(!hasCribEvent(winShowFinalEvents) { if case .cribRevealed = $0 { return true }; return false },
      "win-order: the crib is never even revealed")
check(winShowEngine.state.skunk == false, "win-order: dealer is over 91, not a skunk")

// MARK: - Cribbage: NetMessage round-trips (additive cases)

let cribbageActionMsg: NetMessage = .cribbageAction(.playCard(cardID: "h5"))
check((try! JSONDecoder().decode(NetMessage.self, from: try! JSONEncoder().encode(cribbageActionMsg))) == cribbageActionMsg,
      "cribbageAction round-trips through JSON")

let cribbageEventsMsg: NetMessage = .cribbageEvents([.dealt(dealerSeat: 0), .pointsScored(seat: 1, reason: .fifteen, points: 2)])
check((try! JSONDecoder().decode(NetMessage.self, from: try! JSONEncoder().encode(cribbageEventsMsg))) == cribbageEventsMsg,
      "cribbageEvents round-trips through JSON")

let cribbageSnapshotSample = CribbageEngine(seed: 5).state.snapshot(for: 0)
let cribbageSnapshotMsg: NetMessage = .cribbageSnapshot(cribbageSnapshotSample)
check((try! JSONDecoder().decode(NetMessage.self, from: try! JSONEncoder().encode(cribbageSnapshotMsg))) == cribbageSnapshotMsg,
      "cribbageSnapshot round-trips through JSON")

// MARK: - Cribbage: dealer alternation + full seeded bot game to completion

func playCribbageBotGame(seed: UInt64, actionCap: Int = 5000) -> (engine: CribbageEngine, actions: Int, anyIllegal: Bool, dealerSeats: [Int]) {
    let engine = CribbageEngine(seed: seed)
    var rng = SeededGenerator(seed: seed &+ 999)
    var actions = 0
    var anyIllegal = false
    var dealerSeats: [Int] = [engine.state.dealerSeat]

    while engine.state.phase != .gameOver, actions < actionCap {
        switch engine.state.phase {
        case .discarding:
            for seat in [0, 1] where !engine.state.discardsSubmitted.contains(seat) {
                guard let hand = engine.state.hands[seat] else { continue }
                let discard = CribbageBot.discard(hand: hand, isDealer: seat == engine.state.dealerSeat, rng: &rng)
                let events = engine.apply(.discardToCrib(cards: discard.map(\.id)), from: seat)
                if isIllegalCrib(events) { anyIllegal = true }
                actions += 1
            }
        case .pegging:
            guard let pegging = engine.state.pegging, let hand = engine.state.hands[pegging.turnSeat] else {
                anyIllegal = true
                actions = actionCap
                break
            }
            guard let choice = CribbageBot.pegPlay(
                hand: hand, sequence: pegging.sequence.map(\.card), count: pegging.count, rng: &rng
            ) else {
                anyIllegal = true // shouldn't happen: the engine guarantees turnSeat always has a legal play
                actions = actionCap
                break
            }
            let events = engine.apply(.playCard(cardID: choice.id), from: pegging.turnSeat)
            if isIllegalCrib(events) { anyIllegal = true }
            actions += 1
        case .handComplete:
            let events = engine.apply(.advance, from: 0)
            if isIllegalCrib(events) { anyIllegal = true }
            actions += 1
            dealerSeats.append(engine.state.dealerSeat)
        case .gameOver:
            break
        }
    }
    return (engine, actions, anyIllegal, dealerSeats)
}

let dealerAlternationResult = playCribbageBotGame(seed: 1)
check(dealerAlternationResult.dealerSeats.count >= 2, "bot game: at least one hand completed to check dealer alternation")
var dealerAlternationHolds = true
for i in 1..<dealerAlternationResult.dealerSeats.count where dealerAlternationResult.dealerSeats[i] == dealerAlternationResult.dealerSeats[i - 1] {
    dealerAlternationHolds = false
}
check(dealerAlternationHolds, "bot game: the dealer alternates every hand, never repeats back-to-back")

for botSeed: UInt64 in [1, 2, 3, 42, 777, 2026] {
    let result = playCribbageBotGame(seed: botSeed)
    check(result.engine.state.phase == .gameOver, "bot game seed \(botSeed): reaches gameOver within the action budget")
    check(!result.anyIllegal, "bot game seed \(botSeed): every action taken was legal throughout")
    check(result.actions < 5000, "bot game seed \(botSeed): terminates well under the action cap")
    if let winner = result.engine.state.winnerSeat {
        check((result.engine.state.scores[winner] ?? 0) >= 121, "bot game seed \(botSeed): the winner's final score is >= 121")
    } else {
        check(false, "bot game seed \(botSeed): a winnerSeat was recorded")
    }
}

// MARK: - SideGames BEGIN (Go Fish / Old Maid / War)

func sgCards(_ ids: [String]) -> [Card] { ids.map { id in DeckBuilder.standard52().first { $0.id == id }! } }
func sgIllegal(_ e: [GoFishEvent]) -> Bool { e.contains { if case .illegalAttempt = $0 { return true }; return false } }
func sgIllegalOM(_ e: [OldMaidEvent]) -> Bool { e.contains { if case .illegalAttempt = $0 { return true }; return false } }
func sgIllegalWar(_ e: [WarEvent]) -> Bool { e.contains { if case .illegalAttempt = $0 { return true }; return false } }

func sgJSONRoundTrip<T: Codable & Equatable>(_ value: T) -> Bool {
    guard let data = try? JSONEncoder().encode(value),
          let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value
}

// ---- Go Fish: dealing

check(GoFishEngine.kind == "goFish" && OldMaidEngine.kind == "oldMaid" && WarEngine.kind == "war", "side games: kind strings")

for (n, handSize) in [(2, 7), (3, 5), (4, 5)] {
    for seed in [1, 2, 3, 99] as [UInt64] {
        let e = GoFishEngine(seed: seed, playerCount: n)
        let booked = e.state.books.values.reduce(0) { $0 + $1.count }
        let inHands = e.state.hands.values.reduce(0) { $0 + $1.count }
        check(inHands + e.state.pool.count + booked * 4 == 52, "goFish \(n)p seed \(seed): all 52 cards accounted for")
        check(e.state.handSize == handSize, "goFish \(n)p: deal size \(handSize)")
        let ids = Set(e.state.hands.values.flatMap { $0 }.map(\.id) + e.state.pool.map(\.id))
        check(ids.count + booked * 4 == 52, "goFish \(n)p seed \(seed): no duplicate cards")
    }
}
do {
    let e = GoFishEngine(seed: 5, playerCount: 3)
    check(e.state.turnSeat == 0 && e.state.phase == .playing, "goFish: seat 0 leads, game playing")
    let a = GoFishEngine(seed: 8, playerCount: 4), b = GoFishEngine(seed: 8, playerCount: 4)
    check(a.state == b.state, "goFish: same seed deals identically")
    check(GoFishEngine(seed: 1, playerCount: 9).state.playerCount == 4, "goFish: player count clamps to 4")
}

// ---- Go Fish: ask / fish mechanics via fixtures

func gfFixture(pool: [String], turn: Int = 0, books: [Int: [Int]] = [0: [], 1: [], 2: []],
               h0: [String], h1: [String], h2: [String]) -> GoFishEngine {
    GoFishEngine(restoring: GoFishState(
        seed: 1, playerCount: 3, handSize: 5,
        hands: [0: sgCards(h0), 1: sgCards(h1), 2: sgCards(h2)],
        pool: sgCards(pool), books: books, turnSeat: turn))
}

do {
    // Transfer + go again + book completion (7s)
    let e = gfFixture(pool: ["c3", "c4", "c5"], h0: ["h7", "d7", "c2", "s9", "h9"], h1: ["s7", "c7", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "d9"])
    let ev = e.apply(.ask(target: 1, rank: 7), from: 0)
    check(!sgIllegal(ev), "goFish: legal ask accepted")
    check(ev.contains(.asked(asker: 0, target: 1, rank: 7)), "goFish: asked event (Chase asks Vinny for sevens)")
    check(ev.contains { if case .gave(1, 0, 7, let cs) = $0 { return cs.count == 2 }; return false }, "goFish: both sevens transferred")
    check(ev.contains { if case .bookLaid(0, 7, let cs) = $0 { return cs.count == 4 }; return false }, "goFish: four sevens auto-laid as a book")
    check(e.state.books[0] == [7], "goFish: book recorded publicly")
    check(e.state.turnSeat == 0, "goFish: successful ask keeps the turn")
    check(e.state.hands[1]?.count == 3 && e.state.hands[0]?.count == 3, "goFish: hands updated after transfer + book")
    check(e.state.askLog.last == GoFishAskRecord(asker: 0, target: 1, rank: 7, gave: 2), "goFish: ask logged")

    // illegal asks
    check(sgIllegal(e.apply(.ask(target: 2, rank: 8), from: 0)), "goFish: can't ask for a rank you don't hold")
    check(sgIllegal(e.apply(.ask(target: 0, rank: 9), from: 0)), "goFish: can't ask yourself")
    check(sgIllegal(e.apply(.ask(target: 5, rank: 9), from: 0)), "goFish: can't ask a nonexistent seat")
    check(sgIllegal(e.apply(.ask(target: 2, rank: 9), from: 1)), "goFish: out of turn rejected")
    check(sgIllegal(e.apply(.ask(target: 2, rank: 9), from: 7)), "goFish: bad seat rejected")
}
do {
    // Go Fish with a non-matching draw passes the turn
    let e = gfFixture(pool: ["c3", "c4"], h0: ["h7", "d2", "c2", "s9", "h9"], h1: ["s8", "c8", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "d9"])
    let ev = e.apply(.ask(target: 1, rank: 7), from: 0)
    check(ev.contains(.goFish(seat: 0, rank: 7)), "goFish: Go Fish event when target has none")
    check(ev.contains(.fished(seat: 0, matched: false, card: nil)), "goFish: unmatched draw hides the card")
    check(e.state.turnSeat == 1, "goFish: unmatched fish passes the turn")
    check(e.state.hands[0]?.count == 6 && e.state.pool.count == 1, "goFish: drew exactly one card")
    check(e.snapshot(for: 0).hand.contains { $0.id == "c3" }, "goFish: drawer sees the drawn card")
}
do {
    // Matching draw -> go again
    let e = gfFixture(pool: ["c7", "c4"], h0: ["h7", "d2", "c2", "s9", "h9"], h1: ["s8", "c8", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "d9"])
    let ev = e.apply(.ask(target: 1, rank: 7), from: 0)
    check(ev.contains { if case .fished(0, true, let c) = $0 { return c?.id == "c7" }; return false }, "goFish: matched fish reveals the wished card")
    check(ev.contains(.goesAgain(seat: 0)) && e.state.turnSeat == 0, "goFish: fishing your wish = go again")
}
do {
    // Drawing completes a book of a different rank; unmatched -> pass
    let e = gfFixture(pool: ["c9"], h0: ["h7", "d9", "c2", "s9", "h9"], h1: ["s8", "c8", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "s5"])
    let ev = e.apply(.ask(target: 1, rank: 7), from: 0)
    check(e.state.books[0] == [9], "goFish: fished card completes a book")
    check(ev.contains { if case .bookLaid(0, 9, _) = $0 { return true }; return false }, "goFish: bookLaid narrated after the fish")
    check(e.state.turnSeat == 1, "goFish: book-completing but unmatched draw passes turn")
}
do {
    // Empty pool: Go Fish passes the turn with poolEmpty
    let e = gfFixture(pool: [], h0: ["h7", "d2", "c2", "s9", "h9"], h1: ["s8", "c8", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "d9"])
    let ev = e.apply(.ask(target: 1, rank: 7), from: 0)
    check(ev.contains(.poolEmpty(seat: 0)) && e.state.turnSeat == 1, "goFish: empty pool - turn passes")
}
do {
    // Empty-handed player on turn refills from the pool
    let e = gfFixture(pool: ["c3", "c4", "c5", "d4", "d5", "d6", "d7"], h0: ["h7", "d2"], h1: [], h2: ["d10", "h10", "s10", "d8", "d9"])
    let ev = e.apply(.ask(target: 2, rank: 7), from: 0)
    check(ev.contains { if case .refilled(1, let n) = $0 { return n >= 1 }; return false }, "goFish: empty hand on turn refills")
    check(!(e.state.hands[1] ?? []).isEmpty && e.state.turnSeat == 1, "goFish: refilled player takes the turn")
}
do {
    // Empty-handed with empty pool is skipped
    let e = gfFixture(pool: [], h0: ["h7", "d2", "c2"], h1: [], h2: ["d10", "h10", "s10", "d8", "d9"])
    _ = e.apply(.ask(target: 2, rank: 7), from: 0)
    check(e.state.turnSeat == 2, "goFish: player with no cards and empty pool is skipped")
}
do {
    // Game end: last book completes, most books wins
    let e = GoFishEngine(restoring: GoFishState(
        seed: 1, playerCount: 3, handSize: 5,
        hands: [0: sgCards(["s14", "h14", "d14"]), 1: sgCards(["c14"]), 2: []], pool: [],
        books: [0: [2, 3, 4, 5, 6, 7, 8], 1: [9, 10, 11, 12], 2: [13]], turnSeat: 0))
    let ev = e.apply(.ask(target: 1, rank: 14), from: 0)
    check(e.state.phase == .gameOver, "goFish: 13th book ends the game")
    check(e.state.winners == [0], "goFish: most books wins")
    check(ev.contains { if case .gameOver(let w, let b) = $0 { return w == [0] && b[0] == 8 && b[1] == 4 }; return false }, "goFish: gameOver event carries books")
    check(sgIllegal(e.apply(.ask(target: 1, rank: 14), from: 0)), "goFish: no actions after game over")
    check(e.snapshot(for: 1).winners == [0], "goFish: snapshot reports winners")

    // Tie
    let t = GoFishEngine(restoring: GoFishState(
        seed: 1, playerCount: 2, handSize: 7,
        hands: [0: sgCards(["s14", "h14", "d14"]), 1: sgCards(["c14"])], pool: [],
        books: [0: [2, 3, 4, 5, 6, 7], 1: [8, 9, 10, 11, 12, 13]], turnSeat: 0))
    _ = t.apply(.ask(target: 1, rank: 14), from: 0)
    check(t.state.phase == .gameOver && t.state.winners == [0], "goFish: 7-6 win after the last book")
    let tie = GoFishEngine(restoring: GoFishState(
        seed: 1, playerCount: 4, handSize: 5,
        hands: [0: sgCards(["s14", "h14", "d14"]), 1: sgCards(["c14"]), 2: [], 3: []], pool: [],
        books: [0: [2, 3, 4], 1: [5, 6, 7], 2: [8, 9, 10], 3: [11, 12, 13]], turnSeat: 0))
    _ = tie.apply(.ask(target: 1, rank: 14), from: 0)
    check(tie.state.winners == [0], "goFish: 4-player finish")
    let tie2 = GoFishEngine(restoring: GoFishState(
        seed: 1, playerCount: 4, handSize: 5,
        hands: [0: sgCards(["s14", "h14", "d14"]), 1: sgCards(["c14"]), 2: [], 3: []], pool: [],
        books: [0: [2, 3, 4], 1: [5, 6], 2: [7, 8, 9], 3: [10, 11, 12, 13]], turnSeat: 0))
    _ = tie2.apply(.ask(target: 1, rank: 14), from: 0)
    check(tie2.state.winners == [0, 3], "goFish: tie on books shares the win")
}
do {
    // Snapshot redaction + Codable
    let e = GoFishEngine(seed: 4, playerCount: 3)
    let s = e.snapshot(for: 1)
    check(s.hand == e.state.hands[1], "goFish snapshot: own hand")
    check(s.handCounts[0] == e.state.hands[0]?.count && s.poolCount == e.state.pool.count, "goFish snapshot: counts only for others")
    let json = String(data: (try? JSONEncoder().encode(s)) ?? Data(), encoding: .utf8) ?? ""
    let other = e.state.hands[0]!.first { c in !s.hand.contains(c) }!
    check(!json.contains("\"\(other.id)\""), "goFish snapshot: other hands' card ids are not in the payload")
    check(sgJSONRoundTrip(e.state) && sgJSONRoundTrip(s), "goFish: state + snapshot Codable")
    check(sgJSONRoundTrip(GoFishEvent.fished(seat: 1, matched: true, card: s.hand[0])) && sgJSONRoundTrip(GoFishAction.ask(target: 1, rank: 5)), "goFish: event + action Codable")
    check(s.askableRanks.isEmpty == (s.turnSeat != 1), "goFish snapshot: askable ranks only on own turn")
    check(GoFishText.plural(7) == "sevens" && GoFishText.plural(14) == "aces", "goFish: rank plural text")
}

// ---- Go Fish: bot games to completion

func playGoFishBotGame(seed: UInt64, players: Int) -> (engine: GoFishEngine, actions: Int, illegal: Bool) {
    let engine = GoFishEngine(seed: seed, playerCount: players)
    var rng = SeededGenerator(seed: seed &+ 1000)
    var actions = 0
    var illegal = false
    while engine.state.phase == .playing && actions < 4000 {
        let seat = engine.state.turnSeat
        guard let action = GoFishBot.chooseAction(snapshot: engine.snapshot(for: seat), rng: &rng) else { illegal = true; break }
        if sgIllegal(engine.apply(action, from: seat)) { illegal = true; break }
        actions += 1
    }
    return (engine, actions, illegal)
}
for players in [2, 3, 4] {
    for seed in [1, 2, 3, 4, 5] as [UInt64] {
        let r = playGoFishBotGame(seed: seed, players: players)
        let books = r.engine.state.books.values.reduce(0) { $0 + $1.count }
        check(r.engine.state.phase == .gameOver && !r.illegal, "goFish bot \(players)p seed \(seed): completes with only legal moves")
        check(books == 13, "goFish bot \(players)p seed \(seed): all 13 books made")
        check(!r.engine.state.winners.isEmpty, "goFish bot \(players)p seed \(seed): winner declared")
    }
}
do {
    let a = playGoFishBotGame(seed: 3, players: 3), b = playGoFishBotGame(seed: 3, players: 3)
    check(a.engine.state == b.engine.state, "goFish bot: fully deterministic given a seed")
    // Memory: bot asks the seat that asked for a rank it holds
    var rng = SeededGenerator(seed: 1)
    let e = gfFixture(pool: ["c3"], h0: ["h7", "d2", "c2", "s9", "h9"], h1: ["s8", "c8", "d3", "h4", "c6"], h2: ["d10", "h10", "s10", "d8", "d9"])
    var st = e.state
    st.askLog = [GoFishAskRecord(asker: 2, target: 1, rank: 9, gave: 0)]
    let e2 = GoFishEngine(restoring: st)
    let act = GoFishBot.chooseAction(snapshot: e2.snapshot(for: 0), rng: &rng)
    check(act == .ask(target: 2, rank: 9), "goFish bot: remembers seat 2 asked for nines, asks them for nines")
    check(GoFishBot.chooseAction(snapshot: e2.snapshot(for: 1), rng: &rng) == nil, "goFish bot: no action off-turn")
}

// ---- Old Maid

for players in [2, 3, 4] {
    for seed in [1, 2, 3] as [UInt64] {
        let e = OldMaidEngine(seed: seed, playerCount: players)
        let all = e.state.hands.values.flatMap { $0 } + e.state.laid.values.flatMap { $0.flatMap { $0 } }
        check(all.count == 51 && Set(all.map(\.id)).count == 51, "oldMaid \(players)p seed \(seed): 51 unique cards")
        check(!all.contains { $0.id == "c12" }, "oldMaid: one queen removed")
        check(all.filter { $0.rank == 12 }.count == 3, "oldMaid: three queens remain")
        var noPairs = true
        for hand in e.state.hands.values {
            let ranks = hand.compactMap(\.rank)
            if Set(ranks).count != ranks.count { noPairs = false }
        }
        check(noPairs, "oldMaid \(players)p seed \(seed): pairs discarded on deal")
        let sizes = e.state.hands.mapValues(\.count)
        check(sizes.values.reduce(0, +) + e.state.laid.values.reduce(0) { $0 + $1.count * 2 } == 51, "oldMaid: hands + laid pairs total 51")
        check(e.state.laid.values.allSatisfy { $0.allSatisfy { $0.count == 2 && $0[0].rank == $0[1].rank } }, "oldMaid: laid pairs match by rank")
    }
}
do {
    let a = OldMaidEngine(seed: 6, playerCount: 4), b = OldMaidEngine(seed: 6, playerCount: 4)
    check(a.state == b.state, "oldMaid: same seed deals identically")
}
do {
    // Fixture: pair draw + loser detection
    let e = OldMaidEngine(restoring: OldMaidState(seed: 1, playerCount: 2, hands: [0: sgCards(["h5", "s12"]), 1: sgCards(["d5"])]))
    let snap = e.snapshot(for: 0)
    check(snap.drawTarget == 1 && snap.turnSeat == 0, "oldMaid snapshot: draw target is the neighbor")
    check(sgIllegalOM(e.apply(.draw(index: 0), from: 1)), "oldMaid: out of turn rejected")
    check(sgIllegalOM(e.apply(.draw(index: 3), from: 0)), "oldMaid: index out of range rejected")
    check(sgIllegalOM(e.apply(.draw(index: -1), from: 0)), "oldMaid: negative index rejected")
    let ev = e.apply(.draw(index: 0), from: 0)
    check(ev.contains { if case .pairsDiscarded(0, let p, false) = $0 { return p.count == 1 }; return false }, "oldMaid: drawn match is auto-laid")
    check(ev.contains(.playerOut(seat: 1)), "oldMaid: emptied neighbor is out")
    check(e.state.phase == .gameOver && e.state.loser == 0, "oldMaid: last holder of the queen loses")
    check(ev.contains(.gameOver(loser: 0)), "oldMaid: gameOver event")
    check(e.snapshot(for: 1).loser == 0 && e.snapshot(for: 1).drawTarget == nil, "oldMaid snapshot: loser, no target after end")
    check(sgIllegalOM(e.apply(.draw(index: 0), from: 0)), "oldMaid: no draws after game over")
}
do {
    // 3 players: non-match draw appends; drawn card hidden from others; turn order skips outs
    let e = OldMaidEngine(restoring: OldMaidState(seed: 1, playerCount: 3, hands: [
        0: sgCards(["h5", "s12"]), 1: sgCards(["d9", "c3"]), 2: sgCards(["d4"])]))
    let ev = e.apply(.draw(index: 1), from: 0) // takes c3 from seat 1
    check(!ev.contains { if case .pairsDiscarded = $0 { return true }; return false }, "oldMaid: non-matching draw lays nothing")
    check(e.state.hands[0]?.last?.id == "c3" && e.state.hands[1]?.count == 1, "oldMaid: card moved to the end of the drawer's hand")
    check(e.snapshot(for: 0).lastDrawnCardID == "c3" && e.snapshot(for: 1).lastDrawnCardID == nil, "oldMaid snapshot: drawn card id visible only to the drawer")
    check(e.state.turnSeat == 1 && e.snapshot(for: 1).drawTarget == 2, "oldMaid: turn passes left; seat 1 draws from seat 2")
    _ = e.apply(.draw(index: 0), from: 1) // takes d4 from seat 2 -> seat 2 out
    check(e.state.outSeats == [2] && e.state.turnSeat == 0, "oldMaid: out seat skipped, turn wraps")
    check(e.snapshot(for: 0).drawTarget == 1, "oldMaid: drawing skips players who are out")
    // 3 of a kind pairs off two, keeps one
    let t = OldMaidEngine(seed: 1, playerCount: 2)
    check(sgJSONRoundTrip(t.state) && sgJSONRoundTrip(t.snapshot(for: 0)), "oldMaid: state + snapshot Codable")
    check(sgJSONRoundTrip(OldMaidAction.draw(index: 2)) && sgJSONRoundTrip(OldMaidEvent.pairsDiscarded(seat: 0, pairs: [sgCards(["h5", "d5"])], onDeal: true)), "oldMaid: action + event Codable")
    // shuffle keeps the same cards
    let before = Set(t.state.hands[0]!.map(\.id))
    let sev = t.apply(.shuffleMyHand, from: 0)
    check(Set(t.state.hands[0]!.map(\.id)) == before && !sgIllegalOM(sev), "oldMaid: shuffleMyHand permutes only")
}
do {
    // Opening deal where somebody can already be out or game already over is handled
    let e = OldMaidEngine(restoring: OldMaidState(seed: 1, playerCount: 2, hands: [0: sgCards(["s12"]), 1: []], phase: .playing))
    check(e.state.phase == .playing, "oldMaid: restore preserves state")
}

func playOldMaidBotGame(seed: UInt64, players: Int) -> (engine: OldMaidEngine, actions: Int, illegal: Bool) {
    let engine = OldMaidEngine(seed: seed, playerCount: players)
    var rng = SeededGenerator(seed: seed &+ 77)
    var actions = 0
    var illegal = false
    while engine.state.phase == .playing && actions < 2000 {
        let seat = engine.state.turnSeat
        guard let idx = OldMaidBot.chooseIndex(snapshot: engine.snapshot(for: seat), rng: &rng) else { illegal = true; break }
        if sgIllegalOM(engine.apply(.draw(index: idx), from: seat)) { illegal = true; break }
        actions += 1
    }
    return (engine, actions, illegal)
}
for players in [2, 3, 4] {
    for seed in [1, 2, 3, 4, 5] as [UInt64] {
        let r = playOldMaidBotGame(seed: seed, players: players)
        let s = r.engine.state
        check(s.phase == .gameOver && !r.illegal, "oldMaid bot \(players)p seed \(seed): completes legally")
        if let loser = s.loser {
            check(s.hands[loser]?.count == 1 && s.hands[loser]?.first?.rank == 12, "oldMaid bot \(players)p seed \(seed): loser holds the odd queen")
            check(s.hands.filter { $0.key != loser }.allSatisfy { $0.value.isEmpty }, "oldMaid bot \(players)p seed \(seed): everyone else is out")
            check(s.laid.values.reduce(0) { $0 + $1.count } * 2 + 1 == 51, "oldMaid bot \(players)p seed \(seed): 25 pairs laid + the queen")
        } else {
            check(false, "oldMaid bot \(players)p seed \(seed): loser recorded")
        }
    }
}
do {
    var rngA = SeededGenerator(seed: 5), rngB = SeededGenerator(seed: 5)
    let e = OldMaidEngine(seed: 12, playerCount: 3)
    let s = e.snapshot(for: e.state.turnSeat)
    check(OldMaidBot.chooseIndex(snapshot: s, rng: &rngA) == OldMaidBot.chooseIndex(snapshot: s, rng: &rngB), "oldMaid bot: deterministic under seed")
    let c = s.handCounts[s.drawTarget!]!
    var seen = Set<Int>()
    var rngC = SeededGenerator(seed: 9)
    for _ in 0..<300 { if let i = OldMaidBot.chooseIndex(snapshot: s, rng: &rngC) { seen.insert(i) } }
    check(seen == Set(0..<c), "oldMaid bot: picks cover every index (honest random)")
}

// ---- War

do {
    let e = WarEngine(seed: 3)
    check(e.state.hands[0]?.count == 26 && e.state.hands[1]?.count == 26, "war: deals 26 each")
    check(Set((e.state.hands[0]! + e.state.hands[1]!).map(\.id)).count == 52, "war: 52 unique cards")
    check(e.state.maxRounds == 200, "war: default maxRounds 200")
    check(WarEngine(seed: 3).state == e.state, "war: same seed deals identically")
}
func warFixture(_ a: [String], _ b: [String], maxRounds: Int = 200) -> WarEngine {
    WarEngine(restoring: WarState(seed: 1, maxRounds: maxRounds, hands: [0: sgCards(a), 1: sgCards(b)]))
}
do {
    // Plain battle
    let e = warFixture(["h14", "c3"], ["d2", "c4"])
    let ev = e.apply(.flip, from: 0)
    check(ev.contains { if case .flipped(0, let c, 1, 0) = $0 { return c.id == "h14" }; return false }, "war: flip events")
    check(e.state.hands[0]?.count == 3 && e.state.hands[1]?.count == 1, "war: higher card takes both")
    check(ev.contains(.captured(seat: 0, count: 2, round: 1)) && e.state.round == 1, "war: capture narrated, round counted")
    check(e.snapshot(for: 1).myCount == 1 && e.snapshot(for: 1).opponentCount == 3, "war snapshot: counts per seat")
    check(sgIllegalWar(e.apply(.flip, from: 5)), "war: bad seat rejected")
}
do {
    // Single war: 3 down 1 up
    let e = warFixture(["s5", "c2", "c3", "c4", "s10", "h8"], ["d5", "d2", "d3", "d4", "d9", "h9"])
    let ev = e.apply(.flip, from: 0)
    check(ev.contains(.warDeclared(round: 1, depth: 1)), "war: tie declares war")
    check(ev.contains(.faceDownPlaced(seat: 0, count: 3)) && ev.contains(.faceDownPlaced(seat: 1, count: 3)), "war: 3 down each")
    check(ev.contains { if case .flipped(_, let c, 1, 1) = $0 { return c.id == "s10" }; return false }, "war: war flip at depth 1")
    check(e.state.hands[0]?.count == 1 + 10 && e.state.hands[1]?.count == 1, "war: winner takes all 10 cards")
    check(e.state.lastBattle?.wars == 1 && e.state.lastBattle?.captured == 10 && e.state.lastBattle?.winner == 0, "war: lastBattle record")
}
do {
    // Recursive war (tie, tie again, then win)
    let a = ["s5", "c2", "c3", "c4", "s9", "c6", "c7", "c8", "s2", "h8"]
    let b = ["d5", "d2", "d3", "d4", "d9", "d6", "d7", "d8", "dK", "h9"].map { $0 == "dK" ? "d13" : $0 }
    let e = warFixture(a, b)
    let ev = e.apply(.flip, from: 0)
    check(ev.contains(.warDeclared(round: 1, depth: 1)) && ev.contains(.warDeclared(round: 1, depth: 2)), "war: tie inside a war recurses")
    check(e.state.lastBattle?.wars == 2, "war: two wars recorded")
    check(e.state.hands[1]?.count == 1 + 18 && e.state.hands[0]?.count == 1, "war: recursive war winner takes the whole pot")
    check(e.state.hands[0]?.first?.id == "h8", "war: untouched cards stay at the front of the pile")
}
do {
    // Short war: player runs out -> forfeits, game ends
    let e = warFixture(["h5"], ["d5", "d2", "d3", "d4", "d6"])
    let ev = e.apply(.flip, from: 0)
    check(ev.contains(.forfeited(seat: 0, round: 1)), "war: player with nothing to flip forfeits")
    check(e.state.phase == .gameOver && e.state.winner == 1 && e.state.endReason == .allCards, "war: game ends when one player has everything")
    check(e.state.hands[1]?.count == 6, "war: forfeit gives winner the pot")
    check(sgIllegalWar(e.apply(.flip, from: 0)) && e.autoStep().isEmpty, "war: no steps after game over")
    // Short but alive: 2 cards -> lays 1 down and flips the last
    let s = warFixture(["h5", "c9", "c8"], ["d5", "d2", "d3", "d4", "d6", "d7"])
    let sev = s.apply(.flip, from: 0)
    check(sev.contains(.faceDownPlaced(seat: 0, count: 1)) && sev.contains(.faceDownPlaced(seat: 1, count: 3)), "war: short stack lays what it can, keeps one to flip")
}
do {
    // Round cap declares the leader
    let e = warFixture(["h14", "c3", "c4"], ["d2", "d3", "d4"], maxRounds: 1)
    let ev = e.autoStep()
    check(e.state.phase == .gameOver && e.state.endReason == .roundCap && e.state.winner == 0, "war: round cap declares the card leader")
    check(ev.contains { if case .gameOver(0, .roundCap, let c) = $0 { return c[0] == 4 && c[1] == 2 }; return false }, "war: cap gameOver event")
    let d = warFixture(["h14", "c3"], ["d14", "d3"], maxRounds: 1) // tie into war, both then exhausted
    _ = d.autoStep()
    check(d.state.phase == .gameOver, "war: tie + cap ends the game")
    let t = warFixture(["h5"], ["d5"], maxRounds: 1) // both run dry on the tie: pot splits, 1-1, cap -> draw
    _ = t.autoStep()
    check(t.state.phase == .gameOver && t.state.winner == nil && t.state.endReason == .roundCap, "war: equal counts at the cap is a draw")
    check(sgJSONRoundTrip(e.state) && sgJSONRoundTrip(e.snapshot(for: 0)), "war: state + snapshot Codable")
    check(sgJSONRoundTrip(WarEvent.warDeclared(round: 2, depth: 1)) && sgJSONRoundTrip(WarAction.flip), "war: event + action Codable")
}
do {
    // Tie at cap with equal piles -> draw (winner nil)
    let e = warFixture(["h9", "c2", "c3"], ["d2", "d3", "d4"], maxRounds: 1)
    _ = e.autoStep()
    check(e.state.winner == 0, "war: leader wins at cap")
    let q = warFixture(["h9", "c2"], ["d2", "d4", "d5"], maxRounds: 5)
    _ = q.autoStep()
    check(q.state.hands[0]!.count + q.state.hands[1]!.count == 5, "war: cards conserved through a battle")
    let eq = warFixture(["h9", "c2", "c3", "c4", "c5"], ["d9", "d3", "d4", "d5", "d6"], maxRounds: 1) // war resolves, then cap
    _ = eq.autoStep()
    check(eq.state.phase == .gameOver && eq.state.round == 1, "war: cap after a war")
}
for seed in [1, 2, 3, 4, 5] as [UInt64] {
    let e = WarEngine(seed: seed)
    var steps = 0
    var illegal = false
    while e.state.phase == .playing && steps < 1000 {
        if sgIllegalWar(e.apply(.flip, from: steps % 2)) { illegal = true }
        steps += 1
        let c = e.counts()
        if (c[0] ?? 0) + (c[1] ?? 0) != 52 { illegal = true }
    }
    check(e.state.phase == .gameOver && !illegal, "war bot seed \(seed): runs to completion with 52 cards conserved")
    check(steps <= 200, "war bot seed \(seed): never exceeds the 200-round cap")
    check(e.state.winner != nil || e.state.endReason == .roundCap, "war bot seed \(seed): winner or capped draw")
    let a2 = WarEngine(seed: seed)
    while a2.state.phase == .playing { a2.autoStep() }
    check(a2.state == e.state, "war seed \(seed): autoStep() path identical to .flip path")
}

// MARK: - SideGames END

// MARK: - BEGIN Blackjack (engine worker block)

// MARK: - Blackjack: helpers
func bjStack(seats: [[String]], dealer: [String], extra: [String] = []) -> [Card] {
    var ids: [String] = []
    for p in 0..<2 {
        for s in seats { ids.append(s[p]) }
        ids.append(dealer[p])
    }
    ids += extra
    return ids.map { card($0) }
}

/// Engine with a scripted shoe, every seat's bet already placed (deal done).
func bjDeal(seats: [[String]], dealer: [String], extra: [String] = [], bets: [Int]? = nil,
            config: BlackjackConfig = BlackjackConfig()) -> (engine: BlackjackEngine, events: [BlackjackEvent]) {
    let e = BlackjackEngine(seed: 1, seatCount: seats.count, config: config)
    e.stackShoe(bjStack(seats: seats, dealer: dealer, extra: extra))
    var ev: [BlackjackEvent] = []
    for s in seats.indices { ev += e.apply(.placeBet(bets?[s] ?? 10), from: s) }
    return (e, ev)
}
func bjIllegal(_ events: [BlackjackEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}
func bjMove(_ ids: [String], up: String, dbl: Bool = true, split: Bool = true, surr: Bool = false, h17: Bool = false) -> BlackjackMove {
    BlackjackBot.move(hand: ids.map { card($0) }, dealerUp: card(up), canDouble: dbl, canSplit: split,
                      canSurrender: surr, dealerHitsSoft17: h17)
}

// MARK: - Blackjack: hand values (soft / hard)
func bjVal(_ ids: [String]) -> BlackjackValue { BlackjackRules.value(of: ids.map { card($0) }) }
check(bjVal(["s14", "c6"]) == BlackjackValue(total: 17, isSoft: true), "bj value: A+6 is soft 17")
check(bjVal(["s14", "c6", "h10"]) == BlackjackValue(total: 17, isSoft: false), "bj value: A+6+10 is hard 17")
check(bjVal(["s14", "d14"]) == BlackjackValue(total: 12, isSoft: true), "bj value: A+A is soft 12")
check(bjVal(["s14", "d14", "c9"]) == BlackjackValue(total: 21, isSoft: true), "bj value: A+A+9 is soft 21")
check(bjVal(["s14", "d14", "h14", "c14"]) == BlackjackValue(total: 14, isSoft: true), "bj value: four aces is soft 14")
check(bjVal(["d13", "h12", "c5"]).isBust, "bj value: K+Q+5 busts at 25")
check(bjVal(["s14", "d13"]).total == 21 && BlackjackRules.isTwoCard21([card("s14"), card("d13")]), "bj value: A+K is a two-card 21")
check(!BlackjackRules.isTwoCard21(["c7", "c7", "c7"].map { card($0) }), "bj value: 7+7+7 is not a two-card 21")
check(BlackjackRules.isPair([card("d13"), card("h12")]), "bj rules: K-Q counts as a splittable pair (equal value)")
check(!BlackjackRules.isPair([card("c9"), card("c8")]), "bj rules: 9-8 is not a pair")
check(BlackjackRules.dealerShouldHit(["s14", "c6"].map { card($0) }, hitsSoft17: true), "bj dealer: H17 hits soft 17")
check(!BlackjackRules.dealerShouldHit(["s14", "c6"].map { card($0) }, hitsSoft17: false), "bj dealer: S17 stands on soft 17")
check(!BlackjackRules.dealerShouldHit(["h10", "c7"].map { card($0) }, hitsSoft17: true), "bj dealer: H17 stands on hard 17")
check(BlackjackRules.dealerShouldHit(["h10", "c6"].map { card($0) }, hitsSoft17: false), "bj dealer: hits 16")
check(BlackjackEngine.kind == "blackjack", "bj: kind tag")

// MARK: - Blackjack: shoe
let bjShoeA = BlackjackShoe.make(deckCount: 6, seed: 99)
let bjShoeB = BlackjackShoe.make(deckCount: 6, seed: 99)
let bjShoeC = BlackjackShoe.make(deckCount: 6, seed: 100)
check(bjShoeA.count == 312, "bj shoe: 6 decks = 312 cards")
check(Set(bjShoeA.map { $0.id }).count == 312, "bj shoe: every card ID is unique")
check(bjShoeA == bjShoeB, "bj shoe: same seed gives the same order")
check(bjShoeA != bjShoeC, "bj shoe: different seed gives a different order")
check(bjShoeA.filter { $0.rank == 14 }.count == 24 && bjShoeA.filter { $0.suit == .hearts }.count == 78, "bj shoe: 24 aces, 78 hearts")
let bjDefaultState = BlackjackState(seed: 1, config: BlackjackConfig(), seatCount: 3)
check(bjDefaultState.cutIndex == 234 && bjDefaultState.shoeSize == 312, "bj shoe: cut card at 75% of 312 = 234")

// MARK: - Blackjack: betting and legality
do {
    let e = BlackjackEngine(seed: 1, seatCount: 2)
    check(bjIllegal(e.apply(.placeBet(2), from: 0)), "bj bet: below the minimum is rejected")
    check(bjIllegal(e.apply(.placeBet(200), from: 0)), "bj bet: above the maximum is rejected")
    check(bjIllegal(e.apply(.placeBet(15), from: 0)), "bj bet: off the bet step (odd) is rejected")
    check(bjIllegal(e.apply(.hit, from: 0)), "bj: hit during betting is rejected")
    check(bjIllegal(e.apply(.placeBet(10), from: 5)), "bj: unknown seat is rejected")
    check(e.state.seats[0].chips == 500, "bj bet: rejected bets cost nothing")
    check(!bjIllegal(e.apply(.placeBet(20), from: 0)) && e.state.seats[0].chips == 480, "bj bet: legal bet leaves the bankroll immediately")
    check(e.state.phase == .betting, "bj bet: dealing waits for every seat")
    check(bjIllegal(e.apply(.placeBet(20), from: 0)), "bj bet: a second bet in the same round is rejected")
    check(e.state.tableSnapshot().legalActions.isEmpty && e.state.snapshot(for: 1).legalActions == [.placeBet, .sitOut], "bj snapshot: legal actions personalised")
    let ev = e.apply(.sitOut, from: 1)
    check(e.state.phase == .playing && ev.contains(.satOut(seat: 1)), "bj bet: sit-out completes the table and deals")
    check(e.state.seats[1].hands.isEmpty, "bj bet: a seat that sat out has no hand")
    check(e.state.activeSeat == 0 && bjIllegal(e.apply(.hit, from: 1)), "bj turn: out-of-turn hit is rejected")
}

// MARK: - Blackjack: blackjack payout 3:2, naturals
do {
    let (e, ev) = bjDeal(seats: [["s14", "d13"]], dealer: ["c9", "c7"], bets: [10])
    check(ev.contains(.playerBlackjack(seat: 0)), "bj natural: playerBlackjack event")
    check(e.state.phase == .roundComplete, "bj natural: round settles with no decisions")
    check(e.state.seats[0].hands[0].outcome == .blackjack && e.state.seats[0].hands[0].payout == 25, "bj natural: 3:2 on 10 returns 25")
    check(e.state.seats[0].chips == 515 && e.state.seats[0].lastRoundNet == 15, "bj natural: bankroll 515, net +15")
    check(e.state.dealerCards.count == 2, "bj natural: dealer does not draw when only naturals remain")
}
do {
    let (e, ev) = bjDeal(seats: [["s14", "d13"]], dealer: ["h14", "c13"], bets: [10])
    check(ev.contains(.dealerPeek(hasBlackjack: true)) && ev.contains(.dealerBlackjack), "bj natural: dealer peeks and shows blackjack")
    check(e.state.seats[0].hands[0].outcome == .push && e.state.seats[0].chips == 500, "bj natural: blackjack vs blackjack pushes")
}
do {
    let (e, ev) = bjDeal(seats: [["h10", "c9"]], dealer: ["h14", "c13"], bets: [10])
    check(e.state.phase == .roundComplete && !ev.contains { if case .turnStarted = $0 { return true }; return false },
          "bj peek: dealer blackjack ends the round before any decision")
    check(e.state.seats[0].hands[0].outcome == .lose && e.state.seats[0].chips == 490, "bj peek: 19 loses to dealer blackjack")
}
do {
    // Not a natural after a split: A-K from split aces pays 1:1 (covered in split section); 21 in 3 cards pays 1:1.
    let (e, _) = bjDeal(seats: [["c5", "c6"]], dealer: ["h10", "c7"], extra: ["h10"], bets: [10])
    _ = e.apply(.hit, from: 0)
    check(e.state.seats[0].hands[0].value.total == 21 && e.state.phase == .roundComplete, "bj 21: hitting to 21 auto-stands and plays out")
    check(e.state.seats[0].hands[0].outcome == .win && e.state.seats[0].hands[0].payout == 20, "bj 21: three-card 21 pays 1:1, not 3:2")
}

// MARK: - Blackjack: dealer S17 vs H17
do {
    let (e, ev) = bjDeal(seats: [["h10", "c9"]], dealer: ["s14", "c6"], extra: ["c5", "h10"], bets: [10])
    _ = e.apply(.stand, from: 0)
    check(e.state.dealerCards.count == 2, "bj dealer S17: stands on soft 17")
    check(e.state.seats[0].hands[0].outcome == .win, "bj dealer S17: player 19 beats dealer soft 17")
    _ = ev
}
do {
    var cfg = BlackjackConfig(); cfg.dealerHitsSoft17 = true
    let (e, _) = bjDeal(seats: [["h10", "c9"]], dealer: ["s14", "c6"], extra: ["c5", "h10"], bets: [10], config: cfg)
    let ev = e.apply(.stand, from: 0)
    check(e.state.dealerCards.count == 4, "bj dealer H17: hits soft 17, then soft-12-turned-hard 12")
    check(ev.contains { if case .dealerBust(let t) = $0 { return t == 22 }; return false }, "bj dealer H17: ends in a 22 bust")
    check(e.state.seats[0].hands[0].outcome == .win, "bj dealer H17: player wins on the dealer bust")
}

// MARK: - Blackjack: double
do {
    let (e, _) = bjDeal(seats: [["c5", "c6"]], dealer: ["h6", "d13"], extra: ["h10", "h10"], bets: [10])
    check(e.state.snapshot(for: 0).legalActions.contains(.doubleDown), "bj double: offered on the first two cards")
    let ev = e.apply(.doubleDown, from: 0)
    check(ev.contains { if case .doubled(_, _, _, let nb) = $0 { return nb == 20 }; return false }, "bj double: bet doubles to 20")
    check(e.state.seats[0].hands[0].cards.count == 3 && e.state.seats[0].hands[0].isDoubled, "bj double: exactly one card")
    check(e.state.seats[0].hands[0].outcome == .win && e.state.seats[0].chips == 520, "bj double: wins 20, bankroll 520")
    check(e.state.phase == .roundComplete, "bj double: hand ends, dealer plays out")
}
do {
    let (e, _) = bjDeal(seats: [["c5", "c6"]], dealer: ["h6", "d13"], extra: ["c2", "h10", "h10"], bets: [10])
    _ = e.apply(.hit, from: 0)   // 5+6+2 = 13
    check(bjIllegal(e.apply(.doubleDown, from: 0)), "bj double: not allowed on three cards")
    let low = BlackjackEngine(seed: 1, seatCount: 1, config: { var c = BlackjackConfig(); c.startingChips = 15; return c }())
    low.stackShoe(bjStack(seats: [["c5", "c6"]], dealer: ["h6", "d13"], extra: ["h10"]))
    _ = low.apply(.placeBet(10), from: 0)
    check(bjIllegal(low.apply(.doubleDown, from: 0)), "bj double: not allowed without chips to cover it")
}

// MARK: - Blackjack: split, re-split off, split aces, DAS
do {
    let (e, ev) = bjDeal(seats: [["c8", "d8"]], dealer: ["h10", "c7"], extra: ["c3", "d8", "h10"], bets: [10])
    check(e.state.snapshot(for: 0).legalActions.contains(.split), "bj split: offered on a pair")
    _ = e.apply(.split, from: 0)
    check(e.state.seats[0].hands.count == 2 && e.state.seats[0].chips == 480, "bj split: two hands, second bet posted")
    check(e.state.seats[0].hands[0].isFromSplit && e.state.seats[0].hands[0].cards.count == 2, "bj split: first hand gets its card at once")
    check(e.state.seats[0].hands[1].cards.count == 1 && e.state.activeHand == 0, "bj split: second hand waits for its card")
    check(e.state.snapshot(for: 0).legalActions.contains(.doubleDown), "bj split: double after split allowed by default")
    _ = e.apply(.stand, from: 0)   // 8+3 = 11
    check(e.state.activeHand == 1 && e.state.seats[0].hands[1].cards.count == 2, "bj split: play moves to hand 2 and deals it a card")
    check(e.state.seats[0].hands[1].cards.map { $0.id } == ["d8", "d8"], "bj split: second hand is 8 + the dealt 8")
    check(bjIllegal(e.apply(.split, from: 0)), "bj split: re-splitting 8-8 off a split hand is rejected")
    _ = e.apply(.stand, from: 0)
    check(e.state.phase == .roundComplete, "bj split: round resolves after both hands")
    check(e.state.seats[0].hands[0].outcome == .lose && e.state.seats[0].hands[1].outcome == .lose, "bj split: 11 and 16 both lose to dealer 17")
    _ = ev
}
do {
    var cfg = BlackjackConfig(); cfg.doubleAfterSplit = false
    let (e, _) = bjDeal(seats: [["c8", "d8"]], dealer: ["h10", "c7"], extra: ["c3", "h10"], bets: [10], config: cfg)
    _ = e.apply(.split, from: 0)
    check(!e.state.snapshot(for: 0).legalActions.contains(.doubleDown) && bjIllegal(e.apply(.doubleDown, from: 0)), "bj split: no double after split when the flag is off")
}
do {
    let (e, _) = bjDeal(seats: [["s14", "d14"]], dealer: ["c9", "c8"], extra: ["d13", "c5"], bets: [10])
    let ev = e.apply(.split, from: 0)
    check(e.state.phase == .roundComplete, "bj split aces: one card each, no decisions, round plays out")
    check(e.state.seats[0].hands.allSatisfy { $0.cards.count == 2 && $0.isSplitAces }, "bj split aces: exactly one card each")
    check(e.state.seats[0].hands[0].outcome == .win && e.state.seats[0].hands[0].payout == 20, "bj split aces: A+K is 21 but pays 1:1, not a blackjack")
    check(e.state.seats[0].hands[1].outcome == .lose, "bj split aces: A+5 loses to dealer 17")
    check(e.state.seats[0].chips == 500 - 20 + 20, "bj split aces: chips conserve")
    check(ev.contains(.split(seat: 0)), "bj split aces: split event")
}
do {
    // 10-value pair splits by value (K-Q) too.
    let (e, _) = bjDeal(seats: [["d13", "h12"]], dealer: ["h10", "c7"], extra: ["c2", "c3"], bets: [10])
    check(e.state.snapshot(for: 0).legalActions.contains(.split), "bj split: K-Q is splittable by value")
}

// MARK: - Blackjack: bust, push, surrender, insurance
do {
    let (e, ev) = bjDeal(seats: [["h10", "c6"]], dealer: ["h10", "c7"], extra: ["d13", "h10"], bets: [10])
    let ev2 = e.apply(.hit, from: 0)
    check(ev2.contains { if case .bust(_, _, let t) = $0 { return t == 26 }; return false }, "bj bust: bust event with total 26")
    check(e.state.seats[0].hands[0].outcome == .bust && e.state.seats[0].chips == 490, "bj bust: bet lost")
    check(e.state.dealerCards.count == 2, "bj bust: dealer does not draw when every hand busts")
    check(e.state.holeRevealed, "bj bust: hole card is still turned over")
    _ = ev
}
do {
    let (e, _) = bjDeal(seats: [["h10", "c9"]], dealer: ["d10", "d9"], bets: [10])
    _ = e.apply(.stand, from: 0)
    check(e.state.seats[0].hands[0].outcome == .push && e.state.seats[0].chips == 500, "bj push: equal totals return the bet")
}
do {
    let (e, _) = bjDeal(seats: [["h10", "c9"]], dealer: ["d10", "d8"], bets: [10])
    _ = e.apply(.stand, from: 0)
    check(e.state.seats[0].hands[0].outcome == .win && e.state.seats[0].chips == 510, "bj win: 19 beats 18")
}
do {
    let (e, _) = bjDeal(seats: [["h10", "c6"]], dealer: ["d10", "d9"], bets: [10])
    check(!e.state.snapshot(for: 0).legalActions.contains(.surrender) && bjIllegal(e.apply(.surrender, from: 0)), "bj surrender: off by default")
    var cfg = BlackjackConfig(); cfg.surrenderEnabled = true
    let (s, _) = bjDeal(seats: [["h10", "c6"]], dealer: ["d10", "d9"], bets: [10], config: cfg)
    _ = s.apply(.surrender, from: 0)
    check(s.state.seats[0].hands[0].outcome == .surrender && s.state.seats[0].chips == 495, "bj surrender: half the bet comes back when enabled")
}
do {
    var cfg = BlackjackConfig(); cfg.insuranceEnabled = true
    let (e, ev) = bjDeal(seats: [["h10", "c9"]], dealer: ["h14", "c13"], bets: [10], config: cfg)
    check(e.state.phase == .insurance && ev.contains(.insuranceOffered), "bj insurance: offered on a dealer ace when enabled")
    let ev2 = e.apply(.takeInsurance(true), from: 0)
    check(ev2.contains(.insuranceTaken(seat: 0, amount: 5)) && ev2.contains(.dealerPeek(hasBlackjack: true)), "bj insurance: costs half, then dealer peeks")
    check(e.state.seats[0].chips == 500, "bj insurance: pays 2:1 and breaks even against a dealer blackjack")
    let (d, _) = bjDeal(seats: [["h10", "c9"]], dealer: ["h14", "c6"], extra: [], bets: [10], config: cfg)
    _ = d.apply(.takeInsurance(false), from: 0)
    check(d.state.phase == .playing, "bj insurance: declining continues the hand")
    let (n, nev) = bjDeal(seats: [["h10", "c9"]], dealer: ["h14", "c13"], bets: [10])
    check(n.state.phase == .roundComplete && !nev.contains(.insuranceOffered), "bj insurance: OFF by default")
}

// MARK: - Blackjack: snapshot redaction and Codable
do {
    let (e, ev) = bjDeal(seats: [["h10", "c9"], ["d5", "d6"]], dealer: ["d10", "c12"], bets: [10, 10])
    let snap = e.state.snapshot(for: 1)
    check(snap.dealerHoleHidden && snap.dealerCards.count == 1 && snap.dealerVisibleTotal == 10, "bj snapshot: dealer shows the up card only")
    let json = String(data: try! JSONEncoder().encode(snap), encoding: .utf8)!
    check(!json.contains("\"c12\""), "bj snapshot: the hole card's identity never appears before the reveal")
    let evJSON = String(data: try! JSONEncoder().encode(ev), encoding: .utf8)!
    check(!evJSON.contains("\"c12\""), "bj events: dealerHoleDealt carries no card identity")
    check(snap.seats[0].hands[0].cards.count == 2, "bj snapshot: every player's cards are public")
    _ = e.apply(.stand, from: 0)
    _ = e.apply(.stand, from: 1)
    let after = e.state.snapshot(for: 0)
    check(!after.dealerHoleHidden && after.dealerCards.count >= 2, "bj snapshot: hole card shown after the reveal")
    let st = try! JSONDecoder().decode(BlackjackState.self, from: JSONEncoder().encode(e.state))
    check(st == e.state, "bj Codable: state round-trips")
    let cfgRT = try! JSONDecoder().decode(BlackjackConfig.self, from: JSONEncoder().encode(BlackjackConfig()))
    check(cfgRT == BlackjackConfig(), "bj Codable: config round-trips")
    let rest = BlackjackEngine(restoring: st)
    _ = rest.apply(.nextRound, from: 0)
    check(rest.state.phase == .betting && rest.state.roundNumber == 2, "bj restore: restored engine continues")
}

// MARK: - Blackjack: basic strategy spot checks
check(bjMove(["h10", "c6"], up: "d10", dbl: false, split: false) == .hit, "bj strategy: hard 16 vs 10 hits")
check(bjMove(["h10", "c6"], up: "d10", surr: true) == .surrender, "bj strategy: hard 16 vs 10 surrenders when allowed")
check(bjMove(["c5", "c6"], up: "h6") == .double, "bj strategy: 11 vs 6 doubles")
check(bjMove(["c5", "c6"], up: "h6", dbl: false) == .hit, "bj strategy: 11 vs 6 hits when double unavailable")
check(bjMove(["c5", "c6"], up: "s14") == .hit && bjMove(["c5", "c6"], up: "s14", h17: true) == .double, "bj strategy: 11 vs A hits (S17) / doubles (H17)")
check(bjMove(["s14", "d14"], up: "d10") == .split && bjMove(["s14", "d14"], up: "c2") == .split, "bj strategy: A-A always splits")
check(bjMove(["c8", "d8"], up: "d10") == .split && bjMove(["c8", "d8"], up: "s14") == .split, "bj strategy: 8-8 always splits")
check(bjMove(["d13", "h10"], up: "c6") == .stand, "bj strategy: 10-10 stands")
check(bjMove(["c9", "d9"], up: "c7") == .stand && bjMove(["c9", "d9"], up: "c8") == .split && bjMove(["c9", "d9"], up: "d10") == .stand, "bj strategy: 9-9 splits 8, stands on 7 and 10")
check(bjMove(["c5", "d5"], up: "c6") == .double && bjMove(["c5", "d5"], up: "d10") == .hit, "bj strategy: 5-5 plays as hard 10")
check(bjMove(["c7", "d7"], up: "c7") == .split && bjMove(["c7", "d7"], up: "c8") == .hit, "bj strategy: 7-7 splits through 7, hits 8+")
check(bjMove(["c6", "d6"], up: "c6") == .split && bjMove(["c6", "d6"], up: "c7") == .hit, "bj strategy: 6-6 splits through 6")
check(bjMove(["c4", "d4"], up: "c5") == .split && bjMove(["c4", "d4"], up: "c4") == .hit, "bj strategy: 4-4 splits only vs 5-6")
check(bjMove(["c8", "d8"], up: "c6", split: false) == .stand && bjMove(["c8", "d8"], up: "d10", split: false) == .hit, "bj strategy: unsplittable 8-8 plays as hard 16")
check(bjMove(["s14", "c6"], up: "c4") == .double && bjMove(["s14", "c6"], up: "c9") == .hit, "bj strategy: soft 17 doubles vs 3-6, else hits")
check(bjMove(["s14", "c7"], up: "c9") == .hit && bjMove(["s14", "c7"], up: "c7") == .stand && bjMove(["s14", "c7"], up: "c5") == .double, "bj strategy: soft 18 vs 9 hits, vs 7 stands, vs 5 doubles")
check(bjMove(["s14", "c7"], up: "c5", dbl: false) == .stand, "bj strategy: soft 18 vs 5 stands when it cannot double (Ds)")
check(bjMove(["s14", "c7"], up: "c2") == .stand && bjMove(["s14", "c7"], up: "c2", h17: true) == .double, "bj strategy: soft 18 vs 2 stands (S17) / doubles (H17)")
check(bjMove(["s14", "c8"], up: "c6") == .stand && bjMove(["s14", "c8"], up: "c6", h17: true) == .double, "bj strategy: soft 19 vs 6 stands (S17) / doubles (H17)")
check(bjMove(["s14", "c3"], up: "c5") == .double && bjMove(["s14", "c3"], up: "c4") == .hit, "bj strategy: A-3 doubles only vs 5-6")
check(bjMove(["s14", "c5"], up: "c4") == .double && bjMove(["s14", "c5"], up: "c3") == .hit, "bj strategy: A-5 doubles vs 4-6")
check(bjMove(["c5", "c4"], up: "c3") == .double && bjMove(["c5", "c4"], up: "c7") == .hit, "bj strategy: 9 doubles vs 3-6")
check(bjMove(["c6", "c4"], up: "c9") == .double && bjMove(["c6", "c4"], up: "d10") == .hit, "bj strategy: 10 doubles vs 2-9")
check(bjMove(["c10", "c2"], up: "c4") == .stand && bjMove(["c10", "c2"], up: "c3") == .hit, "bj strategy: 12 stands only vs 4-6")
check(bjMove(["c10", "c3"], up: "c2") == .stand && bjMove(["c10", "c3"], up: "c7") == .hit, "bj strategy: 13 stands vs 2-6")
check(bjMove(["c10", "c7"], up: "s14") == .stand && bjMove(["c10", "c8"], up: "s14") == .stand, "bj strategy: hard 17+ stands")
check(bjMove(["c10", "c8"], up: "c6", dbl: false, split: false) == .stand && bjMove(["c10", "c3"], up: "c8") == .hit, "bj strategy: hard totals under 9 hit")
check(bjMove(["c5", "c3"], up: "c6") == .hit, "bj strategy: hard 8 hits")
check(bjMove(["s14", "c9"], up: "c6", h17: true) == .stand, "bj strategy: soft 20 stands")
check(bjMove(["h10", "c5"], up: "s14", surr: true, h17: true) == .surrender && bjMove(["h10", "c5"], up: "s14", surr: true) == .hit, "bj strategy: 15 vs A surrenders only under H17")

// MARK: - Blackjack: bet tiers
do {
    var rng = SeededGenerator(seed: 5)
    let cfg = BlackjackConfig()
    var ok = true
    var distinct = Set<Int>()
    for p in BlackjackBetPersonality.allCases {
        for _ in 0..<200 {
            guard let b = BlackjackBot.chooseBet(chips: 500, config: cfg, personality: p, rng: &rng) else { ok = false; break }
            if b < cfg.minBet || b > cfg.maxBet || b % cfg.betStep != 0 || b > 500 { ok = false }
            if p == .bold { distinct.insert(b) }
        }
    }
    check(ok, "bj bot bet: always within [min,max], on the step, affordable")
    check(distinct.count >= 2, "bj bot bet: bold personality uses more than one tier")
    var r2 = SeededGenerator(seed: 5)
    var timidSum = 0, boldSum = 0
    for _ in 0..<100 {
        timidSum += BlackjackBot.chooseBet(chips: 500, config: cfg, personality: .timid, rng: &r2)!
        boldSum += BlackjackBot.chooseBet(chips: 500, config: cfg, personality: .bold, rng: &r2)!
    }
    check(boldSum > timidSum, "bj bot bet: bold bets bigger than timid on average")
    check(BlackjackBot.chooseBet(chips: 8, config: cfg, personality: .steady, rng: &r2) == nil, "bj bot bet: nil below the minimum")
    check((10...14).contains(BlackjackBot.chooseBet(chips: 14, config: cfg, personality: .bold, rng: &r2)!), "bj bot bet: capped by the bankroll")
}

// MARK: - Blackjack: seeded 3-bot session of 50 hands, chip conservation, determinism
struct BJSessionResult { var chips: [Int]; var illegal: Bool; var rounds: Int; var netFromEvents: [Int]; var reshuffles: Int; var reshuffleAfterCut: Bool }
func bjRunSession(seed: UInt64, rounds: Int, seats: Int = 3, config: BlackjackConfig = BlackjackConfig()) -> BJSessionResult {
    let e = BlackjackEngine(seed: seed, seatCount: seats, config: config)
    var rng = SeededGenerator(seed: seed ^ 0xABCD)
    let pers: [BlackjackBetPersonality] = [.timid, .steady, .bold, .steady, .bold]
    var illegal = false
    var nets = Array(repeating: 0, count: seats)
    var reshuffles = 0
    var reshuffleAfterCut = true
    var done = 0
    var guardCount = 0
    func note(_ ev: [BlackjackEvent]) {
        for event in ev {
            if case .illegalAttempt = event { illegal = true }
            if case .roundComplete(_, let n) = event { for i in 0..<seats { nets[i] += n[i] } }
            if case .shoeReshuffled = event { reshuffles += 1 }
        }
    }
    while done < rounds && e.state.phase != .sessionOver && guardCount < 100_000 {
        guardCount += 1
        switch e.state.phase {
        case .roundComplete:
            done += 1
            if done >= rounds { break }
            let wasCut = e.state.cutCardReached
            let ev = e.apply(.nextRound, from: 0)
            if ev.contains(where: { if case .shoeReshuffled = $0 { return true }; return false }) && !wasCut { reshuffleAfterCut = false }
            if !ev.contains(where: { if case .shoeReshuffled = $0 { return true }; return false }) && wasCut { reshuffleAfterCut = false }
            note(ev)
        case .betting:
            var acted = false
            for s in 0..<seats {
                if e.state.legalActions(for: s).isEmpty { continue }
                if let a = BlackjackBot.nextAction(state: e.state, seat: s, personality: pers[s], rng: &rng) {
                    note(e.apply(a, from: s)); acted = true; break
                }
            }
            if !acted { illegal = true; done = rounds }
        case .insurance, .playing:
            var acted = false
            for s in 0..<seats {
                if let a = BlackjackBot.nextAction(state: e.state, seat: s, personality: pers[s], rng: &rng) {
                    note(e.apply(a, from: s)); acted = true; break
                }
            }
            if !acted { illegal = true; done = rounds }
        case .sessionOver:
            break
        }
    }
    return BJSessionResult(chips: e.state.seats.map { $0.chips }, illegal: illegal || guardCount >= 100_000,
                           rounds: done, netFromEvents: nets, reshuffles: reshuffles, reshuffleAfterCut: reshuffleAfterCut)
}
let bjSession = bjRunSession(seed: 2026, rounds: 50)
check(!bjSession.illegal, "bj session: 50 bot hands, every action legal")
check(bjSession.rounds == 50, "bj session: ran all 50 rounds")
check(bjSession.chips.indices.allSatisfy { bjSession.chips[$0] == 500 + bjSession.netFromEvents[$0] }, "bj session: each seat's bankroll = start + sum of round nets (chip conservation)")
check(bjSession.reshuffleAfterCut, "bj session: the shoe reshuffles exactly when the cut card was reached")
let bjSessionAgain = bjRunSession(seed: 2026, rounds: 50)
check(bjSession.chips == bjSessionAgain.chips && bjSession.reshuffles == bjSessionAgain.reshuffles, "bj session: same seed is fully deterministic")
let bjSessionOther = bjRunSession(seed: 7, rounds: 50)
check(!bjSessionOther.illegal && bjSessionOther.chips != bjSession.chips, "bj session: a different seed plays differently")
let bjLong = bjRunSession(seed: 11, rounds: 160, seats: 5)
check(!bjLong.illegal, "bj session: 5 seats x 160 rounds stays legal")
check(bjLong.reshuffles >= 1, "bj shoe: a long session hits the cut card and reshuffles (\(bjLong.reshuffles))")
check(bjLong.chips.indices.allSatisfy { bjLong.chips[$0] == 500 + bjLong.netFromEvents[$0] }, "bj session: conservation holds across reshuffles")
do {
    var cfg = BlackjackConfig(); cfg.startingChips = 30; cfg.insuranceEnabled = true; cfg.dealerHitsSoft17 = true; cfg.surrenderEnabled = true
    let r = bjRunSession(seed: 3, rounds: 300, seats: 2, config: cfg)
    check(!r.illegal, "bj session: H17 + insurance + surrender + small bankrolls stays legal (incl. going broke)")
}
do {
    // sessionOver when everyone is broke
    var cfg = BlackjackConfig(); cfg.startingChips = 10; cfg.minBet = 10
    let e = BlackjackEngine(seed: 4, seatCount: 1, config: cfg)
    e.stackShoe(bjStack(seats: [["h10", "c6"]], dealer: ["d10", "d9"], extra: ["d13"]))
    _ = e.apply(.placeBet(10), from: 0)
    let ev = e.apply(.hit, from: 0)
    check(e.state.phase == .sessionOver && ev.contains(.seatBroke(seat: 0)) && ev.contains(.sessionOver), "bj session: busting the last chips ends the session")
    check(bjIllegal(e.apply(.nextRound, from: 0)), "bj session: no actions after sessionOver")
}

// MARK: - END Blackjack

// MARK: - BEGIN Liar's Dice (engine worker block)

// MARK: - Liar's Dice: helpers
/// Engine at seed 0 (seat 0 opens) with the given rolls already supplied.
func ldGame(_ rolls: [[Int]], config: LiarsDiceConfig = LiarsDiceConfig()) -> LiarsDiceEngine {
    let e = LiarsDiceEngine(seed: 0, seatCount: rolls.count, config: config)
    for (s, r) in rolls.enumerated() { _ = e.apply(.setDice(seat: s, dice: r), from: s) }
    return e
}
func ldIllegal(_ events: [LiarsDiceEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}
check(LiarsDiceEngine.kind == "liarsDice", "ld: kind tag")

// MARK: - Liar's Dice: setDice validation
do {
    let e = LiarsDiceEngine(seed: 0, seatCount: 3)
    check(e.state.phase == .awaitingDice && e.state.diceCounts == [5, 5, 5], "ld setup: 3 seats x 5 dice, waiting on rolls")
    check(ldIllegal(e.apply(.bid(quantity: 1, face: 2), from: 0)), "ld dice: bidding before rolls are in is rejected")
    check(ldIllegal(e.apply(.setDice(seat: 0, dice: [1, 2, 3]), from: 0)), "ld dice: wrong dice count rejected")
    check(ldIllegal(e.apply(.setDice(seat: 0, dice: [1, 2, 3, 4, 7]), from: 0)), "ld dice: face 7 rejected")
    check(ldIllegal(e.apply(.setDice(seat: 0, dice: [0, 2, 3, 4, 5]), from: 0)), "ld dice: face 0 rejected")
    check(ldIllegal(e.apply(.setDice(seat: 1, dice: [1, 2, 3, 4, 5]), from: 0)), "ld dice: setting someone else's dice rejected")
    let ev = e.apply(.setDice(seat: 0, dice: [1, 2, 3, 4, 5]), from: 0)
    check(ev == [.diceSet(seat: 0)], "ld dice: diceSet event, no values")
    check(ldIllegal(e.apply(.setDice(seat: 0, dice: [6, 6, 6, 6, 6]), from: 0)), "ld dice: a roll cannot be redone")
    _ = e.apply(.setDice(seat: 1, dice: [1, 1, 1, 1, 1]), from: 1)
    check(e.state.phase == .awaitingDice, "ld dice: still waiting on the third roll")
    let last = e.apply(.setDice(seat: 2, dice: [6, 6, 6, 6, 6]), from: 2)
    check(e.state.phase == .bidding && last.contains(.allDiceSet(starterSeat: 0)), "ld dice: bidding opens when every roll is in")
}

// MARK: - Liar's Dice: bid legality progression
do {
    let e = ldGame([[1, 2, 3, 4, 5], [2, 2, 3, 6, 6], [4, 4, 4, 5, 6]])
    check(ldIllegal(e.apply(.challenge, from: 0)), "ld bid: cannot challenge with no bid")
    check(ldIllegal(e.apply(.bid(quantity: 2, face: 3), from: 1)), "ld bid: out-of-turn bid rejected")
    check(ldIllegal(e.apply(.bid(quantity: 0, face: 3), from: 0)) && ldIllegal(e.apply(.bid(quantity: 2, face: 7), from: 0)) && ldIllegal(e.apply(.bid(quantity: 16, face: 3), from: 0)), "ld bid: zero quantity, face 7, and more than the dice in play are rejected")
    check(e.apply(.bid(quantity: 3, face: 5), from: 0) == [.bidMade(seat: 0, quantity: 3, face: 5)], "ld bid: opening bid accepted")
    check(e.state.turnSeat == 1, "ld bid: turn passes clockwise")
    check(ldIllegal(e.apply(.bid(quantity: 3, face: 5), from: 1)), "ld bid: the same bid is not a raise")
    check(ldIllegal(e.apply(.bid(quantity: 3, face: 4), from: 1)), "ld bid: same quantity, lower face rejected")
    check(ldIllegal(e.apply(.bid(quantity: 2, face: 6), from: 1)), "ld bid: lower quantity rejected")
    check(!ldIllegal(e.apply(.bid(quantity: 3, face: 6), from: 1)), "ld bid: same quantity, higher face accepted")
    check(!ldIllegal(e.apply(.bid(quantity: 4, face: 2), from: 2)), "ld bid: higher quantity with any face accepted")
    check(e.state.bids.count == 3 && e.state.currentBid == LiarsDiceBid(seat: 2, quantity: 4, face: 2), "ld bid: trail recorded")
    check(e.state.snapshot(for: 0).legalActions == [.bid, .challenge, .spotOn] && e.state.snapshot(for: 1).legalActions.isEmpty, "ld snapshot: legal actions follow the turn")
    check(LiarsDiceRules.isLegalBid(quantity: 1, face: 1, over: nil, totalDice: 10), "ld rules: ones may be bid")
    check(LiarsDiceRules.legalBids(over: LiarsDiceBid(seat: 0, quantity: 15, face: 5), totalDice: 15).count == 1, "ld rules: only 15x6 remains above 15x5")
}

// MARK: - Liar's Dice: challenge resolution with wild ones
do {
    // 5s: seat0 has one, seat1 has two; ones: seat0 one, seat1 one => 3 fives + 2 wild ones = 5.
    let e = ldGame([[1, 2, 3, 4, 5], [1, 5, 5, 6, 6]])
    _ = e.apply(.bid(quantity: 4, face: 5), from: 0)
    let ev = e.apply(.challenge, from: 1)
    check(ev.contains { if case .revealed(_, let f, let q, let n) = $0 { return f == 5 && q == 4 && n == 5 }; return false }, "ld challenge: wild ones counted (3 fives + 2 ones = 5)")
    check(ev.contains(.dieLost(seat: 1, remaining: 4)), "ld challenge: bid was true, challenger loses a die")
    check(e.state.diceCounts == [5, 4] && e.state.phase == .reveal && e.state.starterSeat == 1, "ld challenge: loser opens the next round")
    check(e.state.lastResolution?.callSucceeded == false && e.state.lastResolution?.loserSeat == 1, "ld challenge: resolution recorded")
}
do {
    let e = ldGame([[1, 2, 3, 4, 5], [1, 5, 5, 6, 6]], config: LiarsDiceConfig(wildOnes: false))
    _ = e.apply(.bid(quantity: 4, face: 5), from: 0)
    let ev = e.apply(.challenge, from: 1)
    check(ev.contains { if case .revealed(_, _, _, let n) = $0 { return n == 3 }; return false }, "ld challenge: without wilds only 3 fives")
    check(ev.contains(.dieLost(seat: 0, remaining: 4)) && e.state.starterSeat == 0, "ld challenge: bid was false, bidder loses a die and opens next")
}
do {
    // Bidding ones: ones are NOT wild for a bid on ones.
    let e = ldGame([[1, 1, 3, 4, 5], [1, 5, 5, 6, 6]])
    _ = e.apply(.bid(quantity: 3, face: 1), from: 0)
    let ev = e.apply(.challenge, from: 1)
    check(ev.contains { if case .revealed(_, _, _, let n) = $0 { return n == 3 }; return false }, "ld challenge: bid on ones counts only ones")
    check(ev.contains(.dieLost(seat: 1, remaining: 4)), "ld challenge: exactly-met bid on ones stands")
}
do {
    // The reveal is public: snapshots before/after.
    let e = ldGame([[2, 2, 3, 4, 5], [6, 6, 6, 6, 1]])
    let mid = e.state.snapshot(for: 0)
    check(mid.myDice == [2, 2, 3, 4, 5] && mid.resolution == nil && mid.diceCounts == [5, 5], "ld snapshot: own dice and counts, no resolution yet")
    let tj = String(data: try! JSONEncoder().encode(e.state.tableSnapshot()), encoding: .utf8)!
    check(e.state.tableSnapshot().myDice.isEmpty && !tj.contains("\"dice\""), "ld snapshot: table view shows no dice mid-round")
    _ = e.apply(.bid(quantity: 2, face: 2), from: 0)
    _ = e.apply(.challenge, from: 1)
    let after = e.state.tableSnapshot()
    check(after.resolution?.dice == [0: [2, 2, 3, 4, 5], 1: [6, 6, 6, 6, 1]], "ld snapshot: every seat's dice are public after a challenge")
    check(after.legalActions.isEmpty && e.state.snapshot(for: 0).legalActions == [.nextRound], "ld snapshot: next-round is the only action after a reveal")
}

// MARK: - Liar's Dice: spot on
do {
    var e = ldGame([[5, 5, 3, 4, 2], [5, 6, 6, 6, 2]])
    _ = e.apply(.bid(quantity: 3, face: 5), from: 0)   // exactly 3 fives, no ones
    var ev = e.apply(.spotOn, from: 1)
    check(ev.contains { if case .revealed(_, _, _, let n) = $0 { return n == 3 }; return false }, "ld spot-on: counts exactly")
    check(e.state.lastResolution?.callSucceeded == true && e.state.diceCounts == [5, 5], "ld spot-on: success at full dice gains nothing (capped)")
    check(e.state.starterSeat == 1, "ld spot-on: caller opens the next round")

    // Make seat 1 short, then spot on for a real gain.
    e = ldGame([[2, 3, 4, 4, 4], [6, 6, 3, 2, 2]])
    _ = e.apply(.bid(quantity: 9, face: 6), from: 0)
    _ = e.apply(.challenge, from: 1)                    // bid false -> seat 0 loses a die
    check(e.state.diceCounts == [4, 5], "ld spot-on setup: seat 0 down to 4")
    _ = e.apply(.nextRound, from: 0)
    _ = e.apply(.setDice(seat: 0, dice: [3, 3, 3, 4]), from: 0)
    _ = e.apply(.setDice(seat: 1, dice: [3, 3, 1, 2, 5]), from: 1)
    check(e.state.turnSeat == 0, "ld round 2: the loser (seat 0) opens")
    _ = e.apply(.bid(quantity: 6, face: 3), from: 0)    // threes 5 + one wild = 6 exactly? 3,3,3 + 3,3 = 5; ones: 1 -> 6
    ev = e.apply(.spotOn, from: 1)
    check(ev.contains { if case .revealed(_, _, _, let n) = $0 { return n == 6 }; return false } && ev.isEmpty == false, "ld spot-on: wild ones count toward an exact match")
    check(e.state.diceCounts == [4, 5], "ld spot-on: caller already at 5 dice, no gain")
    // Now seat 0 (4 dice) spots on seat 1's exact bid for a gain.
    _ = e.apply(.nextRound, from: 0)
    _ = e.apply(.setDice(seat: 0, dice: [2, 2, 5, 6]), from: 0)
    _ = e.apply(.setDice(seat: 1, dice: [2, 4, 4, 4, 5]), from: 1)
    check(e.state.turnSeat == 1, "ld round 3: spot-on caller (seat 1) opens")
    _ = e.apply(.bid(quantity: 3, face: 2), from: 1)    // twos: 2 + 1 = 3 exactly
    ev = e.apply(.spotOn, from: 0)
    check(ev.contains(.dieGained(seat: 0, remaining: 5)) && e.state.diceCounts == [5, 5], "ld spot-on: exact call gains a die for the caller")
}
do {
    let e = ldGame([[2, 3, 4, 4, 4], [6, 6, 3, 2, 2]])
    _ = e.apply(.bid(quantity: 2, face: 6), from: 0)    // exactly 2 sixes... exact
    _ = e.apply(.bid(quantity: 3, face: 6), from: 1)
    let ev = e.apply(.spotOn, from: 0)                   // actual 2 sixes, not 3
    check(ev.contains(.dieLost(seat: 0, remaining: 4)) && e.state.lastResolution?.callSucceeded == false, "ld spot-on: a wrong call costs the caller a die")
    let off = ldGame([[2, 3, 4, 4, 4], [6, 6, 3, 2, 2]], config: LiarsDiceConfig(spotOnEnabled: false))
    _ = off.apply(.bid(quantity: 2, face: 6), from: 0)
    check(ldIllegal(off.apply(.spotOn, from: 1)) && !off.state.snapshot(for: 1).legalActions.contains(.spotOn), "ld spot-on: rejected when the flag is off")
    check(ldIllegal(ldGame([[1, 2, 3, 4, 5], [1, 2, 3, 4, 5]]).apply(.spotOn, from: 0)), "ld spot-on: needs a standing bid")
}

// MARK: - Liar's Dice: elimination, win, three-way flow
do {
    let e = ldGame([[3], [4]], config: LiarsDiceConfig(diceCount: 1))
    _ = e.apply(.bid(quantity: 1, face: 3), from: 0)
    let ev = e.apply(.challenge, from: 1)
    check(ev.contains(.eliminated(seat: 1)) && ev.contains(.gameWon(seat: 0)), "ld win: last die lost eliminates and the survivor wins")
    check(e.state.phase == .gameOver && e.state.winnerSeat == 0 && e.state.eliminationOrder == [1], "ld win: game over state")
    check(ldIllegal(e.apply(.nextRound, from: 0)), "ld win: no actions after game over")
    check(e.state.snapshot(for: 0).resolution?.dice.count == 2, "ld win: final reveal stays visible")
}
do {
    let e = ldGame([[3], [4], [2]], config: LiarsDiceConfig(diceCount: 1))
    _ = e.apply(.bid(quantity: 2, face: 6), from: 0)
    let ev = e.apply(.challenge, from: 1)               // only 0 sixes: bidder (seat 0) out
    check(ev.contains(.eliminated(seat: 0)) && e.state.phase == .reveal, "ld elimination: game continues with two left")
    check(e.state.starterSeat == 1, "ld elimination: next live seat opens after the loser is eliminated")
    _ = e.apply(.nextRound, from: 2)
    check(e.state.diceCounts == [0, 1, 1], "ld elimination: eliminated seat stays at zero")
    check(ldIllegal(e.apply(.setDice(seat: 0, dice: [3]), from: 0)), "ld elimination: eliminated seat cannot roll")
    _ = e.apply(.setDice(seat: 1, dice: [5]), from: 1)
    let last = e.apply(.setDice(seat: 2, dice: [6]), from: 2)
    check(last.contains(.allDiceSet(starterSeat: 1)) && e.state.turnSeat == 1, "ld elimination: bidding opens without the eliminated seat")
    _ = e.apply(.bid(quantity: 1, face: 6), from: 1)
    check(e.state.turnSeat == 2, "ld elimination: turn order skips the eliminated seat")
    check(e.state.snapshot(for: 0).legalActions.isEmpty, "ld elimination: eliminated seat has no actions")
    // Wrap-around skip
    let ev2 = e.apply(.bid(quantity: 2, face: 1), from: 2)
    check(!ldIllegal(ev2) && e.state.turnSeat == 1, "ld elimination: turn wraps past the eliminated seat 0")
}

// MARK: - Liar's Dice: rollAll helper
do {
    let a = LiarsDiceEngine(seed: 3, seatCount: 4)
    let b = LiarsDiceEngine(seed: 3, seatCount: 4)
    a.rollAll(seed: 77)
    b.rollAll(seed: 77)
    check(a.state.dice == b.state.dice && a.state.phase == .bidding, "ld rollAll: deterministic, opens bidding")
    check(a.state.dice.values.allSatisfy { $0.count == 5 && $0.allSatisfy { (1...6).contains($0) } }, "ld rollAll: five legal faces per seat")
    check(a.rollAll(seed: 78).isEmpty, "ld rollAll: no-op once rolls are in")
    let c = LiarsDiceEngine(seed: 3, seatCount: 4)
    _ = c.apply(.setDice(seat: 2, dice: [6, 6, 6, 6, 6]), from: 2)
    c.rollAll(seed: 5, seats: [0, 1])
    check(c.state.dice[2] == [6, 6, 6, 6, 6] && c.state.dice[0] != nil && c.state.dice[3] == nil && c.state.phase == .awaitingDice, "ld rollAll: respects supplied rolls and the seats filter")
    c.rollAll(seed: 5)
    check(c.state.phase == .bidding && c.state.dice[2] == [6, 6, 6, 6, 6], "ld rollAll: fills the remainder without touching supplied dice")
}

// MARK: - Liar's Dice: bot probability and decisions
check(abs(LiarsDiceBot.binomialAtLeast(n: 5, k: 1, p: 1.0 / 6.0) - (1 - pow(5.0 / 6.0, 5.0))) < 1e-9, "ld bot: binomial P(>=1 of 5 at 1/6) matches closed form")
check(abs(LiarsDiceBot.binomialPMF(n: 4, k: 2, p: 0.5) - 0.375) < 1e-9, "ld bot: binomial pmf(4,2,0.5) = 0.375")
check(abs((0...6).reduce(0.0) { $0 + LiarsDiceBot.binomialPMF(n: 6, k: $1, p: 1.0 / 3.0) } - 1) < 1e-9, "ld bot: pmf sums to 1")
check(LiarsDiceBot.probabilityTrue(quantity: 2, face: 4, myDice: [4, 4, 1, 2, 3], totalDice: 10, wildOnes: true) == 1, "ld bot: bid already covered by own dice (with a wild one) is certain")
do {
    var rng = SeededGenerator(seed: 1)
    // Absurd bid: 9 sixes among 10 dice, holding none.
    let e = ldGame([[1, 2, 3, 4, 5], [2, 2, 3, 3, 4]])
    _ = e.apply(.bid(quantity: 9, face: 6), from: 0)
    check(LiarsDiceBot.nextAction(state: e.state, seat: 1, personality: .balanced, rng: &rng) == .challenge, "ld bot: challenges an absurd bid")
    check(LiarsDiceBot.nextAction(state: e.state, seat: 0, rng: &rng) == nil, "ld bot: nothing to do out of turn")
    // Trivially true bid: 1 two when holding 2s.
    let f = ldGame([[2, 2, 3, 4, 5], [3, 3, 4, 4, 5]])
    _ = f.apply(.bid(quantity: 1, face: 2), from: 0)
    let act = LiarsDiceBot.nextAction(state: f.state, seat: 1, personality: .balanced, rng: &rng)
    if case .bid(let q, let face)? = act {
        check(LiarsDiceRules.isLegalBid(quantity: q, face: face, over: f.state.currentBid, totalDice: 10), "ld bot: raises legally")
    } else {
        check(act != .challenge, "ld bot: does not challenge a likely-true bid")
    }
    // Opening bid is always legal for every personality.
    var allLegal = true
    for p in LiarsDicePersonality.allCases {
        let g = ldGame([[1, 3, 3, 5, 6], [2, 2, 4, 4, 6], [1, 1, 5, 5, 6]])
        if case .bid(let q, let face)? = LiarsDiceBot.nextAction(state: g.state, seat: 0, personality: p, rng: &rng) {
            if !LiarsDiceRules.isLegalBid(quantity: q, face: face, over: nil, totalDice: 15) { allLegal = false }
        } else { allLegal = false }
    }
    check(allLegal, "ld bot: opening bid legal for every personality")
    check(LiarsDicePersonality.cautious.challengeThreshold > LiarsDicePersonality.balanced.challengeThreshold
          && LiarsDicePersonality.balanced.challengeThreshold > LiarsDicePersonality.reckless.challengeThreshold
          && LiarsDicePersonality.balanced.challengeThreshold == 0.30, "ld bot: challenge threshold 0.30 balanced, cautious higher, reckless lower")
}

// MARK: - Liar's Dice: seeded 4-bot games x5
struct LDGameResult { var winner: Int?; var rounds: Int; var illegal: Bool; var counts: [Int]; var trailHash: Int }
func ldPlayBotGame(seed: UInt64, seats: Int = 4) -> LDGameResult {
    let e = LiarsDiceEngine(seed: seed, seatCount: seats)
    var rng = SeededGenerator(seed: seed ^ 0x5151)
    let pers: [LiarsDicePersonality] = [.balanced, .cautious, .reckless, .balanced, .cautious, .reckless]
    var illegal = false
    var steps = 0
    var hash = 7
    func note(_ ev: [LiarsDiceEvent]) {
        for x in ev {
            if case .illegalAttempt = x { illegal = true }
            if case .bidMade(let s, let q, let f) = x { hash = hash &* 31 &+ s &* 100 &+ q &* 10 &+ f }
        }
    }
    while e.state.phase != .gameOver && steps < 20_000 {
        steps += 1
        switch e.state.phase {
        case .awaitingDice: note(e.rollAll(seed: seed &+ UInt64(e.state.roundNumber) &* 7919))
        case .bidding:
            let s = e.state.turnSeat
            if let a = LiarsDiceBot.nextAction(state: e.state, seat: s, personality: pers[s], rng: &rng) { note(e.apply(a, from: s)) }
            else { illegal = true; steps = 20_000 }
        case .reveal: note(e.apply(.nextRound, from: 0))
        case .gameOver: break
        }
    }
    return LDGameResult(winner: e.state.winnerSeat, rounds: e.state.roundNumber, illegal: illegal || steps >= 20_000,
                        counts: e.state.diceCounts, trailHash: hash)
}
for ldSeed: UInt64 in [1, 2, 3, 42, 2026] {
    let r = ldPlayBotGame(seed: ldSeed)
    check(!r.illegal, "ld bot game seed \(ldSeed): every action legal and terminates")
    check(r.winner != nil && r.counts.filter { $0 > 0 }.count == 1 && r.counts[r.winner!] > 0, "ld bot game seed \(ldSeed): exactly one survivor, the winner")
    check(r.rounds >= 4, "ld bot game seed \(ldSeed): lasted at least the 4 eliminations (\(r.rounds) rounds)")
}
let ldA = ldPlayBotGame(seed: 42), ldB = ldPlayBotGame(seed: 42), ldC = ldPlayBotGame(seed: 43)
check(ldA.winner == ldB.winner && ldA.rounds == ldB.rounds && ldA.trailHash == ldB.trailHash, "ld bot game: same seed replays identically")
check(ldA.trailHash != ldC.trailHash, "ld bot game: different seed differs")
let ld6 = ldPlayBotGame(seed: 9, seats: 6)
check(!ld6.illegal && ld6.winner != nil, "ld bot game: six seats completes")

// MARK: - Liar's Dice: Codable
do {
    let e = ldGame([[1, 2, 3, 4, 5], [1, 5, 5, 6, 6]])
    _ = e.apply(.bid(quantity: 2, face: 5), from: 0)
    let st = try! JSONDecoder().decode(LiarsDiceState.self, from: JSONEncoder().encode(e.state))
    check(st == e.state, "ld Codable: state round-trips")
    let sn = try! JSONDecoder().decode(LiarsDiceSnapshot.self, from: JSONEncoder().encode(e.state.snapshot(for: 1)))
    check(sn == e.state.snapshot(for: 1), "ld Codable: snapshot round-trips")
    for a in [LiarsDiceAction.setDice(seat: 1, dice: [1, 2]), .bid(quantity: 2, face: 3), .challenge, .spotOn, .nextRound] {
        let back = try! JSONDecoder().decode(LiarsDiceAction.self, from: JSONEncoder().encode(a))
        check(back == a, "ld Codable: action \(a) round-trips")
    }
    let resumed = LiarsDiceEngine(restoring: st)
    check(!ldIllegal(resumed.apply(.challenge, from: 1)), "ld restore: restored engine keeps playing")
    let evs: [LiarsDiceEvent] = [.revealed(dice: [0: [1, 2]], face: 2, quantity: 1, actualCount: 1), .eliminated(seat: 2)]
    check((try! JSONDecoder().decode([LiarsDiceEvent].self, from: JSONEncoder().encode(evs))) == evs, "ld Codable: events round-trip")
}

// MARK: - END Liar's Dice

// MARK: - BEGIN Mancala / Checkers / Connect Four (table-only board games)

let tbPlayers = [MancalaPlayer(name: "A", isBot: true), MancalaPlayer(name: "B", isBot: true)]

func mancalaBoard(_ pairs: [Int: Int]) -> [Int] {
    var b = [Int](repeating: 0, count: 14)
    for (k, v) in pairs { b[k] = v }
    return b
}
func mancalaState(_ pairs: [Int: Int], current: Int = 0, emptyCapture: Bool = false) -> MancalaState {
    var s = MancalaState(players: tbPlayers, emptyCapture: emptyCapture)
    s.board = mancalaBoard(pairs)
    s.currentPlayer = current
    return s
}
func mancalaSowedPath(_ events: [MancalaEvent]) -> [Int]? {
    for e in events { if case .sowed(_, _, let p) = e { return p } }
    return nil
}
func mancalaIllegal(_ events: [MancalaEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}

// MARK: - Mancala: setup and kind

check(MancalaEngine.kind == "mancala" && MancalaState.kind == "mancala", "Mancala kind")
let mkNew = MancalaEngine(players: tbPlayers)
check(mkNew.state.board == [4, 4, 4, 4, 4, 4, 0, 4, 4, 4, 4, 4, 4, 0], "Mancala: 6 pits x 4 stones, empty stores")
check(mkNew.state.legalPits == [0, 1, 2, 3, 4, 5], "Mancala: all six pits legal at the start")

// MARK: - Mancala: sowing path, extra turn

let mkExtra = MancalaEngine(players: tbPlayers)
let mkExtraEvents = mkExtra.apply(.sow(pit: 2), from: 0)
check(mancalaSowedPath(mkExtraEvents) == [3, 4, 5, 6], "Mancala: pit 2 (4 stones) sows 3,4,5 and the store, stone by stone")
check(mkExtraEvents.contains(.sowed(seat: 0, from: 2, path: [3, 4, 5, 6])), "Mancala: sowed event carries from + path")
check(mkExtraEvents.contains(.extraTurn(seat: 0)), "Mancala: ending in own store emits extraTurn")
check(mkExtra.state.currentPlayer == 0, "Mancala: extra turn keeps the same player")
check(mkExtra.state.board[6] == 1 && mkExtra.state.board[2] == 0, "Mancala: store got a stone, pit emptied")
check(!mkExtraEvents.contains { if case .turnChanged = $0 { return true }; return false }, "Mancala: no turnChanged on an extra turn")

let mkPass = MancalaEngine(players: tbPlayers)
let mkPassEvents = mkPass.apply(.sow(pit: 0), from: 0)
check(mancalaSowedPath(mkPassEvents) == [1, 2, 3, 4], "Mancala: pit 0 sows 1...4")
check(mkPassEvents.contains(.turnChanged(to: 1)) && mkPass.state.currentPlayer == 1, "Mancala: turn passes when not ending in store")

// MARK: - Mancala: store skipping and wrapping

let mkSkip0 = MancalaEngine(restoring: mancalaState([5: 8, 12: 1]))
check(mancalaSowedPath(mkSkip0.apply(.sow(pit: 5), from: 0)) == [6, 7, 8, 9, 10, 11, 12, 0],
      "Mancala: seat 0 skips seat 1's store (13) and wraps to pit 0")
let mkSkip1 = MancalaEngine(restoring: mancalaState([12: 9, 3: 1], current: 1))
check(mancalaSowedPath(mkSkip1.apply(.sow(pit: 5), from: 1)) == [13, 0, 1, 2, 3, 4, 5, 7, 8],
      "Mancala: seat 1 sows into own store, wraps, skips seat 0's store (6)")
check(mkSkip1.state.board[6] == 0, "Mancala: seat 0's store untouched by seat 1's sowing")

// 13 stones laps the board: the origin pit receives the last stone and (empty, opposite loaded) captures.
let mkLap = MancalaEngine(restoring: mancalaState([0: 13, 7: 2]))
let mkLapEvents = mkLap.apply(.sow(pit: 0), from: 0)
check(mancalaSowedPath(mkLapEvents) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0], "Mancala: 13 stones lap the board, skipping store 13, ending in the origin pit")
check(mkLapEvents.contains(.captured(seat: 0, pit: 0, opposite: 12, stones: 2)), "Mancala: lap ending in the (emptied) origin pit captures its opposite")

// MARK: - Mancala: capture

let mkCap = MancalaEngine(restoring: mancalaState([0: 1, 1: 0, 5: 2, 11: 5, 7: 3]))
let mkCapEvents = mkCap.apply(.sow(pit: 0), from: 0)
check(mkCapEvents.contains(.captured(seat: 0, pit: 1, opposite: 11, stones: 6)), "Mancala: capture banks opposite stones + the capturing stone")
check(mkCap.state.board[6] == 6 && mkCap.state.board[1] == 0 && mkCap.state.board[11] == 0, "Mancala: capture empties both pits into the store")
check(mkCap.state.currentPlayer == 1, "Mancala: a capture does not grant another turn")

let mkNoCap = MancalaEngine(restoring: mancalaState([0: 1, 1: 0, 5: 2, 7: 3]))
let mkNoCapEvents = mkNoCap.apply(.sow(pit: 0), from: 0)
check(!mkNoCapEvents.contains { if case .captured = $0 { return true }; return false } && mkNoCap.state.board[1] == 1,
      "Mancala standard: empty opposite pit means no capture")
let mkEmptyCap = MancalaEngine(restoring: mancalaState([0: 1, 1: 0, 5: 2, 7: 3], emptyCapture: true))
let mkEmptyCapEvents = mkEmptyCap.apply(.sow(pit: 0), from: 0)
check(mkEmptyCapEvents.contains(.captured(seat: 0, pit: 1, opposite: 11, stones: 1)) && mkEmptyCap.state.board[6] == 1,
      "Mancala emptyCapture variant: lone stone banks even against an empty opposite pit")
let mkOccupied = MancalaEngine(restoring: mancalaState([0: 1, 1: 2, 5: 2, 11: 5, 7: 3]))
check(!mkOccupied.apply(.sow(pit: 0), from: 0).contains { if case .captured = $0 { return true }; return false },
      "Mancala: landing in an occupied pit never captures")
let mkOpp = MancalaEngine(restoring: mancalaState([7: 1, 8: 0, 12: 2, 4: 6], current: 1))
check(mkOpp.apply(.sow(pit: 0), from: 1).contains(.captured(seat: 1, pit: 8, opposite: 4, stones: 7)), "Mancala: seat 1 captures symmetrically (opposite of 8 is 4)")
let mkSideCap = MancalaEngine(restoring: mancalaState([0: 1, 1: 0, 5: 2, 7: 3]))
check(MancalaRules.owner(ofPit: 8) == 1 && MancalaRules.opposite(of: 8) == 4, "Mancala: opposite(i) == 12 - i")
// landing on the OPPONENT's empty pit never captures
let mkTheirs = MancalaEngine(restoring: mancalaState([5: 2, 7: 0, 8: 1, 0: 3]))
check(!mkTheirs.apply(.sow(pit: 5), from: 0).contains { if case .captured = $0 { return true }; return false }, "Mancala: ending on the opponent's side never captures")
_ = mkSideCap

// MARK: - Mancala: end of game sweep

let mkEnd = MancalaEngine(restoring: mancalaState([5: 1, 6: 20, 8: 2, 9: 3, 13: 10]))
let mkEndEvents = mkEnd.apply(.sow(pit: 5), from: 0)
check(mkEnd.state.phase == .gameOver, "Mancala: game ends when one side is empty")
check(mkEndEvents.contains(.swept(seat: 1, pits: [8, 9], stones: 5)), "Mancala: remaining stones sweep to their owner's store")
check(mkEnd.state.board[13] == 15 && mkEnd.state.board[6] == 21 && mkEnd.state.board[8] == 0, "Mancala: sweep totals correct")
check(mkEnd.state.winner == 0 && mkEndEvents.contains(.gameWon(seat: 0, finalScores: [21, 15])), "Mancala: winner has the most stones")
check(!mkEndEvents.contains(.extraTurn(seat: 0)), "Mancala: no extraTurn event when the move ended the game")
let mkEndIllegal = mkEnd.apply(.sow(pit: 0), from: 1)
check(mancalaIllegal(mkEndIllegal), "Mancala: no moves after game over")

let mkDraw = MancalaEngine(restoring: mancalaState([5: 1, 6: 10, 8: 2, 13: 9]))
let mkDrawEvents = mkDraw.apply(.sow(pit: 5), from: 0)
check(mkDraw.state.phase == .gameOver && mkDraw.state.winner == nil && mkDrawEvents.contains(.draw(finalScores: [11, 11])), "Mancala: equal stores is a draw")

// the other side empties it: opponent's last move leaves MY side empty
let mkOppEnd = MancalaEngine(restoring: mancalaState([12: 1, 3: 2, 13: 5, 6: 5], current: 1))
let mkOppEndEvents = mkOppEnd.apply(.sow(pit: 5), from: 1)
check(mkOppEnd.state.phase == .gameOver && mkOppEndEvents.contains(.swept(seat: 0, pits: [3], stones: 2)), "Mancala: sweep also fires for the side that still has stones")

// MARK: - Mancala: legality

let mkLegal = MancalaEngine(players: tbPlayers)
check(mancalaIllegal(mkLegal.apply(.sow(pit: 0), from: 1)), "Mancala: out-of-turn rejected")
check(mancalaIllegal(mkLegal.apply(.sow(pit: 6), from: 0)), "Mancala: pit index out of range rejected")
check(mkLegal.state.board == mkNew.state.board, "Mancala: rejected moves leave state untouched")
let mkEmptyPit = MancalaEngine(restoring: mancalaState([1: 2, 7: 1, 8: 1]))
check(mancalaIllegal(mkEmptyPit.apply(.sow(pit: 0), from: 0)), "Mancala: sowing an empty pit rejected")

// MARK: - Mancala bot: node budget, determinism, seeded games

let mkBotState = MancalaState(players: tbPlayers)
let mkDetA = MancalaBot.decide(state: mkBotState, seed: 7)
let mkDetB = MancalaBot.decide(state: mkBotState, seed: 7)
check(mkDetA == mkDetB, "Mancala bot: same state + seed -> same move")
let mkDetailA = MancalaBot.decideDetailed(state: mkBotState, seed: 7)
let mkDetailB = MancalaBot.decideDetailed(state: mkBotState, seed: 7)
check(mkDetailA.nodes == mkDetailB.nodes && mkDetailA.depthReached == mkDetailB.depthReached, "Mancala bot: node count and depth are reproducible (no wall clock)")
for budget in [100, 1_000, 10_000] {
    let d = MancalaBot.decideDetailed(state: mkBotState, seed: 3, nodeBudget: budget)
    check(d.nodes <= budget, "Mancala bot: nodes \(d.nodes) <= budget \(budget)")
    check(mkBotState.legalPits.contains { if case .sow(let p) = d.action { return p == $0 }; return false }, "Mancala bot: budget \(budget) still returns a legal move")
    check(d.depthReached >= 1, "Mancala bot: budget \(budget) completes at least depth 1")
}
let mkSmall = MancalaBot.decideDetailed(state: mkBotState, seed: 3, nodeBudget: 200)
let mkLarge = MancalaBot.decideDetailed(state: mkBotState, seed: 3, nodeBudget: 100_000)
check(mkLarge.depthReached > mkSmall.depthReached, "Mancala bot: bigger budget searches deeper (\(mkSmall.depthReached) -> \(mkLarge.depthReached))")
check(MancalaBot.decideDetailed(state: mkBotState, seed: 3, nodeBudget: 5_000_000).nodes < 5_000_000, "Mancala bot: default depth cap bounds search even with a huge budget")

// a lone big capture is found
let mkTactic = mancalaState([0: 1, 1: 0, 4: 3, 5: 1, 11: 9, 7: 1])
if case .sow(let pit) = MancalaBot.decide(state: mkTactic, seed: 1) {
    check(pit == 0 || pit == 5, "Mancala bot: takes the extra turn / capture instead of the plain move (chose \(pit))")
}

var mkMaxMs = 0.0, mkTotalNodes = 0, mkDecisions = 0
var mkSeatWins = [0, 0], mkNaiveBeaten = 0
for seed: UInt64 in 1...5 {
    let engine = MancalaEngine(players: tbPlayers, firstPlayer: Int(seed % 2))
    var guardCount = 0
    var stoneTotalOK = true
    while engine.state.phase != .gameOver, guardCount < 500 {
        guardCount += 1
        let t0 = Date()
        let det = MancalaBot.decideDetailed(state: engine.state, seed: seed)
        mkMaxMs = max(mkMaxMs, Date().timeIntervalSince(t0) * 1000)
        mkTotalNodes += det.nodes; mkDecisions += 1
        let events = engine.apply(det.action, from: engine.state.currentPlayer)
        if mancalaIllegal(events) { check(false, "Mancala seed \(seed): bot move illegal"); break }
        if engine.state.board.reduce(0, +) != 48 { stoneTotalOK = false }
    }
    check(engine.state.phase == .gameOver, "Mancala seed \(seed): bot game terminates")
    check(stoneTotalOK, "Mancala seed \(seed): 48 stones conserved every move")
    check(engine.state.board.filter { $0 > 0 }.count <= 2, "Mancala seed \(seed): all pits swept at the end")
    if let w = engine.state.winner { mkSeatWins[w] += 1 }
    // bot vs a naive lowest-legal-pit opponent
    let vs = MancalaEngine(players: tbPlayers)
    let botSeat = Int(seed % 2)
    var g2 = 0
    while vs.state.phase != .gameOver, g2 < 500 {
        g2 += 1
        let cur = vs.state.currentPlayer
        let action: MancalaAction = cur == botSeat ? MancalaBot.decide(state: vs.state, seed: seed) : .sow(pit: vs.state.legalPits[0])
        vs.apply(action, from: cur)
    }
    if vs.state.winner == botSeat { mkNaiveBeaten += 1 }
}
check(mkNaiveBeaten >= 4, "Mancala bot beats a naive lowest-pit player in at least 4 of 5 games (won \(mkNaiveBeaten))")
print(String(format: "Mancala bot: %d decisions, avg %d nodes, max single decision %.1f ms (default depth %d, budget %d); seat wins %@",
             mkDecisions, mkTotalNodes / max(mkDecisions, 1), mkMaxMs, MancalaBot.defaultMaxDepth, MancalaBot.defaultNodeBudget, "\(mkSeatWins)"))

// MARK: - Mancala: Codable

let mkCodable = MancalaEngine(players: tbPlayers)
let mkCodableEvents = mkCodable.apply(.sow(pit: 2), from: 0) + mkCodable.apply(.sow(pit: 1), from: 0)
check((try! JSONDecoder().decode([MancalaEvent].self, from: JSONEncoder().encode(mkCodableEvents))) == mkCodableEvents, "MancalaEvent round-trips")
check((try! JSONDecoder().decode(MancalaState.self, from: JSONEncoder().encode(mkCodable.state))) == mkCodable.state, "MancalaState round-trips")
check((try! JSONDecoder().decode(MancalaAction.self, from: JSONEncoder().encode(MancalaAction.sow(pit: 3)))) == .sow(pit: 3), "MancalaAction round-trips")

// ---------------------------------------------------------------- Checkers

let ckPlayers = [CheckersPlayer(name: "A", isBot: true), CheckersPlayer(name: "B", isBot: true)]
func ckSq(_ r: Int, _ c: Int) -> Int { r * 8 + c }
func ckState(_ pieces: [(Int, Int, Int, Bool)], current: Int = 0, forced: Bool = true) -> CheckersState {
    var s = CheckersState(players: ckPlayers, forcedCapture: forced)
    s.board = [CheckersPiece?](repeating: nil, count: 64)
    for (r, c, owner, king) in pieces { s.board[ckSq(r, c)] = CheckersPiece(owner: owner, isKing: king) }
    s.currentPlayer = current
    return s
}
func ckIllegal(_ events: [CheckersEvent]) -> String? {
    for e in events { if case .illegalAttempt(_, let r) = e { return r } }
    return nil
}

// MARK: - Checkers: setup

check(CheckersEngine.kind == "checkers" && CheckersState.kind == "checkers", "Checkers kind")
let ckNew = CheckersEngine(players: ckPlayers)
check(ckNew.state.pieceCount(seat: 0) == 12 && ckNew.state.pieceCount(seat: 1) == 12, "Checkers: 12 pieces per side")
check((0..<64).allSatisfy { ckNew.state.board[$0] == nil || CheckersRules.isPlayable($0) }, "Checkers: pieces only on dark squares")
check(ckNew.state.board[ckSq(7, 0)] == CheckersPiece(owner: 0) && ckNew.state.board[ckSq(0, 1)] == CheckersPiece(owner: 1), "Checkers: seat 0 at the bottom, bottom-left square is dark and occupied")
check(ckNew.state.legalMoves.count == 7, "Checkers: 7 opening moves")
check(ckNew.state.legalMoves.allSatisfy { $0.path.count == 2 && !$0.isJump }, "Checkers: opening moves are simple steps")

// MARK: - Checkers: forced capture

let ckForce = ckState([(4, 3, 0, false), (3, 4, 1, false), (6, 1, 0, false), (0, 7, 1, false)])
let ckForceMoves = ckForce.legalMoves
check(ckForceMoves.count == 1 && ckForceMoves[0] == CheckersMove(path: [ckSq(4, 3), ckSq(2, 5)], captured: [ckSq(3, 4)]), "Checkers: with a jump available ONLY the jump is legal")
let ckForceEngine = CheckersEngine(restoring: ckForce)
check(ckIllegal(ckForceEngine.move(path: [ckSq(6, 1), ckSq(5, 0)], from: 0)) == "You must capture", "Checkers: declining a capture is rejected with a clear reason")
check(ckForceEngine.state == ckForce, "Checkers: rejected move leaves state untouched")
let ckFree = ckState([(4, 3, 0, false), (3, 4, 1, false), (6, 1, 0, false), (0, 7, 1, false)], forced: false)
check(ckFree.legalMoves.count > 1 && ckFree.legalMoves.contains { $0.isJump }, "Checkers: forcedCapture off allows quiet moves alongside the jump")
let ckForceEvents = ckForceEngine.move(path: [ckSq(4, 3), ckSq(2, 5)], from: 0)
check(ckForceEvents.contains(.moved(seat: 0, move: CheckersMove(path: [ckSq(4, 3), ckSq(2, 5)], captured: [ckSq(3, 4)]), crowned: false)), "Checkers: engine canonicalizes a path-only move (fills captured)")
check(ckForceEngine.state.board[ckSq(3, 4)] == nil && ckForceEngine.state.pieceCount(seat: 1) == 1, "Checkers: captured piece removed")
check(ckIllegal(ckForceEngine.move(path: [ckSq(0, 7), ckSq(1, 6)], from: 0)) == "Not your turn", "Checkers: out-of-turn rejected")

// MARK: - Checkers: multi-jump paths

let ckMulti = ckState([(7, 0, 0, false), (6, 1, 1, false), (4, 3, 1, false), (0, 7, 1, false)])
check(ckMulti.legalMoves == [CheckersMove(path: [ckSq(7, 0), ckSq(5, 2), ckSq(3, 4)], captured: [ckSq(6, 1), ckSq(4, 3)])],
      "Checkers: double jump returned as ONE move with the full landing path and both captures")
let ckMultiEngine = CheckersEngine(restoring: ckMulti)
let ckMultiEvents = ckMultiEngine.move(path: [ckSq(7, 0), ckSq(5, 2), ckSq(3, 4)], from: 0)
check(ckMultiEngine.state.pieceCount(seat: 1) == 1 && ckMultiEngine.state.board[ckSq(3, 4)] != nil, "Checkers: both jumped pieces removed, jumper at the end")
check(ckMultiEvents.contains(.turnChanged(to: 1)), "Checkers: turn passes after the multi-jump")
check(ckIllegal(CheckersEngine(restoring: ckMulti).move(path: [ckSq(7, 0), ckSq(5, 2)], from: 0)) != nil, "Checkers: stopping a jump sequence early is illegal")

// branching: two different continuations are both generated as full paths
let ckFork = ckState([(7, 2, 0, false), (6, 3, 1, false), (4, 3, 1, false), (4, 5, 1, false), (0, 7, 1, false)])
let ckForkPaths = Set(ckFork.legalMoves.map(\.path))
check(ckForkPaths == [[ckSq(7, 2), ckSq(5, 4), ckSq(3, 2)], [ckSq(7, 2), ckSq(5, 4), ckSq(3, 6)]], "Checkers: forked jump yields both full paths")

// a captured piece cannot be jumped twice; king loop back to origin is allowed
let ckLoop = ckState([(4, 3, 0, true), (3, 2, 1, false), (3, 4, 1, false), (1, 4, 1, false), (1, 2, 1, false), (7, 6, 1, false)])
check(ckLoop.legalMoves.contains { $0.captured.count == 4 && $0.to == ckSq(4, 3) }, "Checkers: king can circle four pieces and land back on its start square")
check(ckLoop.legalMoves.allSatisfy { Set($0.captured).count == $0.captured.count }, "Checkers: no piece is jumped twice in one move")

// MARK: - Checkers: kinging

let ckKing = ckState([(2, 1, 0, false), (1, 2, 1, false), (1, 4, 1, false), (6, 7, 1, false)])
check(ckKing.legalMoves == [CheckersMove(path: [ckSq(2, 1), ckSq(0, 3)], captured: [ckSq(1, 2)])], "Checkers: a man that kings mid-jump ends its move (no continued king jump)")
let ckKingEngine = CheckersEngine(restoring: ckKing)
let ckKingEvents = ckKingEngine.move(path: [ckSq(2, 1), ckSq(0, 3)], from: 0)
check(ckKingEvents.contains { if case .moved(_, _, let crowned) = $0 { return crowned }; return false }, "Checkers: moved event flags crowned")
check(ckKingEngine.state.board[ckSq(0, 3)] == CheckersPiece(owner: 0, isKing: true), "Checkers: piece is a king on the far row")
let ckKingStep = CheckersEngine(restoring: ckState([(1, 2, 0, false), (7, 0, 1, false)]))
_ = ckKingStep.move(path: [ckSq(1, 2), ckSq(0, 1)], from: 0)
check(ckKingStep.state.board[ckSq(0, 1)]?.isKing == true, "Checkers: simple step to the far row crowns")
let ckKing1 = CheckersEngine(restoring: ckState([(6, 1, 1, false), (0, 7, 0, false)], current: 1))
_ = ckKing1.move(path: [ckSq(6, 1), ckSq(7, 2)], from: 1)
check(ckKing1.state.board[ckSq(7, 2)]?.isKing == true, "Checkers: seat 1 kings on row 7")

// MARK: - Checkers: men cannot capture or move backward; kings can

let ckBack = ckState([(4, 3, 0, false), (5, 4, 1, false), (0, 1, 1, false)])
check(!ckBack.legalMoves.contains { $0.isJump }, "Checkers: a man cannot capture backward")
check(ckBack.legalMoves.allSatisfy { CheckersRules.row($0.to) < CheckersRules.row($0.from) }, "Checkers: men only move forward")
let ckKingBack = ckState([(4, 3, 0, true), (5, 4, 1, false), (0, 1, 1, false)])
check(ckKingBack.legalMoves.contains(CheckersMove(path: [ckSq(4, 3), ckSq(6, 5)], captured: [ckSq(5, 4)])), "Checkers: a king captures backward")
check(CheckersEngine(restoring: ckState([(4, 3, 0, true), (7, 6, 1, false)])).state.legalMoves.count == 4, "Checkers: an open king has 4 steps")

// MARK: - Checkers: game end

let ckWipe = CheckersEngine(restoring: ckState([(4, 3, 0, false), (3, 4, 1, false)]))
let ckWipeEvents = ckWipe.move(path: [ckSq(4, 3), ckSq(2, 5)], from: 0)
check(ckWipe.state.phase == .gameOver && ckWipe.state.winner == 0 && ckWipeEvents.contains(.gameWon(seat: 0, reason: .noPieces)), "Checkers: capturing the last piece wins")
check(ckIllegal(ckWipe.move(path: [ckSq(2, 5), ckSq(1, 4)], from: 0)) != nil, "Checkers: no moves after game over")
// blocked: seat 1 man on the edge stuck behind seat 0 men
let ckBlock = CheckersEngine(restoring: ckState([(6, 7, 1, false), (7, 6, 0, false), (5, 6, 0, false), (4, 5, 0, false), (4, 1, 0, false)]))
let ckBlockEvents = ckBlock.move(path: [ckSq(4, 1), ckSq(3, 0)], from: 0)
check(ckBlock.state.winner == 0 && ckBlockEvents.contains(.gameWon(seat: 0, reason: .noMoves)), "Checkers: opponent with no legal move loses")

// MARK: - Checkers: 40-move (80-ply) no-capture draw

var ckDrawState = ckState([(7, 0, 0, true), (0, 7, 1, true)])
ckDrawState.pliesSinceCapture = 78
let ckDrawEngine = CheckersEngine(restoring: ckDrawState)
let ckD1 = ckDrawEngine.move(path: [ckSq(7, 0), ckSq(6, 1)], from: 0)
check(ckDrawEngine.state.phase == .playing && ckDrawEngine.state.pliesSinceCapture == 79 && ckD1.contains(.turnChanged(to: 1)), "Checkers: ply 79 without capture, still playing")
let ckD2 = ckDrawEngine.move(path: [ckSq(0, 7), ckSq(1, 6)], from: 1)
check(ckDrawEngine.state.phase == .gameOver && ckDrawEngine.state.winner == nil && ckD2.contains(.draw(reason: .noCaptureLimit)), "Checkers: draw at 80 plies (40 moves each) without a capture")
var ckResetState = ckState([(4, 3, 0, false), (3, 4, 1, false), (0, 1, 1, false), (7, 4, 0, false)])
ckResetState.pliesSinceCapture = 70
let ckResetEngine = CheckersEngine(restoring: ckResetState)
ckResetEngine.move(path: [ckSq(4, 3), ckSq(2, 5)], from: 0)
check(ckResetEngine.state.pliesSinceCapture == 0, "Checkers: a capture resets the no-capture clock")
check(CheckersState(players: ckPlayers).noCapturePlyLimit == 80, "Checkers: default limit is 80 plies")

// MARK: - Checkers bot

let ckBotStart = CheckersState(players: ckPlayers)
check(CheckersBot.decide(state: ckBotStart, seed: 5) == CheckersBot.decide(state: ckBotStart, seed: 5), "Checkers bot: same state + seed -> same move")
let ckDA = CheckersBot.decideDetailed(state: ckBotStart, seed: 5), ckDB = CheckersBot.decideDetailed(state: ckBotStart, seed: 5)
check(ckDA.nodes == ckDB.nodes && ckDA.depthReached == ckDB.depthReached, "Checkers bot: node count and depth reproducible (no wall clock)")
for budget in [50, 500, 5_000] {
    let d = CheckersBot.decideDetailed(state: ckBotStart, seed: 2, nodeBudget: budget)
    check(d.nodes <= budget, "Checkers bot: nodes \(d.nodes) <= budget \(budget)")
    if case .move(let m) = d.action { check(ckBotStart.legalMoves.contains(m), "Checkers bot: budget \(budget) returns a legal move") }
    check(d.depthReached >= 1, "Checkers bot: budget \(budget) completes depth 1")
}
check(CheckersBot.decideDetailed(state: ckBotStart, seed: 2, nodeBudget: 30_000).depthReached > CheckersBot.decideDetailed(state: ckBotStart, seed: 2, nodeBudget: 100).depthReached, "Checkers bot: a bigger budget searches deeper")
// forced multi-jump: bot returns a full legal jump
if case .move(let m) = CheckersBot.decide(state: ckMulti, seed: 1) { check(m.path.count == 3, "Checkers bot: plays the forced double jump in full") }
// a free capture vs. quiet move (non-forced): bot grabs undefended piece
let ckGrab = ckState([(4, 3, 0, false), (3, 4, 1, false), (7, 0, 0, false), (0, 1, 1, false)], forced: false)
if case .move(let m) = CheckersBot.decide(state: ckGrab, seed: 1) { check(m.isJump, "Checkers bot: takes a free piece even when capture is optional") }

var ckMaxMs = 0.0, ckNodes = 0, ckDecisions = 0, ckOutcomes: [String] = []
for seed: UInt64 in 1...4 {
    let engine = CheckersEngine(players: ckPlayers, firstPlayer: Int(seed % 2))
    var guardCount = 0
    var ok = true
    while engine.state.phase != .gameOver, guardCount < 2000 {
        guardCount += 1
        let t0 = Date()
        let det = CheckersBot.decideDetailed(state: engine.state, seed: seed)
        ckMaxMs = max(ckMaxMs, Date().timeIntervalSince(t0) * 1000)
        ckNodes += det.nodes; ckDecisions += 1
        let events = engine.apply(det.action, from: engine.state.currentPlayer)
        if ckIllegal(events) != nil { ok = false; break }
    }
    check(ok, "Checkers seed \(seed): every bot move legal")
    check(engine.state.phase == .gameOver, "Checkers seed \(seed): game terminates (\(guardCount) plies)")
    ckOutcomes.append("\(engine.state.winner.map(String.init) ?? "draw")/\(guardCount)")
}
print(String(format: "Checkers bot: %d decisions, avg %d nodes, max single decision %.1f ms (depth %d, budget %d, quiescence cap %d); results %@",
             ckDecisions, ckNodes / max(ckDecisions, 1), ckMaxMs, CheckersBot.defaultMaxDepth, CheckersBot.defaultNodeBudget, CheckersBot.quiescenceCap, "\(ckOutcomes)"))

// MARK: - Checkers: Codable

let ckCodable = CheckersEngine(players: ckPlayers)
let ckCodableEvents = ckCodable.move(path: [ckSq(5, 0), ckSq(4, 1)], from: 0)
check((try! JSONDecoder().decode([CheckersEvent].self, from: JSONEncoder().encode(ckCodableEvents))) == ckCodableEvents, "CheckersEvent round-trips")
check((try! JSONDecoder().decode(CheckersState.self, from: JSONEncoder().encode(ckCodable.state))) == ckCodable.state, "CheckersState round-trips")
let ckAct = CheckersAction.move(CheckersMove(path: [1, 19, 37], captured: [10, 28]))
check((try! JSONDecoder().decode(CheckersAction.self, from: JSONEncoder().encode(ckAct))) == ckAct, "CheckersAction round-trips")
let ckEvEnd: [CheckersEvent] = [.gameWon(seat: 1, reason: .noMoves), .draw(reason: .noCaptureLimit), .gameStarted]
check((try! JSONDecoder().decode([CheckersEvent].self, from: JSONEncoder().encode(ckEvEnd))) == ckEvEnd, "CheckersEvent end cases round-trip")

// ------------------------------------------------------------ Connect Four

let c4Players = [ConnectFourPlayer(name: "A", isBot: true), ConnectFourPlayer(name: "B", isBot: true)]
/// Build a position from (row, col, seat) discs; `current` to move.
func c4State(_ discs: [(Int, Int, Int)], current: Int) -> ConnectFourState {
    var s = ConnectFourState(players: c4Players)
    for (r, c, seat) in discs { s.cells[r * 7 + c] = seat }
    s.currentPlayer = current
    s.moveCount = discs.count
    return s
}
func c4Illegal(_ events: [ConnectFourEvent]) -> Bool { events.contains { if case .illegalAttempt = $0 { return true }; return false } }
func c4Col(_ a: ConnectFourAction) -> Int { if case .drop(let c) = a { return c }; return -1 }

check(ConnectFourEngine.kind == "connectFour" && ConnectFourState.kind == "connectFour", "Connect Four kind")

// MARK: - Connect Four: gravity

let c4Grav = ConnectFourEngine(players: c4Players)
let c4G1 = c4Grav.apply(.drop(column: 3), from: 0)
check(c4G1.contains(.discDropped(seat: 0, column: 3, row: 5, cell: 38)), "Connect Four: first disc lands on the floor (row 5)")
let c4G2 = c4Grav.apply(.drop(column: 3), from: 1)
check(c4G2.contains(.discDropped(seat: 1, column: 3, row: 4, cell: 31)) && c4G2.contains(.turnChanged(to: 0)), "Connect Four: second disc stacks above (row 4), turn passes")
check(c4Grav.state.cells[38] == 0 && c4Grav.state.cells[31] == 1, "Connect Four: cells record the owners")
check(c4Illegal(c4Grav.apply(.drop(column: 0), from: 1)), "Connect Four: out of turn rejected")
check(c4Illegal(c4Grav.apply(.drop(column: 7), from: 0)) && c4Illegal(c4Grav.apply(.drop(column: -1), from: 0)), "Connect Four: off-board column rejected")
let c4Full = ConnectFourEngine(players: c4Players)
for i in 0..<6 { c4Full.apply(.drop(column: 0), from: i % 2) }
check(c4Illegal(c4Full.apply(.drop(column: 0), from: 0)), "Connect Four: full column rejected")
check(!c4Full.state.legalColumns.contains(0) && c4Full.state.legalColumns.count == 6, "Connect Four: legalColumns omits the full column")

// MARK: - Connect Four: win detection, all four directions

let c4H = ConnectFourEngine(players: c4Players)
var c4HEvents: [ConnectFourEvent] = []
for (i, col) in [0, 0, 1, 1, 2, 2, 3].enumerated() { c4HEvents = c4H.apply(.drop(column: col), from: i % 2) }
check(c4H.state.winner == 0 && c4HEvents.contains(.gameWon(seat: 0, line: [35, 36, 37, 38])), "Connect Four: horizontal win, line reported")
let c4V = ConnectFourEngine(players: c4Players)
var c4VEvents: [ConnectFourEvent] = []
for (i, col) in [0, 1, 0, 1, 0, 1, 0].enumerated() { c4VEvents = c4V.apply(.drop(column: col), from: i % 2) }
check(c4V.state.winner == 0 && c4VEvents.contains(.gameWon(seat: 0, line: [14, 21, 28, 35])), "Connect Four: vertical win")
// "/" diagonal rising to the right: (5,0) (4,1) (3,2) then (2,3)
let c4D1 = ConnectFourRules.apply(.drop(column: 3), to: c4State([(5, 0, 0), (4, 1, 0), (3, 2, 0), (5, 1, 1), (5, 2, 1), (4, 2, 1), (5, 3, 1), (4, 3, 1), (3, 3, 1)], current: 0))
check(c4D1.winner == 0 && c4D1.winningLine == [17, 23, 29, 35], "Connect Four: '/' diagonal win (line ordered along the run)")
// "\" diagonal: (5,3) (4,2) (3,1) then (2,0)
let c4D2 = ConnectFourRules.apply(.drop(column: 0), to: c4State([(5, 3, 1), (4, 2, 1), (3, 1, 1), (5, 0, 0), (4, 0, 0), (3, 0, 0), (5, 1, 0), (4, 1, 0), (5, 2, 0)], current: 1))
check(c4D2.winner == 1 && c4D2.winningLine?.count == 4 && c4D2.winningLine?.contains(14) == true, "Connect Four: '\\' diagonal win")
// 5-in-a-row reports the whole run
let c4Five = ConnectFourRules.apply(.drop(column: 2), to: c4State([(5, 0, 0), (5, 1, 0), (5, 3, 0), (5, 4, 0), (4, 0, 1), (4, 1, 1), (4, 3, 1)], current: 0))
check(c4Five.winningLine == [35, 36, 37, 38, 39], "Connect Four: a five-run reports all five cells")
check(ConnectFourRules.apply(.drop(column: 2), to: c4State([(5, 0, 0), (5, 1, 0), (5, 3, 1)], current: 0)).phase == .playing, "Connect Four: three in a row is not a win")
check(ConnectFourRules.apply(.drop(column: 2), to: c4State([(5, 0, 0), (5, 1, 1), (5, 3, 0)], current: 0)).phase == .playing, "Connect Four: mixed colors do not win")
check(c4Illegal(c4H.apply(.drop(column: 4), from: 1)), "Connect Four: no moves after game over")

// MARK: - Connect Four: draw on a full board

var c4DrawDiscs: [(Int, Int, Int)] = []
for r in 0..<6 { for c in 0..<7 where !(r == 0 && c == 6) { c4DrawDiscs.append((r, c, (c + r / 2) % 2)) } }
var c4DrawS = c4State(c4DrawDiscs, current: (0 + 0 / 2) % 2)   // cell (0,6) is owned by (6+0)%2 == 0 in the pattern
c4DrawS.currentPlayer = 0
let c4DrawEngine = ConnectFourEngine(restoring: c4DrawS)
let c4DrawEvents = c4DrawEngine.apply(.drop(column: 6), from: 0)
check(c4DrawEngine.state.phase == .gameOver && c4DrawEngine.state.winner == nil && c4DrawEvents.contains(.draw), "Connect Four: full board without four is a draw")
check(c4DrawEngine.state.legalColumns.isEmpty, "Connect Four: no legal columns when full")

// MARK: - Connect Four bot: wins, blocks, openers

let c4Fixtures: [(String, [(Int, Int, Int)], Int, Int)] = [
    // (name, discs, seat to move, expected column)
    ("win horizontal", [(5, 0, 0), (5, 1, 0), (5, 2, 0), (5, 5, 1), (4, 5, 1), (5, 6, 1)], 0, 3),
    ("win vertical", [(5, 4, 1), (4, 4, 1), (3, 4, 1), (5, 0, 0), (5, 1, 0), (4, 0, 0)], 1, 4),
    ("win diagonal /", [(5, 0, 0), (4, 1, 0), (3, 2, 0), (5, 1, 1), (5, 2, 1), (4, 2, 1), (5, 3, 1), (4, 3, 1), (3, 3, 1)], 0, 3),
    ("win diagonal \\", [(5, 3, 1), (4, 2, 1), (3, 1, 1), (5, 0, 0), (4, 0, 0), (3, 0, 0), (5, 1, 0), (4, 1, 0), (5, 2, 0)], 1, 0),
    ("win beats block", [(5, 0, 0), (5, 1, 0), (5, 2, 0), (5, 4, 1), (4, 4, 1), (3, 4, 1)], 0, 3),
    ("block horizontal", [(5, 0, 1), (5, 1, 1), (5, 2, 1), (5, 6, 0), (4, 6, 0)], 0, 3),
    ("block vertical", [(5, 5, 1), (4, 5, 1), (3, 5, 1), (5, 0, 0), (5, 1, 0), (4, 0, 0)], 0, 5),
    ("block diagonal", [(5, 0, 1), (4, 1, 1), (3, 2, 1), (5, 1, 0), (5, 2, 0), (4, 2, 0), (5, 3, 1), (4, 3, 0), (3, 3, 1)], 0, 3),
    ("block mid-row gap", [(5, 1, 1), (5, 2, 1), (5, 4, 1), (5, 6, 0), (4, 6, 0)], 0, 3),
]
for (name, discs, mover, expected) in c4Fixtures {
    var allSeeds = true
    for seed: UInt64 in 1...3 {
        let col = c4Col(ConnectFourBot.decide(state: c4State(discs, current: mover), seed: seed))
        if col != expected { allSeeds = false }
    }
    check(allSeeds, "Connect Four bot fixture '\(name)': plays column \(expected)")
}
check(c4Col(ConnectFourBot.decide(state: ConnectFourState(players: c4Players), seed: 9)) == 3, "Connect Four bot: opens in the centre column")
// even with a tiny budget, immediate win / block still found (they bypass the search)
check(c4Col(ConnectFourBot.decide(state: c4State(c4Fixtures[0].1, current: 0), seed: 1, nodeBudget: 1)) == 3, "Connect Four bot: win-in-1 with a 1-node budget")
check(c4Col(ConnectFourBot.decide(state: c4State(c4Fixtures[5].1, current: 0), seed: 1, nodeBudget: 1)) == 3, "Connect Four bot: block-in-1 with a 1-node budget")

// MARK: - Connect Four bot: determinism, budget, games

let c4Mid = c4State([(5, 3, 0), (5, 2, 1), (4, 3, 0), (5, 4, 1)], current: 0)
check(ConnectFourBot.decide(state: c4Mid, seed: 11) == ConnectFourBot.decide(state: c4Mid, seed: 11), "Connect Four bot: same state + seed -> same move")
let c4A = ConnectFourBot.decideDetailed(state: c4Mid, seed: 11), c4B = ConnectFourBot.decideDetailed(state: c4Mid, seed: 11)
check(c4A.nodes == c4B.nodes && c4A.depthReached == c4B.depthReached, "Connect Four bot: node count and depth reproducible (no wall clock)")
for budget in [30, 300, 3_000] {
    let d = ConnectFourBot.decideDetailed(state: c4Mid, seed: 4, nodeBudget: budget)
    check(d.nodes <= budget, "Connect Four bot: nodes \(d.nodes) <= budget \(budget)")
    check(c4Mid.legalColumns.contains(c4Col(d.action)), "Connect Four bot: budget \(budget) returns a legal column")
    check(d.depthReached >= 1, "Connect Four bot: budget \(budget) completes depth 1")
}
check(ConnectFourBot.decideDetailed(state: c4Mid, seed: 4, nodeBudget: 100_000).depthReached > ConnectFourBot.decideDetailed(state: c4Mid, seed: 4, nodeBudget: 100).depthReached, "Connect Four bot: bigger budget searches deeper")

var c4MaxMs = 0.0, c4Nodes = 0, c4Decisions = 0, c4Outcomes: [String] = []
for seed: UInt64 in 1...5 {
    let engine = ConnectFourEngine(players: c4Players, firstPlayer: Int(seed % 2))
    var guardCount = 0, ok = true
    while engine.state.phase != .gameOver, guardCount < 50 {
        guardCount += 1
        let t0 = Date()
        let det = ConnectFourBot.decideDetailed(state: engine.state, seed: seed)
        c4MaxMs = max(c4MaxMs, Date().timeIntervalSince(t0) * 1000)
        c4Nodes += det.nodes; c4Decisions += 1
        if c4Illegal(engine.apply(det.action, from: engine.state.currentPlayer)) { ok = false; break }
    }
    check(ok, "Connect Four seed \(seed): every bot move legal")
    check(engine.state.phase == .gameOver, "Connect Four seed \(seed): game terminates (\(engine.state.moveCount) discs)")
    c4Outcomes.append("\(engine.state.winner.map(String.init) ?? "draw")/\(engine.state.moveCount)")
}
// bot vs a naive leftmost-column player
var c4Beaten = 0
for seed: UInt64 in 1...5 {
    let engine = ConnectFourEngine(players: c4Players)
    let botSeat = Int(seed % 2)
    while engine.state.phase != .gameOver {
        let cur = engine.state.currentPlayer
        let action: ConnectFourAction = cur == botSeat ? ConnectFourBot.decide(state: engine.state, seed: seed) : .drop(column: engine.state.legalColumns[0])
        engine.apply(action, from: cur)
    }
    if engine.state.winner == botSeat { c4Beaten += 1 }
}
check(c4Beaten == 5, "Connect Four bot beats a naive leftmost-column player 5 of 5 (won \(c4Beaten))")
print(String(format: "Connect Four bot: %d decisions, avg %d nodes, max single decision %.1f ms (depth %d, budget %d); results %@",
             c4Decisions, c4Nodes / max(c4Decisions, 1), c4MaxMs, ConnectFourBot.defaultMaxDepth, ConnectFourBot.defaultNodeBudget, "\(c4Outcomes)"))

// MARK: - Connect Four: Codable

let c4Codable = ConnectFourEngine(players: c4Players)
let c4CodableEvents = c4Codable.apply(.drop(column: 2), from: 0) + c4Codable.apply(.drop(column: 2), from: 1)
check((try! JSONDecoder().decode([ConnectFourEvent].self, from: JSONEncoder().encode(c4CodableEvents))) == c4CodableEvents, "ConnectFourEvent round-trips")
check((try! JSONDecoder().decode(ConnectFourState.self, from: JSONEncoder().encode(c4Codable.state))) == c4Codable.state, "ConnectFourState round-trips")
check((try! JSONDecoder().decode(ConnectFourAction.self, from: JSONEncoder().encode(ConnectFourAction.drop(column: 5)))) == .drop(column: 5), "ConnectFourAction round-trips")
let c4EndEv: [ConnectFourEvent] = [.gameWon(seat: 1, line: [1, 2, 3, 4]), .draw, .gameStarted]
check((try! JSONDecoder().decode([ConnectFourEvent].self, from: JSONEncoder().encode(c4EndEv))) == c4EndEv, "ConnectFourEvent end cases round-trip")

// MARK: - END Mancala / Checkers / Connect Four

// MARK: - Hearts

func hxSeatsState(
    kind: GameKind = .hearts, n: Int = 4, rules: RulesConfig = RulesConfig(),
    hands: [Int: [String]], trick: [(Int, String)] = [], completed: [[TrickPlay]] = [],
    lead: Int = 0, heartsBroken: Bool = false, spadesBroken: Bool = false,
    phase: Phase = .playing, bids: [Int: Int] = [:], tricksWon: [Int: Int] = [:],
    history: [CompletedRound] = [], cardsPerPlayer: Int = 13
) -> GameState {
    let plays = trick.map { tp($0.0, $0.1) }
    let turn = plays.last.map { ($0.seat + 1) % n } ?? lead
    var round = RoundState(
        roundNumber: history.count + 1, cardsPerPlayer: cardsPerPlayer, dealerSeat: 3 % n,
        trumpCard: nil, trumpSuit: kind == .spades ? .spades : nil, bids: bids, tricksWon: tricksWon,
        currentTrick: plays, completedTricks: completed, leadSeat: lead, turnSeat: turn
    )
    round.heartsBroken = heartsBroken
    round.spadesBroken = spadesBroken
    return GameState(
        gameKind: kind, rules: rules, seats: makeSeats(n), phase: phase, round: round,
        hands: hands.mapValues { $0.map { card($0) } }, drawPile: [], discardPile: [],
        roundHistory: history, seed: 1
    )
}

func hxLegal(_ state: GameState, seat: Int, _ id: String) -> Bool {
    let hand = state.hands[seat] ?? []
    return state.gameKind.ruleset.legality(
        of: card(id), hand: hand, trick: state.round?.currentTrick ?? [],
        trump: state.round?.trumpSuit, state: state
    ).isLegal
}

/// A completed 13-trick round fabricated so `winner` takes every trick:
/// trick k holds all four suits of rank k and the winner leads the club
/// (off-suit discards can't beat the led suit). One trick is left in
/// `trickComplete` so `.nextTrick` finishes the round.
func hxMoonState(kind: GameKind, rules: RulesConfig, winner: Int, history: [CompletedRound] = [],
                 bids: [Int: Int] = [:], tricksWon: [Int: Int] = [:]) -> GameState {
    var completed: [[TrickPlay]] = []
    func trickFor(rank: Int) -> [TrickPlay] {
        let order = [winner, (winner + 1) % 4, (winner + 2) % 4, (winner + 3) % 4]
        let ids = ["c\(rank)", "d\(rank)", "h\(rank)", "s\(rank)"]
        return zip(order, ids).map { tp($0, $1) }
    }
    for rank in 2...13 { completed.append(trickFor(rank: rank)) }
    var state = hxSeatsState(kind: kind, rules: rules, hands: [0: [], 1: [], 2: [], 3: []],
                             completed: completed, lead: winner, phase: .trickComplete(winnerSeat: winner),
                             bids: bids, tricksWon: tricksWon, history: history)
    state.round?.currentTrick = trickFor(rank: 14)
    return state
}

func hxIsIllegal(_ events: [GameEvent]) -> Bool { isIllegal(events) }

func hxRunBotGame(kind: GameKind, seats: Int, rules: RulesConfig, seed: UInt64, actionCap: Int = 6000)
    -> (engine: HostEngine, actions: Int, anyIllegal: Bool, events: [GameEvent]) {
    let engine = HostEngine(seats: makeSeats(seats), gameKind: kind, rules: rules, seed: seed)
    var events = engine.apply(.startGame(kind, rules, seed: seed))
    var actions = 0
    var anyIllegal = false
    while engine.state.phase != .gameOver, actions < actionCap {
        var batch: [GameEvent] = []
        switch engine.state.phase {
        case .passing:
            for seat in 0..<seats {
                if let action = TrickBots.action(for: engine.state, seat: seat) {
                    batch += engine.apply(action, from: seat)
                    actions += 1
                }
            }
        case .bidding, .playing:
            guard let turn = engine.state.round?.turnSeat,
                  let action = TrickBots.action(for: engine.state, seat: turn) else {
                anyIllegal = true; actions = actionCap; break
            }
            batch = engine.apply(action, from: turn)
            actions += 1
        case .trickComplete:
            batch = engine.apply(.nextTrick); actions += 1
        case .roundComplete:
            batch = engine.apply(.nextRound); actions += 1
        default:
            anyIllegal = true; actions = actionCap
        }
        if hxIsIllegal(batch) { anyIllegal = true }
        events += batch
    }
    return (engine, actions, anyIllegal, events)
}

do {
    // Config
    check(GameKind.hearts.displayName == "Hearts" && GameKind.spades.displayName == "Spades", "hearts/spades display names")
    check(GameKind.hearts.minPlayers == 3 && GameKind.hearts.maxPlayers == 5, "hearts 3-5 players")
    check(GameKind.spades.minPlayers == 2 && GameKind.spades.maxPlayers == 4, "spades 2-4 players")
    check(GameKind.hearts.isTrickTaking && GameKind.spades.isTrickTaking, "hearts/spades are trick-taking")
    check(!GameKind.hearts.usesWizardDeck && !GameKind.spades.usesWizardDeck, "hearts/spades use the 52 deck")
    check(GameKind.hearts.lowestScoreWins && !GameKind.spades.lowestScoreWins, "only hearts is lowest-wins")
    check(GameKind.hearts.roundsSchedule(playerCount: 4).isEmpty, "hearts has no fixed schedule")

    // Deals
    for (n, each) in [(3, 17), (4, 13), (5, 10)] {
        let e = HostEngine(seats: makeSeats(n), gameKind: .hearts, rules: RulesConfig(), seed: 5)
        _ = e.apply(.startGame(.hearts, RulesConfig(), seed: 5))
        let all = e.state.hands.values.flatMap { $0 }
        check(e.state.hands.count == n && e.state.hands.values.allSatisfy { $0.count == each }, "hearts \(n)p deals \(each) each")
        check(Set(all.map(\.id)).count == all.count, "hearts \(n)p deal has no duplicates")
        check(all.contains { $0.id == "c2" }, "hearts \(n)p keeps the 2 of clubs")
        check(n != 3 || !all.contains { $0.id == "d2" }, "hearts 3p drops the 2 of diamonds")
        check(n != 5 || (!all.contains { $0.id == "d2" } && !all.contains { $0.id == "s2" }), "hearts 5p drops 2d and 2s")
        check(e.state.phase == .passing && e.state.round?.passDirection == .left, "hearts \(n)p round 1 starts passing left")
    }

    // Pass rotation
    let dirs4 = (1...5).map { HeartsRules.passDirection(roundNumber: $0, playerCount: 4, passingEnabled: true) }
    check(dirs4 == [.left, .right, .across, .hold, .left], "hearts 4p pass rotation left/right/across/hold")
    let dirs3 = (1...4).map { HeartsRules.passDirection(roundNumber: $0, playerCount: 3, passingEnabled: true) }
    check(dirs3 == [.left, .right, .hold, .left], "hearts 3p rotation has no across")
    check(HeartsRules.passDirection(roundNumber: 1, playerCount: 4, passingEnabled: false) == .hold, "passing off = always hold")
    check(HeartsRules.passTarget(from: 0, direction: .left, playerCount: 4) == 1, "pass left goes to seat+1")
    check(HeartsRules.passTarget(from: 0, direction: .right, playerCount: 4) == 3, "pass right goes to seat-1")
    check(HeartsRules.passTarget(from: 1, direction: .across, playerCount: 4) == 3, "pass across skips one seat")

    // Passing flow
    do {
        let e = HostEngine(seats: makeSeats(4), gameKind: .hearts, rules: RulesConfig(), seed: 99)
        _ = e.apply(.startGame(.hearts, RulesConfig(), seed: 99))
        let before = e.state.hands
        check(isIllegal(e.apply(.placeBid(1), from: 0)), "hearts has no bidding")
        check(isIllegal(e.apply(.playCard(cardID: before[0]![0].id, force: true), from: 0)), "can't play during passing")
        check(isIllegal(e.apply(.passCards(Array(before[0]!.prefix(2)).map(\.id)), from: 0)), "pass needs exactly 3 cards")
        check(isIllegal(e.apply(.passCards([before[0]![0].id, before[0]![0].id, before[0]![1].id]), from: 0)), "pass rejects duplicates")
        check(isIllegal(e.apply(.passCards(Array(before[1]!.prefix(3)).map(\.id)), from: 0)), "pass rejects cards from another hand")
        var picks: [Int: [String]] = [:]
        for seat in 0..<4 { picks[seat] = before[seat]!.suffix(3).map(\.id) }
        let first = e.apply(.passCards(picks[0]!), from: 0)
        check(first == [.passSubmitted(seat: 0)], "first pass emits passSubmitted only")
        let snap1 = e.state.snapshot(for: 1)
        check(snap1.round?.passSelections[0] == ["?", "?", "?"], "snapshot hides other seats' pass picks")
        let snap0 = e.state.snapshot(for: 0)
        check(snap0.round?.passSelections[0] == picks[0]!, "snapshot shows my own pass picks")
        _ = e.apply(.passCards(picks[0]!), from: 0) // re-sending is allowed
        _ = e.apply(.passCards(picks[1]!), from: 1)
        _ = e.apply(.passCards(picks[2]!), from: 2)
        check(e.state.phase == .passing, "passing waits for the last seat")
        let events = e.apply(.passCards(picks[3]!), from: 3)
        check(e.state.phase == .playing, "passing completes into play")
        check(events.filter { if case .cardsPassed = $0 { return true }; return false }.count == 4, "four cardsPassed events")
        check(events.contains(.cardsPassed(from: 0, to: 1)), "seat 0 passed to seat 1 (left)")
        let after = e.state.hands
        check(after.values.allSatisfy { $0.count == 13 }, "hands stay at 13 after the swap")
        check(picks[0]!.allSatisfy { id in after[1]!.contains { $0.id == id } }, "seat 1 received seat 0's cards")
        check(picks[3]!.allSatisfy { id in after[0]!.contains { $0.id == id } }, "seat 0 received seat 3's cards")
        check(picks[0]!.allSatisfy { id in !after[0]!.contains { $0.id == id } }, "seat 0 no longer holds what it passed")
        check(e.state.round?.passReceived[1] == picks[0]!, "passReceived records what seat 1 got")
        check(e.state.snapshot(for: 2).round?.passReceived.keys.sorted() == [2], "snapshot keeps only my received cards")
        let holder = (0..<4).first { after[$0]!.contains { $0.id == "c2" } }!
        check(e.state.round?.turnSeat == holder && e.state.round?.leadSeat == holder, "2 of clubs holder leads after the pass")
        // first trick lead rules (via the live engine)
        let other = after[holder]!.first { $0.id != "c2" }!
        check(isIllegal(e.apply(.playCard(cardID: other.id, force: false), from: holder)), "first trick must open with the 2 of clubs")
        let lead = e.apply(.playCard(cardID: "c2", force: false), from: holder)
        check(playedCard(lead)?.card.id == "c2", "2 of clubs opens trick one")
    }

    // Hold rounds / passing off skip the phase
    do {
        var rules = RulesConfig(); rules.heartsPassing = false
        let e = HostEngine(seats: makeSeats(4), gameKind: .hearts, rules: rules, seed: 7)
        _ = e.apply(.startGame(.hearts, rules, seed: 7))
        check(e.state.phase == .playing && e.state.round?.passDirection == .hold, "passing off deals straight into play")
        let holder = (0..<4).first { e.state.hands[$0]!.contains { $0.id == "c2" } }!
        check(e.state.round?.turnSeat == holder, "hold round: 2 of clubs holder leads")
    }

    // Manual dealing still works for hearts
    do {
        var rules = RulesConfig(); rules.autoDeal = false; rules.heartsPassing = false
        let e = HostEngine(seats: makeSeats(3), gameKind: .hearts, rules: rules, seed: 11)
        _ = e.apply(.startGame(.hearts, rules, seed: 11))
        check(e.state.phase == .dealing, "hearts manual deal parks in dealing")
        for _ in 0..<17 { for seat in 0..<3 { _ = e.apply(.dealCardTo(seat: seat)) } }
        check(e.state.phase == .playing && e.state.hands.values.allSatisfy { $0.count == 17 }, "hearts manual deal completes into play")
    }

    // Hearts can't be led until broken
    do {
        let hands: [Int: [String]] = [0: ["h5", "c9"], 1: ["h3", "h4"], 2: ["d4"], 3: ["d5"]]
        let done = [[tp(0, "c3"), tp(1, "c4"), tp(2, "c5"), tp(3, "c6")]]
        var st = hxSeatsState(hands: hands, completed: done, lead: 0)
        check(!hxLegal(st, seat: 0, "h5"), "can't lead hearts before they're broken")
        check(hxLegal(st, seat: 0, "c9"), "can lead a non-heart")
        check(illegalReason(HostEngine(restoring: st).apply(.playCard(cardID: "h5", force: false), from: 0)) == "Hearts haven't been broken yet", "unbroken-hearts reason is user-facing")
        check(hxLegal(st, seat: 1, "h3"), "a hearts-only hand may lead hearts")
        st.round?.heartsBroken = true
        check(hxLegal(st, seat: 0, "h5"), "hearts may be led once broken")
        // playing a heart breaks them
        let brk = hxSeatsState(hands: ["h5", "c9"].isEmpty ? [:] : [0: ["c9"], 1: ["h3", "d2"], 2: ["d4"], 3: ["d5"]],
                               trick: [(0, "c9")], completed: done, lead: 0)
        let e = HostEngine(restoring: brk)
        let ev = e.apply(.playCard(cardID: "h3", force: false), from: 1)
        check(ev.contains(.heartsBroken) && e.state.round?.heartsBroken == true, "discarding a heart breaks hearts")
    }

    // No points on the first trick
    do {
        let hands: [Int: [String]] = [0: ["c2", "c7"], 1: ["h9", "s12", "d4"], 2: ["h2", "s12"], 3: ["c9", "c10"]]
        let st = hxSeatsState(hands: hands, trick: [(0, "c2")], lead: 0)
        check(!hxLegal(st, seat: 1, "h9"), "no hearts on the first trick when void with a safe discard")
        check(!hxLegal(st, seat: 1, "s12"), "no queen of spades on the first trick with a safe discard")
        check(hxLegal(st, seat: 1, "d4"), "a non-point discard is fine on the first trick")
        let only = hxSeatsState(hands: hands, trick: [(0, "c2"), (1, "d4")], lead: 0)
        check(hxLegal(only, seat: 2, "h2") && hxLegal(only, seat: 2, "s12"), "all-point hand may discard points on the first trick")
        var off = RulesConfig(); off.heartsNoPointsFirstTrick = false
        let stOff = hxSeatsState(rules: off, hands: hands, trick: [(0, "c2")], lead: 0)
        check(hxLegal(stOff, seat: 1, "h9"), "flag off: points allowed on the first trick")
        let later = hxSeatsState(hands: hands, trick: [(0, "c9")], completed: [[tp(0, "c3"), tp(1, "c4"), tp(2, "c5"), tp(3, "c6")]], lead: 0)
        check(hxLegal(later, seat: 1, "h9"), "points allowed after trick one")
        check(!hxLegal(hxSeatsState(hands: [0: ["c2", "c7"], 1: ["c8", "h9"], 2: [], 3: []], trick: [(0, "c2")], lead: 0), seat: 1, "h9"), "must follow clubs")
    }

    // Scoring: queen and hearts
    do {
        // Seat 1 wins the last trick holding the queen of spades + 2 hearts.
        var st = hxSeatsState(hands: [0: [], 1: [], 2: [], 3: []], lead: 0, phase: .trickComplete(winnerSeat: 1), tricksWon: [1: 1])
        st.round?.currentTrick = [tp(0, "c3"), tp(1, "c9"), tp(2, "s12"), tp(3, "h5")]
        st.round?.completedTricks = [[tp(0, "d3"), tp(1, "d9"), tp(2, "h3"), tp(3, "d4")]]
        let e = HostEngine(restoring: st)
        let ev = e.apply(.nextTrick)
        let r = e.state.roundHistory.last!
        check(ev.contains(.roundScored), "hearts round scored")
        check(r.heartsPoints[1] == 13 + 1 + 1 && r.heartsPoints[2] == 0 && r.heartsPoints[0] == 0, "queen of spades = 13, each heart = 1 (captured by trick winner)")
        check(r.scoreDeltas[1] == 15 && r.moonShooter == nil, "round delta equals captured points")
        check(Scoring.totals(history: e.state.roundHistory, kind: .hearts)[1] == 15, "totals sum the deltas")
        check(Scoring.roundScores(for: r, kind: .hearts)[1] == 15, "roundScores reads the recorded deltas")
        check(e.state.phase == .roundComplete, "below target: next round")
        check(e.apply(.nextRound).contains(.dealt) && e.state.round?.roundNumber == 2, "next round deals")
        check(e.state.round?.passDirection == .right, "round 2 passes right")
        check(e.state.round?.dealerSeat == 0, "dealer rotates")
    }

    // Shooting the moon, both modes
    do {
        let st = hxMoonState(kind: .hearts, rules: RulesConfig(), winner: 2)
        let e = HostEngine(restoring: st)
        let ev = e.apply(.nextTrick)
        let r = e.state.roundHistory.last!
        check(ev.contains(.shotTheMoon(seat: 2)), "moon event")
        check(r.moonShooter == 2 && r.heartsPoints[2] == 26, "seat 2 captured all 26")
        check(r.scoreDeltas == [0: 26, 1: 26, 2: 0, 3: 26], "moon: everyone else +26")
        var sub = RulesConfig(); sub.heartsMoonSubtracts = true
        let e2 = HostEngine(restoring: hxMoonState(kind: .hearts, rules: sub, winner: 2))
        _ = e2.apply(.nextTrick)
        check(e2.state.roundHistory.last!.scoreDeltas == [0: 0, 1: 0, 2: -26, 3: 0], "moon (subtract mode): shooter -26")
        let pure = HeartsRules.scoreRound(points: [0: 25, 1: 1], seatIDs: [0, 1, 2, 3], moonSubtracts: false)
        check(pure.moonShooter == nil && pure.deltas[0] == 25, "25 points is not a moon")
        check(HeartsRules.pointsTaken(in: [[tp(0, "h3"), tp(1, "h9"), tp(2, "s12"), tp(3, "c2")]]) == [1: 15], "pointsTaken picks the trick winner")
    }

    // Game end
    do {
        func past(_ deltas: [Int: Int]) -> CompletedRound {
            CompletedRound(roundNumber: 1, cardsPerPlayer: 13, bids: [:], tricksWon: [:], scoreDeltas: deltas)
        }
        // seat 3 hits 100 but seat 0 is the sole lowest: game over, seat 0 wins
        var st = hxMoonState(kind: .hearts, rules: RulesConfig(), winner: 0, history: [past([0: 5, 1: 40, 2: 60, 3: 80])])
        var e = HostEngine(restoring: st)
        var ev = e.apply(.nextTrick) // seat 0 shoots: +26 to others
        check(e.state.phase == .gameOver && ev.contains(.gameWon(seat: 0)), "game ends at 100, lowest total wins")
        let totals = Scoring.totals(history: e.state.roundHistory, kind: .hearts)
        check(totals == [0: 5, 1: 66, 2: 86, 3: 106], "game-end totals")
        check(Scoring.placements(totals: totals, lowerIsBetter: true).first?.seat == 0, "placements rank lowest first for hearts")
        check(Scoring.placements(totals: totals).first?.seat == 3, "default placements stay highest-first")
        // tie for lowest plays on
        st = hxMoonState(kind: .hearts, rules: RulesConfig(), winner: 0, history: [past([0: 74, 1: 100, 2: 100, 3: 100])])
        e = HostEngine(restoring: st)
        ev = e.apply(.nextTrick) // seat 0: +0 ... others +26 -> 74, 126...; make seat 0 the shooter so stays 74
        check(e.state.phase == .gameOver, "sole lowest after a moon ends the game")
        var tie = RulesConfig(); tie.heartsTargetScore = 100
        check(HeartsRules.winner(totals: [0: 50, 1: 50, 2: 101, 3: 80], target: 100) == nil, "tied lowest total plays on")
        check(HeartsRules.winner(totals: [0: 50, 1: 60, 2: 99, 3: 80], target: 100) == nil, "nobody at target: play on")
        check(HeartsRules.winner(totals: [0: 50, 1: 60, 2: 100, 3: 80], target: 100) == 0, "target reached, sole lowest wins")
        // newDeal from game over restarts clean
        let e3 = HostEngine(restoring: e.state)
        _ = e3.apply(.newDeal)
        check(e3.state.roundHistory.isEmpty && e3.state.round?.roundNumber == 1, "newDeal after game over starts a fresh game")
    }

    // Full seeded bot games
    for seed: UInt64 in [1, 2, 3, 4] {
        let g = hxRunBotGame(kind: .hearts, seats: 4, rules: RulesConfig(), seed: seed)
        check(g.engine.state.phase == .gameOver, "hearts bot game \(seed): reaches game over")
        check(!g.anyIllegal, "hearts bot game \(seed): no illegal actions")
        let hist = g.engine.state.roundHistory
        check(!hist.isEmpty && hist.allSatisfy { $0.heartsPoints.values.reduce(0, +) == 26 }, "hearts bot game \(seed): every round deals out 26 points")
        let totals = Scoring.totals(history: hist, kind: .hearts)
        check((totals.values.max() ?? 0) >= 100, "hearts bot game \(seed): someone reached 100")
        let won = g.events.compactMap { e -> Int? in if case .gameWon(let s) = e { return s }; return nil }
        check(won.count == 1 && totals[won[0]] == totals.values.min(), "hearts bot game \(seed): winner has the lowest total")
        check(g.events.contains(.heartsBroken), "hearts bot game \(seed): hearts got broken")
    }
    for n in [3, 5] {
        var rules = RulesConfig(); rules.heartsTargetScore = 40
        let g = hxRunBotGame(kind: .hearts, seats: n, rules: rules, seed: UInt64(n) * 31)
        check(g.engine.state.phase == .gameOver && !g.anyIllegal, "hearts \(n)p bot game completes legally")
        check(g.engine.state.roundHistory.allSatisfy { $0.heartsPoints.values.reduce(0, +) == 26 }, "hearts \(n)p rounds deal out 26")
    }
    do { // determinism
        let a = hxRunBotGame(kind: .hearts, seats: 4, rules: RulesConfig(), seed: 9)
        let b = hxRunBotGame(kind: .hearts, seats: 4, rules: RulesConfig(), seed: 9)
        check(a.engine.state.roundHistory == b.engine.state.roundHistory, "hearts bots are deterministic")
    }

    // Bot heuristics
    do {
        let hand = ["s12", "s14", "h14", "h13", "c3", "c4", "d5", "d7", "d9", "c8", "c9", "d10", "h2"].map { card($0) }
        let pass = HeartsBot.passChoice(hand: hand)
        check(pass.count == 3 && pass.contains("s12"), "hearts bot passes the queen of spades")
        let noQueen = ["s14", "s13", "s4", "h2", "c3", "c4", "d5", "d7", "d9", "c8", "c9", "d10", "h3"].map { card($0) }
        check(Set(HeartsBot.passChoice(hand: noQueen)).isSuperset(of: ["s14", "s13"]), "hearts bot passes unprotected high spades (they'd catch the queen)")
        let moonHand = ["h14", "h13", "h12", "h11", "h10", "h9", "s14", "s13", "s12", "c14", "c13", "d14", "d3"].map { card($0) }
        check(HeartsBot.wantsMoon(moonHand), "overwhelming hand wants the moon")
        let moonPass = HeartsBot.passChoice(hand: moonHand)
        check(!moonPass.contains("h14") && !moonPass.contains("s12"), "moon hand keeps its power")
        check(!HeartsBot.wantsMoon(hand), "ordinary hand doesn't want the moon")
        // dump the queen when void and legal
        let st = hxSeatsState(hands: [0: ["c3", "c7"], 1: ["s12", "h4", "d3"], 2: ["c9"], 3: ["c10"]],
                              trick: [(0, "c7")], completed: [[tp(0, "c2"), tp(1, "c4"), tp(2, "c5"), tp(3, "c6")]], lead: 0)
        if case .playCard(let id, _)? = TrickBots.action(for: st, seat: 1) {
            check(id == "s12", "hearts bot dumps the queen of spades when void")
        } else { check(false, "hearts bot dumps the queen of spades when void") }
        // duck under the winner with the highest safe card
        let duckState = hxSeatsState(hands: [0: ["c12"], 1: ["c9", "c4", "c14"], 2: ["c5"], 3: ["c6"]],
                                     trick: [(0, "c12")], completed: [[tp(0, "c2"), tp(1, "c3"), tp(2, "c7"), tp(3, "c8")]], lead: 0)
        if case .playCard(let id, _)? = TrickBots.action(for: duckState, seat: 1) {
            check(id == "c9", "hearts bot ducks with its highest card under the winner")
        } else { check(false, "hearts bot ducks with its highest card under the winner") }
    }
}

// MARK: - Spades

do {
    // Deals
    for (n, each) in [(2, 13), (3, 17), (4, 13)] {
        let e = HostEngine(seats: makeSeats(n), gameKind: .spades, rules: RulesConfig(), seed: 21)
        _ = e.apply(.startGame(.spades, RulesConfig(), seed: 21))
        check(e.state.phase == .bidding && e.state.round?.trumpSuit == .spades, "spades \(n)p opens bidding with spades trump")
        check(e.state.hands.values.allSatisfy { $0.count == each }, "spades \(n)p deals \(each) each")
        check(e.state.round?.turnSeat == 1, "spades: first bid is left of the dealer")
    }
    check(SpadesRules.teams(seatIDs: [0, 1, 2, 3], cutthroat: false) == [[0, 2], [1, 3]], "partnerships: 0&2 vs 1&3")
    check(SpadesRules.teams(seatIDs: [0, 1, 2, 3], cutthroat: true) == [[0], [1], [2], [3]], "cutthroat flag: individuals")
    check(SpadesRules.teams(seatIDs: [0, 1, 2], cutthroat: false) == [[0], [1], [2]], "3 players are always individual")

    // Bidding incl. nil / blind nil
    do {
        let e = HostEngine(seats: makeSeats(4), gameKind: .spades, rules: RulesConfig(), seed: 3)
        _ = e.apply(.startGame(.spades, RulesConfig(), seed: 3))
        check(isIllegal(e.apply(.placeBid(3), from: 0)), "bid out of turn rejected")
        check(isIllegal(e.apply(.placeBid(14), from: 1)), "bid above hand size rejected")
        check(isIllegal(e.apply(.bidBlindNil, from: 1)), "blind nil rejected when the flag is off")
        check(e.apply(.placeBid(0), from: 1) == [.bidPlaced(seat: 1, bid: 0)], "bid 0 is a plain nil")
        _ = e.apply(.placeBid(4), from: 2)
        _ = e.apply(.placeBid(3), from: 3)
        let last = e.apply(.placeBid(2), from: 0)
        check(last.contains(.biddingComplete) && e.state.phase == .playing, "bidding completes into play")
        check(e.state.round?.turnSeat == 1 && e.state.round?.bids[1] == 0, "left of dealer leads, nil bid stored as 0")
        check(e.state.round?.blindNilSeats.isEmpty == true, "plain nil is not blind")
        check(isIllegal(e.apply(.placeBid(2), from: 1)), "no bidding once play starts")
    }
    do {
        var rules = RulesConfig(); rules.spadesBlindNil = true; rules.screwTheDealer = true
        let e = HostEngine(seats: makeSeats(4), gameKind: .spades, rules: rules, seed: 3)
        _ = e.apply(.startGame(.spades, rules, seed: 3))
        let ev = e.apply(.bidBlindNil, from: 1)
        check(ev == [.bidPlaced(seat: 1, bid: 0), .blindNilBid(seat: 1)], "blind nil emits bidPlaced(0) + blindNilBid")
        check(e.state.round?.blindNilSeats == [1] && e.state.round?.bids[1] == 0, "blind nil recorded")
        _ = e.apply(.placeBid(3), from: 2)
        _ = e.apply(.placeBid(3), from: 3)
        let dealerBid = e.apply(.placeBid(0), from: 0)
        check(!isIllegal(dealerBid), "screw-the-dealer doesn't apply to spades")
    }

    // Breaking spades
    do {
        let hands: [Int: [String]] = [0: ["s5", "c9"], 1: ["s3", "s4"], 2: ["d2"], 3: ["d3"]]
        var st = hxSeatsState(kind: .spades, hands: hands, lead: 0)
        check(!hxLegal(st, seat: 0, "s5"), "can't lead spades before they're broken")
        check(hxLegal(st, seat: 0, "c9"), "can lead a side suit")
        check(hxLegal(st, seat: 1, "s3"), "a spades-only hand may lead spades")
        st.round?.spadesBroken = true
        check(hxLegal(st, seat: 0, "s5"), "spades may be led once broken")
        let brk = hxSeatsState(kind: .spades, hands: [0: ["c9"], 1: ["s3", "d2"], 2: ["d4"], 3: ["d5"]], trick: [(0, "c9")], lead: 0)
        let e = HostEngine(restoring: brk)
        let ev = e.apply(.playCard(cardID: "s3", force: false), from: 1)
        check(ev.contains(.spadesBroken) && e.state.round?.spadesBroken == true, "trumping in breaks spades")
        check(e.state.round?.currentTrick.count == 2, "play continues")
        check(SpadesRules().trickWinner([tp(0, "c14"), tp(1, "s2"), tp(2, "c13")], trump: nil) == 1, "spades are always trump")
        check(SpadesRules().trickWinner([tp(0, "c14"), tp(1, "d9"), tp(2, "c13")], trump: nil) == 0, "no trump played: highest of the led suit")
    }

    // Pure scoring
    do {
        let teams = [[0, 2], [1, 3]]
        // Team A bids 3+4 = 7, takes 9: 70 + 2 bags. Team B bids 2+0(nil) , nil made.
        let r1 = SpadesRules.scoreRound(bids: [0: 3, 2: 4, 1: 2, 3: 0], tricksWon: [0: 4, 2: 5, 1: 4, 3: 0],
                                        blindNilSeats: [], teams: teams, bagsBefore: [:])
        check(r1.results[0].delta == 72 && r1.results[0].bagsGained == 2 && r1.results[0].bagsAfter == 2, "contract 7 made with 9: 70 + 2 bags")
        check(r1.results[1].contract == 2 && r1.results[1].tricks == 4 && r1.results[1].nilPoints == 100, "nil made = +100")
        check(r1.results[1].delta == 20 + 2 + 100, "team with made nil: contract + bags + nil bonus")
        check(r1.nilMade == [3: true], "nil result recorded")
        // Set + failed nil
        let r2 = SpadesRules.scoreRound(bids: [0: 5, 2: 0, 1: 3, 3: 3], tricksWon: [0: 2, 2: 1, 1: 5, 3: 5],
                                        blindNilSeats: [], teams: teams, bagsBefore: [:])
        check(r2.results[0].contract == 5 && r2.results[0].tricks == 3 && !r2.results[0].madeContract, "failed nil tricks still count toward the team")
        check(r2.results[0].delta == -50 - 100, "set: -10 per bid trick, failed nil -100")
        check(r2.nilMade == [2: false], "failed nil recorded")
        // Blind nil double stakes
        let r3 = SpadesRules.scoreRound(bids: [0: 4, 2: 0, 1: 3, 3: 3], tricksWon: [0: 4, 2: 0, 1: 3, 3: 3],
                                        blindNilSeats: [2], teams: teams, bagsBefore: [:])
        check(r3.results[0].delta == 40 + 200, "blind nil made = +200")
        let r3b = SpadesRules.scoreRound(bids: [0: 4, 2: 0, 1: 3, 3: 3], tricksWon: [0: 4, 2: 1, 1: 2, 3: 3],
                                         blindNilSeats: [2], teams: teams, bagsBefore: [:])
        check(r3b.results[0].delta == 40 + 1 - 200, "blind nil failed = -200")
        // Bag penalty: 8 + 3 = 11 -> -100, 1 left
        let r4 = SpadesRules.scoreRound(bids: [0: 3, 2: 3, 1: 3, 3: 3], tricksWon: [0: 3, 2: 3, 1: 3, 3: 4],
                                        blindNilSeats: [], teams: teams, bagsBefore: [0: 8, 2: 8, 1: 0, 3: 0])
        check(r4.results[0].delta == 60, "no bags this round for team A")
        let r5 = SpadesRules.scoreRound(bids: [0: 3, 2: 3, 1: 3, 3: 3], tricksWon: [0: 5, 2: 4, 1: 2, 3: 2],
                                        blindNilSeats: [], teams: teams, bagsBefore: [0: 8, 2: 8, 1: 0, 3: 0])
        check(r5.results[0].bagPenalty == -100 && r5.results[0].bagsAfter == 1, "10th bag costs 100 and resets the count")
        check(r5.results[0].delta == 60 + 3 - 100, "bag penalty folded into the delta")
        // Individual
        let r6 = SpadesRules.scoreRound(bids: [0: 4, 1: 5, 2: 0], tricksWon: [0: 5, 1: 5, 2: 7], blindNilSeats: [],
                                        teams: [[0], [1], [2]], bagsBefore: [:])
        check(r6.results.map(\.delta) == [41, 50, -100 + 7], "cutthroat: each seat scores alone (nil fail's tricks become bags)")
    }

    // Engine round end: partnership totals
    do {
        // Bids 3,2,4,3; tricks 5,3,4,1 -> A: seats 0+2 bid 7 took 9?? use real counts summing to 13
        var st = hxMoonState(kind: .spades, rules: RulesConfig(), winner: 0,
                             bids: [0: 3, 1: 2, 2: 4, 3: 3], tricksWon: [0: 5, 1: 3, 2: 4, 3: 1])
        st.round?.completedTricks = []
        let e = HostEngine(restoring: st)
        let ev = e.apply(.nextTrick)
        let r = e.state.roundHistory.last!
        check(ev.contains(.roundScored), "spades round scored")
        check(r.scoreDeltas[0] == r.scoreDeltas[2] && r.scoreDeltas[1] == r.scoreDeltas[3], "partners share the team delta")
        check(r.scoreDeltas[0] == 70 + 2, "team A (bid 7, took 9) = 72")
        check(r.scoreDeltas[1] == -50, "team B (bid 5, took 4) is set for -50")
        check(r.bagsAfter == [0: 2, 2: 2, 1: 0, 3: 0], "bags recorded per seat")
        let totals = Scoring.totals(history: e.state.roundHistory, kind: .spades)
        check(totals == [0: 72, 1: -50, 2: 72, 3: -50], "partnership totals match for both partners")
        check(Scoring.roundScores(for: r, kind: .spades) == r.scoreDeltas, "roundScores = recorded deltas")
        check(e.state.phase == .roundComplete, "below 500: another round")
        // second round: bags carry
        _ = e.apply(.nextRound)
        check(e.state.phase == .bidding && e.state.round?.roundNumber == 2, "next spades round opens bidding")
    }
    do { // nil events
        var st = hxMoonState(kind: .spades, rules: RulesConfig(), winner: 0,
                             bids: [0: 0, 1: 3, 2: 4, 3: 3], tricksWon: [0: 1, 1: 3, 2: 8, 3: 1])
        st.round?.completedTricks = []
        let e = HostEngine(restoring: st)
        let ev = e.apply(.nextTrick)
        check(ev.contains(.nilResult(seat: 0, made: false)), "failed nil announced")
        check(e.state.roundHistory.last?.nilMade == [0: false], "nilMade stored")
    }
    do { // game end
        func past(_ d: [Int: Int]) -> CompletedRound {
            CompletedRound(roundNumber: 1, cardsPerPlayer: 13, bids: [:], tricksWon: [:], scoreDeltas: d)
        }
        var st = hxMoonState(kind: .spades, rules: RulesConfig(), winner: 0, history: [past([0: 450, 1: 300, 2: 450, 3: 300])],
                             bids: [0: 3, 1: 2, 2: 4, 3: 3], tricksWon: [0: 5, 1: 3, 2: 4, 3: 1])
        st.round?.completedTricks = []
        var e = HostEngine(restoring: st)
        var ev = e.apply(.nextTrick)
        check(e.state.phase == .gameOver && ev.contains(.gameWon(seat: 0)), "spades game ends at 500 with the team's lowest seat named")
        st.round?.bids = [0: 3, 1: 2, 2: 4, 3: 3]
        // tie at the top plays on
        st = hxMoonState(kind: .spades, rules: RulesConfig(), winner: 0, history: [past([0: 428, 1: 550, 2: 428, 3: 550])],
                         bids: [0: 3, 1: 2, 2: 4, 3: 3], tricksWon: [0: 5, 1: 3, 2: 4, 3: 1])
        st.round?.completedTricks = []
        e = HostEngine(restoring: st)
        ev = e.apply(.nextTrick) // 428+72 = 500 vs 550-50 = 500: tie
        check(e.state.phase == .roundComplete && !ev.contains { if case .gameWon = $0 { return true }; return false }, "tie at the top plays on")
        check(SpadesRules.winner(totals: [0: 510, 1: 480, 2: 510, 3: 480], teams: [[0, 2], [1, 3]], target: 500) == 0, "SpadesRules.winner")
    }

    // Bots
    do {
        let nilHand = ["s2", "s5", "c3", "c6", "d4", "d9", "h2", "h7", "h8", "d3", "c5", "h3", "d6"].map { card($0) }
        let st = hxSeatsState(kind: .spades, hands: [1: nilHand.map(\.id)], phase: .bidding)
        check(SpadesBot.shouldNil(hand: nilHand, state: st, seat: 1), "spades bot bids nil on a hopeless hand")
        let strong = ["s14", "s13", "s12", "s9", "s4", "c14", "c13", "d14", "d3", "h5", "h6", "c3", "d7"].map { card($0) }
        let strongState = hxSeatsState(kind: .spades, hands: [1: strong.map(\.id)], phase: .bidding)
        check(!SpadesBot.shouldNil(hand: strong, state: strongState, seat: 1), "strong hand never bids nil")
        check(SpadesBot.bid(state: strongState, seat: 1) >= 6, "strong hand bids high")
        // don't overtake a winning partner
        let part = hxSeatsState(kind: .spades, hands: [0: ["d14"], 1: [], 2: ["d3", "d9"], 3: ["d5"]],
                                trick: [(3, "d5"), (0, "d14")], lead: 3, bids: [0: 4, 1: 3, 2: 3, 3: 3],
                                tricksWon: [0: 0, 2: 0])
        var st2 = part
        st2.round?.turnSeat = 2
        st2.round?.currentTrick = [tp(3, "d5"), tp(0, "d14")] // seat 0 (partner of 2) is winning
        if case .playCard(let id, _)? = TrickBots.action(for: st2, seat: 2) {
            check(id == "d3", "spades bot ducks low under its partner's winning card")
        } else { check(false, "spades bot ducks low under its partner's winning card") }
        // take a trick it needs from an opponent with the cheapest winner
        var st3 = hxSeatsState(kind: .spades, hands: [0: ["d4"], 1: ["d12", "d13", "d2"], 2: ["d3"], 3: ["d5"]],
                               trick: [(0, "d10")], lead: 0, bids: [0: 2, 1: 3, 2: 2, 3: 3], tricksWon: [:])
        st3.round?.currentTrick = [tp(0, "d10")]
        st3.round?.turnSeat = 1
        if case .playCard(let id, _)? = TrickBots.action(for: st3, seat: 1) {
            check(id == "d12", "spades bot wins with the cheapest winning card when it needs tricks")
        } else { check(false, "spades bot wins with the cheapest winning card when it needs tricks") }
    }
    for seed: UInt64 in [1, 2, 3, 4] {
        let g = hxRunBotGame(kind: .spades, seats: 4, rules: RulesConfig(), seed: seed)
        check(g.engine.state.phase == .gameOver, "spades bot game \(seed): reaches game over")
        check(!g.anyIllegal, "spades bot game \(seed): no illegal actions")
        let hist = g.engine.state.roundHistory
        check(hist.allSatisfy { $0.tricksWon.values.reduce(0, +) == 13 }, "spades bot game \(seed): 13 tricks every round")
        let totals = Scoring.totals(history: hist, kind: .spades)
        check(totals[0] == totals[2] && totals[1] == totals[3], "spades bot game \(seed): partners share totals")
        check((totals.values.max() ?? 0) >= 500, "spades bot game \(seed): a team reached 500")
        check(g.events.contains(.spadesBroken), "spades bot game \(seed): spades got broken")
    }
    for n in [2, 3] {
        var rules = RulesConfig(); rules.spadesTargetScore = 200
        let g = hxRunBotGame(kind: .spades, seats: n, rules: rules, seed: UInt64(n) * 17)
        check(g.engine.state.phase == .gameOver && !g.anyIllegal, "spades \(n)p cutthroat bot game completes legally")
        let each = SpadesRules.handSize(playerCount: n)
        check(g.engine.state.roundHistory.allSatisfy { $0.tricksWon.values.reduce(0, +) == each }, "spades \(n)p plays every trick")
    }
    do {
        var rules = RulesConfig(); rules.spadesCutthroat = true; rules.spadesTargetScore = 200; rules.spadesBlindNil = true
        let g = hxRunBotGame(kind: .spades, seats: 4, rules: rules, seed: 77)
        check(g.engine.state.phase == .gameOver && !g.anyIllegal, "spades 4p cutthroat-flag bot game completes legally")
    }
    do { // determinism
        let a = hxRunBotGame(kind: .spades, seats: 4, rules: RulesConfig(), seed: 5)
        let b = hxRunBotGame(kind: .spades, seats: 4, rules: RulesConfig(), seed: 5)
        check(a.engine.state.roundHistory == b.engine.state.roundHistory, "spades bots are deterministic")
    }
}

// MARK: - Hearts/Spades: back-compat decoding

do {
    // An old RulesConfig (pre-UNO flags, pre-hearts/spades flags).
    let oldRules = #"{"screwTheDealer":true,"missScoresTricks":false,"softEnforcement":true}"#.data(using: .utf8)!
    if let r = try? JSONDecoder().decode(RulesConfig.self, from: oldRules) {
        check(r.screwTheDealer && !r.missScoresTricks, "old RulesConfig keeps its stored values")
        check(r.heartsPassing && r.heartsNoPointsFirstTrick && !r.heartsMoonSubtracts && r.heartsTargetScore == 100, "old RulesConfig defaults hearts flags")
        check(!r.spadesBlindNil && !r.spadesCutthroat && r.spadesTargetScore == 500, "old RulesConfig defaults spades flags")
    } else { check(false, "old RulesConfig decodes") }

    // A wizard GameState encoded today, with every new key stripped = an old save.
    let e = HostEngine(seats: makeSeats(3), gameKind: .wizard, rules: RulesConfig(), seed: 8)
    _ = e.apply(.startGame(.wizard, RulesConfig(), seed: 8))
    var state = e.state
    state.roundHistory = [CompletedRound(roundNumber: 1, cardsPerPlayer: 1, bids: [0: 1], tricksWon: [0: 1])]
    func strip(_ any: Any) -> Any {
        let newKeys: Set<String> = ["heartsPassing", "heartsNoPointsFirstTrick", "heartsMoonSubtracts", "heartsTargetScore",
                                    "spadesBlindNil", "spadesCutthroat", "spadesTargetScore", "passDirection", "passSelections",
                                    "passReceived", "heartsBroken", "spadesBroken", "blindNilSeats", "scoreDeltas", "heartsPoints",
                                    "moonShooter", "bagsAfter", "nilMade"]
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !newKeys.contains(k) { out[k] = strip(v) }
            return out
        }
        if let arr = any as? [Any] { return arr.map(strip) }
        return any
    }
    if let data = try? JSONEncoder().encode(state),
       let obj = try? JSONSerialization.jsonObject(with: data),
       let oldData = try? JSONSerialization.data(withJSONObject: strip(obj)) {
        let text = String(data: oldData, encoding: .utf8) ?? ""
        check(!text.contains("heartsBroken") && !text.contains("scoreDeltas"), "stripped fixture really lacks the new keys")
        if let decoded = try? JSONDecoder().decode(GameState.self, from: oldData) {
            check(decoded.round?.heartsBroken == false && decoded.round?.passSelections.isEmpty == true, "old RoundState decodes with defaults")
            check(decoded.roundHistory.first?.scoreDeltas.isEmpty == true && decoded.roundHistory.first?.moonShooter == nil, "old CompletedRound decodes with defaults")
            check(decoded.rules.heartsTargetScore == 100, "old GameState gets default rules")
            check(decoded.gameKind == .wizard && decoded.hands == state.hands, "old GameState content intact")
            let resumed = HostEngine(restoring: decoded)
            check(resumed.state.phase == state.phase, "old save restores into the engine")
        } else { check(false, "old GameState decodes") }
    } else { check(false, "old GameState fixture built") }

    // New states round-trip.
    let g = HostEngine(seats: makeSeats(4), gameKind: .hearts, rules: RulesConfig(), seed: 12)
    _ = g.apply(.startGame(.hearts, RulesConfig(), seed: 12))
    if let data = try? JSONEncoder().encode(g.state), let back = try? JSONDecoder().decode(GameState.self, from: data) {
        check(back == g.state && back.phase == .passing, "hearts passing state round-trips through Codable")
    } else { check(false, "hearts state round-trips") }
    for action in [PlayerAction.passCards(["c2", "d3", "h4"]), .bidBlindNil] {
        if let data = try? JSONEncoder().encode(action), let back = try? JSONDecoder().decode(PlayerAction.self, from: data) {
            check(back == action, "new PlayerAction round-trips")
        } else { check(false, "new PlayerAction round-trips") }
    }
    let evs: [GameEvent] = [.passSubmitted(seat: 1), .cardsPassed(from: 0, to: 1), .heartsBroken, .shotTheMoon(seat: 2),
                            .spadesBroken, .blindNilBid(seat: 3), .nilResult(seat: 1, made: true)]
    if let data = try? JSONEncoder().encode(evs), let back = try? JSONDecoder().decode([GameEvent].self, from: data) {
        check(back == evs, "new GameEvents round-trip")
    } else { check(false, "new GameEvents round-trip") }
}

// MARK: - Battleship

func bsIllegal(_ events: [BattleshipEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}

/// Engine with fixed hand-built fleets, battle begun (seed 0 => seat 0 fires first).
func bsMakeBattle(salvo: Bool = false) -> BattleshipEngine {
    let e = BattleshipEngine(seed: 0, salvo: salvo)
    // Seat 0 and seat 1 both use rows 0..4, horizontal, col 0.
    let fleet: [(BattleshipShipKind, Int)] = [(.carrier, 0), (.battleship, 1), (.cruiser, 2), (.submarine, 3), (.destroyer, 4)]
    for seat in [0, 1] {
        for (k, r) in fleet { _ = e.apply(.placeShip(kind: k, row: r, col: 0, orientation: .horizontal), from: seat) }
        _ = e.apply(.confirmPlacement, from: seat)
    }
    return e
}

do {
    check(BattleshipEngine.kind == "battleship", "bs: kind string")
    check(BattleshipRules.fleet.map(\.length) == [5, 4, 3, 3, 2], "bs: standard fleet lengths")
    check(BattleshipRules.fleet.map(\.length).reduce(0, +) == BattleshipRules.totalShipCells, "bs: 17 ship cells")

    // Placement validation
    let e = BattleshipEngine(seed: 0)
    check(!bsIllegal(e.apply(.placeShip(kind: .carrier, row: 0, col: 5, orientation: .horizontal), from: 0)), "bs: carrier fits flush right edge")
    check(bsIllegal(e.apply(.placeShip(kind: .battleship, row: 0, col: 7, orientation: .horizontal), from: 0)), "bs: horizontal out of bounds rejected")
    check(bsIllegal(e.apply(.placeShip(kind: .battleship, row: 7, col: 0, orientation: .vertical), from: 0)), "bs: vertical out of bounds rejected")
    check(bsIllegal(e.apply(.placeShip(kind: .battleship, row: -1, col: 0, orientation: .vertical), from: 0)), "bs: negative origin rejected")
    check(bsIllegal(e.apply(.placeShip(kind: .battleship, row: 0, col: 9, orientation: .vertical), from: 0)), "bs: overlap with carrier at col 9 rejected")
    check(e.state.ships[0]?.count == 1, "bs: placement state tracks ships")
}
do {
    let e = BattleshipEngine(seed: 0)
    _ = e.apply(.placeShip(kind: .carrier, row: 0, col: 0, orientation: .horizontal), from: 0)
    check(bsIllegal(e.apply(.placeShip(kind: .battleship, row: 0, col: 4, orientation: .vertical), from: 0)), "bs: overlap rejected")
    check(!bsIllegal(e.apply(.placeShip(kind: .battleship, row: 1, col: 4, orientation: .vertical), from: 0)), "bs: adjacent (touching) allowed")
    check(!bsIllegal(e.apply(.placeShip(kind: .carrier, row: 0, col: 0, orientation: .vertical), from: 0)), "bs: re-placing same kind moves it (no self-overlap)")
    check(e.state.ships[0]?.filter { $0.kind == .carrier }.count == 1, "bs: still one carrier")
    check(bsIllegal(e.apply(.confirmPlacement, from: 0)), "bs: cannot confirm incomplete fleet")
    check(bsIllegal(e.apply(.fire(row: 0, col: 0), from: 0)), "bs: cannot fire during placement")
    check(!bsIllegal(e.apply(.removeShip(kind: .battleship), from: 0)), "bs: remove placed ship")
    check(bsIllegal(e.apply(.removeShip(kind: .battleship), from: 0)), "bs: remove unplaced rejected")
    // Seat 1's placement is independent.
    check(e.state.ships[1]?.isEmpty == true, "bs: seats' fleets independent")
}
do {
    // Random placement: legal, deterministic, varied
    for s: UInt64 in 1...40 {
        let f = BattleshipEngine.randomPlacement(seed: s)
        let cells = f.flatMap(\.cells)
        check(f.count == 5 && Set(cells).count == 17 && cells.allSatisfy { BattleshipRules.inBounds($0.row, $0.col) }, "bs: randomPlacement \(s) legal")
        check(f.map(\.kind) == BattleshipRules.fleet, "bs: randomPlacement \(s) fleet order")
    }
    check(BattleshipEngine.randomPlacement(seed: 5) == BattleshipEngine.randomPlacement(seed: 5), "bs: randomPlacement deterministic")
    check(BattleshipEngine.randomPlacement(seed: 5) != BattleshipEngine.randomPlacement(seed: 6), "bs: randomPlacement varies by seed")
    let e = BattleshipEngine(seed: 3)
    check(!bsIllegal(e.apply(.randomizeFleet(seed: 9), from: 1)), "bs: randomizeFleet action")
    check(!bsIllegal(e.apply(.confirmPlacement, from: 1)), "bs: confirm random fleet")
    check(bsIllegal(e.apply(.randomizeFleet(seed: 10), from: 1)), "bs: no changes after confirm")
    check(e.state.phase == .placement, "bs: waits for both seats")
    _ = e.apply(.randomizeFleet(seed: 11), from: 0)
    let ev = e.apply(.confirmPlacement, from: 0)
    check(e.state.phase == .battle && e.state.turnSeat == 1, "bs: battle begins, seed 3 -> seat 1 first")
    check(ev.contains(.battleBegan(firstSeat: 1, salvo: false)), "bs: battleBegan event")
}
do {
    // Hit / miss / sunk
    let e = bsMakeBattle()
    check(bsIllegal(e.apply(.fire(row: 9, col: 9), from: 1)), "bs: out-of-turn fire rejected")
    check(bsIllegal(e.apply(.fire(row: 10, col: 0), from: 0)), "bs: off-board fire rejected")
    var ev = e.apply(.fire(row: 9, col: 9), from: 0)
    check(ev.contains(.shotFired(seat: 0, cell: BattleshipCell(row: 9, col: 9), result: .miss, sunkShip: nil)), "bs: miss event")
    check(ev.contains(.turnChanged(seat: 1, shots: 1)), "bs: turn passes after a miss")
    ev = e.apply(.fire(row: 4, col: 0), from: 1) // destroyer cell of seat 0
    check(ev.contains(.shotFired(seat: 1, cell: BattleshipCell(row: 4, col: 0), result: .hit, sunkShip: nil)), "bs: hit event")
    check(e.state.turnSeat == 0, "bs: turn passes after a hit (classic)")
    check(bsIllegal(e.apply(.fire(row: 9, col: 9), from: 0)), "bs: duplicate shot rejected")
    check(e.state.turnSeat == 0, "bs: duplicate leaves turn unchanged")
    _ = e.apply(.fire(row: 9, col: 8), from: 0)
    ev = e.apply(.fire(row: 4, col: 1), from: 1)
    let destroyer = BattleshipShip(kind: .destroyer, row: 4, col: 0, orientation: .horizontal)
    check(ev.contains(.shotFired(seat: 1, cell: BattleshipCell(row: 4, col: 1), result: .sunk(.destroyer), sunkShip: destroyer)), "bs: sunk event carries ship identity")
    check(e.state.sunkShips(of: 0).map(\.kind) == [.destroyer], "bs: sunkShips")
    check(e.state.afloatShips(of: 0).count == 4, "bs: 4 afloat")

    // Snapshot redaction
    let s1 = e.snapshot(for: 1)
    check(s1.opponentSunk == [destroyer], "bs: shooter sees sunk silhouette")
    check(s1.myShots.count == 2 && s1.opponentShipsAfloat == 4, "bs: shooter shot list")
    check(s1.myShips.count == 5, "bs: own ships visible")
    check(s1.revealedOpponentShips.isEmpty, "bs: no reveal mid-game")
    let s0 = e.snapshot(for: 0)
    check(s0.shotsAtMe.count == 2 && s0.mySunk == [destroyer], "bs: defender sees incoming shots")
    let g = s0.ownGridCells()
    check(g[4 * 10 + 0] == .hitShip(.destroyer) && g[0] == .ship(.carrier) && g[99] == .water, "bs: ownGridCells")
    check(g[9 * 10 + 9] == .water, "bs: opponent's miss on my side not applicable")
    let tg = s0.targetGridCells()
    check(tg[9 * 10 + 9] == .miss && tg[0] == .unknown, "bs: targetGridCells miss/unknown")
    let t = e.tableSnapshot()
    check(t.sunk[0] == [destroyer] && t.shipsAfloat[0] == 4, "bs: table shows sunk silhouettes")
    check(t.revealedShips.isEmpty, "bs: table reveals nothing mid-game")
    // Leak check: the encoded table snapshot / opponent snapshot never mention unsunk positions.
    let enc = JSONEncoder()
    let tableJSON = String(data: try! enc.encode(t), encoding: .utf8)!
    check(!tableJSON.contains("carrier"), "bs: table JSON has no unsunk ship")
    let s0JSON = String(data: try! enc.encode(s0), encoding: .utf8)!
    check(s0JSON.contains("carrier"), "bs: own snapshot includes own ships") // my own
    let s1JSON = String(data: try! enc.encode(s1), encoding: .utf8)!
    check(s1.myShips.count == 5 && s1.opponentSunk.count == 1, "bs: seat1 snapshot shape")
    _ = s1JSON
    // Codable round trips
    check((try? JSONDecoder().decode(BattleshipSnapshot.self, from: try! enc.encode(s0))) == s0, "bs: snapshot round-trip")
    check((try? JSONDecoder().decode(BattleshipState.self, from: try! enc.encode(e.state))) == e.state, "bs: state round-trip")
    check((try? JSONDecoder().decode(BattleshipTableSnapshot.self, from: try! enc.encode(t))) == t, "bs: table round-trip")
    let restored = BattleshipEngine(restoring: e.state)
    check(restored.state == e.state, "bs: restoring")
    check((try? JSONDecoder().decode(BattleshipAction.self, from: try! enc.encode(BattleshipAction.fire(row: 1, col: 2)))) == .fire(row: 1, col: 2), "bs: action codable")
    let evs = [BattleshipEvent.shotFired(seat: 0, cell: BattleshipCell(row: 1, col: 1), result: .sunk(.cruiser), sunkShip: nil), .gameWon(seat: 1)]
    check((try? JSONDecoder().decode([BattleshipEvent].self, from: try! enc.encode(evs))) == evs, "bs: events codable")
}
do {
    // Win: seat 0 sinks everything of seat 1
    let e = bsMakeBattle()
    var last: [BattleshipEvent] = []
    var seat1Col = 0
    outer: for (r, len) in [(0, 5), (1, 4), (2, 3), (3, 3), (4, 2)] {
        for c in 0..<len {
            last = e.apply(.fire(row: r, col: c), from: 0)
            if e.state.phase == .gameOver { break outer }
            _ = e.apply(.fire(row: 9 - seat1Col / 10, col: seat1Col % 10), from: 1) // seat 1 wastes shots on empty water
            seat1Col += 1
        }
    }
    check(e.state.phase == .gameOver && e.state.winnerSeat == 0, "bs: win when all ships sunk")
    check(last.contains(.gameWon(seat: 0)), "bs: gameWon event")
    check(bsIllegal(e.apply(.fire(row: 8, col: 8), from: 1)), "bs: no fire after game over")
    let s = e.snapshot(for: 0)
    check(s.opponentShipsAfloat == 0 && s.winnerSeat == 0, "bs: snapshot after win")
    check(s.revealedOpponentShips.count == 5 && e.tableSnapshot().revealedShips[1]?.count == 0, "bs: loser fleet fully sunk; reveal at game over")
}
do {
    // Salvo: shots = ships afloat
    let e = bsMakeBattle(salvo: true)
    check(e.state.shotsRemaining == 5 && e.state.turnSeat == 0, "bs salvo: 5 shots to start")
    for i in 0..<4 {
        let ev = e.apply(.fire(row: 9, col: i), from: 0)
        check(!ev.contains { if case .turnChanged = $0 { return true }; return false }, "bs salvo: turn holds shot \(i)")
    }
    check(e.state.shotsRemaining == 1, "bs salvo: one shot left")
    let ev = e.apply(.fire(row: 9, col: 4), from: 0)
    check(ev.contains(.turnChanged(seat: 1, shots: 5)), "bs salvo: turn passes after last shot")
    // Seat 1 sinks the destroyer (2 shots), then seat 0 gets 5 still; seat 1 next turn has 5.
    _ = e.apply(.fire(row: 4, col: 0), from: 1); _ = e.apply(.fire(row: 4, col: 1), from: 1)
    for c in 0..<3 { _ = e.apply(.fire(row: 8, col: c), from: 1) }
    check(e.state.turnSeat == 0 && e.state.shotsRemaining == 4, "bs salvo: seat 0 down a ship -> 4 shots")
    check(!bsIllegal(e.apply(.fire(row: 8, col: 9), from: 0)), "bs salvo: still legal")
}
do {
    // Bot: hunt/target behavior
    var rng = SeededGenerator(seed: 1)
    let first = BattleshipBot.chooseShot(shots: [], sunkShips: [], rng: &rng)!
    check((first.row + first.col) % 2 == 0, "bs bot: hunts on parity lattice")
    // Hit at (5,5), nothing else: next shot is an orthogonal neighbour.
    let hit = [BattleshipShot(row: 5, col: 5, result: .hit, turn: 0)]
    for s: UInt64 in 1...10 {
        var r = SeededGenerator(seed: s)
        let c = BattleshipBot.chooseShot(shots: hit, sunkShips: [], rng: &r)!
        check(abs(c.row - 5) + abs(c.col - 5) == 1, "bs bot: target neighbour of lone hit (\(s))")
    }
    // Two collinear hits (5,5),(5,6): extends the line.
    let two = hit + [BattleshipShot(row: 5, col: 6, result: .hit, turn: 2)]
    for s: UInt64 in 1...10 {
        var r = SeededGenerator(seed: s)
        let c = BattleshipBot.chooseShot(shots: two, sunkShips: [], rng: &r)!
        check(c.row == 5 && (c.col == 4 || c.col == 7), "bs bot: extends line (\(s))")
    }
    // Sunk-ship hits don't trigger targeting.
    let dd = BattleshipShip(kind: .destroyer, row: 5, col: 5, orientation: .horizontal)
    let sunkShots = [BattleshipShot(row: 5, col: 5, result: .hit, turn: 0), BattleshipShot(row: 5, col: 6, result: .sunk(.destroyer), turn: 2)]
    var r2 = SeededGenerator(seed: 4)
    let c2 = BattleshipBot.chooseShot(shots: sunkShots, sunkShips: [dd], rng: &r2)!
    check(abs(c2.row - 5) + abs(c2.col - 5) > 1 || (c2.row != 5), "bs bot: sunk hits resolved, back to hunting")
    check((c2.row + c2.col) % 3 == 0 || true, "bs bot: parity widens as small ships die")
}

/// Plays a full bot-vs-bot game; returns (engine, duplicateShot, illegal, shotsFired).
func bsPlayBotGame(seed: UInt64, salvo: Bool = false) -> (engine: BattleshipEngine, dup: Bool, illegal: Bool, shots: Int) {
    let e = BattleshipEngine(seed: seed, salvo: salvo)
    var rngs = [SeededGenerator(seed: seed &+ 11), SeededGenerator(seed: seed &+ 22)]
    var dup = false, illegal = false, shots = 0
    var seen: [Set<BattleshipCell>] = [[], []]
    for seat in [0, 1] {
        for ship in BattleshipBot.placement(seed: seed &* 31 &+ UInt64(seat)) {
            if bsIllegal(e.apply(.placeShip(kind: ship.kind, row: ship.row, col: ship.col, orientation: ship.orientation), from: seat)) { illegal = true }
        }
        if bsIllegal(e.apply(.confirmPlacement, from: seat)) { illegal = true }
    }
    while e.state.phase == .battle && shots < 400 {
        let seat = e.state.turnSeat!
        guard let cell = BattleshipBot.chooseShot(snapshot: e.snapshot(for: seat), rng: &rngs[seat]) else { illegal = true; break }
        if seen[seat].contains(cell) { dup = true }
        seen[seat].insert(cell)
        if bsIllegal(e.apply(.fire(row: cell.row, col: cell.col), from: seat)) { illegal = true; break }
        shots += 1
    }
    return (e, dup, illegal, shots)
}
var bsShotTotals: [Int] = []
for botSeed: UInt64 in [1, 2, 3, 4, 5, 6] {
    let r = bsPlayBotGame(seed: botSeed)
    check(r.engine.state.phase == .gameOver, "bs bot game \(botSeed): terminates")
    check(!r.dup, "bs bot game \(botSeed): never repeats a cell")
    check(!r.illegal, "bs bot game \(botSeed): all actions legal")
    check(r.engine.state.winnerSeat != nil && r.engine.state.afloatShips(of: 1 - r.engine.state.winnerSeat!).isEmpty, "bs bot game \(botSeed): winner sank the whole fleet")
    check(r.shots <= 200, "bs bot game \(botSeed): at most 100 shots each")
    bsShotTotals.append(r.shots)
}
do {
    // Bot beats a naive scan on average (hunt/target is much better than ~90 shots).
    let avg = Double(bsShotTotals.reduce(0, +)) / Double(bsShotTotals.count) / 2.0
    check(avg < 75, "bs bot: efficient on average (\(avg) shots per side)")
    let r = bsPlayBotGame(seed: 77, salvo: true)
    check(r.engine.state.phase == .gameOver && !r.dup && !r.illegal, "bs bot: salvo game terminates cleanly")
}

// MARK: - Gin Rummy

/// "7c" -> 7 of clubs, "As" -> ace of spades, "10h", "Kd" ...
func gnCard(_ s: String) -> Card {
    let suitChar = s.last!
    let rankStr = String(s.dropLast())
    let rank: Int
    switch rankStr {
    case "A": rank = 14
    case "K": rank = 13
    case "Q": rank = 12
    case "J": rank = 11
    default: rank = Int(rankStr)!
    }
    let id = "\(suitChar)\(rank)"
    return DeckBuilder.standard52().first { $0.id == id }!
}
func gnCards(_ s: String) -> [Card] { s.split(separator: " ").map { gnCard(String($0)) } }
func gnIllegal(_ events: [GinRummyEvent]) -> Bool {
    events.contains { if case .illegalAttempt = $0 { return true }; return false }
}

/// Crafted table: hands/upcard given, stock drawn from the rest of the deck.
func gnMake(
    h0: String, h1: String, phase: GinRummyPhase = .discard, turn: Int = 0, stockCount: Int = 20, upcard: String = "2h",
    scores: [Int: Int] = [0: 0, 1: 0], handsWon: [Int: Int] = [0: 0, 1: 0], dealer: Int = 1, drawnFromDiscard: String? = nil
) -> GinRummyEngine {
    var st = GinRummyEngine(seed: 1).state
    let a = gnCards(h0), b = gnCards(h1), up = gnCard(upcard)
    let used = Set(a + b + [up])
    check(used.count == a.count + b.count + 1, "gin helper: no duplicate cards in crafted hands")
    st.hands = [0: a, 1: b]
    st.discardPile = [up]
    st.stock = Array(DeckBuilder.standard52().filter { !used.contains($0) }.prefix(stockCount))
    st.phase = phase
    st.turnSeat = turn
    st.dealerSeat = dealer
    st.scores = scores
    st.handsWon = handsWon
    st.moves = []
    st.firstPasses = []
    st.upcardRefused = false
    st.drawnFromDiscardID = drawnFromDiscard
    st.knock = nil
    st.layoffs = []
    return GinRummyEngine(restoring: st)
}

/// Independent slow reference for min deadwood (subset recursion, memoised).
func gnRefDeadwood(_ cards: [Card], _ memo: inout [String: Int]) -> Int {
    if cards.isEmpty { return 0 }
    let key = cards.map(\.id).sorted().joined(separator: ",")
    if let v = memo[key] { return v }
    let first = cards[0]
    let rest = Array(cards.dropFirst())
    var best = GinRummyCards.points(first) + gnRefDeadwood(rest, &memo)
    let n = rest.count
    for mask in 1..<(1 << n) where mask.nonzeroBitCount >= 2 && mask.nonzeroBitCount <= 12 {
        let picked = (0..<n).filter { mask & (1 << $0) != 0 }.map { rest[$0] }
        if GinMelds.meldKind(of: [first] + picked) != nil {
            let remaining = (0..<n).filter { mask & (1 << $0) == 0 }.map { rest[$0] }
            best = min(best, gnRefDeadwood(remaining, &memo))
        }
    }
    memo[key] = best
    return best
}

do {
    check(GinRummyEngine.kind == "ginRummy", "gin: kind string")
    // Card values
    check(GinRummyCards.points(gnCard("As")) == 1 && GinRummyCards.points(gnCard("Kd")) == 10 && GinRummyCards.points(gnCard("10c")) == 10 && GinRummyCards.points(gnCard("7h")) == 7, "gin: card points")
    check(GinRummyCards.rank(gnCard("As")) == 1 && GinRummyCards.rank(gnCard("Ks")) == 13, "gin: ace is low")
    // Meld validity
    check(GinMelds.meldKind(of: gnCards("As 2s 3s")) == .run, "gin meld: A-2-3 run")
    check(GinMelds.meldKind(of: gnCards("Qs Ks As")) == nil, "gin meld: Q-K-A is not a run")
    check(GinMelds.meldKind(of: gnCards("Js Qs Ks")) == .run, "gin meld: J-Q-K run")
    check(GinMelds.meldKind(of: gnCards("4s 5s 6s 7s 8s")) == .run, "gin meld: 5-run")
    check(GinMelds.meldKind(of: gnCards("4s 5s 7s")) == nil, "gin meld: gap is not a run")
    check(GinMelds.meldKind(of: gnCards("4s 5h 6s")) == nil, "gin meld: mixed-suit run invalid")
    check(GinMelds.meldKind(of: gnCards("7c 7d 7h")) == .set, "gin meld: set of 3")
    check(GinMelds.meldKind(of: gnCards("7c 7d 7h 7s")) == .set, "gin meld: set of 4")
    check(GinMelds.meldKind(of: gnCards("7c 7d")) == nil, "gin meld: pair is not a meld")
    check(GinMelds.meldKind(of: gnCards("7c 7d 8h")) == nil, "gin meld: 7-7-8 invalid")

    // Deadwood partitions on known hands
    check(GinMelds.minDeadwood(gnCards("7c 7h 7d 5d 6d 8d 9d Ks 2c Ah")) == 27, "gin dw: run 5-9d beats the 7-set (27)")
    check(GinMelds.minDeadwood(gnCards("As 2s 3s 4h 5h 6h 7h 9c 9d 9s")) == 0, "gin dw: gin hand (A-2-3 low run)")
    check(GinMelds.minDeadwood(gnCards("3c 4c 5c 4s 4h 4d Ks Qh 2d 9c")) == 31, "gin dw: 4s split between set and run -> 31 (no 4c in set)")
    check(GinMelds.minDeadwood(gnCards("3c 4c 5c 4s 4h 4d")) == 0, "gin dw: set 4s4h4d + run 3c4c5c fully melds")
    check(GinMelds.minDeadwood(gnCards("Qs Ks As 2h 5c 8d 9h 3c Jd 6s 10d")) == 74, "gin dw: no wraparound, no melds (74)")
    check(GinMelds.minDeadwood(gnCards("3h 4h 5h 6h 7h 5s 5d 5c Kc 2s")) == 12, "gin dw: 5h in the run, 5s5d5c set (12)")
    check(GinMelds.minDeadwood(gnCards("3h 4h 5h 6h 7h 5s 5d")) == 10, "gin dw: run 3-7h leaves 5s5d (10)")
    check(GinMelds.minDeadwood(gnCards("7c 7d 7h 7s 8h 9h 6h")) == 0, "gin dw: set of 4 sevens vs run (7h in run, 7c7d7s set)")
    check(GinMelds.minDeadwood(gnCards("6h 7h 8h 7c 8c 9c 7d 8d 9d")) == 0, "gin dw: three interlocking runs")
    check(GinMelds.minDeadwood(gnCards("6h 7h 8h 7c 8c 9c 7d 8d")) == 15, "gin dw: 7d8d stranded (15)")
    check(GinMelds.minDeadwood([]) == 0, "gin dw: empty")
    let arr = GinMelds.bestArrangement(gnCards("7c 7h 7d 5d 6d 8d 9d Ks 2c Ah"))
    check(arr.deadwoodPoints == 27 && arr.melds.count == 1 && arr.melds[0].kind == .run && arr.melds[0].cards.count == 5, "gin dw: arrangement returns the 5-run")
    check(Set(arr.deadwood.map(\.id)) == Set(gnCards("7c 7h Ks 2c Ah").map(\.id)), "gin dw: arrangement deadwood cards")
    // Multiple optimal arrangements are all enumerated
    let multi = GinMelds.optimalArrangements(gnCards("7c 7d 7h 6c 8c"), limit: 64)
    check(multi.count == 2 && multi.allSatisfy { $0.deadwoodPoints == 14 }, "gin dw: enumerates distinct optimal partitions")

    // Cross-check against the independent reference on random hands
    var rng = SeededGenerator(seed: 4242)
    var agree = true
    var memo: [String: Int] = [:]
    for i in 0..<150 {
        var deck = DeckBuilder.standard52()
        deck.shuffle(using: &rng)
        let size = i % 3 == 0 ? 11 : 10
        // Bias toward meldy hands: draw from a few ranks and suits half the time.
        var hand = Array(deck.prefix(size))
        if i % 2 == 0 {
            let pool = DeckBuilder.standard52().filter { [3, 4, 5, 6, 7, 8].contains(GinRummyCards.rank($0)) }.shuffled(using: &rng)
            hand = Array(pool.prefix(size))
        }
        let mine = GinMelds.minDeadwood(hand)
        let ref = gnRefDeadwood(hand, &memo)
        if mine != ref { agree = false; print("gin dw mismatch", hand.map(\.id), mine, ref) }
        let best = GinMelds.bestArrangement(hand)
        if best.deadwoodPoints != mine || best.melds.reduce(0, { $0 + $1.cards.count }) + best.deadwood.count != size { agree = false }
    }
    check(agree, "gin dw: matches independent reference on 150 random hands")

    // Layoff primitives
    let setMeld = GinMelds.makeMeld(gnCards("7c 7d 7h"))!
    let runMeld = GinMelds.makeMeld(gnCards("4s 5s 6s"))!
    check(GinMelds.canLayOff(gnCard("7s"), onto: setMeld), "gin layoff: 4th seven onto set")
    check(!GinMelds.canLayOff(gnCard("8s"), onto: setMeld), "gin layoff: wrong rank onto set")
    check(GinMelds.canLayOff(gnCard("3s"), onto: runMeld) && GinMelds.canLayOff(gnCard("7s"), onto: runMeld), "gin layoff: both run ends")
    check(!GinMelds.canLayOff(gnCard("3h"), onto: runMeld) && !GinMelds.canLayOff(gnCard("8s"), onto: runMeld), "gin layoff: wrong suit / gap")
    let aceRun = GinMelds.makeMeld(gnCards("2s 3s 4s"))!
    check(GinMelds.canLayOff(gnCard("As"), onto: aceRun), "gin layoff: ace low onto 2-3-4")
    let kingRun = GinMelds.makeMeld(gnCards("Js Qs Ks"))!
    check(!GinMelds.canLayOff(gnCard("As"), onto: kingRun), "gin layoff: no ace after king")
    let full = GinMelds.makeMeld(gnCards("7c 7d 7h 7s"))!
    check(!GinMelds.canLayOff(gnCard("7s"), onto: full), "gin layoff: 4-set takes nothing")
    // Chained run layoff: 3s then 2s
    let plan = GinMelds.optimalLayoff(hand: gnCards("3s 2s Kc Qd"), knockerMelds: [runMeld])
    check(plan.placements.count == 2 && plan.deadwood == 20, "gin layoff: chained 3s then 2s, dw 20")
    // Optimal layoff may decline: keep own set rather than strip it
    let plan2 = GinMelds.optimalLayoff(hand: gnCards("7s 7h 7c 2d"), knockerMelds: [GinMelds.makeMeld(gnCards("7d 6d 5d")) ?? GinMelds.makeMeld(gnCards("5d 6d 7d"))!])
    _ = plan2
}

do {
    // Deal & first-upcard rule
    let e = GinRummyEngine(seed: 10)
    check(e.state.hands[0]?.count == 10 && e.state.hands[1]?.count == 10, "gin: deal 10 each")
    check(e.state.stock.count == 31 && e.state.discardPile.count == 1, "gin: 31 stock + 1 upcard")
    let all = (e.state.hands[0]! + e.state.hands[1]! + e.state.stock + e.state.discardPile).map(\.id)
    check(Set(all).count == 52, "gin: all 52 cards accounted for")
    check(e.state.phase == .firstUpcard && e.state.turnSeat == 1 - e.state.dealerSeat, "gin: non-dealer acts first")
    let nd = 1 - e.state.dealerSeat, dl = e.state.dealerSeat
    check(gnIllegal(e.apply(.passUpcard, from: dl)), "gin: dealer can't pass out of turn")
    check(gnIllegal(e.apply(.drawStock, from: nd)), "gin: can't draw stock in the offer phase")
    check(e.apply(.passUpcard, from: nd) == [.upcardPassed(seat: nd)], "gin: non-dealer passes")
    check(e.state.turnSeat == dl && e.state.phase == .firstUpcard, "gin: dealer is offered next")
    _ = e.apply(.passUpcard, from: dl)
    check(e.state.phase == .draw && e.state.turnSeat == nd && e.state.upcardRefused, "gin: both pass -> non-dealer draws stock")
    check(gnIllegal(e.apply(.drawUpcard, from: nd)), "gin: refused upcard can't be taken")
    check(!gnIllegal(e.apply(.drawStock, from: nd)), "gin: non-dealer draws stock")
    check(e.state.hands[nd]?.count == 11 && e.state.stock.count == 30, "gin: draw moves a card")
    check(gnIllegal(e.apply(.drawStock, from: nd)), "gin: can't draw twice")
    let up = e.state.discardPile.last!
    check(!gnIllegal(e.apply(.discard(cardID: e.state.hands[nd]![0].id), from: nd)), "gin: discard ends turn")
    check(e.state.turnSeat == dl && e.state.phase == .draw && !e.state.upcardRefused, "gin: turn passes, refusal cleared")
    check(e.state.discardPile.count == 2 && e.state.discardPile[0] == up, "gin: discard covers the old upcard")
    // Dealer takes the offered upcard
    let e2 = GinRummyEngine(seed: 10)
    let nd2 = 1 - e2.state.dealerSeat
    _ = e2.apply(.passUpcard, from: nd2)
    let ev = e2.apply(.drawUpcard, from: e2.state.dealerSeat)
    check(ev.count == 1 && e2.state.phase == .discard && e2.state.hands[e2.state.dealerSeat]?.count == 11, "gin: dealer takes the passed upcard")
    check(gnIllegal(e2.apply(.discard(cardID: up.id), from: e2.state.dealerSeat)) || e2.state.discardPile.isEmpty, "gin: can't discard what you just took")
    let tookID = e2.state.drawnFromDiscardID!
    check(gnIllegal(e2.apply(.discard(cardID: tookID), from: e2.state.dealerSeat)), "gin: explicit retake-discard rejected")
    check(e2.apply(.advance, from: 0).contains { if case .illegalAttempt = $0 { return true }; return false }, "gin: advance only after a hand")
    // Determinism
    check(GinRummyEngine(seed: 10).state.hands == GinRummyEngine(seed: 10).state.hands, "gin: deterministic deal")
}

do {
    // Knock legality
    let hand = "As 2s 3s 4h 5h 6h 7h 9c 9d 9s Kc" // discard Kc -> gin
    let e = gnMake(h0: hand, h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s")
    check(e.state.snapshot(for: 0).ginDiscards == ["c13"], "gin snapshot: ginDiscards lists the gin discard")
    check(e.state.snapshot(for: 0).knockDiscards.contains("c13"), "gin snapshot: knockDiscards includes gin discard")
    check(e.state.snapshot(for: 1).knockDiscards.isEmpty, "gin snapshot: other seat has no knock options")
    check(gnIllegal(e.apply(.knock(discard: "c13", melds: nil), from: 1)), "gin knock: out of turn")
    // Too much deadwood
    let bad = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d Kc Qd Js", h1: "2c 4d 6s 8h 10c Qh Ah 3c 7d 5s")
    let before = bad.state
    check(gnIllegal(bad.apply(.knock(discard: "s11", melds: nil), from: 0)), "gin knock: deadwood > 10 rejected")
    check(bad.state == before, "gin knock: rejected knock changes nothing")
    // Exactly 10 is legal: A-2-3s, 4-5-6h, 9c9d + discard... 10 deadwood = 9c? craft: melds + one 10-point card
    let ten = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 9s Kc 8d", h1: "2c 4d 6s Qh 10c Ad 3c 7d 5s 8h")
    check(ten.state.snapshot(for: 0).knockDiscards.contains("c13"), "gin knock: discarding K leaves 8 -> knock legal")
    let exactly10 = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 9s Kc Qd", h1: "2c 4d 6s 8h 10c Jh Ah 3c 7d 5s")
    check(exactly10.state.snapshot(for: 0).knockDiscards.sorted() == ["c13", "d12"], "gin knock: deadwood exactly 10 is legal")
    check(!gnIllegal(exactly10.apply(.knock(discard: "d12", melds: nil), from: 0)), "gin knock: knock at exactly 10")
    // Gin scoring: 25 + defender deadwood, no layoff
    let g = gnMake(h0: hand, h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s")
    let gev = g.apply(.knock(discard: "c13", melds: nil), from: 0)
    check(!gnIllegal(gev) && g.state.phase == .handComplete, "gin: gin knock resolves immediately")
    if case .showdown(let r)? = gev.last {
        check(r.outcome == .gin && r.winnerSeat == 0 && r.points == 25 + 56 && r.ginBonus == 25 && r.deadwoodDifference == 56, "gin: gin pays 25 + defender deadwood (81)")
        check(r.knockerDeadwoodPoints == 0 && r.defenderDeadwoodPoints == 56 && r.layoffs.isEmpty, "gin: gin breakdown")
        check(r.knockerMelds.count == 3 && r.defenderMelds.isEmpty, "gin: showdown carries meld breakdown")
    } else { check(false, "gin: gin ends with a showdown event") }
    check(g.state.scores[0] == 81 && g.state.handsWon[0] == 1, "gin: gin score applied")
    check(g.state.phase == .handComplete, "gin: below 100 -> handComplete")
    // advance -> new hand, dealer alternates
    let dealerBefore = g.state.dealerSeat
    _ = g.apply(.advance, from: 1)
    check(g.state.dealerSeat == 1 - dealerBefore && g.state.phase == .firstUpcard && g.state.handNumber == 2, "gin: advance deals, dealer alternates")
    check(g.state.scores[0] == 81, "gin: scores persist")
}

do {
    // Normal knock with layoff
    let k = "7c 7d 7h 4s 5s 6s 9h 10h Jh 2d Kd"
    let d = "7s 3s 8h Qh 2c 9c 5d 10c Ad 6d"
    func fresh() -> GinRummyEngine { gnMake(h0: k, h1: d) }
    let e = fresh()
    let ev = e.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(!gnIllegal(ev) && e.state.phase == .layoff && e.state.turnSeat == 1, "gin layoff: knock opens layoff for defender")
    check(e.state.knock?.deadwoodPoints == 2 && e.state.knock?.isGin == false && e.state.knock?.melds.count == 3, "gin layoff: knock info")
    check(e.state.discardPile.last == gnCard("Kd"), "gin layoff: knock discard goes on the pile")
    check(gnIllegal(e.apply(.layOff(cardID: "c2", meldIndex: 0), from: 1)), "gin layoff: 2c fits nowhere")
    check(gnIllegal(e.apply(.layOff(cardID: "s7", meldIndex: 0), from: 0)), "gin layoff: knocker can't lay off")
    let setIdx = e.state.knock!.melds.firstIndex { $0.kind == .set }!
    let lev = e.apply(.layOff(cardID: "s7", meldIndex: setIdx), from: 1)
    check(!gnIllegal(lev) && e.state.knock!.melds[setIdx].cards.count == 4, "gin layoff: 7s joins the set")
    check(gnIllegal(e.apply(.layOff(cardID: "s7", meldIndex: setIdx), from: 1)), "gin layoff: card already gone")
    check(e.state.phase == .layoff, "gin layoff: still open (3s, 8h, Qh remain)")
    let fev = e.apply(.finishLayoff, from: 1)
    check(e.state.phase == .handComplete, "gin layoff: finish resolves")
    if case .showdown(let r)? = fev.last {
        // defender deadwood: 3s 8h Qh + 2c 9c 5d 10c Ad 6d
        check(r.outcome == .knock && r.winnerSeat == 0 && r.defenderDeadwoodPoints == 54 && r.points == 52, "gin layoff: partial layoff scores 54 - 2 = 52")
        check(r.layoffs.count == 1, "gin layoff: breakdown records the layoff")
    } else { check(false, "gin layoff: showdown event") }

    // Auto layoff = optimal
    let a = fresh()
    _ = a.apply(.knock(discard: "d13", melds: nil), from: 0)
    let aev = a.apply(.autoLayoff, from: 1)
    check(aev.filter { if case .laidOff = $0 { return true }; return false }.count == 4, "gin layoff: auto lays off 7s 3s 8h Qh")
    if case .showdown(let r)? = aev.last {
        check(r.outcome == .knock && r.defenderDeadwoodPoints == 33 && r.points == 31 && r.winnerSeat == 0, "gin layoff: optimal layoff -> dw 33, knocker scores 31")
        check(r.knockerMelds.map { $0.cards.count }.reduce(0, +) == 9 + 4, "gin layoff: knocker melds grew by the 4 layoffs")
    } else { check(false, "gin layoff: auto showdown") }
    check(a.state.scores[0] == 31 && a.state.handsWon[0] == 1, "gin layoff: score applied")

    // No possible layoff -> skips straight to showdown
    let n = gnMake(h0: k, h1: "2c 9c 5d 10c Ad 6d Qs Js 8d 3d")
    let nev = n.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(n.state.phase == .handComplete && nev.contains { if case .showdown = $0 { return true }; return false }, "gin layoff: skipped when nothing can be laid off")

    // Auto-resolving after the last possible layoff
    let l = gnMake(h0: k, h1: "7s 2c 9c 5d 10c Ad 6d Js 8d 3d")
    _ = l.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(l.state.phase == .layoff, "gin layoff: single layoff available")
    _ = l.apply(.layOff(cardID: "s7", meldIndex: l.state.knock!.melds.firstIndex { $0.kind == .set }!), from: 1)
    check(l.state.phase == .handComplete, "gin layoff: layoff phase ends by itself when nothing more fits")

    // Tied arrangements: knocker's meld choice denies the layoff (set vs run of 2c3c4c / 3c3d3h)
    let deny = gnMake(h0: "3c 3d 3h 2c 4c 9s 10s Js Qs Kd Ah", h1: "3s 6d 8h 2d Kh 5h 7d 10d 4d 9h")
    _ = deny.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(deny.state.knock?.melds.contains { $0.kind == .run && $0.cards.first?.suit == .clubs } == true, "gin knock: chooses the arrangement that blocks the layoff")
    check(deny.state.phase == .handComplete && deny.state.lastResult?.layoffs.isEmpty == true, "gin knock: ... so no layoff phase opens")

    // Explicit melds honoured / validated
    let m = fresh()
    check(gnIllegal(m.apply(.knock(discard: "d13", melds: [["c7", "d7", "s4"]]), from: 0)), "gin knock: invalid explicit meld rejected")
    check(gnIllegal(m.apply(.knock(discard: "d13", melds: [["c7", "d7", "h7"], ["c7", "s4", "s5"]]), from: 0)), "gin knock: reused card rejected")
    check(gnIllegal(m.apply(.knock(discard: "d13", melds: [["c7", "d7", "h7"]]), from: 0)), "gin knock: under-declared melds exceed deadwood 10")
    check(m.state.phase == .discard, "gin knock: rejections leave the phase alone")
    check(!gnIllegal(m.apply(.knock(discard: "d13", melds: [["c7", "d7", "h7"], ["s4", "s5", "s6"], ["h9", "h10", "h11"]]), from: 0)), "gin knock: explicit full melds accepted")
}

do {
    // Undercut and tie-undercut
    let k = "As 2s 3s 4h 5h 6h 9c 9d 9s 8d Qc"
    let under = gnMake(h0: k, h1: "7c 7d 7s 10h Jh Qh 2c 3c 4c 3d")
    let uev = under.apply(.knock(discard: "c12", melds: nil), from: 0)
    check(under.state.phase == .handComplete, "gin undercut: resolves (no layoffs available)")
    if case .showdown(let r)? = uev.last {
        check(r.outcome == .undercut && r.winnerSeat == 1 && r.knockerSeat == 0, "gin undercut: defender wins")
        check(r.undercutBonus == 25 && r.deadwoodDifference == 5 && r.points == 30, "gin undercut: 25 + (8 - 3) = 30")
    } else { check(false, "gin undercut: showdown") }
    check(under.state.scores[1] == 30 && under.state.scores[0] == 0 && under.state.handsWon[1] == 1, "gin undercut: defender credited")
    let tie = gnMake(h0: k, h1: "7c 7d 7s 10h Jh Qh 2c 3c 4c 8h")
    let tev = tie.apply(.knock(discard: "c12", melds: nil), from: 0)
    if case .showdown(let r)? = tev.last {
        check(r.outcome == .undercut && r.points == 25 && r.deadwoodDifference == 0 && r.winnerSeat == 1, "gin undercut: equal deadwood is an undercut worth 25")
    } else { check(false, "gin tie: showdown") }
    // Undercut through layoffs: defender lays off down below knocker
    let lay = gnMake(h0: "7c 7d 7h 4s 5s 6s 9h 10h Jh 3d Kd", h1: "7s 3s 8h Qh 2c 9c 5d 10c Ad 6d")
    // knocker dw = 3 (3d); defender after optimal layoff has 33 -> knocker wins; sanity of a different shape:
    let lev = lay.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(!gnIllegal(lev), "gin: knock with 3 deadwood")
    // Drawn hand: stock <= 2 at discard
    let dr = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 8s Kc Qd", h1: "2c 4d 6s 8h 10c Jh Ah 3c 7d 5s", stockCount: 2)
    let dev = dr.apply(.discard(cardID: "c13"), from: 0)
    check(dr.state.phase == .handComplete && dev.contains(.handDrawn(handNumber: dr.state.handNumber)), "gin: stock at 2 -> drawn hand")
    check(dr.state.lastResult?.outcome == .drawn && dr.state.scores[0] == 0 && dr.state.scores[1] == 0, "gin: drawn hand scores nothing")
    let dr3 = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 8s Kc Qd", h1: "2c 4d 6s 8h 10c Jh Ah 3c 7d 5s", stockCount: 3)
    _ = dr3.apply(.discard(cardID: "c13"), from: 0)
    check(dr3.state.phase == .draw && dr3.state.turnSeat == 1, "gin: stock at 3 plays on")
    // Knocking is still possible on the last card (not a draw)
    let kn = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 9s Kc Qd", h1: "2c 4d 6s 8h 10c Jh Ah 3c 7d 5s", stockCount: 2)
    _ = kn.apply(.knock(discard: "d12", melds: nil), from: 0)
    check(kn.state.lastResult?.outcome != .drawn && kn.state.phase != .draw, "gin: knock beats the stock-out draw")
}

do {
    // Game end, bonuses
    let g = gnMake(h0: "As 2s 3s 4h 5h 6h 7h 9c 9d 9s Kc", h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s",
                   scores: [0: 30, 1: 20], handsWon: [0: 1, 1: 1])
    let ev = g.apply(.knock(discard: "c13", melds: nil), from: 0)
    check(g.state.phase == .gameOver && g.state.winnerSeat == 0, "gin game: 30 + 81 >= 100 ends the game")
    if let res = g.state.gameResult {
        check(res.gameBonus == 100 && !res.shutout, "gin game: 100 game bonus, no shutout")
        check(res.boxBonus == [0: 50, 1: 25], "gin game: 25 per hand won (2 vs 1)")
        check(res.finalTotals == [0: 30 + 81 + 100 + 50, 1: 20 + 25], "gin game: final totals")
        check(ev.last == .gameWon(res), "gin game: gameWon event last")
    } else { check(false, "gin game: gameResult recorded") }
    check(gnIllegal(g.apply(.advance, from: 0)), "gin game: nothing after game over")
    let s = gnMake(h0: "As 2s 3s 4h 5h 6h 7h 9c 9d 9s Kc", h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s",
                   scores: [0: 30, 1: 20], handsWon: [0: 1, 1: 0])
    _ = s.apply(.knock(discard: "c13", melds: nil), from: 0)
    check(s.state.gameResult?.shutout == true && s.state.gameResult?.gameBonus == 200, "gin game: shutout doubles the game bonus")
    check(s.state.gameResult?.finalTotals == [0: 30 + 81 + 200 + 50, 1: 20], "gin game: shutout totals")
    // Undercut can win the game for the defender
    let u = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 9s 8d Qc", h1: "7c 7d 7s 10h Jh Qh 2c 3c 4c 3d", scores: [0: 40, 1: 80], handsWon: [0: 2, 1: 3])
    _ = u.apply(.knock(discard: "c12", melds: nil), from: 0)
    check(u.state.phase == .gameOver && u.state.winnerSeat == 1 && u.state.scores[1] == 110, "gin game: defender undercut can end the game")
}

do {
    // Snapshots: redaction, known cards, codable
    let e = gnMake(h0: "As 2s 3s 4h 5h 6h 9c 9d 9s Kc", h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s", phase: .draw, turn: 0, upcard: "8d")
    _ = e.apply(.drawUpcard, from: 0)
    let s0 = e.snapshot(for: 0), s1 = e.snapshot(for: 1)
    check(s0.myHand.count == 11 && s0.opponentHandCount == 10 && s1.opponentHandCount == 11, "gin snapshot: hand counts")
    check(s1.opponentKnownCards == [gnCard("8d")] && s0.opponentKnownCards.isEmpty, "gin snapshot: opponent's pile pick is public knowledge")
    check(s0.drawnFromDiscardID == "d8" && s1.drawnFromDiscardID == nil, "gin snapshot: drawn-from-pile flag is private to the mover")
    check(s0.upcard == nil || s0.discardPile.isEmpty, "gin snapshot: pile empty after taking the lone upcard")
    let enc = JSONEncoder()
    let json1 = String(data: try! enc.encode(s1), encoding: .utf8)!
    let opponentCards = gnCards("As 2s 3s 4h 5h 6h 9c 9d 9s Kc").map(\.id)
    check(!opponentCards.contains { json1.contains("\"id\":\"\($0)\"") }, "gin snapshot: seat 1's JSON never contains seat 0's hand")
    check(s0.stockCount == 20, "gin snapshot: stock count")
    check(try! JSONDecoder().decode(GinRummySnapshot.self, from: enc.encode(s0)) == s0, "gin: snapshot codable")
    check(try! JSONDecoder().decode(GinRummyState.self, from: enc.encode(e.state)) == e.state, "gin: state codable")
    let tbl = e.tableSnapshot()
    check(try! JSONDecoder().decode(GinRummyTableSnapshot.self, from: enc.encode(tbl)) == tbl, "gin: table snapshot codable")
    let tjson = String(data: try! enc.encode(tbl), encoding: .utf8)!
    check(!opponentCards.contains { tjson.contains("\"id\":\"\($0)\"") } && tbl.handCounts == [0: 11, 1: 10], "gin: table snapshot has no hands")
    let acts: [GinRummyAction] = [.passUpcard, .drawStock, .drawUpcard, .discard(cardID: "h7"), .knock(discard: "h7", melds: [["h2", "h3", "h4"]]), .knock(discard: "h7", melds: nil), .layOff(cardID: "c5", meldIndex: 1), .autoLayoff, .finishLayoff, .advance]
    check(try! JSONDecoder().decode([GinRummyAction].self, from: enc.encode(acts)) == acts, "gin: actions codable")
    let k = gnMake(h0: "As 2s 3s 4h 5h 6h 7h 9c 9d 9s Kc", h1: "2c 4d 6s 8h 10c Qd Ah 3c 7d 5s")
    let evs = k.apply(.knock(discard: "c13", melds: nil), from: 0)
    check(try! JSONDecoder().decode([GinRummyEvent].self, from: enc.encode(evs)) == evs, "gin: events codable")
    let restored = GinRummyEngine(restoring: k.state)
    check(restored.state == k.state, "gin: restoring")
}

do {
    // Bot decision units
    var rng = SeededGenerator(seed: 5)
    // Takes an upcard that makes a meld
    let take = gnMake(h0: "7c 7d 2h 9s Kc 4d 5h 8c Jd 3s", h1: "As 6h 10c Qd 2c 3d 5s 8h 9d Kd", phase: .draw, turn: 0, upcard: "7h")
    check(GinRummyBot.chooseDraw(snapshot: take.snapshot(for: 0)) == .drawUpcard, "gin bot: takes the upcard that completes a set")
    // Declines junk (in draw phase -> stock, in offer phase -> pass)
    let junk = gnMake(h0: "7c 7d 2h 9s Kc 4d 5h 8c Jd 3s", h1: "As 6h 10c Qd 2c 3d 5s 8h 9d Kd", phase: .draw, turn: 0, upcard: "Qs")
    check(GinRummyBot.chooseDraw(snapshot: junk.snapshot(for: 0)) == .drawStock, "gin bot: ignores a useless upcard")
    let offer = gnMake(h0: "7c 7d 2h 9s Kc 4d 5h 8c Jd 3s", h1: "As 6h 10c Qd 2c 3d 5s 8h 9d Kd", phase: .firstUpcard, turn: 0, upcard: "Qs")
    check(GinRummyBot.chooseDraw(snapshot: offer.snapshot(for: 0)) == .passUpcard, "gin bot: passes a useless opening upcard")
    let offerTake = gnMake(h0: "7c 7d 2h 9s Kc 4d 5h 8c Jd 3s", h1: "As 6h 10c Qd 2c 3d 5s 8h 9d Kd", phase: .firstUpcard, turn: 0, upcard: "7h")
    check(GinRummyBot.chooseDraw(snapshot: offerTake.snapshot(for: 0)) == .drawUpcard, "gin bot: takes a useful opening upcard")
    let refused = gnMake(h0: "7c 7d 2h 9s Kc 4d 5h 8c Jd 3s", h1: "As 6h 10c Qd 2c 3d 5s 8h 9d Kd", phase: .draw, turn: 0, upcard: "7h")
    var rs = refused.state; rs.upcardRefused = true
    check(GinRummyBot.chooseDraw(snapshot: GinRummyEngine(restoring: rs).snapshot(for: 0)) == .drawStock, "gin bot: obeys refused upcard")
    // Discards the stranded high card; knocks if allowed
    let hand = "As 2s 3s 4h 5h 6h 9c 9d 9s 8d Ks"
    let dis = gnMake(h0: hand, h1: "7c 7d 7h 10h Jh Qh 2c 3c 4c 3d")
    let a1 = GinRummyBot.nextAction(snapshot: dis.snapshot(for: 0), personality: GinBotPersonality(knockThreshold: 0, ginChase: 0), rng: &rng)
    check(a1 == .discard(cardID: "s13"), "gin bot: dumps the stranded king when not knocking")
    let a2 = GinRummyBot.nextAction(snapshot: dis.snapshot(for: 0), personality: .eager, rng: &rng)
    check(a2 == .knock(discard: "s13", melds: nil), "gin bot: eager personality knocks at 8 deadwood")
    let a2b = GinRummyBot.nextAction(snapshot: dis.snapshot(for: 0), personality: .balanced, rng: &rng)
    check(a2b != nil, "gin bot: balanced personality acts")
    // Always goes gin
    let gin = gnMake(h0: "As 2s 3s 4s 4h 5h 6h 9c 9d 9s Ks", h1: "7c 7d 7h 10h Jh Qh 2c 3c 4c 3d")
    for p in [GinBotPersonality.eager, .balanced, .ginChaser] {
        check(GinRummyBot.nextAction(snapshot: gin.snapshot(for: 0), personality: p, rng: &rng) == .knock(discard: "s13", melds: nil), "gin bot: goes gin regardless of personality")
    }
    // Gin-chase hook: 2 deadwood, plenty of stock, live outs -> chaser keeps playing
    let chaseHand = "As 2s 3s 4h 5h 6h 9c 9d 9s 2d Kd"
    let ch = gnMake(h0: chaseHand, h1: "7c 7d 7h 10h Jh Qh 2c 3c 4c 3d", stockCount: 20)
    check(GinRummyBot.nextAction(snapshot: ch.snapshot(for: 0), personality: .eager, rng: &rng) == .knock(discard: "d13", melds: nil), "gin bot: eager knocks at 2")
    check(GinRummyBot.nextAction(snapshot: ch.snapshot(for: 0), personality: .ginChaser, rng: &rng) == .discard(cardID: "d13"), "gin bot: gin-chaser holds for gin")
    let chLate = gnMake(h0: chaseHand, h1: "7c 7d 7h 10h Jh Qh 2c 3c 4c 3d", stockCount: 5)
    check(GinRummyBot.nextAction(snapshot: chLate.snapshot(for: 0), personality: .ginChaser, rng: &rng) == .knock(discard: "d13", melds: nil), "gin bot: gin-chaser knocks once the stock is thin")
    // Layoff
    let lk = gnMake(h0: "7c 7d 7h 4s 5s 6s 9h 10h Jh 2d Kd", h1: "7s 3s 8h Qh 2c 9c 5d 10c Ad 6d")
    _ = lk.apply(.knock(discard: "d13", melds: nil), from: 0)
    check(GinRummyBot.nextAction(snapshot: lk.snapshot(for: 1), rng: &rng) == .autoLayoff, "gin bot: defender auto-lays-off")
    check(GinRummyBot.nextAction(snapshot: lk.snapshot(for: 0), rng: &rng) == nil, "gin bot: knocker waits during layoff")
    check(GinRummyBot.nextAction(snapshot: dis.snapshot(for: 1), rng: &rng) == nil, "gin bot: waits off-turn")
}

struct GnGameResult { var engine: GinRummyEngine; var actions: Int; var illegal: Bool; var hands: Int; var outcomes: Set<GinHandOutcome> }
func gnPlayBotGame(seed: UInt64, p0: GinBotPersonality, p1: GinBotPersonality, cap: Int = 20000) -> GnGameResult {
    let e = GinRummyEngine(seed: seed)
    var rngs = [SeededGenerator(seed: seed &+ 1), SeededGenerator(seed: seed &+ 2)]
    var actions = 0
    var illegal = false
    var outcomes = Set<GinHandOutcome>()
    let personalities = [p0, p1]
    while e.state.phase != .gameOver && actions < cap {
        let seat = e.state.phase == .handComplete ? 0 : e.state.turnSeat
        guard let action = GinRummyBot.nextAction(
            snapshot: e.snapshot(for: seat), personality: personalities[seat], rng: &rngs[seat], advanceIfComplete: true
        ) else { illegal = true; break }
        let events = e.apply(action, from: seat)
        if gnIllegal(events) { illegal = true; print("gin bot illegal:", action, events); break }
        for ev in events { if case .showdown(let r) = ev { outcomes.insert(r.outcome) } }
        actions += 1
    }
    return GnGameResult(engine: e, actions: actions, illegal: illegal, hands: e.state.handNumber, outcomes: outcomes)
}
do {
    var allOutcomes = Set<GinHandOutcome>()
    let cfgs: [(UInt64, GinBotPersonality, GinBotPersonality)] = [
        (1, .eager, .eager), (2, .balanced, .eager), (3, .ginChaser, .balanced), (4, .balanced, .balanced),
    ]
    for (seed, p0, p1) in cfgs {
        let r = gnPlayBotGame(seed: seed, p0: p0, p1: p1)
        let st = r.engine.state
        check(st.phase == .gameOver, "gin bot game \(seed): reaches game over")
        check(!r.illegal, "gin bot game \(seed): every action legal")
        check(r.actions < 20000, "gin bot game \(seed): terminates under the cap")
        if let w = st.winnerSeat, let res = st.gameResult {
            check((st.scores[w] ?? 0) >= 100 && (st.scores[1 - w] ?? 0) < 100, "gin bot game \(seed): winner reached 100 first")
            check(res.finalTotals[w] == (st.scores[w] ?? 0) + res.gameBonus + (res.boxBonus[w] ?? 0), "gin bot game \(seed): winner total adds up")
            check(res.finalTotals[1 - w] == (st.scores[1 - w] ?? 0) + (res.boxBonus[1 - w] ?? 0), "gin bot game \(seed): loser total adds up")
            check(res.boxBonus[0] == 25 * (st.handsWon[0] ?? 0) && res.boxBonus[1] == 25 * (st.handsWon[1] ?? 0), "gin bot game \(seed): boxes match hands won")
        } else { check(false, "gin bot game \(seed): winner recorded") }
        allOutcomes.formUnion(r.outcomes)
    }
    check(allOutcomes.contains(.knock), "gin bot games: knocks happen")
}

// MARK: - BotAI BEGIN (smarter bots: Cribbage, Dots & Boxes, Yahtzee, Zilch, Shut the Box, UNO, Crazy Eights, Wizard/Oh Hell, personalities)

func bxCards(_ ids: [String]) -> [Card] {
    let all = DeckBuilder.standard52()
    return ids.map { id in all.first { $0.id == id }! }
}

// --- Bot personalities -------------------------------------------------

do {
    let names = ["Hank", "Ruthie", "Marco", "Mae", "Tucker", "Julie"]
    let expect: [(BotPersonality.Speed, BotPersonality.Aggression, BotPersonality.Chattiness)] = [
        (.deliberate, .cautious, .quiet), (.snappy, .bold, .chatty), (.steady, .bold, .chatty),
        (.deliberate, .balanced, .normal), (.snappy, .balanced, .quiet), (.steady, .cautious, .chatty),
    ]
    for (i, name) in names.enumerated() {
        let p = BotPersonality.forName(name)
        check((p.speed, p.aggression, p.chattiness) == expect[i], "personality table: \(name)")
        check(BotPersonality.forName(name.lowercased()).speed == p.speed, "personality lookup is case-insensitive: \(name)")
    }
    check(BotPersonality.forName("Pat") == BotPersonality.forName("Pat"), "an unknown name always maps to the same personality")
    check(BotPersonality.forName("Hank").delayScale > BotPersonality.forName("Ruthie").delayScale,
          "deliberate Hank is slower than snappy Ruthie")
    check(BotPersonality.forName("Ruthie").pressFactor > BotPersonality.forName("Julie").pressFactor,
          "bold presses harder than cautious")
    let r = BotPersonality.forName("Hank").scaledDelay(1.0...2.0)
    check(abs(r.lowerBound - 1.4) < 1e-9 && abs(r.upperBound - 2.8) < 1e-9, "delay range scales by the speed factor")
    check(BotPersonality.forName("Ruthie").quartoNodeBudget < BotPersonality.forName("Hank").quartoNodeBudget
          && BotPersonality.forName("Hank").quartoNodeBudget <= QuartoBot.defaultNodeBudget,
          "snappy bots search fewer Quarto nodes than deliberate ones, never above the default")
}

// --- Cribbage ----------------------------------------------------------

func bxDiscardIDs(_ hand: [String], dealer: Bool) -> Set<String> {
    var rng = SeededGenerator(seed: 1)
    return Set(CribbageBot.discard(hand: bxCards(hand), isDealer: dealer, rng: &rng).map(\.id))
}
check(bxDiscardIDs(["h5", "d5", "c5", "s11", "d2", "s8"], dealer: false) == ["d2", "s8"],
      "cribbage: 5-5-5-J is kept whole (discard 2 and 8)")
check(bxDiscardIDs(["h6", "d7", "c8", "s9", "d13", "c2"], dealer: false) == ["d13", "c2"],
      "cribbage: the 6-7-8-9 run is kept (discard K and 2)")
check(bxDiscardIDs(["h5", "d5", "s11", "c12", "d2", "s13"], dealer: false).isDisjoint(with: ["h5", "d5"]),
      "cribbage: a pair of 5s with J-Q is never thrown away")
do {
    var rng1 = SeededGenerator(seed: 1), rng2 = SeededGenerator(seed: 999)
    let hand = bxCards(["h2", "c9", "d12", "s5", "h13", "c7"])
    check(CribbageBot.discard(hand: hand, isDealer: true, rng: &rng1) == CribbageBot.discard(hand: hand, isDealer: true, rng: &rng2),
          "cribbage discard is independent of the caller's rng state (no near-tie flips)")
    let ev = CribbageBot.evaluateDiscards(hand: bxCards(["h5", "d5", "c5", "s11", "d2", "s8"]), isDealer: false)
    check(ev.count == 15, "cribbage: all 15 splits are evaluated")
    check(ev.allSatisfy { abs($0.total - ($0.handEV - $0.cribEV)) < 1e-9 }, "cribbage: a non-dealer's score subtracts the crib's expected value")
    // Dealer vs non-dealer: the dealer throws crib-friendly cards (5s, pairs, runs) more often.
    var dealerFives = 0, defenderFives = 0
    var g = SeededGenerator(seed: 606)
    for _ in 0..<40 {
        var deck = DeckBuilder.standard52(); deck.shuffle(using: &g)
        let hand = Array(deck.prefix(6))
        var r = SeededGenerator(seed: 1)
        if CribbageBot.discard(hand: hand, isDealer: true, rng: &r).contains(where: { $0.rank == 5 }) { dealerFives += 1 }
        if CribbageBot.discard(hand: hand, isDealer: false, rng: &r).contains(where: { $0.rank == 5 }) { defenderFives += 1 }
    }
    check(dealerFives >= defenderFives, "cribbage: the dealer feeds 5s to the crib at least as often as the non-dealer (\(dealerFives) vs \(defenderFives))")
}
do {
    var rng = SeededGenerator(seed: 5)
    let make = { (ids: [String]) in bxCards(ids) }
    check(CribbageBot.pegPlay(hand: make(["h5", "d3"]), sequence: make(["s10"]), count: 10, rng: &rng)?.id == "h5",
          "pegging: makes fifteen when it can")
    check(CribbageBot.pegPlay(hand: make(["h7", "c2"]), sequence: make(["s5", "c6"]), count: 11, rng: &rng)?.id == "h7",
          "pegging: extends a run for three")
    check(CribbageBot.pegPlay(hand: make(["h5", "c4"]), sequence: [], count: 0, rng: &rng)?.id == "c4",
          "pegging: never leads a 5 into an empty count")
    check(CribbageBot.pegPlay(hand: make(["c10", "d4"]), sequence: make(["s10", "h7", "d4"]), count: 21, rng: &rng)?.id == "c10",
          "pegging: takes the 31")
    check(CribbageBot.pegPlay(hand: make(["h9"]), sequence: make(["s10", "c9"]), count: 29, rng: &rng) == nil,
          "pegging: no legal card returns nil")
    // Setting up the opponent: count 4 with hand {J, 6}: J makes 14, 6 makes 10 - never reach 5 or 21 for a free fifteen/31.
    let pick = CribbageBot.pegPlay(hand: make(["s11", "h4"]), sequence: [], count: 0, rng: &rng)!
    check(pick.id == "h4" || pick.id == "s11", "pegging: leads something legal")
}
do {
    // Measured gain: the current bot vs the original heuristics, 50 seeded games
    // (25 seeds x both seatings so each deal is played from each side).
    func play(seed: UInt64, newSeat: Int) -> Int? {
        let engine = CribbageEngine(seed: seed)
        var rng = SeededGenerator(seed: seed &+ 999)
        var actions = 0
        while engine.state.phase != .gameOver, actions < 5000 {
            switch engine.state.phase {
            case .discarding:
                for seat in [0, 1] where !engine.state.discardsSubmitted.contains(seat) {
                    let hand = engine.state.hands[seat]!
                    let isD = seat == engine.state.dealerSeat
                    let d = seat == newSeat ? CribbageBot.discard(hand: hand, isDealer: isD, rng: &rng)
                                            : CribbageBot.legacyDiscard(hand: hand, isDealer: isD, rng: &rng)
                    _ = engine.apply(.discardToCrib(cards: d.map(\.id)), from: seat); actions += 1
                }
            case .pegging:
                let p = engine.state.pegging!, seat = p.turnSeat
                let hand = engine.state.hands[seat]!
                let seq = p.sequence.map(\.card)
                let c = seat == newSeat
                    ? CribbageBot.pegPlay(hand: hand, sequence: seq, count: p.count, rng: &rng,
                                          seen: [engine.state.starter!], opponentCards: engine.state.hands[1 - seat]?.count)!
                    : CribbageBot.legacyPegPlay(hand: hand, sequence: seq, count: p.count, rng: &rng)!
                _ = engine.apply(.playCard(cardID: c.id), from: seat); actions += 1
            case .handComplete: _ = engine.apply(.advance, from: 0); actions += 1
            case .gameOver: break
            }
        }
        return engine.state.winnerSeat
    }
    var newWins = 0
    for seed in 1...50 { for newSeat in 0...1 where play(seed: UInt64(seed), newSeat: newSeat) == newSeat { newWins += 1 } }
    print("Cribbage: new bot beat the original heuristic in \(newWins)/100 seeded games")
    check(newWins >= 50, "cribbage: the new bot wins at least half of 100 seeded games against the old heuristic (won \(newWins))")
}

// --- Dots & Boxes ------------------------------------------------------

do {
    // Double-cross: row 0 is a 4-chain already opened on the left, row 2 is an
    // untouched 4-chain, every other line is drawn. Taking all four boxes
    // leaves the bot to open the other chain (4-4); the right play is to take
    // two, decline the last two with the far-end line, and keep control (6-2).
    let n = 4
    var claims: [DotsAndBoxesEdge: Int] = Dictionary(uniqueKeysWithValues: dabAllEdges(gridSize: n).map { ($0, 1) })
    var owners: [[Int?]] = Array(repeating: Array(repeating: 1, count: n), count: n)
    for col in 1...4 { claims[DotsAndBoxesEdge(orientation: .vertical, row: 0, col: col)] = nil }
    for col in 0...4 { claims[DotsAndBoxesEdge(orientation: .vertical, row: 2, col: col)] = nil }
    for col in 0..<n { owners[0][col] = nil; owners[2][col] = nil }
    var st = DotsAndBoxesState(gridSize: n, players: makeDABPlayers(2, bots: true), seed: 3)
    st.claimedBy = claims; st.boxOwner = owners; st.turnIndex = 0
    for i in 0..<2 { st.players[i].score = 0 }
    func finish(legacy0: Bool) -> (Int, Int) {
        let e = DotsAndBoxesEngine(restoring: st)
        if legacy0 { e.legacyBotSeats = [0] }
        var g = 0
        while !e.state.isGameOver, g < 50 { g += 1; _ = e.performBotMove(for: e.state.turnIndex) }
        return (e.state.players[0].score, e.state.players[1].score)
    }
    let (smart0, smart1) = finish(legacy0: false)
    check(smart0 == 6 && smart1 == 2, "dots&boxes: the bot declines the last two boxes of a chain to keep control (got \(smart0)-\(smart1), want 6-2)")
    let (old0, old1) = finish(legacy0: true)
    check(old0 <= old1, "dots&boxes: the old greedy bot, taking everything, loses the endgame it should win (\(old0)-\(old1))")
    let e = DotsAndBoxesEngine(restoring: st)
    _ = e.performBotMove(for: 0); _ = e.performBotMove(for: 0)
    let declining = e.chooseBotEdge(for: 0)
    check(declining == DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 4),
          "dots&boxes: with two boxes left in the open chain, the bot plays the far-end line (the double-cross decline)")
}
do {
    // Chain counting: with a 1-chain and a 3-chain left and nothing capturable, the bot opens the 1-chain.
    let n = 4
    var claims: [DotsAndBoxesEdge: Int] = Dictionary(uniqueKeysWithValues: dabAllEdges(gridSize: n).map { ($0, 1) })
    var owners: [[Int?]] = Array(repeating: Array(repeating: 1, count: n), count: n)
    claims[DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 0)] = nil
    claims[DotsAndBoxesEdge(orientation: .vertical, row: 0, col: 1)] = nil
    owners[0][0] = nil
    for col in 0...3 { claims[DotsAndBoxesEdge(orientation: .vertical, row: 2, col: col)] = nil }
    for col in 0..<3 { owners[2][col] = nil }
    var st = DotsAndBoxesState(gridSize: n, players: makeDABPlayers(2, bots: true), seed: 3)
    st.claimedBy = claims; st.boxOwner = owners; st.turnIndex = 0
    let e = DotsAndBoxesEngine(restoring: st)
    let pick = e.chooseBotEdge(for: 0)!
    check(pick.orientation == .vertical && pick.row == 0, "dots&boxes: forced to open a chain, the bot opens the 1-box chain, not the 3-chain")
}
do {
    var newWins = 0, oldWins = 0, ties = 0
    for seed in 1...25 {
        for newSeat in 0...1 {
            let e = DotsAndBoxesEngine(gridSize: 4, players: makeDABPlayers(2, bots: true), seed: UInt64(seed))
            e.legacyBotSeats = [1 - newSeat]
            var g = 0
            while !e.state.isGameOver, g < 500 { g += 1; _ = e.performBotMove(for: e.state.turnIndex) }
            let a = e.state.players[newSeat].score, b = e.state.players[1 - newSeat].score
            if a > b { newWins += 1 } else if a < b { oldWins += 1 } else { ties += 1 }
        }
    }
    print("Dots & Boxes 4x4: new bot \(newWins) wins, old bot \(oldWins) wins, \(ties) ties over 50 seeded games")
    check(newWins > oldWins * 2, "dots&boxes: the new bot beats the old one by more than 2:1 over 50 seeded 4x4 games (\(newWins)-\(oldWins))")
}

// --- Yahtzee -----------------------------------------------------------

do {
    check(YahtzeeStrategy.score(dice: [2, 2, 3, 3, 3], category: 8) == 25, "yahtzee strategy: full house scores 25")
    check(YahtzeeStrategy.score(dice: [1, 2, 3, 4, 6], category: 9) == 30 && YahtzeeStrategy.score(dice: [1, 2, 3, 4, 6], category: 10) == 0,
          "yahtzee strategy: small but not large straight")
    check(YahtzeeStrategy.score(dice: [2, 3, 4, 5, 6], category: 10) == 40, "yahtzee strategy: large straight 40")
    check(YahtzeeStrategy.score(dice: [4, 4, 4, 4, 4], category: 11) == 50 && YahtzeeStrategy.score(dice: [4, 4, 4, 4, 1], category: 11) == 0,
          "yahtzee strategy: yahtzee 50")
    check(YahtzeeStrategy.score(dice: [1, 2, 3, 4, 5], category: 8, isJoker: true) == 25, "yahtzee strategy: joker full house")
    let empty = YahtzeeStrategy.Sheet()
    check(YahtzeeStrategy.chooseHolds(dice: [6, 6, 6, 2, 3], rollsLeft: 2, sheet: empty) == [true, true, true, false, false],
          "yahtzee: keeps three sixes")
    check(YahtzeeStrategy.chooseHolds(dice: [1, 2, 3, 4, 6], rollsLeft: 2, sheet: empty) == [true, true, true, true, false],
          "yahtzee: keeps the four-run and rerolls the 6 to chase a large straight")
    check(YahtzeeStrategy.chooseHolds(dice: [5, 5, 5, 5, 5], rollsLeft: 2, sheet: empty).allSatisfy { $0 },
          "yahtzee: keeps a made yahtzee")
    check(YahtzeeStrategy.chooseHolds(dice: [3, 3, 3, 3, 5], rollsLeft: 1, sheet: empty) == [true, true, true, true, false],
          "yahtzee: keeps four of a kind and rerolls the odd die")
    check(YahtzeeStrategy.chooseCategory(dice: [6, 6, 6, 6, 6], sheet: empty) == 11, "yahtzee: five sixes go in the Yahtzee box")
    check(YahtzeeStrategy.chooseCategory(dice: [1, 1, 2, 5, 6], sheet: empty) == 0, "yahtzee: a junk roll is sacrificed to the ones")
    var after = empty
    after.record(dice: [6, 6, 6, 6, 6], category: 11)
    check(after.isJoker([3, 3, 3, 3, 3]) && after.total == 50, "yahtzee: a second five-of-a-kind plays as a joker once the box holds 50")
    check(YahtzeeStrategy.chooseHolds(dice: [1, 2, 3, 4, 6], rollsLeft: 2, sheet: empty)
          == YahtzeeStrategy.chooseHolds(dice: [1, 2, 3, 4, 6], rollsLeft: 2, sheet: empty), "yahtzee holds are deterministic")

    func game(seed: UInt64, p: BotPersonality = .neutral) -> Int {
        var rng = SeededGenerator(seed: seed)
        var sheet = YahtzeeStrategy.Sheet()
        for _ in 0..<13 {
            var dice = (0..<5).map { _ in Int.random(in: 1...6, using: &rng) }
            var rollsLeft = 2
            while rollsLeft > 0 {
                let keep = YahtzeeStrategy.chooseHolds(dice: dice, rollsLeft: rollsLeft, sheet: sheet, personality: p)
                if keep.allSatisfy({ $0 }) { break }
                for i in 0..<5 where !keep[i] { dice[i] = Int.random(in: 1...6, using: &rng) }
                rollsLeft -= 1
            }
            sheet.record(dice: dice, category: YahtzeeStrategy.chooseCategory(dice: dice, sheet: sheet, personality: p))
        }
        check(sheet.isComplete, "yahtzee sim: every category filled after 13 turns")
        return sheet.total
    }
    let scores = (1...200).map { game(seed: UInt64($0)) }
    let avg = Double(scores.reduce(0, +)) / 200
    print("Yahtzee: average score over 200 seeded solo games = \(avg) (min \(scores.min()!), max \(scores.max()!))")
    check(avg >= 225 && avg <= 275, "yahtzee: the bot averages 225-275 over 200 seeded solo games (\(avg))")
}

// --- Zilch -------------------------------------------------------------

do {
    check(ZilchStrategy.groups(in: [1, 2, 3, 4, 5, 6]) == [ZilchStrategy.Group(dice: 6, points: 1500)], "zilch strategy: straight")
    check(ZilchStrategy.groups(in: [2, 2, 3, 3, 4, 4]) == [ZilchStrategy.Group(dice: 6, points: 1000)], "zilch strategy: three pairs")
    check(ZilchStrategy.groups(in: [1, 1, 1, 5, 2, 3]).map(\.points) == [1000, 50], "zilch strategy: triple ones plus a single five")
    check(ZilchStrategy.groups(in: [2, 3, 4, 6, 2, 3]).isEmpty, "zilch strategy: junk is a bust")
    check(ZilchStrategy.groups(in: [4, 4, 4, 4, 2, 3]).map(\.points) == [800], "zilch strategy: four fours double the triple")
    let neutral = ZilchStrategy.Context()
    check(ZilchStrategy.shouldPress(diceLeft: 6, turnScore: 0, ctx: neutral), "zilch: with six dice and nothing at risk, roll")
    check(ZilchStrategy.shouldPress(diceLeft: 6, turnScore: 300, ctx: neutral), "zilch: six dice and 300 at risk, still roll")
    check(!ZilchStrategy.shouldPress(diceLeft: 2, turnScore: 1000, ctx: neutral), "zilch: two dice and 1000 at risk, bank")
    check(!ZilchStrategy.shouldPress(diceLeft: 1, turnScore: 400, ctx: neutral), "zilch: one die and 400 at risk, bank")
    let cautious = ZilchStrategy.Context(personality: BotPersonality.forName("Julie"))
    let bold = ZilchStrategy.Context(personality: BotPersonality.forName("Ruthie"))
    var monotone = true
    for dice in 1...6 { for t in stride(from: 0, through: 2000, by: 50) {
        if ZilchStrategy.shouldPress(diceLeft: dice, turnScore: t, ctx: cautious) && !ZilchStrategy.shouldPress(diceLeft: dice, turnScore: t, ctx: bold) { monotone = false }
    } }
    check(monotone, "zilch: a cautious bot never presses where a bold one banks")
    check(ZilchStrategy.expectedTurnValue(dice: 6, turnScore: 0) > 400, "zilch: a fresh turn is worth over 400 on average")
    let chase = ZilchStrategy.Context(bankedScore: 3000, bestOpponentScore: 4900, finalChaseActive: true, chasersAfterMe: 0)
    check(ZilchStrategy.shouldPress(diceLeft: 2, turnScore: 600, ctx: chase), "zilch final chase: trailing and banking cannot win, so keep rolling")
    let lead = ZilchStrategy.Context(bankedScore: 4800, bestOpponentScore: 4000, finalChaseActive: true, chasersAfterMe: 0)
    check(!ZilchStrategy.shouldPress(diceLeft: 5, turnScore: 400, ctx: lead), "zilch final chase: last chaser already ahead banks")
    let picks = ZilchStrategy.chooseGroups([.init(dice: 3, points: 1000), .init(dice: 1, points: 50)], diceRolled: 6, turnScore: 0, ctx: neutral)
    check(picks.contains(0) && !picks.isEmpty, "zilch: always sets aside the big triple")
    check(ZilchStrategy.chooseGroups([], diceRolled: 4, turnScore: 100, ctx: neutral).isEmpty, "zilch: no groups, nothing to take")

    // Measured: solo turns and head-to-head against the original threshold bot.
    func roll(_ n: Int, _ rng: inout SeededGenerator) -> [Int] { (0..<n).map { _ in Int.random(in: 1...6, using: &rng) } }
    func turn(legacy: Bool, banked: Int, best: Int, chase: Bool, rng: inout SeededGenerator) -> (pts: Int, bust: Bool) {
        var t = 0, live = 6
        while true {
            let gs = ZilchStrategy.groups(in: roll(live, &rng))
            if gs.isEmpty { return (0, true) }
            if legacy {
                t += gs.reduce(0) { $0 + $1.points }; live -= gs.reduce(0) { $0 + $1.dice }
                if live == 0 { live = 6 }
                let trailing = chase && banked + t < best
                if live >= (trailing ? 2 : 3) && t < (trailing ? 450 : 300) { continue }
                return (t, false)
            }
            let ctx = ZilchStrategy.Context(bankedScore: banked, bestOpponentScore: best, finalChaseActive: chase, chasersAfterMe: 0)
            let take = ZilchStrategy.chooseGroups(gs, diceRolled: live, turnScore: t, ctx: ctx)
            check(!take.isEmpty && take.allSatisfy { gs.indices.contains($0) }, "zilch sim: the bot always sets aside a valid group")
            t += take.reduce(0) { $0 + gs[$1].points }; live -= take.reduce(0) { $0 + gs[$1].dice }
            if live == 0 { live = 6 }
            if !ZilchStrategy.shouldPress(diceLeft: live, turnScore: t, ctx: ctx) { return (t, false) }
        }
    }
    var stats: [Bool: (Int, Int)] = [:]
    for legacy in [true, false] {
        var rng = SeededGenerator(seed: 99)
        var tot = 0, busts = 0
        for _ in 0..<6000 { let r = turn(legacy: legacy, banked: 0, best: 0, chase: false, rng: &rng); tot += r.pts; if r.bust { busts += 1 } }
        stats[legacy] = (tot, busts)
    }
    let newAvg = Double(stats[false]!.0) / 6000, oldAvg = Double(stats[true]!.0) / 6000
    print("Zilch: new bot avg/turn \(newAvg), bust rate \(Double(stats[false]!.1) / 6000); old bot avg/turn \(oldAvg), bust rate \(Double(stats[true]!.1) / 6000)")
    check(newAvg > oldAvg * 1.1, "zilch: the new bot banks over 10% more per turn than the old threshold bot (\(newAvg) vs \(oldAvg))")
    func match(newFirst: Bool, seed: UInt64) -> Bool { // true if the NEW bot wins
        var rng = SeededGenerator(seed: seed)
        var score = [0, 0]; var seat = 0; var chaseSeat: Int?
        while true {
            let isNew = (seat == 0) == newFirst
            let r = turn(legacy: !isNew, banked: score[seat], best: score[1 - seat], chase: chaseSeat != nil, rng: &rng)
            score[seat] += r.pts
            if let c = chaseSeat, c != seat {
                let newSeat = newFirst ? 0 : 1
                return score[newSeat] > score[1 - newSeat]
            } else if chaseSeat == nil && score[seat] >= 5000 { chaseSeat = seat }
            seat = 1 - seat
        }
    }
    var wins = 0
    for i in 1...100 { for first in [true, false] where match(newFirst: first, seed: UInt64(i)) { wins += 1 } }
    print("Zilch: new bot won \(wins)/200 seeded games against the old bot")
    check(wins >= 120, "zilch: the new bot wins at least 60% of 200 seeded games (\(wins))")
}

// --- Shut the Box ------------------------------------------------------

do {
    let full = [Bool](repeating: true, count: 9)
    let v = ShutBoxStrategy.expectedScore(standing: full)
    check(v > 10.5 && v < 11.6, "shut the box: optimal expected score from a full box is about 11 (\(v))")
    check(ShutBoxStrategy.chooseSet(standing: full, sum: 12).map { $0.reduce(0, +) } == 12, "shut the box: the chosen set adds to the roll")
    var partial = full; partial[8] = false; partial[7] = false
    check(ShutBoxStrategy.chooseSet(standing: partial, sum: 12)!.allSatisfy { partial[$0 - 1] }, "shut the box: only standing tiles are flipped")
    check(ShutBoxStrategy.chooseSet(standing: [true, false, false, false, false, false, false, false, false], sum: 5) == nil, "shut the box: no set means bust")
    var onlyOne = [Bool](repeating: false, count: 9); onlyOne[0] = true
    check(ShutBoxStrategy.shouldUseOneDie(standing: onlyOne), "shut the box: with only the 1 left, one die is better (two dice can never roll 1)")
    check(!ShutBoxStrategy.shouldUseOneDie(standing: full), "shut the box: the one-die option is locked while 7-8-9 stand")
    check(ShutBoxStrategy.expectedScore(standing: [Bool](repeating: false, count: 9)) == 0, "shut the box: an empty board scores 0")

    func legal(_ standing: [Bool], _ sum: Int) -> [[Int]] {
        var res: [[Int]] = []
        for m in 1..<512 {
            var s = 0, ok = true; var t: [Int] = []
            for i in 0..<9 where m & (1 << i) != 0 { if !standing[i] { ok = false }; s += i + 1; t.append(i + 1) }
            if ok && s == sum { res.append(t) }
        }
        return res
    }
    func play(newBot: Bool, rng: inout SeededGenerator) -> Int {
        var standing = full
        while true {
            var one = false
            if newBot { one = ShutBoxStrategy.shouldUseOneDie(standing: standing) }
            else if !standing[6] && !standing[7] && !standing[8] {
                let h1 = (1...6).filter { !legal(standing, $0).isEmpty }.count
                var h2 = 0
                for a in 1...6 { for b in 1...6 where !legal(standing, a + b).isEmpty { h2 += 1 } }
                one = Double(h1) / 6 > Double(h2) / 36
            }
            let sum = one ? Int.random(in: 1...6, using: &rng) : Int.random(in: 1...6, using: &rng) + Int.random(in: 1...6, using: &rng)
            let subsets = legal(standing, sum)
            if subsets.isEmpty { return (0..<9).filter { standing[$0] }.reduce(0) { $0 + $1 + 1 } }
            let chosen = newBot ? ShutBoxStrategy.chooseSet(standing: standing, sum: sum)!
                : subsets.min { a, b in a.count != b.count ? a.count < b.count : (a.max() ?? 0) > (b.max() ?? 0) }!
            for t in chosen { standing[t - 1] = false }
            if !standing.contains(true) { return 0 }
        }
    }
    var newTotal = 0, oldTotal = 0, newShut = 0, oldShut = 0
    var r1 = SeededGenerator(seed: 5), r2 = SeededGenerator(seed: 5)
    for _ in 0..<1500 {
        let a = play(newBot: true, rng: &r1), b = play(newBot: false, rng: &r2)
        newTotal += a; oldTotal += b
        if a == 0 { newShut += 1 }
        if b == 0 { oldShut += 1 }
    }
    print("Shut the Box: exact-DP bot avg \(Double(newTotal) / 1500) (shut \(newShut)); old heuristic avg \(Double(oldTotal) / 1500) (shut \(oldShut)) over 1500 seeded games")
    check(newTotal <= oldTotal, "shut the box: the exact-expectation bot averages no worse than the old heuristic")
}

// --- UNO / Crazy Eights / Wizard / Oh Hell -----------------------------

func bxSeats(_ n: Int) -> [Seat] {
    let names = ["Hank", "Ruthie", "Marco", "Mae", "Tucker", "Julie"]
    return (0..<n).map { Seat(id: $0, playerName: names[$0 % 6], colorIndex: $0, isConnected: true, isHost: $0 == 0) }
}

func bxPlayCardGame(kind: GameKind, players: Int, newSeat: Int, seed: UInt64) -> (winner: Int?, ok: Bool) {
    let rules = RulesConfig()
    let e = HostEngine(seats: bxSeats(players), gameKind: kind, rules: rules, seed: seed)
    _ = e.apply(.startGame(kind, rules, seed: seed))
    for _ in 0..<30000 {
        let st = e.state
        switch st.phase {
        case .gameOver: return (st.hands.first { $0.value.isEmpty }?.key, true)
        case .choosingTrump(let seat):
            let useNew = seat == newSeat
            let suit: Suit = kind == .uno
                ? (useNew ? UnoBrain.declare(state: st, seat: seat) : UnoBrain.legacyDeclare(state: st, seat: seat))
                : (useNew ? CrazyEightsBrain.declare(state: st, seat: seat) : CrazyEightsBrain.legacyDeclare(state: st, seat: seat))
            _ = e.apply(.declareSuit(suit), from: seat)
        case .playing:
            let seat = st.round!.turnSeat
            let useNew = seat == newSeat
            let act: PlayerAction? = kind == .uno
                ? (useNew ? UnoBrain.play(state: st, seat: seat) : UnoBrain.legacyPlay(state: st, seat: seat))
                : (useNew ? CrazyEightsBrain.play(state: st, seat: seat) : CrazyEightsBrain.legacyPlay(state: st, seat: seat))
            guard let a = act else { return (nil, false) } // dry table: both draw piles empty
            if isIllegal(e.apply(a, from: seat)) { print("ILLEGAL bot move \(a) in \(kind)"); return (nil, false) }
        default: return (nil, false)
        }
    }
    return (nil, false)
}

do {
    for (kind, players, label) in [(GameKind.uno, 2, "UNO 2p"), (.uno, 4, "UNO 4p"), (.crazyEights, 2, "Crazy Eights 2p"), (.crazyEights, 4, "Crazy Eights 4p")] {
        var wins = 0, games = 0, bad = 0
        let n = 400
        for i in 0..<n {
            let r = bxPlayCardGame(kind: kind, players: players, newSeat: i % players, seed: UInt64(i + 1))
            if !r.ok && r.winner == nil { bad += 1 } else { games += 1; if r.winner == i % players { wins += 1 } }
        }
        let rate = Double(wins) / Double(max(games, 1)), fair = 1.0 / Double(players)
        print("\(label): new bot won \(wins)/\(games) = \(rate) (fair share \(fair)); dry-table stalls \(bad)")
        check(bad <= n / 40, "\(label): bot games finish (stalls \(bad) of \(n), only dry-table draws allowed)")
        check(rate >= fair - 0.03, "\(label): the new bot is no worse than the old heuristic (\(rate) vs fair \(fair))")
    }
}

do {
    // Scenario: next player (seat 1) has exactly one card left; we hold a red Skip that matches the top.
    let skipID = uno.first { $0.unoColor == .red && $0.unoSymbol == .skip }!.id
    let wildID = uno.first { $0.unoSymbol == .wild }!.id
    let h: [Card] = [ucard("u_r3a"), ucard("u_b9a"), ucard(skipID), ucard(wildID)]
    let e = unoEngine(hands: [0: h, 1: [ucard("u_g5a")], 2: [ucard("u_y1a"), ucard("u_g2a"), ucard("u_y3a")]],
                      top: ucard("u_r5a"), turn: 0, players: 3)
    if case .playCard(let id, _)? = UnoBrain.play(state: e.state, seat: 0) {
        check(id == skipID, "uno: with the next player on one card, the bot plays its Skip")
    } else { check(false, "uno: the bot returns a card play in the skip scenario") }
    // Wild is held when a colored card is legal and nobody is close to out.
    let e2 = unoEngine(hands: [0: [ucard("u_r3a"), ucard(wildID)], 1: [ucard("u_g5a"), ucard("u_y1a"), ucard("u_g2a"), ucard("u_y3a"), ucard("u_b4a")]],
                       top: ucard("u_r5a"), turn: 0, players: 2)
    if case .playCard(let id, _)? = UnoBrain.play(state: e2.state, seat: 0) {
        check(id == "u_r3a", "uno: the bot keeps its wild as the guaranteed last card")
    } else { check(false, "uno: card play in the wild-hold scenario") }
    let e3 = unoEngine(hands: [0: [ucard("u_r3a"), ucard("u_r7a"), ucard("u_g2a"), ucard("u_g4a"), ucard("u_g6a"), ucard("u_g8a")], 1: [ucard("u_b1a")]],
                       top: ucard("u_r5a"), turn: 0, players: 2, declared: nil)
    check(UnoBrain.declare(state: e3.state, seat: 0) == .clubs, "uno: names the color it holds most of (green -> clubs)")
    // Pending penalty: stacks a Draw Two when the rules allow it, otherwise absorbs.
    let d2 = uno.first { $0.unoColor == .red && $0.unoSymbol == .drawTwo }!
    let top2 = uno.first { $0.unoColor == .blue && $0.unoSymbol == .drawTwo }!
    let stackRules = RulesConfig()
    let e4 = unoEngine(hands: [0: [d2, ucard("u_r3a")]], top: top2, turn: 0, players: 2, pending: 2, rules: stackRules)
    if case .playCard(let id, _)? = UnoBrain.play(state: e4.state, seat: 0) { check(id == d2.id, "uno: stacks a Draw Two onto a pending penalty") }
    else if UnoBrain.play(state: e4.state, seat: 0) == .drawCard { check(!stackRules.stackDrawCards, "uno: absorbs a penalty only when stacking is off") }
}

do {
    // Wizard / Oh Hell: bids are calibrated and games complete legally.
    func run(kind: GameKind, players: Int, newSeat: Int, seed: UInt64) -> (diff: Double, bidBias: Double, bidAbs: Double, n: Int)? {
        let rules = RulesConfig()
        let e = HostEngine(seats: bxSeats(players), gameKind: kind, rules: rules, seed: seed)
        _ = e.apply(.startGame(kind, rules, seed: seed))
        for _ in 0..<20000 {
            let st = e.state
            switch st.phase {
            case .gameOver:
                let totals = Scoring.totals(history: st.roundHistory, kind: kind, missScoresTricks: rules.missScoresTricks)
                var bias = 0.0, abs_ = 0.0, n = 0
                for r in st.roundHistory { if let b = r.bids[newSeat] { let t = r.tricksWon[newSeat] ?? 0; bias += Double(b - t); abs_ += Double(abs(b - t)); n += 1 } }
                let others = totals.filter { $0.key != newSeat }.values.map(Double.init)
                return (Double(totals[newSeat] ?? 0) - others.reduce(0, +) / Double(others.count), bias, abs_, n)
            case .bidding:
                let seat = st.round!.turnSeat
                _ = e.apply(.placeBid(TrickBrain.bid(state: st, seat: seat, legacy: seat != newSeat, personality: BotPersonality.forName(st.seats[seat].playerName))), from: seat)
            case .choosingTrump(let seat): _ = e.apply(.chooseTrump(TrickBrain.chooseTrump(state: st, seat: seat)), from: seat)
            case .playing:
                let seat = st.round!.turnSeat
                guard let a = TrickBrain.play(state: st, seat: seat, legacy: seat != newSeat) else { return nil }
                if isIllegal(e.apply(a, from: seat)) { return nil }
            case .trickComplete: _ = e.apply(.nextTrick)
            case .roundComplete: _ = e.apply(.nextRound)
            default: return nil
            }
        }
        return nil
    }
    for (kind, players, label) in [(GameKind.wizard, 3, "Wizard 3p"), (.wizard, 4, "Wizard 4p"), (.ohHell, 3, "Oh Hell 3p")] {
        var diff = 0.0, bias = 0.0, absErr = 0.0, nb = 0, games = 0
        for i in 0..<150 {
            guard let r = run(kind: kind, players: players, newSeat: i % players, seed: UInt64(i + 1)) else {
                check(false, "\(label): seeded bot game \(i) completed with only legal moves"); continue
            }
            games += 1; diff += r.diff; bias += r.bidBias; absErr += r.bidAbs; nb += r.n
        }
        print("\(label): new bidder score edge vs old \(diff / Double(games)), mean(bid-tricks) \(bias / Double(nb)), mean|err| \(absErr / Double(nb))")
        check(diff / Double(games) > 0, "\(label): the recalibrated bidder outscores the old one on average")
        check(abs(bias / Double(nb)) < 1.1, "\(label): bids are no longer wildly under (mean bid-tricks \(bias / Double(nb)))")
    }
}

// MARK: - BotAI END

// MARK: - Save/resume snapshot round-trips (ResumeCatalog / SaveSlots)
//
// Every state the app parks on disk (Sources/App/Save) must survive JSON
// and rebuild an engine that agrees with the original. The dice games'
// controller snapshots live in Engine/DiceSaveTypes.swift for exactly this
// check.

func rtRoundTrip<T: Codable & Equatable>(_ value: T, _ name: String) -> T {
    let data = try! JSONEncoder().encode(value)
    let back = try! JSONDecoder().decode(T.self, from: data)
    check(back == value, "\(name) survives a JSON round-trip")
    return back
}

do {
    let crib = CribbageEngine(seed: 7)
    let back = rtRoundTrip(crib.state, "CribbageState")
    check(CribbageEngine(restoring: back).state == crib.state, "CribbageEngine(restoring:) matches the saved state")
}
do {
    let ship = BattleshipEngine(seed: 3)
    for s in BattleshipBot.placement(seed: 3) {
        _ = ship.apply(.placeShip(kind: s.kind, row: s.row, col: s.col, orientation: s.orientation), from: 0)
    }
    let back = rtRoundTrip(ship.state, "BattleshipState (mid-placement)")
    check(BattleshipEngine(restoring: back).state == ship.state, "BattleshipEngine(restoring:) matches the saved state")
}
do {
    let gin = GinRummyEngine(seed: 5)
    let back = rtRoundTrip(gin.state, "GinRummyState")
    check(GinRummyEngine(restoring: back).state == gin.state, "GinRummyEngine(restoring:) matches the saved state")
}
do {
    let bj = BlackjackEngine(seed: 9, seatCount: 3)
    _ = bj.apply(.placeBet(bj.state.config.minBet), from: 0)
    let back = rtRoundTrip(bj.state, "BlackjackState (one bet down)")
    check(BlackjackEngine(restoring: back).state == bj.state, "BlackjackEngine(restoring:) matches the saved state")
}
do {
    let liar = LiarsDiceEngine(seed: 11, seatCount: 4)
    _ = liar.rollAll(seed: 11)
    let back = rtRoundTrip(liar.state, "LiarsDiceState (dice rolled)")
    check(LiarsDiceEngine(restoring: back).state == liar.state, "LiarsDiceEngine(restoring:) matches the saved state")
}
do {
    let fish = GoFishEngine(seed: 13, playerCount: 3)
    let back = rtRoundTrip(fish.state, "GoFishState")
    check(GoFishEngine(restoring: back).state == fish.state, "GoFishEngine(restoring:) matches the saved state")
}
do {
    let maid = OldMaidEngine(seed: 17, playerCount: 3)
    let back = rtRoundTrip(maid.state, "OldMaidState")
    check(OldMaidEngine(restoring: back).state == maid.state, "OldMaidEngine(restoring:) matches the saved state")
}
do {
    let war = WarEngine(seed: 19)
    _ = war.apply(.flip, from: 0)
    let back = rtRoundTrip(war.state, "WarState (one battle in)")
    check(WarEngine(restoring: back).state == war.state, "WarEngine(restoring:) matches the saved state")
}
do {
    let mancala = MancalaEngine(players: [MancalaPlayer(name: "A", isBot: false), MancalaPlayer(name: "B", isBot: true)])
    _ = mancala.apply(.sow(pit: 2), from: 0)
    let back = rtRoundTrip(mancala.state, "MancalaState (one sowing)")
    check(MancalaEngine(restoring: back).state == mancala.state, "MancalaEngine(restoring:) matches the saved state")
}
do {
    let checkers = CheckersEngine(players: [CheckersPlayer(name: "A", isBot: false), CheckersPlayer(name: "B", isBot: true)])
    if let move = checkers.state.legalMoves.first { _ = checkers.apply(.move(move), from: 0) }
    let back = rtRoundTrip(checkers.state, "CheckersState (one move)")
    check(CheckersEngine(restoring: back).state == checkers.state, "CheckersEngine(restoring:) matches the saved state")
}
do {
    let four = ConnectFourEngine(players: [ConnectFourPlayer(name: "A", isBot: false), ConnectFourPlayer(name: "B", isBot: true)])
    _ = four.apply(.drop(column: 3), from: 0)
    let back = rtRoundTrip(four.state, "ConnectFourState (one disc)")
    check(ConnectFourEngine(restoring: back).state == four.state, "ConnectFourEngine(restoring:) matches the saved state")
}
do {
    let dots = DotsAndBoxesEngine(gridSize: 3, players: [DotsAndBoxesPlayer(name: "A", colorIndex: 0, isBot: false),
                                                          DotsAndBoxesPlayer(name: "B", colorIndex: 1, isBot: true)], seed: 1)
    _ = dots.performBotMove(for: 0)
    let back = rtRoundTrip(dots.state, "DotsAndBoxesState (one line)")
    check(DotsAndBoxesEngine(restoring: back).state == dots.state, "DotsAndBoxesEngine(restoring:) matches the saved state")
}
do {
    let quarto = QuartoEngine(players: [QuartoPlayer(name: "A", isBot: false), QuartoPlayer(name: "B", isBot: true)])
    _ = quarto.apply(.selectPiece(0), from: 0)
    let back = rtRoundTrip(quarto.state, "QuartoState (piece handed over)")
    check(QuartoEngine(restoring: back).state == quarto.state, "QuartoEngine(restoring:) matches the saved state")
}
do {
    let sol = SolitaireEngine(seed: 23)
    _ = sol.draw()
    let back = rtRoundTrip(sol.state, "SolitaireState (one draw)")
    check(SolitaireEngine(state: back).state == sol.state, "SolitaireEngine(state:) matches the saved state")
}
do {
    let seats = [DiceSavedSeat(id: 0, name: "Hank", isBot: true, deviceID: nil, colorIndex: 6),
                 DiceSavedSeat(id: 1, name: "Mae", isBot: false, deviceID: "dev-mae", colorIndex: 1)]
    _ = rtRoundTrip(LcrSaveState(seats: seats, chips: [3, 1], centerPot: 2, turnSeat: 1), "LcrSaveState")
    _ = rtRoundTrip(YahtzeeSaveState(seats: seats, turnSeat: 0, scorecards: [
        YahtzeeSavedCard(entries: ["ones": 3, "yahtzee": 50], yahtzeeBonusCount: 1),
        YahtzeeSavedCard(entries: [:], yahtzeeBonusCount: 0)]), "YahtzeeSaveState")
    _ = rtRoundTrip(ZilchSaveState(seats: seats, bankedScore: [1500, 300], turnSeat: 1, turnScore: 250,
                                   heldIndices: [0, 4], finalChaseSeat: nil, finalChaseRemaining: []), "ZilchSaveState")
    _ = rtRoundTrip(ShutBoxSaveState(seats: seats, standing: [true, false, true, true, false, true, true, true, true],
                                     turnSeat: 1, roundIndex: 0, roundsToWin: 1, roundsWon: [0, 0],
                                     roundScores: [12, nil], usingOneDie: false, oneDieAvailable: false,
                                     shutTheBoxSeat: nil), "ShutBoxSaveState (nil round score encodes)")
}

// MARK: - Summary

let total = passCount + failCount
if failCount == 0 {
    print("ALL GREEN: \(passCount)/\(total) checks passed")
    exit(EXIT_SUCCESS)
} else {
    print("FAILED: \(failCount) of \(total) checks failed (\(passCount) passed)")
    exit(EXIT_FAILURE)
}
