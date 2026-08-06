import Foundation

public struct Seat: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public var playerName: String
    public var colorIndex: Int
    public var isConnected: Bool
    public var isHost: Bool

    public init(id: Int, playerName: String, colorIndex: Int, isConnected: Bool, isHost: Bool) {
        self.id = id
        self.playerName = playerName
        self.colorIndex = colorIndex
        self.isConnected = isConnected
        self.isHost = isHost
    }
}

public enum Phase: Codable, Sendable, Equatable {
    case lobby
    case dealing
    case bidding
    /// Wizard: dealer picks trump after a wizard flip.
    /// Crazy Eights: the seat that just played an eight picks the suit.
    case choosingTrump(seat: Int)
    case playing
    case trickComplete(winnerSeat: Int)
    case roundComplete
    case gameOver
}

public struct TrickPlay: Codable, Sendable, Equatable {
    public let seat: Int
    public let card: Card
    /// True when the card was played through the illegal-play confirmation
    /// (soft enforcement's "play it anyway").
    public var wasForced: Bool

    public init(seat: Int, card: Card, wasForced: Bool) {
        self.seat = seat
        self.card = card
        self.wasForced = wasForced
    }
}

public struct RoundState: Codable, Sendable, Equatable {
    public var roundNumber: Int
    public var cardsPerPlayer: Int
    public var dealerSeat: Int
    public var trumpCard: Card?
    /// Trick games: the effective trump suit (nil = no trump).
    /// Crazy Eights: the suit declared by the last played eight (nil = match
    /// the top discard directly).
    public var trumpSuit: Suit?
    public var bids: [Int: Int]
    public var tricksWon: [Int: Int]
    public var currentTrick: [TrickPlay]
    public var completedTricks: [[TrickPlay]]
    public var leadSeat: Int
    public var turnSeat: Int
    /// UNO: +1 clockwise, -1 after a reverse. Other games leave it at 1.
    public var direction: Int
    /// UNO: accumulated draw-two / wild-draw-four penalty awaiting the next
    /// player (stack or absorb). Other games leave it at 0.
    public var pendingDraw: Int

    public init(
        roundNumber: Int,
        cardsPerPlayer: Int,
        dealerSeat: Int,
        trumpCard: Card?,
        trumpSuit: Suit?,
        bids: [Int: Int],
        tricksWon: [Int: Int],
        currentTrick: [TrickPlay],
        completedTricks: [[TrickPlay]],
        leadSeat: Int,
        turnSeat: Int,
        direction: Int = 1,
        pendingDraw: Int = 0
    ) {
        self.roundNumber = roundNumber
        self.cardsPerPlayer = cardsPerPlayer
        self.dealerSeat = dealerSeat
        self.trumpCard = trumpCard
        self.trumpSuit = trumpSuit
        self.bids = bids
        self.tricksWon = tricksWon
        self.currentTrick = currentTrick
        self.completedTricks = completedTricks
        self.leadSeat = leadSeat
        self.turnSeat = turnSeat
        self.direction = direction
        self.pendingDraw = pendingDraw
    }

    private enum CodingKeys: String, CodingKey {
        case roundNumber, cardsPerPlayer, dealerSeat, trumpCard, trumpSuit
        case bids, tricksWon, currentTrick, completedTricks, leadSeat, turnSeat
        case direction, pendingDraw
    }

    /// Custom decode so states encoded before the UNO fields existed still
    /// load: `direction` defaults to 1, `pendingDraw` to 0.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roundNumber = try container.decode(Int.self, forKey: .roundNumber)
        cardsPerPlayer = try container.decode(Int.self, forKey: .cardsPerPlayer)
        dealerSeat = try container.decode(Int.self, forKey: .dealerSeat)
        trumpCard = try container.decodeIfPresent(Card.self, forKey: .trumpCard)
        trumpSuit = try container.decodeIfPresent(Suit.self, forKey: .trumpSuit)
        bids = try container.decode([Int: Int].self, forKey: .bids)
        tricksWon = try container.decode([Int: Int].self, forKey: .tricksWon)
        currentTrick = try container.decode([TrickPlay].self, forKey: .currentTrick)
        completedTricks = try container.decode([[TrickPlay]].self, forKey: .completedTricks)
        leadSeat = try container.decode(Int.self, forKey: .leadSeat)
        turnSeat = try container.decode(Int.self, forKey: .turnSeat)
        direction = try container.decodeIfPresent(Int.self, forKey: .direction) ?? 1
        pendingDraw = try container.decodeIfPresent(Int.self, forKey: .pendingDraw) ?? 0
    }
}

public struct CompletedRound: Codable, Sendable, Equatable {
    public let roundNumber: Int
    public let cardsPerPlayer: Int
    public let bids: [Int: Int]
    public let tricksWon: [Int: Int]

    public init(roundNumber: Int, cardsPerPlayer: Int, bids: [Int: Int], tricksWon: [Int: Int]) {
        self.roundNumber = roundNumber
        self.cardsPerPlayer = cardsPerPlayer
        self.bids = bids
        self.tricksWon = tricksWon
    }
}

/// The authoritative table state, owned by the host iPad. Scores are never
/// stored — always derived from `roundHistory` via `Scoring`.
public struct GameState: Codable, Sendable, Equatable {
    public var gameKind: GameKind
    public var rules: RulesConfig
    public var seats: [Seat]
    public var phase: Phase
    public var round: RoundState?
    public var hands: [Int: [Card]]
    public var drawPile: [Card]
    public var discardPile: [Card]
    public var roundHistory: [CompletedRound]
    public var seed: UInt64

    public init(
        gameKind: GameKind,
        rules: RulesConfig,
        seats: [Seat],
        phase: Phase,
        round: RoundState?,
        hands: [Int: [Card]],
        drawPile: [Card],
        discardPile: [Card],
        roundHistory: [CompletedRound],
        seed: UInt64
    ) {
        self.gameKind = gameKind
        self.rules = rules
        self.seats = seats
        self.phase = phase
        self.round = round
        self.hands = hands
        self.drawPile = drawPile
        self.discardPile = discardPile
        self.roundHistory = roundHistory
        self.seed = seed
    }
}

/// What one iPhone is allowed to see: the full public state plus only its
/// own hand. Other hands become counts, the draw pile becomes a count, and
/// the shuffle seed is withheld (it would let a client reconstruct the deck).
public struct ClientSnapshot: Codable, Sendable, Equatable {
    public let gameKind: GameKind
    public let rules: RulesConfig
    public let seats: [Seat]
    public let phase: Phase
    public let round: RoundState?
    public let roundHistory: [CompletedRound]
    public let mySeat: Int
    public let myHand: [Card]
    public let handCounts: [Int: Int]
    public let drawCount: Int
    public let discardPile: [Card]
    /// UNO manual draw-penalty mode: this seat's pending forced-draw count.
    /// 0 when nothing is pending, or when it isn't this seat's turn — a
    /// pending penalty only ever sits on `round.turnSeat`. Mirrors
    /// `round.pendingDraw`, pre-filtered to "is this mine right now" so the
    /// hand UI doesn't have to re-derive that from `round`.
    public let myPendingDraw: Int

    public init(
        gameKind: GameKind,
        rules: RulesConfig,
        seats: [Seat],
        phase: Phase,
        round: RoundState?,
        roundHistory: [CompletedRound],
        mySeat: Int,
        myHand: [Card],
        handCounts: [Int: Int],
        drawCount: Int,
        discardPile: [Card],
        myPendingDraw: Int = 0
    ) {
        self.gameKind = gameKind
        self.rules = rules
        self.seats = seats
        self.phase = phase
        self.round = round
        self.roundHistory = roundHistory
        self.mySeat = mySeat
        self.myHand = myHand
        self.handCounts = handCounts
        self.drawCount = drawCount
        self.discardPile = discardPile
        self.myPendingDraw = myPendingDraw
    }

    private enum CodingKeys: String, CodingKey {
        case gameKind, rules, seats, phase, round, roundHistory, mySeat, myHand
        case handCounts, drawCount, discardPile, myPendingDraw
    }

    /// Older encodes predate `myPendingDraw` (manual draw-penalty mode);
    /// default it to 0 on decode so saved/older-peer snapshots still parse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gameKind = try container.decode(GameKind.self, forKey: .gameKind)
        rules = try container.decode(RulesConfig.self, forKey: .rules)
        seats = try container.decode([Seat].self, forKey: .seats)
        phase = try container.decode(Phase.self, forKey: .phase)
        round = try container.decodeIfPresent(RoundState.self, forKey: .round)
        roundHistory = try container.decode([CompletedRound].self, forKey: .roundHistory)
        mySeat = try container.decode(Int.self, forKey: .mySeat)
        myHand = try container.decode([Card].self, forKey: .myHand)
        handCounts = try container.decode([Int: Int].self, forKey: .handCounts)
        drawCount = try container.decode(Int.self, forKey: .drawCount)
        discardPile = try container.decode([Card].self, forKey: .discardPile)
        myPendingDraw = try container.decodeIfPresent(Int.self, forKey: .myPendingDraw) ?? 0
    }
}

public extension GameState {
    /// Redacted view for one seat. Never leaks other hands or draw-pile
    /// contents; only cards already public (trump flip, current trick,
    /// discards) appear outside `myHand`.
    func snapshot(for seat: Int) -> ClientSnapshot {
        ClientSnapshot(
            gameKind: gameKind,
            rules: rules,
            seats: seats,
            phase: phase,
            round: round,
            roundHistory: roundHistory,
            mySeat: seat,
            myHand: hands[seat] ?? [],
            handCounts: hands.mapValues { $0.count },
            drawCount: drawPile.count,
            discardPile: discardPile,
            myPendingDraw: (round?.turnSeat == seat) ? (round?.pendingDraw ?? 0) : 0
        )
    }
}
