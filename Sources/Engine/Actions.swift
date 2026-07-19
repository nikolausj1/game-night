import Foundation

public enum FreePlayZone: String, Codable, Sendable {
    case table, hand, deck
}

/// Actions a phone (or the table acting for a seat) can take.
public enum PlayerAction: Codable, Sendable, Equatable {
    case placeBid(Int)
    case chooseTrump(Suit)
    case playCard(cardID: String, force: Bool)
    case drawCard
    /// Crazy Eights: pick the suit after playing an eight.
    case declareSuit(Suit)
    /// Free Play: move any visible/owned card between zones. x/y/rotation are
    /// table-layout hints for the host UI; the engine tracks zone membership.
    case freeMoveCard(cardID: String, to: FreePlayZone, x: Double, y: Double, rotation: Double)
    case requestUndo
}

/// Actions only the host iPad can take.
public enum TableAction: Codable, Sendable, Equatable {
    case startGame(GameKind, RulesConfig, seed: UInt64)
    case nextRound
    case nextTrick
    case approveUndo
    case newDeal
}

/// Emitted by the reducer for UI updates and the announcer.
public enum GameEvent: Codable, Sendable, Equatable {
    case dealt
    case bidPlaced(seat: Int, bid: Int)
    case biddingComplete
    case trumpRevealed(Card, Suit?)
    case cardPlayed(seat: Int, card: Card, forced: Bool)
    case trickWon(seat: Int)
    case roundScored
    case gameWon(seat: Int)
    case illegalAttempt(seat: Int, reason: String)
    case undone
    case suitDeclared(Suit)
}
