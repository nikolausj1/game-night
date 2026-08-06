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

// MARK: - Summary

let total = passCount + failCount
if failCount == 0 {
    print("ALL GREEN: \(passCount)/\(total) checks passed")
    exit(EXIT_SUCCESS)
} else {
    print("FAILED: \(failCount) of \(total) checks failed (\(passCount) passed)")
    exit(EXIT_FAILURE)
}
