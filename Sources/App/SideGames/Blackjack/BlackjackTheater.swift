import SwiftUI

// MARK: - What the felt is currently SHOWING
//
// The engine's state is always the truth, but it runs ahead of the felt: a
// single `apply` deals a whole round or plays the dealer's whole turn. The
// theater keeps a separate display model and replays the engine's events
// onto it, one timed beat at a time. When the queue goes quiet it checks the
// display against the engine's snapshot and silently repairs any drift, so a
// missed event can never leave the table lying.

/// Where a chip stack can fly from/to. Resolved to points by the layout.
enum BJAnchor: Hashable {
    case dealerRack
    case spot(seat: Int, hand: Int)
    case playerRack(seat: Int)
}

struct BJCardSlot: Identifiable, Equatable {
    /// View identity. The card's own id, except the hole card, whose slot id
    /// is fixed at the deal so the same view flips when it is revealed.
    let id: String
    var card: Card
    var faceUp: Bool
    /// Where the card flew in from.
    var origin: Origin = .shoe
    /// A doubled hand's last card lies across the others.
    var sideways = false

    enum Origin: Equatable {
        case shoe
        case slot(seat: Int, hand: Int, index: Int, handCount: Int)
    }
}

struct BJHandDisplay: Equatable {
    var cards: [BJCardSlot] = []
    /// The wager (for labels).
    var bet = 0
    /// Chips physically sitting on the betting spot right now.
    var betShown = 0
    var doubled = false
    var finished = false
    var tag: BJTag?
}

struct BJTag: Equatable {
    enum Style { case win, lose, push, blackjack, neutral }
    var text: String
    var style: Style
}

struct BJSeatDisplay: Equatable {
    var chips: Int
    var hands: [BJHandDisplay] = []
    var sittingOut = false
    var isOut = false
    var insurance = 0
    /// Transient "HIT" / "STAND" / "DOUBLE" the bot or player just chose.
    var actionTag: String?
}

struct BJDisplay: Equatable {
    var seats: [BJSeatDisplay] = []
    var dealer: [BJCardSlot] = []
    var dealerTag: BJTag?
    var round = 1
    var activeSeat: Int?
    var activeHand = 0
    var statusOverride: String?
    var trayCount = 0
    var sessionOver = false
}

struct BJCallout: Identifiable, Equatable {
    enum Style { case gold, crimson, ivory }
    enum Anchor: Equatable { case seat(Int), dealer, center }
    let id: Int
    var text: String
    var style: Style
    var anchor: Anchor
}

struct BJFlightItem: Identifiable, Equatable {
    let id: Int
    var from: BJAnchor
    var to: BJAnchor
    var amount: Int
    var duration: Double
}

extension BJDisplay {
    /// The display that matches the engine right now, with nothing in flight.
    init(snapshot s: BlackjackSnapshot) {
        round = s.roundNumber
        activeSeat = s.phase == .playing ? s.activeSeat : nil
        activeHand = s.activeHand
        sessionOver = s.phase == .sessionOver
        seats = s.seats.map { seat in
            var d = BJSeatDisplay(chips: seat.chips)
            d.sittingOut = seat.sittingOut
            d.isOut = seat.isOut
            d.insurance = seat.insuranceBet
            let settled = s.phase == .roundComplete || s.phase == .sessionOver
            d.hands = seat.hands.map { h in
                var hd = BJHandDisplay()
                hd.cards = h.cards.enumerated().map { i, c in
                    BJCardSlot(id: c.id, card: c, faceUp: true,
                               sideways: h.isDoubled && i == h.cards.count - 1)
                }
                hd.bet = h.bet
                hd.betShown = (settled && h.outcome != nil) ? 0 : h.bet
                hd.doubled = h.isDoubled
                hd.finished = h.isFinished
                if let o = h.outcome {
                    hd.tag = BJDisplay.tag(for: o, net: h.payout - h.bet)
                }
                return hd
            }
            return d
        }
        dealer = s.dealerCards.map { BJCardSlot(id: $0.id, card: $0, faceUp: true) }
        if s.dealerHoleHidden {
            dealer.append(BJDisplay.holeSlot(round: s.roundNumber))
        }
        trayCount = 0
    }

    static func holeSlot(round: Int) -> BJCardSlot {
        BJCardSlot(id: "bj-hole-\(round)",
                   card: Card(id: "bj-hole-\(round)", kind: .standard(suit: .spades, rank: 2)),
                   faceUp: false)
    }

    static func tag(for o: BlackjackOutcome, net: Int) -> BJTag {
        let text = BlackjackText.outcomeTag(o, net: net)
        switch o {
        case .blackjack: return BJTag(text: text, style: .blackjack)
        case .win: return BJTag(text: text, style: .win)
        case .push: return BJTag(text: text, style: .push)
        case .lose, .bust, .surrender: return BJTag(text: text, style: .lose)
        }
    }

    /// Card ids on the felt, per seat/hand, and dealer — drift check.
    var cardSignature: [String] {
        var out: [String] = []
        for (s, seat) in seats.enumerated() {
            for (h, hand) in seat.hands.enumerated() {
                out.append("\(s).\(h):" + hand.cards.map(\.id).joined(separator: ","))
            }
        }
        out.append("D:" + dealer.map { $0.faceUp ? $0.card.id : "down" }.joined(separator: ","))
        return out
    }
}

// MARK: - Motion constants shared by the theater and the felt

enum BJMotion {
    static let tossDuration = 0.46
    static let tossCurve = Animation.timingCurve(0.25, 0.10, 0.30, 1.0, duration: tossDuration)
    static let flipDuration = 0.62
    static let chipFlight = 0.46
}

// MARK: - The theater

@Observable
final class BlackjackTheater {
    private(set) var display = BJDisplay()
    /// Card id -> flight progress 0...1 (absent = home).
    private(set) var progress: [String: CGFloat] = [:]
    private(set) var flights: [BJFlightItem] = []
    private(set) var flightProgress: [Int: CGFloat] = [:]
    private(set) var callouts: [BJCallout] = []
    /// 0...1: the dealer sweeping the table's cards to the tray.
    private(set) var sweep: CGFloat = 0
    /// Counts up per card out of the shoe; the shoe's card edge slides on it.
    private(set) var shoeKick = 0
    private(set) var peeking = false
    /// Counts up per natural blackjack; drives the gold burst.
    private(set) var fanfare = 0
    /// Nothing queued and nothing animating.
    private(set) var idle = true

    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private weak var host: BlackjackHost?
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var queueFreeAt = Date()
    @ObservationIgnored private var idleAt = Date()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var holeSlotID: String?

    // MARK: lifecycle

    func attach(_ host: BlackjackHost, reduceMotion: Bool) {
        generation += 1
        self.host = host
        self.reduceMotion = reduceMotion
        progress = [:]
        flights = []
        flightProgress = [:]
        callouts = []
        sweep = 0
        peeking = false
        display = BJDisplay(snapshot: host.engine.state.tableSnapshot())
        holeSlotID = display.dealer.first { !$0.faceUp }?.id
        lastSeq = host.latestSeq
        queueFreeAt = Date()
        idleAt = Date()
        idle = true
    }

    func detach() {
        generation += 1
    }

    /// Call whenever the host's `version` changes.
    func consume() {
        guard let host else { return }
        for batch in host.batches(after: lastSeq) {
            lastSeq = batch.seq
            guard BlackjackTimeline.isVisible(batch.events) else { continue }
            enqueue(batch.events)
        }
    }

    private func enqueue(_ events: [BlackjackEvent]) {
        let sched = BlackjackTimeline.schedule(events, speed: reduceMotion ? 1.7 : 1)
        let start = max(Date(), queueFreeAt)
        let lead = start.timeIntervalSinceNow
        idle = false
        for beat in sched.beats {
            let e = beat.event
            schedule(after: lead + beat.at) { [weak self] in self?.apply(e) }
        }
        queueFreeAt = start.addingTimeInterval(sched.advance)
        idleAt = max(idleAt, start.addingTimeInterval(sched.total))
        let wait = idleAt.timeIntervalSinceNow + 0.08
        schedule(after: wait) { [weak self] in self?.settleIfQuiet() }
    }

    private func schedule(after delay: Double, _ work: @escaping () -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, self.generation == gen else { return }
            work()
        }
    }

    /// Queue drained: mark idle and repair any drift against the engine.
    private func settleIfQuiet() {
        guard Date() >= idleAt else { return }
        idle = true
        guard let host else { return }
        let truth = BJDisplay(snapshot: host.engine.state.tableSnapshot())
        let off = truth.cardSignature != display.cardSignature
            || truth.seats.map(\.chips) != display.seats.map(\.chips)
            || truth.sessionOver != display.sessionOver
        if off {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                var repaired = truth
                repaired.trayCount = display.trayCount
                display = repaired
                holeSlotID = repaired.dealer.first { !$0.faceUp }?.id
                progress = [:]
            }
        }
    }

    // MARK: event -> theater

    private func apply(_ e: BlackjackEvent) {
        let sfx = TableSFX.shared
        switch e {
        case .roundStarted(let r):
            sweepAway()
            display.round = r
            display.statusOverride = nil
            display.dealerTag = nil

        case .shoeReshuffled:
            display.statusOverride = "Shuffling the shoe"
            display.trayCount = 0
            shoeKick += 3
            sfx.play(.shuffle)
            callout("SHUFFLE", .ivory, .center, hold: 1.4)
            schedule(after: 1.5) { [weak self] in self?.display.statusOverride = nil }

        case .betPlaced(let seat, let amount):
            guard valid(seat) else { return }
            display.seats[seat].hands = [BJHandDisplay(bet: amount)]
            display.seats[seat].chips -= amount
            fly(.playerRack(seat: seat), .spot(seat: seat, hand: 0), amount) { [weak self] in
                guard let self, self.valid(seat), !self.display.seats[seat].hands.isEmpty else { return }
                self.display.seats[seat].hands[0].betShown = amount
                self.chipSound(strength: 0.5)
            }

        case .satOut(let seat):
            guard valid(seat) else { return }
            display.seats[seat].sittingOut = true

        case .cardDealt(let seat, let h, let card):
            guard valid(seat) else { return }
            ensureHand(seat, h)
            addCard(card, toSeat: seat, hand: h)

        case .dealerUpCard(let card):
            deal(BJCardSlot(id: card.id, card: card, faceUp: true), toDealer: true)

        case .dealerHoleDealt:
            let hole = BJDisplay.holeSlot(round: display.round)
            holeSlotID = hole.id
            deal(hole, toDealer: true)

        case .playerBlackjack(let seat):
            guard valid(seat) else { return }
            fanfare += 1
            callout("BLACKJACK!", .gold, .seat(seat), hold: 1.7)
            sfx.play(.fanfareWin)

        case .insuranceOffered:
            display.statusOverride = "Insurance?"

        case .insuranceTaken(let seat, let amount):
            guard valid(seat) else { return }
            display.seats[seat].insurance = amount
            display.seats[seat].chips -= amount
            chipSound(strength: 0.4)

        case .insuranceDeclined:
            break

        case .insuranceSettled(let seat, let payout, let net):
            guard valid(seat) else { return }
            display.seats[seat].insurance = 0
            display.seats[seat].chips += payout
            if net > 0 { callout("INSURANCE +\(net)", .gold, .seat(seat), hold: 1.2); chipSound(strength: 0.6) }

        case .dealerPeek:
            display.statusOverride = "Dealer peeks"
            peeking = true
            schedule(after: 0.9) { [weak self] in
                self?.peeking = false
                self?.display.statusOverride = nil
            }

        case .turnStarted(let seat, let h):
            display.activeSeat = seat
            display.activeHand = h
            display.statusOverride = nil
            for i in display.seats.indices { display.seats[i].actionTag = nil }

        case .hit(let seat, let h, let card):
            guard valid(seat) else { return }
            actionTag(seat, "HIT")
            ensureHand(seat, h)
            addCard(card, toSeat: seat, hand: h)

        case .stand(let seat, let h, let auto):
            guard valid(seat) else { return }
            if !auto { actionTag(seat, "STAND") }
            if display.seats[seat].hands.indices.contains(h) {
                display.seats[seat].hands[h].finished = true
            }
            if display.activeSeat == seat { display.activeSeat = nil }

        case .doubled(let seat, let h, let card, let newBet):
            guard valid(seat), display.seats[seat].hands.indices.contains(h) else { return }
            actionTag(seat, "DOUBLE")
            let extra = max(0, newBet - display.seats[seat].hands[h].bet)
            display.seats[seat].hands[h].bet = newBet
            display.seats[seat].hands[h].doubled = true
            display.seats[seat].chips -= extra
            fly(.playerRack(seat: seat), .spot(seat: seat, hand: h), extra) { [weak self] in
                guard let self, self.valid(seat), self.display.seats[seat].hands.indices.contains(h) else { return }
                self.display.seats[seat].hands[h].betShown = newBet
                self.chipSound(strength: 0.6)
            }
            schedule(after: 0.35) { [weak self] in
                guard let self, self.valid(seat), self.display.seats[seat].hands.indices.contains(h) else { return }
                self.addCard(card, toSeat: seat, hand: h, sideways: true)
                self.display.seats[seat].hands[h].finished = true
            }

        case .split(let seat):
            guard valid(seat), let old = display.seats[seat].hands.first, old.cards.count == 2 else { return }
            actionTag(seat, "SPLIT")
            var a = BJHandDisplay(bet: old.bet), b = BJHandDisplay(bet: old.bet)
            a.betShown = old.betShown
            var c0 = old.cards[0], c1 = old.cards[1]
            c0.origin = .slot(seat: seat, hand: 0, index: 0, handCount: 1)
            c1.origin = .slot(seat: seat, hand: 0, index: 1, handCount: 1)
            a.cards = [c0]; b.cards = [c1]
            display.seats[seat].hands = [a, b]
            display.seats[seat].chips -= old.bet
            beginToss(c0.id); beginToss(c1.id)
            fly(.playerRack(seat: seat), .spot(seat: seat, hand: 1), old.bet) { [weak self] in
                guard let self, self.valid(seat), self.display.seats[seat].hands.count > 1 else { return }
                self.display.seats[seat].hands[1].betShown = old.bet
                self.chipSound(strength: 0.5)
            }

        case .surrendered(let seat, _):
            guard valid(seat) else { return }
            actionTag(seat, "SURRENDER")
            display.activeSeat = nil

        case .bust(let seat, let h, _):
            guard valid(seat) else { return }
            if display.seats[seat].hands.indices.contains(h) {
                display.seats[seat].hands[h].finished = true
                display.seats[seat].hands[h].tag = BJTag(text: "BUST", style: .lose)
            }
            if display.activeSeat == seat { display.activeSeat = nil }
            callout("BUST", .crimson, .seat(seat), hold: 1.3)
            sfx.play(.tableKnock, intensity: 0.8)

        case .dealerRevealed(let card, let total):
            display.activeSeat = nil
            if let id = holeSlotID, let i = display.dealer.firstIndex(where: { $0.id == id }) {
                display.dealer[i].card = card
                display.dealer[i].faceUp = true
            }
            display.statusOverride = "Dealer shows \(total)"
            sfx.play(.cardFlip)

        case .dealerDrew(let card, _):
            display.statusOverride = nil
            deal(BJCardSlot(id: card.id, card: card, faceUp: true), toDealer: true)

        case .dealerStands(let total):
            display.dealerTag = BJTag(text: "\(total)", style: .neutral)
            display.statusOverride = "Dealer stands on \(total)"

        case .dealerBust(let total):
            display.dealerTag = BJTag(text: "BUST \(total)", style: .lose)
            display.statusOverride = nil
            callout("DEALER BUSTS", .gold, .dealer, hold: 1.6)
            sfx.play(.fanfareWin, intensity: 0.5)

        case .dealerBlackjack:
            display.dealerTag = BJTag(text: "BLACKJACK", style: .blackjack)
            callout("DEALER BLACKJACK", .crimson, .dealer, hold: 1.6)
            sfx.play(.tableKnock, intensity: 1.0)

        case .handSettled(let seat, let h, let outcome, let bet, let payout, let net):
            guard valid(seat), display.seats[seat].hands.indices.contains(h) else { return }
            settleHand(seat: seat, hand: h, outcome: outcome, bet: bet, payout: payout, net: net)

        case .roundComplete:
            display.activeSeat = nil
            display.statusOverride = nil

        case .seatBroke(let seat):
            guard valid(seat) else { return }
            display.seats[seat].isOut = true
            callout("OUT OF CHIPS", .ivory, .seat(seat), hold: 1.8)

        case .sessionOver:
            display.sessionOver = true

        case .illegalAttempt:
            break
        }
    }

    // MARK: pieces

    private func valid(_ seat: Int) -> Bool { display.seats.indices.contains(seat) }

    private func ensureHand(_ seat: Int, _ h: Int) {
        while display.seats[seat].hands.count <= h {
            var hand = BJHandDisplay()
            hand.bet = display.seats[seat].hands.first?.bet ?? 0
            display.seats[seat].hands.append(hand)
        }
    }

    private func addCard(_ card: Card, toSeat seat: Int, hand h: Int, sideways: Bool = false) {
        var slot = BJCardSlot(id: card.id, card: card, faceUp: true)
        slot.sideways = sideways
        display.seats[seat].hands[h].cards.append(slot)
        shoeKick += 1
        beginToss(slot.id)
    }

    private func deal(_ slot: BJCardSlot, toDealer: Bool) {
        display.dealer.append(slot)
        shoeKick += 1
        beginToss(slot.id)
    }

    private func actionTag(_ seat: Int, _ text: String) {
        display.seats[seat].actionTag = text
        schedule(after: 1.1) { [weak self] in
            guard let self, self.valid(seat), self.display.seats[seat].actionTag == text else { return }
            self.display.seats[seat].actionTag = nil
        }
    }

    /// One single-progress flight from the shoe (or a slot) onto the felt.
    private func beginToss(_ id: String) {
        if reduceMotion {
            progress[id] = 1
            TableSFX.shared.play(.cardSlide, intensity: 0.5)
            return
        }
        progress[id] = 0
        let gen = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            withAnimation(BJMotion.tossCurve) { self.progress[id] = 1 }
        }
        schedule(after: BJMotion.tossDuration * 0.55) {
            TableSFX.shared.play(.cardSlide, intensity: 0.55)
        }
    }

    private func sweepAway() {
        let n = display.seats.reduce(0) { $0 + $1.hands.reduce(0) { $0 + $1.cards.count } } + display.dealer.count
        guard n > 0 else {
            for i in display.seats.indices { resetSeatForRound(i) }
            return
        }
        TableSFX.shared.play(.trickSweep, intensity: 0.7)
        if reduceMotion { sweep = 1 } else { withAnimation(.easeIn(duration: 0.5)) { sweep = 1 } }
        schedule(after: reduceMotion ? 0.05 : 0.52) { [weak self] in
            guard let self else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                self.display.trayCount += n
                self.display.dealer = []
                for i in self.display.seats.indices { self.resetSeatForRound(i) }
                self.progress = [:]
                self.holeSlotID = nil
                self.sweep = 0
            }
        }
    }

    private func resetSeatForRound(_ i: Int) {
        display.seats[i].hands = []
        display.seats[i].sittingOut = false
        display.seats[i].insurance = 0
        display.seats[i].actionTag = nil
    }

    private func settleHand(seat: Int, hand h: Int, outcome: BlackjackOutcome,
                            bet: Int, payout: Int, net: Int) {
        let spot = BJAnchor.spot(seat: seat, hand: h)
        let rack = BJAnchor.playerRack(seat: seat)
        display.seats[seat].hands[h].tag = BJDisplay.tag(for: outcome, net: net)
        display.seats[seat].hands[h].finished = true
        if outcome == .blackjack { callout("+\(net)", .gold, .seat(seat), hold: 1.4) }
        else if outcome == .win { callout("+\(net)", .ivory, .seat(seat), hold: 1.2) }

        let dealerPays = max(0, payout - bet)
        let dealerTakes = max(0, bet - payout)

        func returnToPlayer() {
            guard payout > 0 else { return }
            display.seats[seat].hands[h].betShown = 0
            fly(spot, rack, payout) { [weak self] in
                guard let self, self.valid(seat) else { return }
                self.display.seats[seat].chips += payout
                self.chipSound(strength: 0.55)
            }
        }

        if dealerPays > 0 {
            // The house pays: its chips slide to the spot, then the whole
            // pile goes to the player.
            fly(.dealerRack, spot, dealerPays) { [weak self] in
                guard let self, self.valid(seat), self.display.seats[seat].hands.indices.contains(h) else { return }
                self.display.seats[seat].hands[h].betShown = payout
                self.chipSound(strength: 0.7)
                self.schedule(after: 0.35) { returnToPlayer() }
            }
        } else if dealerTakes > 0 {
            // The house takes its share (all of a lost bet; half of a surrender).
            if payout > 0 {
                display.seats[seat].hands[h].betShown = payout
                fly(spot, .dealerRack, dealerTakes) { [weak self] in
                    self?.chipSound(strength: 0.5)
                    self?.schedule(after: 0.3) { returnToPlayer() }
                }
            } else {
                display.seats[seat].hands[h].betShown = 0
                fly(spot, .dealerRack, bet) { [weak self] in self?.chipSound(strength: 0.5) }
            }
        } else {
            // A push: the stake simply goes home.
            schedule(after: 0.3) { returnToPlayer() }
        }
    }

    // MARK: chips + callouts

    private func fly(_ from: BJAnchor, _ to: BJAnchor, _ amount: Int,
                     arrive: @escaping () -> Void) {
        guard amount > 0 else { arrive(); return }
        if reduceMotion { arrive(); return }
        nextID += 1
        let id = nextID
        flights.append(BJFlightItem(id: id, from: from, to: to, amount: amount, duration: BJMotion.chipFlight))
        flightProgress[id] = 0
        TableSFX.shared.play(.chipPass, intensity: 0.6)
        let gen = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            withAnimation(.timingCurve(0.3, 0.1, 0.25, 1.0, duration: BJMotion.chipFlight)) {
                self.flightProgress[id] = 1
            }
        }
        schedule(after: BJMotion.chipFlight + 0.02) { [weak self] in
            guard let self else { return }
            arrive()
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                self.flights.removeAll { $0.id == id }
                self.flightProgress[id] = nil
            }
        }
    }

    private func chipSound(strength: Double) {
        TableSFX.shared.play(.chipPlace, intensity: 0.7 + strength * 0.5)
        TableSFX.shared.playCoinClink(strength: strength)
    }

    private func callout(_ text: String, _ style: BJCallout.Style, _ anchor: BJCallout.Anchor, hold: Double) {
        nextID += 1
        let c = BJCallout(id: nextID, text: text, style: style, anchor: anchor)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { callouts.append(c) }
        schedule(after: hold) { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.callouts.removeAll { $0.id == c.id } }
        }
    }
}
