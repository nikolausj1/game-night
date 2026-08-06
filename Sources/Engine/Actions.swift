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
    /// Manual dealing (rules.autoDeal off): pop the top draw-pile card into
    /// this seat's hand. Only valid in `.dealing`, only for seats below the
    /// round's target count; the deal auto-completes when every hand is full.
    case dealCardTo(seat: Int)
    /// Free Play, trump-style peek: pop the top of the draw pile face-up
    /// beside the deck (onto the discard pile). Free play only; a silent
    /// no-op everywhere else and when the draw pile is empty, same as every
    /// other TableAction guard failure.
    case flipTopCard
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
    /// UNO: a play just left this seat holding exactly one card.
    case unoCalled(seat: Int)
    /// UNO: a voluntary draw pulled `count` cards into this seat's hand
    /// (drawUntilPlayable draws more than one when the first few misses are
    /// unplayable). The turn does not pass — the drawer must play next,
    /// unless the deck ran dry first.
    case cardsDrawn(seat: Int, count: Int)
    /// Manual dealing: one card just moved from the draw pile into this
    /// seat's hand via `TableAction.dealCardTo`.
    case cardDealt(seat: Int)
    /// UNO manual draw-penalty mode (`rules.autoDrawPenalty == false`, the
    /// default): a forced `drawCard` against a pending draw-two / wild-draw-
    /// four penalty moved exactly one card into this seat's hand. `remaining`
    /// is what's left on the counter after this card — 0 means the penalty
    /// is now paid and the turn has passed. One event per card, for the
    /// table/hand to animate the same way a real draw looks.
    case penaltyCardDrawn(seat: Int, remaining: Int)
    /// Free Play: `TableAction.flipTopCard` popped this card face-up beside
    /// the deck (it's already on the discard pile by the time this fires).
    case topCardFlipped(Card)
}
