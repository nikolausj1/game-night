import Foundation

/// Old Maid bot: picks a card INDEX from the neighbor's fan. Honest - it
/// never sees card faces in the neighbor's hand - so the pick is uniform
/// random with one tiny bias: if the neighbor just drew from this bot (and
/// didn't pair it off), that card was appended to the END of the neighbor's
/// fan, and the bot gives that one index half weight (it handed that card
/// over for a reason, maybe the queen, and doesn't want it back). If the
/// hand was shuffled since, the bias is simply harmless noise.
public enum OldMaidBot {
    public static func chooseIndex(snapshot: OldMaidSnapshot, rng: inout SeededGenerator) -> Int? {
        guard snapshot.phase == .playing, snapshot.turnSeat == snapshot.seat,
              let target = snapshot.drawTarget else { return nil }
        let count = snapshot.handCounts[target] ?? 0
        guard count > 0 else { return nil }
        var weights = [Double](repeating: 1.0, count: count)
        if let last = snapshot.lastDraw, last.drawer == target, last.from == snapshot.seat, !last.matched {
            weights[count - 1] = 0.5
        }
        let total = weights.reduce(0, +)
        var roll = Double.random(in: 0..<total, using: &rng)
        for (i, w) in weights.enumerated() {
            if roll < w { return i }
            roll -= w
        }
        return count - 1
    }
}
