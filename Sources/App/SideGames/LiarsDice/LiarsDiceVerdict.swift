import Foundation

/// The words for the end of a call, shared by the table's verdict beat and
/// the phone's reveal panel so both always tell the same story.
struct LiarsDiceVerdict: Equatable {
    let title: String
    let detail: String
    /// "Hank is out of dice!" when the loser just ran dry.
    let outLine: String?

    static func make(_ r: LiarsDiceResolution, diceCounts: [Int],
                     name: (Int) -> String) -> LiarsDiceVerdict {
        let bidder = name(r.bid.seat)
        let caller = name(r.caller)
        let phrase = LiarsDiceWords.bid(r.bid.quantity, r.bid.face)
        let found = r.actualCount == 0 ? "no" : LiarsDiceWords.number(r.actualCount)
        let faces = LiarsDiceWords.faces(r.bid.face, count: r.actualCount)

        let title: String
        let detail: String
        switch r.kind {
        case .challenge:
            if r.callSucceeded {
                title = "\(bidder) was bluffing"
                detail = "Only \(found) \(faces), not \(LiarsDiceWords.number(r.bid.quantity)). \(bidder) loses a die."
            } else {
                title = "The bid was good"
                detail = "There were \(found) \(faces) - \(bidder) said \(phrase). \(caller) loses a die."
            }
        case .spotOn:
            if r.callSucceeded {
                title = "Spot on!"
                detail = r.gainerSeat != nil
                    ? "Exactly \(found) \(faces). \(caller) wins a die back."
                    : "Exactly \(found) \(faces). \(caller) already has a full cup."
            } else {
                title = "Not exactly"
                detail = "There were \(found) \(faces), not \(LiarsDiceWords.number(r.bid.quantity)). \(caller) loses a die."
            }
        }

        var out: String?
        if let loser = r.loserSeat, diceCounts.indices.contains(loser), diceCounts[loser] == 0 {
            out = "\(name(loser)) is out of dice!"
        }
        return LiarsDiceVerdict(title: title, detail: detail, outLine: out)
    }
}

/// Which dice count toward a bid (the face itself, plus wild ones unless the
/// bid is on ones) - the same rule `LiarsDiceRules.count` applies.
func liarsDiceDieCounts(_ die: Int, face: Int, wildOnes: Bool) -> Bool {
    die == face || (wildOnes && face != 1 && die == 1)
}
