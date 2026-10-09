import Foundation

/// Liar's Dice for 2-6 players, 5 dice each under a private cup. On this
/// platform EACH PHONE hides its own dice, so the engine never rolls on its
/// own: roll RESULTS arrive as `setDice` actions (from the phone-cup roll),
/// with `LiarsDiceEngine.rollAll(seed:)` as the helper for bots and tests.
///
/// Rule decisions (see `LiarsDiceRules`):
/// - A bid is (quantity, face). A raise must have a higher quantity, or the
///   same quantity with a higher face. Face 1 ranks LOWEST as a bid.
/// - `wildOnes`: ones count toward every face EXCEPT when the bid itself is
///   on ones (then only ones count). No Perudo ace-conversion rule.
/// - Challenge: bid true (count >= quantity) -> challenger loses a die;
///   bid false -> bidder loses a die. The loser opens the next round.
/// - Spot on (flag): count == quantity exactly -> caller GAINS a die (up to
///   the starting count); otherwise caller loses a die. Caller opens next.
/// - A seat at 0 dice is eliminated; last seat standing wins.

public struct LiarsDiceConfig: Codable, Sendable, Equatable {
    public var diceCount: Int
    public var wildOnes: Bool
    public var spotOnEnabled: Bool

    public init(diceCount: Int = 5, wildOnes: Bool = true, spotOnEnabled: Bool = true) {
        self.diceCount = max(1, diceCount)
        self.wildOnes = wildOnes
        self.spotOnEnabled = spotOnEnabled
    }
}

public struct LiarsDiceBid: Codable, Sendable, Equatable {
    public let seat: Int
    public let quantity: Int
    public let face: Int

    public init(seat: Int, quantity: Int, face: Int) {
        self.seat = seat
        self.quantity = quantity
        self.face = face
    }
}

public enum LiarsDicePhase: String, Codable, Sendable, Equatable {
    /// Waiting on `setDice` from every live seat.
    case awaitingDice
    /// `turnSeat` must bid, challenge, or (flag) spot on.
    case bidding
    /// A challenge/spot-on resolved; dice are public. Waiting on `nextRound`.
    case reveal
    case gameOver
}

public enum LiarsDiceAction: Codable, Sendable, Equatable {
    /// Supply `seat`'s roll (its phone-cup result). Sender must be `seat`.
    case setDice(seat: Int, dice: [Int])
    case bid(quantity: Int, face: Int)
    /// "Liar!" against the standing bid.
    case challenge
    /// "Exactly right" against the standing bid (flag).
    case spotOn
    /// Begin the next round after a reveal. Any seat may send it.
    case nextRound
}

public enum LiarsDiceCallKind: String, Codable, Sendable, Equatable {
    case challenge, spotOn
}

/// The public result of a challenge or spot-on call.
public struct LiarsDiceResolution: Codable, Sendable, Equatable {
    public let kind: LiarsDiceCallKind
    public let caller: Int
    public let bid: LiarsDiceBid
    /// Dice matching the bid (wilds included), counted across the table.
    public let actualCount: Int
    /// Every live seat's dice, revealed.
    public let dice: [Int: [Int]]
    /// Did the call succeed (challenge: bid was false; spot-on: exact).
    public let callSucceeded: Bool
    public let loserSeat: Int?
    public let gainerSeat: Int?
}

public enum LiarsDiceEvent: Codable, Sendable, Equatable {
    case roundStarted(round: Int, starterSeat: Int, diceCounts: [Int])
    /// A seat's dice are in. The VALUES are never in this event.
    case diceSet(seat: Int)
    case allDiceSet(starterSeat: Int)
    case bidMade(seat: Int, quantity: Int, face: Int)
    case challenged(seat: Int, against: Int)
    case spotOnCalled(seat: Int, against: Int)
    /// Public reveal of every live seat's dice.
    case revealed(dice: [Int: [Int]], face: Int, quantity: Int, actualCount: Int)
    case dieLost(seat: Int, remaining: Int)
    case dieGained(seat: Int, remaining: Int)
    case eliminated(seat: Int)
    case gameWon(seat: Int)
    case illegalAttempt(seat: Int, reason: String)
}

public struct LiarsDiceState: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var config: LiarsDiceConfig
    public var phase: LiarsDicePhase
    public var roundNumber: Int
    /// Dice remaining per seat (0 = eliminated).
    public var diceCounts: [Int]
    /// Host-only hidden dice for the current round (seat -> faces). Never
    /// leaves the host except through `snapshot(for:)` (own dice only) or a
    /// reveal.
    public var dice: [Int: [Int]]
    public var bids: [LiarsDiceBid]
    public var turnSeat: Int
    public var starterSeat: Int
    public var lastResolution: LiarsDiceResolution?
    public var winnerSeat: Int?
    public var eliminationOrder: [Int]

    public init(seed: UInt64, seatCount: Int, config: LiarsDiceConfig, starterSeat: Int) {
        self.seed = seed
        self.config = config
        self.phase = .awaitingDice
        self.roundNumber = 1
        self.diceCounts = Array(repeating: config.diceCount, count: seatCount)
        self.dice = [:]
        self.bids = []
        self.turnSeat = starterSeat
        self.starterSeat = starterSeat
        self.lastResolution = nil
        self.winnerSeat = nil
        self.eliminationOrder = []
    }

    public var seatCount: Int { diceCounts.count }
    public var liveSeats: [Int] { diceCounts.indices.filter { diceCounts[$0] > 0 } }
    public var totalDice: Int { diceCounts.reduce(0, +) }
    public var currentBid: LiarsDiceBid? { bids.last }

    /// Next live seat clockwise strictly after `seat`.
    public func nextLiveSeat(after seat: Int) -> Int {
        let n = seatCount
        for step in 1...n {
            let s = (seat + step) % n
            if diceCounts[s] > 0 { return s }
        }
        return seat
    }
}

// MARK: - Rules

public enum LiarsDiceRules {
    /// Dice matching `face` (ones included as wild when `wildOnes` and the
    /// bid is not on ones).
    public static func count(face: Int, in dice: [Int], wildOnes: Bool) -> Int {
        dice.filter { $0 == face || (wildOnes && face != 1 && $0 == 1) }.count
    }

    public static func isLegalBid(quantity: Int, face: Int, over previous: LiarsDiceBid?, totalDice: Int) -> Bool {
        guard (1...6).contains(face), quantity >= 1, quantity <= totalDice else { return false }
        guard let p = previous else { return true }
        return quantity > p.quantity || (quantity == p.quantity && face > p.face)
    }

    public static func legalBids(over previous: LiarsDiceBid?, totalDice: Int) -> [(quantity: Int, face: Int)] {
        var out: [(Int, Int)] = []
        guard totalDice >= 1 else { return [] }
        for q in 1...totalDice {
            for f in 1...6 where isLegalBid(quantity: q, face: f, over: previous, totalDice: totalDice) {
                out.append((q, f))
            }
        }
        return out
    }
}

// MARK: - Snapshot

public enum LiarsDiceActionKind: String, Codable, Sendable, Equatable {
    case setDice, bid, challenge, spotOn, nextRound
}

/// Per-seat view. `myDice` is the seat's own roll; everyone else's dice are
/// absent except in `resolution` after a call. The table's public view uses
/// `mySeat == -1` and an empty `myDice`.
public struct LiarsDiceSnapshot: Codable, Sendable, Equatable {
    public let mySeat: Int
    public let config: LiarsDiceConfig
    public let phase: LiarsDicePhase
    public let roundNumber: Int
    public let diceCounts: [Int]
    public let totalDice: Int
    public let myDice: [Int]
    /// Which live seats have supplied their roll this round.
    public let diceReady: [Bool]
    public let bids: [LiarsDiceBid]
    public let currentBid: LiarsDiceBid?
    public let turnSeat: Int
    /// Present only in `.reveal` / `.gameOver`.
    public let resolution: LiarsDiceResolution?
    public let winnerSeat: Int?
    public let legalActions: [LiarsDiceActionKind]
}

public extension LiarsDiceState {
    func legalActions(for seat: Int) -> [LiarsDiceActionKind] {
        guard seat >= 0, seat < seatCount else { return [] }
        if phase == .reveal { return [.nextRound] }
        guard diceCounts[seat] > 0 else { return [] }
        switch phase {
        case .awaitingDice: return dice[seat] == nil ? [.setDice] : []
        case .bidding:
            guard seat == turnSeat else { return [] }
            var out: [LiarsDiceActionKind] = [.bid]
            if currentBid != nil {
                out.append(.challenge)
                if config.spotOnEnabled { out.append(.spotOn) }
            }
            return out
        case .reveal: return [.nextRound]
        case .gameOver: return []
        }
    }

    func snapshot(for seat: Int) -> LiarsDiceSnapshot {
        let show = phase == .reveal || phase == .gameOver
        return LiarsDiceSnapshot(
            mySeat: seat, config: config, phase: phase, roundNumber: roundNumber,
            diceCounts: diceCounts, totalDice: totalDice,
            myDice: seat >= 0 ? (dice[seat] ?? []) : [],
            diceReady: diceCounts.indices.map { diceCounts[$0] > 0 && dice[$0] != nil },
            bids: bids, currentBid: currentBid, turnSeat: turnSeat,
            resolution: show ? lastResolution : nil, winnerSeat: winnerSeat,
            legalActions: legalActions(for: seat)
        )
    }

    func tableSnapshot() -> LiarsDiceSnapshot { snapshot(for: -1) }
}
