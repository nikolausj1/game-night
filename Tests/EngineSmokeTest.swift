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
var legacyRulesDict = try! JSONSerialization.jsonObject(
    with: try! JSONEncoder().encode(RulesConfig(stackDrawCards: false, drawUntilPlayable: false))) as! [String: Any]
legacyRulesDict.removeValue(forKey: "stackDrawCards")
legacyRulesDict.removeValue(forKey: "drawUntilPlayable")
let legacyRules = try! JSONDecoder().decode(
    RulesConfig.self, from: try! JSONSerialization.data(withJSONObject: legacyRulesDict))
check(legacyRules.stackDrawCards == true && legacyRules.drawUntilPlayable == true,
      "pre-UNO RulesConfig decodes with defaults")

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

// MARK: - UNO draw-two stacking: accumulate → absorb → skip

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
_ = eChain.apply(.drawCard, from: 2)
check(eChain.state.hands[2]?.count == 3 + 4, "absorbing draws the whole 4-card penalty")
check(eChain.state.round?.pendingDraw == 0 && eChain.state.round?.turnSeat == 0,
      "absorbing clears the pending draw and skips the turn")

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
_ = eW4.apply(.drawCard, from: 2)
check(eW4.state.hands[2]?.count == 3 + 6 && eW4.state.round?.pendingDraw == 0, "absorbing a 2+4 chain draws 6")

// MARK: - UNO non-stacking: immediate penalty

let noStack = RulesConfig(stackDrawCards: false)
let eNo = unoEngine(
    hands: [0: [ucard("u_rDa"), ucard("u_r2b")], 1: [ucard("u_g1a")], 2: [ucard("u_b1b")]],
    top: ucard("u_r5a"), turn: 0, players: 3, rules: noStack,
    drawPile: [ucard("u_y8a"), ucard("u_y8b"), ucard("u_y9a"), ucard("u_y9b")])
_ = eNo.apply(.playCard(cardID: "u_rDa", force: false), from: 0)
check(eNo.state.hands[1]?.count == 3 && eNo.state.round?.pendingDraw == 0,
      "non-stacking drawTwo deals 2 to the victim immediately")
check(eNo.state.round?.turnSeat == 2, "non-stacking drawTwo skips the victim")

let eNoW = unoEngine(
    hands: [0: [ucard("u_wd42"), ucard("u_r2a")], 1: [ucard("u_g1b")], 2: [ucard("u_b2a")]],
    top: ucard("u_r5b"), turn: 0, players: 3, rules: noStack,
    drawPile: [ucard("u_y0"), ucard("u_g0"), ucard("u_b0"), ucard("u_r0"), ucard("u_y5a")])
_ = eNoW.apply(.playCard(cardID: "u_wd42", force: false), from: 0)
check(eNoW.state.phase == .choosingTrump(seat: 0) && eNoW.state.hands[1]?.count == 1,
      "non-stacking wild draw four picks a color before the penalty lands")
_ = eNoW.apply(.declareSuit(.hearts), from: 0)
check(eNoW.state.hands[1]?.count == 5 && eNoW.state.round?.pendingDraw == 0,
      "non-stacking wild draw four deals 4 after the color pick")
check(eNoW.state.round?.turnSeat == 2 && eNoW.state.round?.trumpSuit == .hearts,
      "victim skipped and red (hearts) declared")

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

// MARK: - unoCalled event codable

let unoEvents: [GameEvent] = [.unoCalled(seat: 2), .suitDeclared(.hearts)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(unoEvents))) == unoEvents,
      "unoCalled round-trips through JSON")

let cardsDrawnEvents: [GameEvent] = [.cardsDrawn(seat: 1, count: 3)]
check((try! JSONDecoder().decode([GameEvent].self, from: try! JSONEncoder().encode(cardsDrawnEvents))) == cardsDrawnEvents,
      "cardsDrawn round-trips through JSON")

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

// MARK: - Summary

let total = passCount + failCount
if failCount == 0 {
    print("ALL GREEN: \(passCount)/\(total) checks passed")
    exit(EXIT_SUCCESS)
} else {
    print("FAILED: \(failCount) of \(total) checks failed (\(passCount) passed)")
    exit(EXIT_FAILURE)
}
