import Foundation

/// The authoritative reducer, owned by the host iPad. Phones send
/// `PlayerAction`s, the table sends `TableAction`s; every apply returns the
/// events the UI/announcer should react to. Illegal or out-of-turn actions
/// produce an `illegalAttempt` event and change nothing.
public final class HostEngine {
    public private(set) var state: GameState

    /// Last few pre-action snapshots for the undo flow (bounded).
    private var undoStack: [GameState] = []
    private var undoRequested = false
    private let undoDepth = 3

    /// Bumped every deal/reshuffle so each shuffle draws from a fresh,
    /// deterministic stream derived from the game seed.
    private var dealSerial: UInt64 = 0

    public init(seats: [Seat], gameKind: GameKind, rules: RulesConfig, seed: UInt64) {
        state = GameState(
            gameKind: gameKind,
            rules: rules,
            seats: seats,
            phase: .lobby,
            round: nil,
            hands: [:],
            drawPile: [],
            discardPile: [],
            roundHistory: [],
            seed: seed
        )
    }

    /// Resume from a saved `GameState` (save/resume flow). Undo history is
    /// not persisted, so the restored engine starts with nothing to undo.
    /// `dealSerial` isn't part of `GameState` either; it's re-derived from
    /// visible state so post-restore reshuffles stay deterministic without
    /// having to replay the exact pre-save shuffle stream.
    public init(restoring state: GameState) {
        self.state = state
        dealSerial = UInt64(truncatingIfNeeded: state.roundHistory.count * 97 + state.discardPile.count + 1)
    }

    // MARK: - Connection bookkeeping

    /// Presence is transport truth, not game truth — it bypasses the
    /// reducer deliberately and never alters play state.
    public func setConnected(seat: Int, connected: Bool) {
        guard state.seats.indices.contains(seat) else { return }
        state.seats[seat].isConnected = connected
    }

    // MARK: - Table actions

    public func apply(_ action: TableAction) -> [GameEvent] {
        switch action {
        case .startGame(let kind, let rules, let seed):
            state.gameKind = kind
            state.rules = rules
            state.seed = seed
            state.round = nil
            state.hands = [:]
            state.drawPile = []
            state.discardPile = []
            state.roundHistory = []
            undoStack = []
            undoRequested = false
            dealSerial = 0
            switch kind {
            case .wizard, .ohHell:
                return dealTrickRound(roundNumber: 1, dealerSeat: 0)
            case .crazyEights:
                return dealCrazyEights(dealerSeat: 0)
            case .uno:
                return dealUno(dealerSeat: 0)
            case .freePlay:
                return setUpFreePlay()
            }

        case .nextRound:
            guard state.phase == .roundComplete, let round = state.round else { return [] }
            return dealTrickRound(
                roundNumber: round.roundNumber + 1,
                dealerSeat: nextSeat(after: round.dealerSeat)
            )

        case .nextTrick:
            guard case .trickComplete(let winner) = state.phase, var round = state.round else { return [] }
            round.completedTricks.append(round.currentTrick)
            round.currentTrick = []
            round.leadSeat = winner
            round.turnSeat = winner
            state.round = round
            if state.hands.values.allSatisfy({ $0.isEmpty }) {
                return finishRound()
            }
            state.phase = .playing
            return []

        case .approveUndo:
            guard undoRequested, let snapshot = undoStack.popLast() else { return [] }
            state = snapshot
            undoRequested = false
            return [.undone]

        case .newDeal:
            guard let round = state.round else { return [] }
            switch state.gameKind {
            case .wizard, .ohHell:
                return dealTrickRound(roundNumber: round.roundNumber, dealerSeat: round.dealerSeat)
            case .crazyEights:
                return dealCrazyEights(dealerSeat: round.dealerSeat)
            case .uno:
                return dealUno(dealerSeat: round.dealerSeat)
            case .freePlay:
                return setUpFreePlay()
            }
        }
    }

    // MARK: - Player actions

    public func apply(_ action: PlayerAction, from seat: Int) -> [GameEvent] {
        guard state.seats.contains(where: { $0.id == seat }) else {
            return reject(seat, "Unknown seat")
        }
        switch action {
        case .placeBid(let bid):
            return handleBid(bid, from: seat)
        case .chooseTrump(let suit):
            return handleChooseTrump(suit, from: seat)
        case .playCard(let cardID, let force):
            return handlePlayCard(cardID, force: force, from: seat)
        case .drawCard:
            return handleDrawCard(from: seat)
        case .declareSuit(let suit):
            return handleDeclareSuit(suit, from: seat)
        case .freeMoveCard(let cardID, let zone, _, _, _):
            return handleFreeMove(cardID, to: zone, from: seat)
        case .requestUndo:
            guard !undoStack.isEmpty else { return reject(seat, "Nothing to undo") }
            undoRequested = true
            return []
        }
    }

    // MARK: - Bidding & trump

    private func handleBid(_ bid: Int, from seat: Int) -> [GameEvent] {
        guard state.phase == .bidding, var round = state.round else {
            return reject(seat, "Bidding isn't open right now")
        }
        guard seat == round.turnSeat else {
            return reject(seat, "It's not your turn to bid")
        }
        guard (0...round.cardsPerPlayer).contains(bid) else {
            return reject(seat, "Bid must be between 0 and \(round.cardsPerPlayer)")
        }
        if state.rules.screwTheDealer, seat == round.dealerSeat {
            let othersTotal = round.bids.values.reduce(0, +)
            if othersTotal + bid == round.cardsPerPlayer {
                return reject(seat, "Dealer can't bid \(bid) — bids can't add up to \(round.cardsPerPlayer)")
            }
        }
        pushUndo()
        round.bids[seat] = bid
        var events: [GameEvent] = [.bidPlaced(seat: seat, bid: bid)]
        if round.bids.count == state.seats.count {
            events.append(.biddingComplete)
            round.leadSeat = nextSeat(after: round.dealerSeat)
            round.turnSeat = round.leadSeat
            state.round = round
            state.phase = .playing
        } else {
            round.turnSeat = nextSeat(after: seat)
            state.round = round
        }
        return events
    }

    private func handleChooseTrump(_ suit: Suit, from seat: Int) -> [GameEvent] {
        guard state.gameKind == .wizard,
              case .choosingTrump(let chooser) = state.phase,
              var round = state.round else {
            return reject(seat, "There's no trump to choose right now")
        }
        guard seat == chooser else {
            return reject(seat, "Only the dealer chooses trump")
        }
        pushUndo()
        round.trumpSuit = suit
        round.turnSeat = nextSeat(after: round.dealerSeat)
        state.round = round
        state.phase = .bidding
        if let trumpCard = round.trumpCard {
            return [.trumpRevealed(trumpCard, suit)]
        }
        return []
    }

    // MARK: - Playing cards

    private func handlePlayCard(_ cardID: String, force: Bool, from seat: Int) -> [GameEvent] {
        guard state.phase == .playing else {
            return reject(seat, "You can't play a card right now")
        }
        guard var hand = state.hands[seat], let index = hand.firstIndex(where: { $0.id == cardID }) else {
            return reject(seat, "That card isn't in your hand")
        }
        let card = hand[index]

        switch state.gameKind {
        case .wizard, .ohHell:
            guard var round = state.round else { return reject(seat, "No round in progress") }
            guard seat == round.turnSeat else { return reject(seat, "It's not your turn") }
            var forced = false
            if case .illegal(let reason) = ruleset.legality(
                of: card, hand: hand, trick: round.currentTrick, trump: round.trumpSuit, state: state
            ) {
                guard force, state.rules.softEnforcement else {
                    return [.illegalAttempt(seat: seat, reason: reason)]
                }
                forced = true
            }
            pushUndo()
            hand.remove(at: index)
            state.hands[seat] = hand
            round.currentTrick.append(TrickPlay(seat: seat, card: card, wasForced: forced))
            var events: [GameEvent] = [.cardPlayed(seat: seat, card: card, forced: forced)]
            if round.currentTrick.count == state.seats.count {
                let winner = ruleset.trickWinner(round.currentTrick, trump: round.trumpSuit)
                round.tricksWon[winner, default: 0] += 1
                state.round = round
                state.phase = .trickComplete(winnerSeat: winner)
                events.append(.trickWon(seat: winner))
            } else {
                round.turnSeat = nextSeat(after: seat)
                state.round = round
            }
            return events

        case .crazyEights:
            guard var round = state.round else { return reject(seat, "No round in progress") }
            guard seat == round.turnSeat else { return reject(seat, "It's not your turn") }
            var forced = false
            if case .illegal(let reason) = ruleset.legality(
                of: card, hand: hand, trick: [], trump: round.trumpSuit, state: state
            ) {
                guard force, state.rules.softEnforcement else {
                    return [.illegalAttempt(seat: seat, reason: reason)]
                }
                forced = true
            }
            pushUndo()
            hand.remove(at: index)
            state.hands[seat] = hand
            state.discardPile.append(card)
            var events: [GameEvent] = [.cardPlayed(seat: seat, card: card, forced: forced)]
            round.trumpSuit = nil // a fresh play always clears any declared suit
            if hand.isEmpty {
                state.round = round
                state.phase = .gameOver
                events.append(.gameWon(seat: seat))
            } else if card.rank == 8 {
                state.round = round
                state.phase = .choosingTrump(seat: seat) // waiting on declareSuit
            } else {
                round.turnSeat = nextSeat(after: seat)
                state.round = round
            }
            return events

        case .uno:
            guard var round = state.round else { return reject(seat, "No round in progress") }
            guard seat == round.turnSeat else { return reject(seat, "It's not your turn") }
            guard case .uno(_, let symbol) = card.kind else {
                return reject(seat, "That card doesn't belong to an UNO deck")
            }
            var forced = false
            if case .illegal(let reason) = ruleset.legality(
                of: card, hand: hand, trick: [], trump: round.trumpSuit, state: state
            ) {
                guard force, state.rules.softEnforcement else {
                    return [.illegalAttempt(seat: seat, reason: reason)]
                }
                forced = true
            }
            pushUndo()
            hand.remove(at: index)
            state.hands[seat] = hand
            state.discardPile.append(card)
            round.trumpSuit = nil // a fresh play always clears any declared color
            var events: [GameEvent] = [.cardPlayed(seat: seat, card: card, forced: forced)]
            if hand.count == 1 {
                events.append(.unoCalled(seat: seat))
            }
            if hand.isEmpty {
                // Going out ends the game immediately — any effect on the
                // last card (draw penalty, wild color) never resolves.
                state.round = round
                state.phase = .gameOver
                events.append(.gameWon(seat: seat))
                return events
            }
            switch symbol {
            case .number:
                round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
            case .skip:
                round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 2)
            case .reverse:
                if state.seats.count == 2 {
                    // Two players: reverse acts as a skip — same player again.
                    round.turnSeat = seat
                } else {
                    round.direction = -round.direction
                    round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
                }
            case .drawTwo:
                round.pendingDraw += 2
                if state.rules.stackDrawCards {
                    round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
                } else {
                    // No stacking: the penalty lands immediately and the
                    // victim is skipped.
                    let victim = advanceSeat(from: seat, direction: round.direction, steps: 1)
                    drawCards(round.pendingDraw, to: victim)
                    round.pendingDraw = 0
                    round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 2)
                }
            case .wild:
                state.round = round
                state.phase = .choosingTrump(seat: seat) // waiting on declareSuit
                return events
            case .wildDrawFour:
                round.pendingDraw += 4
                state.round = round
                state.phase = .choosingTrump(seat: seat) // color first, then penalty resolves
                return events
            }
            state.round = round
            return events

        case .freePlay:
            pushUndo()
            hand.remove(at: index)
            state.hands[seat] = hand
            state.discardPile.append(card)
            return [.cardPlayed(seat: seat, card: card, forced: false)]
        }
    }

    /// Crazy Eights: pick the suit after an eight. UNO: pick the active color
    /// after a wild — the chosen color rides in `trumpSuit` via the fixed
    /// Suit↔UnoColor mapping (red↔hearts, yellow↔diamonds, green↔clubs,
    /// blue↔spades).
    private func handleDeclareSuit(_ suit: Suit, from seat: Int) -> [GameEvent] {
        guard state.gameKind == .crazyEights || state.gameKind == .uno,
              case .choosingTrump(let declarer) = state.phase,
              var round = state.round else {
            return reject(seat, "There's no suit to declare right now")
        }
        guard seat == declarer else {
            let reason = state.gameKind == .uno
                ? "Only the player of the wild declares the color"
                : "Only the player of the eight declares the suit"
            return reject(seat, reason)
        }
        pushUndo()
        round.trumpSuit = suit
        if state.gameKind == .uno {
            if round.pendingDraw > 0, !state.rules.stackDrawCards {
                // Wild draw four without stacking: penalty lands now and the
                // victim is skipped.
                let victim = advanceSeat(from: seat, direction: round.direction, steps: 1)
                drawCards(round.pendingDraw, to: victim)
                round.pendingDraw = 0
                round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 2)
            } else {
                round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
            }
        } else {
            round.turnSeat = nextSeat(after: seat)
        }
        state.round = round
        state.phase = .playing
        return [.suitDeclared(suit)]
    }

    private func handleDrawCard(from seat: Int) -> [GameEvent] {
        guard state.gameKind == .crazyEights || state.gameKind == .uno || state.gameKind == .freePlay else {
            return reject(seat, "You can't draw in this game")
        }
        guard state.phase == .playing else {
            return reject(seat, "You can't draw right now")
        }
        if state.gameKind == .uno {
            guard var round = state.round, seat == round.turnSeat else {
                return reject(seat, "It's not your turn")
            }
            if round.pendingDraw > 0 {
                // Absorb the whole stacked penalty; the turn is skipped.
                pushUndo()
                drawCards(round.pendingDraw, to: seat)
                round.pendingDraw = 0
                round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
                state.round = round
                return []
            }
            // Voluntary draw.
            guard !state.drawPile.isEmpty || state.discardPile.count > 1 else {
                return reject(seat, "The draw pile is empty")
            }
            pushUndo()
            if state.rules.drawUntilPlayable {
                // Family rule: keep drawing until a playable card turns up.
                // Every drawn card joins the hand; the drawn-into playable
                // card is NOT auto-played — the turn stays with the drawer,
                // who must then play (any currently-playable card, not just
                // the one that was drawn). If the deck and recyclable
                // discard both run dry before a playable card appears, stop
                // drawing and pass the turn instead of stalling forever.
                var drawnCount = 0
                var foundPlayable = false
                while let drawn = drawOneCard(to: seat) {
                    drawnCount += 1
                    if ruleset.legality(
                        of: drawn, hand: state.hands[seat] ?? [], trick: [], trump: round.trumpSuit, state: state
                    ).isLegal {
                        foundPlayable = true
                        break
                    }
                }
                var events: [GameEvent] = []
                if drawnCount > 0 {
                    events.append(.cardsDrawn(seat: seat, count: drawnCount))
                }
                if !foundPlayable {
                    round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
                }
                state.round = round
                return events
            }
            // Toggle off: strict draw-once-then-pass.
            drawCards(1, to: seat)
            round.turnSeat = advanceSeat(from: seat, direction: round.direction, steps: 1)
            state.round = round
            return []
        }
        if state.gameKind == .crazyEights {
            guard let round = state.round, seat == round.turnSeat else {
                return reject(seat, "It's not your turn")
            }
        }
        let canReshuffle = state.gameKind == .crazyEights && state.discardPile.count > 1
        guard !state.drawPile.isEmpty || canReshuffle else {
            return reject(seat, "The draw pile is empty")
        }
        pushUndo()
        if state.drawPile.isEmpty {
            // Recycle the discard pile (minus its top card) into a new pile.
            let top = state.discardPile.removeLast()
            let recycled = state.discardPile
            state.discardPile = [top]
            state.drawPile = DeckBuilder.shuffled(recycled, seed: state.seed &+ dealSerial)
            dealSerial &+= 1
        }
        let card = state.drawPile.removeFirst()
        state.hands[seat, default: []].append(card)
        return []
    }

    private func handleFreeMove(_ cardID: String, to zone: FreePlayZone, from seat: Int) -> [GameEvent] {
        guard state.gameKind == .freePlay else {
            return reject(seat, "Cards can only be moved freely in Free Play")
        }
        guard locateCard(cardID) != nil else {
            return reject(seat, "That card isn't on the table")
        }
        pushUndo()
        let card = removeCard(cardID)!
        switch zone {
        case .table: state.discardPile.append(card)
        case .hand: state.hands[seat, default: []].append(card)
        case .deck: state.drawPile.append(card)
        }
        return []
    }

    // MARK: - Dealing

    private func dealTrickRound(roundNumber: Int, dealerSeat: Int) -> [GameEvent] {
        let playerCount = state.seats.count
        let schedule = state.gameKind.roundsSchedule(playerCount: playerCount)
        guard roundNumber >= 1, roundNumber <= schedule.count else { return [] }
        let cardsEach = schedule[roundNumber - 1]

        state.phase = .dealing
        let baseDeck = state.gameKind.usesWizardDeck ? DeckBuilder.wizard60() : DeckBuilder.standard52()
        var deck = DeckBuilder.shuffled(baseDeck, seed: state.seed &+ dealSerial)
        dealSerial &+= 1

        state.hands = [:]
        for offset in 0..<playerCount {
            let seat = (dealerSeat + 1 + offset) % playerCount
            state.hands[seat] = Array(deck.prefix(cardsEach))
            deck.removeFirst(cardsEach)
        }
        state.discardPile = []

        var events: [GameEvent] = [.dealt]
        var trumpCard: Card?
        var trumpSuit: Suit?
        var phase = Phase.bidding
        if !deck.isEmpty {
            let flipped = deck.removeFirst()
            trumpCard = flipped
            switch flipped.kind {
            case .standard(let suit, _):
                trumpSuit = suit
            case .wizard:
                phase = .choosingTrump(seat: dealerSeat) // dealer picks trump
            case .jester:
                trumpSuit = nil // no trump this round
            case .uno:
                trumpSuit = nil // unreachable: trick decks contain no UNO cards
            }
            events.append(.trumpRevealed(flipped, trumpSuit))
        }
        state.drawPile = deck

        let firstBidder = nextSeat(after: dealerSeat)
        state.round = RoundState(
            roundNumber: roundNumber,
            cardsPerPlayer: cardsEach,
            dealerSeat: dealerSeat,
            trumpCard: trumpCard,
            trumpSuit: trumpSuit,
            bids: [:],
            tricksWon: [:],
            currentTrick: [],
            completedTricks: [],
            leadSeat: firstBidder,
            turnSeat: phase == .bidding ? firstBidder : dealerSeat
        )
        state.phase = phase
        return events
    }

    private func dealCrazyEights(dealerSeat: Int) -> [GameEvent] {
        let playerCount = state.seats.count
        let cardsEach = 5

        state.phase = .dealing
        var deck = DeckBuilder.shuffled(DeckBuilder.standard52(), seed: state.seed &+ dealSerial)
        dealSerial &+= 1

        state.hands = [:]
        for offset in 0..<playerCount {
            let seat = (dealerSeat + 1 + offset) % playerCount
            state.hands[seat] = Array(deck.prefix(cardsEach))
            deck.removeFirst(cardsEach)
        }
        let starter = deck.removeFirst()
        state.discardPile = [starter]
        state.drawPile = deck

        let firstPlayer = nextSeat(after: dealerSeat)
        state.round = RoundState(
            roundNumber: 1,
            cardsPerPlayer: cardsEach,
            dealerSeat: dealerSeat,
            trumpCard: nil,
            trumpSuit: nil,
            bids: [:],
            tricksWon: [:],
            currentTrick: [],
            completedTricks: [],
            leadSeat: firstPlayer,
            turnSeat: firstPlayer
        )
        state.phase = .playing
        return [.dealt]
    }

    private func dealUno(dealerSeat: Int) -> [GameEvent] {
        let playerCount = state.seats.count
        let cardsEach = 7

        state.phase = .dealing
        var deck = DeckBuilder.shuffled(DeckBuilder.uno108(), seed: state.seed &+ dealSerial)
        dealSerial &+= 1

        state.hands = [:]
        for offset in 0..<playerCount {
            let seat = (dealerSeat + 1 + offset) % playerCount
            state.hands[seat] = Array(deck.prefix(cardsEach))
            deck.removeFirst(cardsEach)
        }

        // Flip the starter. A wild can't start the discard pile: put it back
        // and reshuffle the remaining deck until a colored card comes up.
        // Starter action cards (skip/reverse/draw-two) set the color and
        // symbol to match but apply no effect in v1.
        var starter = deck.removeFirst()
        while isWildKind(starter) {
            deck.append(starter)
            deck = DeckBuilder.shuffled(deck, seed: state.seed &+ dealSerial)
            dealSerial &+= 1
            starter = deck.removeFirst()
        }
        state.discardPile = [starter]
        state.drawPile = deck

        let firstPlayer = (dealerSeat + 1) % playerCount
        state.round = RoundState(
            roundNumber: 1,
            cardsPerPlayer: cardsEach,
            dealerSeat: dealerSeat,
            trumpCard: nil,
            trumpSuit: nil,
            bids: [:],
            tricksWon: [:],
            currentTrick: [],
            completedTricks: [],
            leadSeat: firstPlayer,
            turnSeat: firstPlayer,
            direction: 1,
            pendingDraw: 0
        )
        state.phase = .playing
        return [.dealt]
    }

    private func setUpFreePlay() -> [GameEvent] {
        state.phase = .dealing
        state.drawPile = DeckBuilder.shuffled(state.rules.freePlayDeck.buildDeck(), seed: state.seed &+ dealSerial)
        dealSerial &+= 1
        state.hands = Dictionary(uniqueKeysWithValues: state.seats.map { ($0.id, [Card]()) })
        state.discardPile = []
        state.round = nil
        state.phase = .playing
        return [.dealt]
    }

    // MARK: - Round completion

    private func finishRound() -> [GameEvent] {
        guard let round = state.round else { return [] }
        let completed = CompletedRound(
            roundNumber: round.roundNumber,
            cardsPerPlayer: round.cardsPerPlayer,
            bids: round.bids,
            tricksWon: round.tricksWon
        )
        state.roundHistory.append(completed)
        var events: [GameEvent] = [.roundScored]

        let schedule = state.gameKind.roundsSchedule(playerCount: state.seats.count)
        if round.roundNumber >= schedule.count {
            state.phase = .gameOver
            let totals = Scoring.totals(
                history: state.roundHistory,
                kind: state.gameKind,
                missScoresTricks: state.rules.missScoresTricks
            )
            if let best = totals.values.max(),
               let winner = totals.filter({ $0.value == best }).keys.min() {
                events.append(.gameWon(seat: winner))
            }
        } else {
            state.phase = .roundComplete
        }
        return events
    }

    // MARK: - Helpers

    private var ruleset: any GameRules { state.gameKind.ruleset }

    private func nextSeat(after seat: Int) -> Int {
        (seat + 1) % state.seats.count
    }

    /// Direction-aware seat stepping for UNO (direction is +1 or -1).
    private func advanceSeat(from seat: Int, direction: Int, steps: Int) -> Int {
        let count = state.seats.count
        let raw = (seat + direction * steps) % count
        return (raw + count) % count
    }

    private func isWildKind(_ card: Card) -> Bool {
        guard case .uno(_, let symbol) = card.kind else { return false }
        return symbol == .wild || symbol == .wildDrawFour
    }

    /// Deal `count` cards from the draw pile into a hand, recycling the
    /// discard pile (minus its top card) whenever the pile runs dry. Stops
    /// early only if both piles are exhausted.
    private func drawCards(_ count: Int, to seat: Int) {
        for _ in 0..<count {
            guard drawOneCard(to: seat) != nil else { break }
        }
    }

    /// Draws exactly one card into `seat`'s hand, recycling the discard pile
    /// (minus its top card) if the draw pile is empty. Returns the drawn
    /// card, or `nil` if both piles are exhausted (never draws partially).
    @discardableResult
    private func drawOneCard(to seat: Int) -> Card? {
        if state.drawPile.isEmpty {
            guard state.discardPile.count > 1 else { return nil }
            let top = state.discardPile.removeLast()
            let recycled = state.discardPile
            state.discardPile = [top]
            state.drawPile = DeckBuilder.shuffled(recycled, seed: state.seed &+ dealSerial)
            dealSerial &+= 1
        }
        guard !state.drawPile.isEmpty else { return nil }
        let card = state.drawPile.removeFirst()
        state.hands[seat, default: []].append(card)
        return card
    }

    private func reject(_ seat: Int, _ reason: String) -> [GameEvent] {
        [.illegalAttempt(seat: seat, reason: reason)]
    }

    private func pushUndo() {
        undoStack.append(state)
        if undoStack.count > undoDepth {
            undoStack.removeFirst(undoStack.count - undoDepth)
        }
    }

    private func locateCard(_ cardID: String) -> Card? {
        if let card = state.drawPile.first(where: { $0.id == cardID }) { return card }
        if let card = state.discardPile.first(where: { $0.id == cardID }) { return card }
        for hand in state.hands.values {
            if let card = hand.first(where: { $0.id == cardID }) { return card }
        }
        return nil
    }

    private func removeCard(_ cardID: String) -> Card? {
        if let index = state.drawPile.firstIndex(where: { $0.id == cardID }) {
            return state.drawPile.remove(at: index)
        }
        if let index = state.discardPile.firstIndex(where: { $0.id == cardID }) {
            return state.discardPile.remove(at: index)
        }
        for (seat, hand) in state.hands {
            if let index = hand.firstIndex(where: { $0.id == cardID }) {
                var updated = hand
                let card = updated.remove(at: index)
                state.hands[seat] = updated
                return card
            }
        }
        return nil
    }
}
