import Foundation

/// Deterministic Go Fish bot. Works only from its own `GoFishSnapshot`
/// (honest - never peeks at other hands). Same snapshot + same rng state
/// always yields the same ask.
///
/// Strategy: ask for the rank it holds the MOST of (biggest book progress),
/// breaking ties toward ranks it remembers someone else holds, then by rng.
/// Memory is simple: every public ask proves the asker held that rank, until
/// that seat hands the rank over or it is booked.
public enum GoFishBot {
    public static func chooseAction(snapshot: GoFishSnapshot, rng: inout SeededGenerator) -> GoFishAction? {
        guard snapshot.phase == .playing, snapshot.turnSeat == snapshot.seat,
              !snapshot.askableRanks.isEmpty, !snapshot.askableTargets.isEmpty else { return nil }

        var counts: [Int: Int] = [:]
        for card in snapshot.hand { if let r = card.rank { counts[r, default: 0] += 1 } }
        let holders = knownHolders(snapshot)

        func holderSeats(_ rank: Int) -> [Int] {
            holders.filter { $0.rank == rank }.map(\.seat).sorted()
        }

        let ranks = snapshot.askableRanks.filter { counts[$0] != nil }
        let bestCount = ranks.map { counts[$0] ?? 0 }.max() ?? 0
        var candidates = ranks.filter { (counts[$0] ?? 0) == bestCount }
        let withMemory = candidates.filter { !holderSeats($0).isEmpty }
        if !withMemory.isEmpty { candidates = withMemory }
        guard !candidates.isEmpty else { return nil }
        let rank = candidates.sorted()[Int.random(in: 0..<candidates.count, using: &rng)]

        let remembered = holderSeats(rank).filter { snapshot.askableTargets.contains($0) }
        let target: Int
        if !remembered.isEmpty {
            target = remembered[Int.random(in: 0..<remembered.count, using: &rng)]
        } else {
            let withCards = snapshot.askableTargets.filter { (snapshot.handCounts[$0] ?? 0) > 0 }
            let pool = withCards.isEmpty ? snapshot.askableTargets : withCards
            target = pool[Int.random(in: 0..<pool.count, using: &rng)]
        }
        return .ask(target: target, rank: rank)
    }

    /// (seat, rank) pairs another seat is believed to still hold.
    static func knownHolders(_ snapshot: GoFishSnapshot) -> [(seat: Int, rank: Int)] {
        var held = Set<[Int]>()
        for record in snapshot.askLog {
            held.insert([record.asker, record.rank])
            if record.gave > 0 { held.remove([record.target, record.rank]) }
        }
        let booked = Set(snapshot.books.values.flatMap { $0 })
        return held.compactMap { pair -> (seat: Int, rank: Int)? in
            let seat = pair[0], rank = pair[1]
            guard seat != snapshot.seat, !booked.contains(rank),
                  (snapshot.handCounts[seat] ?? 0) > 0 else { return nil }
            return (seat, rank)
        }
    }
}
