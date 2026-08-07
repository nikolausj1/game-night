import Foundation

/// Classic 2-player cribbage to 121, no muggins. Seats are always exactly
/// 0 and 1 (no lobby/seating concept — `CribbageEngine` is a standalone
/// reducer, separate from `HostEngine`/`GameKind`).
///
/// Reasons attached to `CribbageEvent.pointsScored`. Pegging uses `fifteen`,
/// `pair`, `run`, `go`, `thirtyOne`, `lastCard`. The show (post-pegging
/// counting) uses `heels`, `showFifteen`, `showPair`, `showRun`, `flush`,
/// `nobs`. `pair`/`showPair` carry no count — the event's `points` field
/// (2/6/12) already conveys pair vs. trips vs. quads; `run`/`showRun`/
/// `flush` carry the length/size since that isn't otherwise recoverable
/// from `points` alone once multiplicities are in play (e.g. a double run
/// scores 2× the per-run points, same `points` shape as a single bigger
/// run would take for a different length).
public enum CribbageScoreReason: Codable, Sendable, Equatable {
    case fifteen
    case pair
    case run(Int)
    case go
    case thirtyOne
    case lastCard
    case heels
    case showFifteen
    case showPair
    case showRun(Int)
    /// `Int` is the flush size — 4 (hand only) or 5 (starter matches too;
    /// always 5 for a scoring crib flush, since a crib flush requires all
    /// five cards to match).
    case flush(Int)
    case nobs
}

/// One scoring line in a show breakdown — one entry per *category*
/// (fifteens, pairs, the run, flush, nobs), not one per individual
/// combination. E.g. a double run of 4 is a single `showRun(4)` entry
/// worth 10 points (2 combinations × 4 + implied by the pair, folded into
/// the `showPair` entry separately) — see `CribbageScoring.scoreShow`.
public struct CribbageScoreEntry: Codable, Sendable, Equatable {
    public let reason: CribbageScoreReason
    public let points: Int

    public init(reason: CribbageScoreReason, points: Int) {
        self.reason = reason
        self.points = points
    }
}

/// Which pile `handCounted` is reporting on.
public enum CribbageCountSource: Codable, Sendable, Equatable {
    case hand, crib
}

/// Actions a phone/table can take against a `CribbageEngine`.
public enum CribbageAction: Codable, Sendable, Equatable {
    /// Discard exactly 2 cards (by ID) from the caller's 6-card hand into
    /// the dealer's crib. Legal only during `.discarding`, once per seat.
    case discardToCrib(cards: [String])
    /// Play one card (by ID) from the caller's pegging hand. Legal only on
    /// the caller's `pegging.turnSeat` during `.pegging`, and only when it
    /// doesn't push the count past 31.
    case playCard(cardID: String)
    /// Present for API completeness only — see the "auto-go" design note
    /// on `CribbageEngine`. Always rejected: the engine resolves every
    /// stuck position (and scores the go/last-card point) automatically as
    /// a side effect of the preceding `playCard`, so a caller can never
    /// legitimately observe itself stuck with `declareGo` to send.
    case declareGo
    /// Deal the next hand (dealer alternates). Legal only once the
    /// previous hand's show has fully resolved (`.handComplete`) — the
    /// engine never auto-deals so the UI can hold the score screen up as
    /// long as it likes between hands.
    case advance
}

/// Emitted by `CribbageEngine.apply` for UI/announcer reactions.
public enum CribbageEvent: Codable, Sendable, Equatable {
    /// A new hand was dealt (6 cards each); `dealerSeat` is who deals it.
    case dealt(dealerSeat: Int)
    /// `seat`'s 2 discards landed in the crib. Card identities aren't
    /// included — the crib stays secret until `cribRevealed` at the show.
    case discarded(seat: Int)
    /// Both seats have discarded; the crib is set at 4 cards.
    case cribComplete
    /// The starter card was cut (revealed to both seats immediately).
    case starterCut(Card)
    /// One scoring event, pegging or show. `reason` disambiguates what it
    /// was for; see `CribbageScoreReason`.
    case pointsScored(seat: Int, reason: CribbageScoreReason, points: Int)
    /// `seat` pegged `card`, bringing the running count to `count`.
    case cardPlayed(seat: Int, card: Card, count: Int)
    /// Pegging is over (both hands empty) — the show is up next.
    case pegComplete
    /// The crib's 4 cards, revealed for counting at the show.
    case cribRevealed([Card])
    /// One pile (`seat`'s hand, or the dealer's crib via `source == .crib`)
    /// has finished counting at the show. `points` is the total; `breakdown`
    /// is one `CribbageScoreEntry` per scoring category found.
    case handCounted(seat: Int, source: CribbageCountSource, points: Int, breakdown: [CribbageScoreEntry])
    /// `seat` reached 121 and won immediately — this can land mid-pegging
    /// or mid-show, cutting the rest of that hand off unplayed/uncounted.
    /// `skunk` is cosmetic narration only: true when the loser was still
    /// under 91.
    case gameWon(seat: Int, skunk: Bool)
    /// A rejected action changed nothing.
    case illegalAttempt(seat: Int, reason: String)
}

/// One pegged card, in play order within the current count segment.
public struct CribbagePeggedPlay: Codable, Sendable, Equatable {
    public let seat: Int
    public let card: Card

    public init(seat: Int, card: Card) {
        self.seat = seat
        self.card = card
    }
}

/// Live pegging state — the "current segment" since the count last reset
/// (hand start, a `go`/`lastCard`, or a `thirtyOne`).
public struct CribbagePeggingState: Codable, Sendable, Equatable {
    public var sequence: [CribbagePeggedPlay]
    public var count: Int
    public var turnSeat: Int
    /// Who played the most recently pegged card in this segment — the
    /// go/last-card point (when the segment ends because the *other* seat
    /// is stuck) goes here. `nil` only at the very start of a fresh
    /// segment, before anyone in it has played.
    public var lastPlayerSeat: Int?

    public init(sequence: [CribbagePeggedPlay], count: Int, turnSeat: Int, lastPlayerSeat: Int?) {
        self.sequence = sequence
        self.count = count
        self.turnSeat = turnSeat
        self.lastPlayerSeat = lastPlayerSeat
    }
}

public enum CribbagePhase: Codable, Sendable, Equatable {
    /// 6 cards each are on the table; waiting on both seats'
    /// `discardToCrib`.
    case discarding
    /// The crib is set, the starter is cut; seats alternate `playCard`
    /// (non-dealer leads) until both pegging hands are empty.
    case pegging
    /// The show has fully resolved (or was cut short by a win) and nobody
    /// has won yet. Waiting on `.advance` to deal the next hand.
    case handComplete
    /// Someone reached 121. Terminal — no further actions are accepted.
    case gameOver
}

/// The authoritative cribbage table state. Codable, Equatable — same
/// conventions as `GameState`. Scores are stored directly (unlike
/// `GameState`, which derives them from round history) because cribbage
/// scoring happens continuously, card by card, not just at round
/// boundaries.
public struct CribbageState: Codable, Sendable, Equatable {
    public var seed: UInt64
    /// `seed &+ dealSerial` at the moment the *current* hand was dealt —
    /// kept so the starter cut can deterministically re-derive the exact
    /// same shuffle (index 12 of it) without having to carry the leftover
    /// 40-card deck around in state.
    public var dealShuffleSeed: UInt64
    public var scores: [Int: Int]
    public var dealerSeat: Int
    public var phase: CribbagePhase
    /// During `.discarding`: each seat's live 6-card hand, shrinking to 4
    /// as discards land. During `.pegging`: each seat's remaining
    /// unplayed pegging cards, shrinking to 0. Irrelevant (and empty)
    /// once `.handComplete`/`.gameOver`.
    public var hands: [Int: [Card]]
    /// Frozen snapshot of each seat's 4-card hand, taken the instant both
    /// discards land — pegging mutates `hands`, but the show needs the
    /// original 4 cards to count against the starter.
    public var postDiscardHands: [Int: [Card]]
    public var crib: [Card]
    public var discardsSubmitted: Set<Int>
    public var starter: Card?
    /// Present only during `.pegging`.
    public var pegging: CribbagePeggingState?
    /// Hands dealt so far this game (1-based once the first deal lands).
    public var handNumber: Int
    public var winnerSeat: Int?
    public var skunk: Bool?

    public init(
        seed: UInt64,
        dealShuffleSeed: UInt64,
        scores: [Int: Int],
        dealerSeat: Int,
        phase: CribbagePhase,
        hands: [Int: [Card]],
        postDiscardHands: [Int: [Card]],
        crib: [Card],
        discardsSubmitted: Set<Int>,
        starter: Card?,
        pegging: CribbagePeggingState?,
        handNumber: Int,
        winnerSeat: Int? = nil,
        skunk: Bool? = nil
    ) {
        self.seed = seed
        self.dealShuffleSeed = dealShuffleSeed
        self.scores = scores
        self.dealerSeat = dealerSeat
        self.phase = phase
        self.hands = hands
        self.postDiscardHands = postDiscardHands
        self.crib = crib
        self.discardsSubmitted = discardsSubmitted
        self.starter = starter
        self.pegging = pegging
        self.handNumber = handNumber
        self.winnerSeat = winnerSeat
        self.skunk = skunk
    }
}

/// What one phone is allowed to see: full public state plus only its own
/// hand. Mirrors `GameState.snapshot(for:)`'s redaction shape.
public struct CribbageSnapshot: Codable, Sendable, Equatable {
    public let mySeat: Int
    public let dealerSeat: Int
    public let phase: CribbagePhase
    public let scores: [Int: Int]
    public let myHand: [Card]
    public let opponentHandCount: Int
    public let iHaveDiscarded: Bool
    public let opponentHasDiscarded: Bool
    /// 0, 2, or 4 — never reveals which cards, just the pile size.
    public let cribCount: Int
    public let starter: Card?
    /// Fully public once pegging starts — both seats always see every
    /// pegged card.
    public let pegSequence: [CribbagePeggedPlay]
    public let pegCount: Int
    /// `nil` outside `.pegging`.
    public let turnSeat: Int?
    /// Empty until the crib is revealed at the show (`.handComplete` or
    /// `.gameOver`); the full 4 cards after.
    public let crib: [Card]
    public let winnerSeat: Int?
    public let skunk: Bool?

    public init(
        mySeat: Int,
        dealerSeat: Int,
        phase: CribbagePhase,
        scores: [Int: Int],
        myHand: [Card],
        opponentHandCount: Int,
        iHaveDiscarded: Bool,
        opponentHasDiscarded: Bool,
        cribCount: Int,
        starter: Card?,
        pegSequence: [CribbagePeggedPlay],
        pegCount: Int,
        turnSeat: Int?,
        crib: [Card],
        winnerSeat: Int?,
        skunk: Bool?
    ) {
        self.mySeat = mySeat
        self.dealerSeat = dealerSeat
        self.phase = phase
        self.scores = scores
        self.myHand = myHand
        self.opponentHandCount = opponentHandCount
        self.iHaveDiscarded = iHaveDiscarded
        self.opponentHasDiscarded = opponentHasDiscarded
        self.cribCount = cribCount
        self.starter = starter
        self.pegSequence = pegSequence
        self.pegCount = pegCount
        self.turnSeat = turnSeat
        self.crib = crib
        self.winnerSeat = winnerSeat
        self.skunk = skunk
    }
}

public extension CribbageState {
    /// Redacted view for one seat — never leaks the opponent's hand or the
    /// crib's contents before it's revealed at the show.
    func snapshot(for seat: Int) -> CribbageSnapshot {
        let opponent = 1 - seat
        let cribVisible = phase == .handComplete || phase == .gameOver
        return CribbageSnapshot(
            mySeat: seat,
            dealerSeat: dealerSeat,
            phase: phase,
            scores: scores,
            myHand: hands[seat] ?? [],
            opponentHandCount: hands[opponent]?.count ?? 0,
            iHaveDiscarded: discardsSubmitted.contains(seat),
            opponentHasDiscarded: discardsSubmitted.contains(opponent),
            cribCount: crib.count,
            starter: starter,
            pegSequence: pegging?.sequence ?? [],
            pegCount: pegging?.count ?? 0,
            turnSeat: pegging?.turnSeat,
            crib: cribVisible ? crib : [],
            winnerSeat: winnerSeat,
            skunk: skunk
        )
    }
}
