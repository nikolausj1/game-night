import Foundation

/// UI-facing sugar over the wire snapshot, so views read like sentences.
extension ClientSnapshot {
    var roundNumber: Int? { round?.roundNumber }
    var cardsPerRound: Int? { round?.cardsPerPlayer }
    var trumpSuit: Suit? { round?.trumpSuit }
    var turnSeat: Int? { round?.turnSeat }
    var myBid: Int? { round?.bids[mySeat] }
    var myTricksWon: Int? { round?.tricksWon[mySeat] }
}
