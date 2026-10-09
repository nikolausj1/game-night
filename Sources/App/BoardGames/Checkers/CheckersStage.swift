import SwiftUI

/// One physical checker. Identity matters: it is how a captured piece
/// knows which sprite to flip off the board.
struct CheckersToken: Identifiable, Equatable {
    let id: Int
    var owner: Int
    var isKing: Bool
    var square: Int
}

/// The VISUAL model: numbered tokens on squares, the captured piles, and
/// whichever `CheckersPlan` is currently animating over them.
@Observable
final class CheckersStage {
    private(set) var tokens: [CheckersToken]
    /// `pile[seat]` = how many pieces `seat` has captured (their sprites are
    /// the opponent's colour).
    private(set) var pile: [Int]
    private(set) var plan: CheckersPlan?
    private(set) var startDate = Date()

    init(board: [CheckersPiece?] = CheckersRules.initialBoard(), capturedBy: [Int] = [0, 0]) {
        var built: [CheckersToken] = []
        for sq in 0..<64 {
            if let p = board[sq] { built.append(CheckersToken(id: built.count, owner: p.owner, isKing: p.isKing, square: sq)) }
        }
        tokens = built
        pile = capturedBy
    }

    func token(at square: Int) -> CheckersToken? { tokens.first { $0.square == square } }

    func begin(_ plan: CheckersPlan) {
        self.plan = plan
        startDate = Date()
    }

    func commit() {
        if let plan {
            tokens = plan.finalTokens
            pile = plan.finalPile
        }
        plan = nil
    }

    /// If the visual tokens ever disagree with the engine board, rebuild
    /// from the engine so the table is honest.
    func reconcile(with board: [CheckersPiece?]) {
        var matches = true
        for sq in 0..<64 {
            let t = token(at: sq)
            if (t == nil) != (board[sq] == nil) { matches = false; break }
            if let t, let p = board[sq], t.owner != p.owner || t.isKing != p.isKing { matches = false; break }
        }
        if matches { return }
        let keep = pile
        let fresh = CheckersStage(board: board, capturedBy: keep)
        tokens = fresh.tokens
    }
}
