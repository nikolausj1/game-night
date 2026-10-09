import Foundation

// Dots & Boxes lives entirely outside the card engine — same pattern as
// DiceTypes.swift/DiceGameController: this file is the whole rules world
// (grid geometry, turn/score state, a heuristic bot), pure and Codable, with
// no dependency on GameState/HostEngine/GameRules. The App layer's
// DotsAndBoxesController owns one of these per game, exactly the way
// DiceGameController owns dice rules table-side. Played entirely on the
// iPad (pass-and-play, finger = pencil) — there is no phone/network leg at
// all, so unlike dice there's no client-state wire type here either.

// MARK: - Grid geometry

/// Which way a line segment runs between two adjacent dots.
public enum DotsAndBoxesEdgeOrientation: String, Codable, Sendable, Hashable {
    case horizontal, vertical
}

/// One placeable pencil line between two adjacent dots, addressed by DOT
/// coordinates (not box coordinates). A horizontal edge at `(row, col)` runs
/// from dot `(row, col)` to dot `(row, col+1)`; a vertical edge at
/// `(row, col)` runs from dot `(row, col)` to dot `(row+1, col)`. For an
/// N×N-box grid there are `N+1` dot rows/cols, so horizontal edges have
/// `row` in `0...N, col` in `0..<N`, and vertical edges have `row` in
/// `0..<N, col` in `0...N`.
public struct DotsAndBoxesEdge: Codable, Sendable, Hashable {
    public let orientation: DotsAndBoxesEdgeOrientation
    public let row: Int
    public let col: Int

    public init(orientation: DotsAndBoxesEdgeOrientation, row: Int, col: Int) {
        self.orientation = orientation
        self.row = row
        self.col = col
    }
}

/// One square of the paper, addressed by its top-left dot: box `(row, col)`
/// spans dots `(row, col)…(row+1, col+1)`, both in `0..<gridSize`.
public struct DotsAndBoxesBox: Codable, Sendable, Hashable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// This box's four bounding edges: top, bottom, left, right.
    public func edges() -> [DotsAndBoxesEdge] {
        [
            DotsAndBoxesEdge(orientation: .horizontal, row: row, col: col),
            DotsAndBoxesEdge(orientation: .horizontal, row: row + 1, col: col),
            DotsAndBoxesEdge(orientation: .vertical, row: row, col: col),
            DotsAndBoxesEdge(orientation: .vertical, row: row, col: col + 1),
        ]
    }
}

// MARK: - Players

/// One pencil at the table. `colorIndex` is an index into the App layer's
/// pencil-color palette (same convention as `Seat.colorIndex` for cards) —
/// the engine only remembers WHICH pencil, never the actual `Color`.
public struct DotsAndBoxesPlayer: Codable, Sendable, Equatable {
    public var name: String
    /// What gets written inside a box this player completes — usually the
    /// first letter of `name`, but callers may hand-pick one (e.g. to keep
    /// two "Sam"s apart at the table).
    public var initial: String
    public var colorIndex: Int
    public var isBot: Bool
    public var score: Int

    public init(name: String, initial: String? = nil, colorIndex: Int, isBot: Bool, score: Int = 0) {
        self.name = name
        self.initial = initial ?? String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        self.colorIndex = colorIndex
        self.isBot = isBot
        self.score = score
    }
}

// MARK: - State

/// The whole sheet of paper: grid size, every pencil, every claimed line,
/// every filled-in box, and whose turn it is. Codable so a mid-game demo
/// snapshot (or, later, a save) round-trips exactly like the card engine's
/// `GameState`.
public struct DotsAndBoxesState: Codable, Sendable, Equatable {
    public var gridSize: Int
    public var players: [DotsAndBoxesPlayer]
    /// Edge → the player who drew it. A dictionary (not a Set) because the
    /// paper view needs to know whose pencil color to render each line in.
    public var claimedBy: [DotsAndBoxesEdge: Int]
    /// `boxOwner[row][col]` — the player who completed that box, or nil.
    public var boxOwner: [[Int?]]
    public var turnIndex: Int
    public var isGameOver: Bool
    /// The seed this game was dealt with (for display/debugging only — the
    /// engine's live RNG state isn't persisted, see `DotsAndBoxesEngine`).
    public var seed: UInt64

    public init(gridSize: Int, players: [DotsAndBoxesPlayer], seed: UInt64) {
        self.gridSize = gridSize
        self.players = players
        self.claimedBy = [:]
        self.boxOwner = Array(repeating: Array(repeating: nil, count: gridSize), count: gridSize)
        self.turnIndex = 0
        self.isGameOver = false
        self.seed = seed
    }

    /// Every edge this grid size can hold: `(N+1)·N` horizontal plus
    /// `N·(N+1)` vertical.
    public var totalEdgeCount: Int { 2 * gridSize * (gridSize + 1) }
    public var totalBoxCount: Int { gridSize * gridSize }
}

/// What happened as a result of one `claimEdge` call. The App layer maps
/// these to the felt/paper reactions (draw the stroke, write the initial,
/// flourish the extra turn, flip the turn card, show the scoreboard) — same
/// role `GameEvent` plays for the card engine.
public enum DotsAndBoxesEvent: Equatable, Sendable {
    case edgeClaimed(edge: DotsAndBoxesEdge, by: Int)
    case boxCompleted(box: DotsAndBoxesBox, by: Int)
    /// The mover completed at least one box and goes again — the paper
    /// game's one house rule with real teeth.
    case extraTurn(playerIndex: Int)
    case turnChanged(to: Int)
    case gameOver(winners: [Int])
    case illegalAttempt(reason: String)
}

// MARK: - Engine

/// The reducer. One instance per game, owned by the App layer's
/// `DotsAndBoxesController` (the pass-and-play equivalent of
/// `DiceGameController` — no networking, no phones, just the iPad and
/// whoever's turn it is). `claimEdge` is the single mutating entry point;
/// everything else is read-only geometry/analysis, including the bot.
public final class DotsAndBoxesEngine {
    public private(set) var state: DotsAndBoxesState

    /// Grid sizes the setup overlay offers. The engine itself doesn't
    /// enforce this list — any positive size works — but this is the
    /// contract with the picker.
    public static let allowedGridSizes = [4, 6, 8]

    /// Deterministic bot randomness (tie-breaks among equally-good moves).
    /// Deliberately NOT part of `DotsAndBoxesState`: like `HostEngine`'s
    /// `dealSerial`, it's derived state that only matters within one live
    /// engine's lifetime, not something a save needs to reproduce exactly.
    private var rng: SeededGenerator

    public init(gridSize: Int, players: [DotsAndBoxesPlayer], seed: UInt64) {
        state = DotsAndBoxesState(gridSize: gridSize, players: players, seed: seed)
        rng = SeededGenerator(seed: seed)
    }

    /// Resume from a snapshot (demo harness, or a future save/resume).
    /// The RNG reseeds from the state's original seed — bot play after
    /// resume diverges from an uninterrupted game's, same tradeoff
    /// `HostEngine.init(restoring:)` makes with `dealSerial`.
    public init(restoring state: DotsAndBoxesState) {
        self.state = state
        rng = SeededGenerator(seed: state.seed)
    }

    // MARK: - The one legal move

    /// Draw one pencil line. Returns the events the UI should react to; an
    /// illegal attempt (wrong turn, off-grid, already drawn) changes
    /// nothing and returns a single `.illegalAttempt`.
    @discardableResult
    public func claimEdge(_ edge: DotsAndBoxesEdge, by playerIndex: Int) -> [DotsAndBoxesEvent] {
        guard !state.isGameOver else {
            return [.illegalAttempt(reason: "The game is already over")]
        }
        guard state.players.indices.contains(playerIndex) else {
            return [.illegalAttempt(reason: "No such player")]
        }
        guard playerIndex == state.turnIndex else {
            return [.illegalAttempt(reason: "Not your turn")]
        }
        guard isOnGrid(edge) else {
            return [.illegalAttempt(reason: "That's not a line on this grid")]
        }
        guard state.claimedBy[edge] == nil else {
            return [.illegalAttempt(reason: "That line is already drawn")]
        }

        state.claimedBy[edge] = playerIndex
        var events: [DotsAndBoxesEvent] = [.edgeClaimed(edge: edge, by: playerIndex)]

        // Both boxes on a shared edge can complete in the same stroke — the
        // "multi-box double-claim" case, e.g. the last line inside a 1×2
        // pocket finishes two boxes at once. Both get credited here.
        let completed = adjacentBoxes(to: edge).filter { filledSideCount(of: $0) == 4 && owner(of: $0) == nil }
        for box in completed {
            state.boxOwner[box.row][box.col] = playerIndex
            state.players[playerIndex].score += 1
            events.append(.boxCompleted(box: box, by: playerIndex))
        }

        if state.claimedBy.count == state.totalEdgeCount {
            state.isGameOver = true
            events.append(.gameOver(winners: computeWinners()))
        } else if !completed.isEmpty {
            // Completing a box earns another turn immediately — the turn
            // index does NOT advance, so the same player is asked again.
            events.append(.extraTurn(playerIndex: playerIndex))
        } else {
            state.turnIndex = nextPlayerIndex()
            events.append(.turnChanged(to: state.turnIndex))
        }

        return events
    }

    /// Every line not yet drawn — what the current player (or the setup
    /// picker's legality check) may choose from.
    public func legalEdges() -> [DotsAndBoxesEdge] {
        allEdges().filter { state.claimedBy[$0] == nil }
    }

    private func nextPlayerIndex() -> Int {
        (state.turnIndex + 1) % max(state.players.count, 1)
    }

    private func computeWinners() -> [Int] {
        guard let top = state.players.map(\.score).max() else { return [] }
        return state.players.indices.filter { state.players[$0].score == top }
    }

    // MARK: - Geometry

    private func isOnGrid(_ edge: DotsAndBoxesEdge) -> Bool {
        let n = state.gridSize
        switch edge.orientation {
        case .horizontal: return (0...n).contains(edge.row) && (0..<n).contains(edge.col)
        case .vertical: return (0..<n).contains(edge.row) && (0...n).contains(edge.col)
        }
    }

    private func allEdges() -> [DotsAndBoxesEdge] {
        let n = state.gridSize
        var edges: [DotsAndBoxesEdge] = []
        edges.reserveCapacity(2 * n * (n + 1))
        for row in 0...n {
            for col in 0..<n {
                edges.append(DotsAndBoxesEdge(orientation: .horizontal, row: row, col: col))
            }
        }
        for row in 0..<n {
            for col in 0...n {
                edges.append(DotsAndBoxesEdge(orientation: .vertical, row: row, col: col))
            }
        }
        return edges
    }

    /// The one or two boxes that share `edge` — one on a border edge, two
    /// for an interior one.
    private func adjacentBoxes(to edge: DotsAndBoxesEdge) -> [DotsAndBoxesBox] {
        let n = state.gridSize
        switch edge.orientation {
        case .horizontal:
            var boxes: [DotsAndBoxesBox] = []
            if edge.row - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row - 1, col: edge.col)) } // above
            if edge.row < n { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) } // below
            return boxes
        case .vertical:
            var boxes: [DotsAndBoxesBox] = []
            if edge.col - 1 >= 0 { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col - 1)) } // left
            if edge.col < n { boxes.append(DotsAndBoxesBox(row: edge.row, col: edge.col)) } // right
            return boxes
        }
    }

    private func filledSideCount(of box: DotsAndBoxesBox, in claimed: [DotsAndBoxesEdge: Int]? = nil) -> Int {
        let table = claimed ?? state.claimedBy
        return box.edges().filter { table[$0] != nil }.count
    }

    private func owner(of box: DotsAndBoxesBox) -> Int? {
        guard state.boxOwner.indices.contains(box.row), state.boxOwner[box.row].indices.contains(box.col) else {
            return nil
        }
        return state.boxOwner[box.row][box.col]
    }

    // MARK: - Bot

    /// Seats that play the ORIGINAL heuristic bot (no chain counting, no
    /// double-cross). Empty by default; tests set this to measure the gain
    /// of the current bot, and a future "easy" difficulty could use it.
    public var legacyBotSeats: Set<Int> = []

    /// Play the bot's move for `playerIndex` and apply it. No-op (empty
    /// events) if there's nothing legal left or it isn't that seat's turn.
    ///
    /// Two-player games use the full strategy; 3+ players fall back to the
    /// original heuristic (control theory doesn't carry over to free-for-all).
    ///
    /// 1. **Exact endgame.** With `exactEndgameEdgeLimit` or fewer lines left
    ///    the position is solved outright (memoized negamax over the set of
    ///    drawn lines, extra turns included), so the double-cross, sacrifices
    ///    that flip control, and the last-chain take-all all fall out exactly.
    /// 2. **Chain phase.** Once no line is "safe" (every box has at most two
    ///    open sides, so the board is only chains and loops), a chain/loop
    ///    value recursion decides everything: when capturing, whether to take
    ///    every box or decline the last two of a chain (four of a loop) to
    ///    keep control (the DOUBLE-CROSS); when forced to open, which
    ///    component to give up (shortest/cheapest by the recursion, and a
    ///    2-chain is opened in the middle so the opponent cannot decline).
    /// 3. **Otherwise** the original rules: take free boxes (most at once),
    ///    else play a safe line, else open the cheapest chain.
    @discardableResult
    public func performBotMove(for playerIndex: Int) -> [DotsAndBoxesEvent] {
        guard let edge = chooseBotEdge(for: playerIndex) else { return [] }
        return claimEdge(edge, by: playerIndex)
    }

    /// Lines-remaining threshold at or below which the bot solves the game
    /// exactly (2^15 states; a fraction of a second even unoptimized).
    public static let exactEndgameEdgeLimit = 15

    /// Same selection `performBotMove` plays, exposed separately so tests
    /// can inspect the choice without also mutating the engine.
    func chooseBotEdge(for playerIndex: Int) -> DotsAndBoxesEdge? {
        guard playerIndex == state.turnIndex, !state.isGameOver else { return nil }
        let legal = legalEdges()
        guard !legal.isEmpty else { return nil }

        if state.players.count == 2, !legacyBotSeats.contains(playerIndex) {
            if legal.count <= Self.exactEndgameEdgeLimit, let edge = exactEndgameEdge(legal: legal) {
                return edge
            }
            if let edge = chainPhaseEdge(legal: legal) { return edge }
        }
        return legacyBotEdge(legal: legal)
    }

    private func legacyBotEdge(legal: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge {
        let capturing = legal.map { edge in (edge, boxesCompleted(ifPlayed: edge).count) }
            .filter { $0.1 > 0 }
        if let bestCount = capturing.map(\.1).max() {
            let best = capturing.filter { $0.1 == bestCount }.map(\.0)
            return pick(among: best)
        }

        let safe = legal.filter { isSafe($0) }
        if !safe.isEmpty {
            return pick(among: safe)
        }

        // Forced: every remaining line gives away at least one box.
        // Minimize the sweep the opponent collects.
        let sweeps = legal.map { ($0, chainSweepSize(openedBy: $0)) }
        guard let minSweep = sweeps.map(\.1).min() else { return pick(among: legal) }
        let shortest = sweeps.filter { $0.1 == minSweep }.map(\.0)
        return pick(among: shortest)
    }

    // MARK: Exact endgame

    /// Solves the remaining game exactly and returns an optimal line
    /// (preferring ones that complete boxes, then seeded-random among ties).
    /// `nil` only if the position is somehow degenerate.
    private func exactEndgameEdge(legal: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge? {
        let k = legal.count
        guard k > 0, k <= 20 else { return nil }
        var edgeIndex: [DotsAndBoxesEdge: Int] = [:]
        for (i, e) in legal.enumerated() { edgeIndex[e] = i }

        // Live boxes = unowned boxes; mask = their still-open sides.
        var boxMasks: [UInt32] = []
        var edgeBoxes = Array(repeating: [Int](), count: k)
        for row in 0..<state.gridSize {
            for col in 0..<state.gridSize where state.boxOwner[row][col] == nil {
                let box = DotsAndBoxesBox(row: row, col: col)
                var mask: UInt32 = 0
                for e in box.edges() { if let i = edgeIndex[e] { mask |= 1 << UInt32(i) } }
                guard mask != 0 else { continue }
                let bi = boxMasks.count
                boxMasks.append(mask)
                for i in 0..<k where mask & (1 << UInt32(i)) != 0 { edgeBoxes[i].append(bi) }
            }
        }

        let full: UInt32 = k == 32 ? .max : (1 << UInt32(k)) - 1
        var memo = [Int16](repeating: Int16.min, count: 1 << k)

        func completed(_ drawn: UInt32, _ edge: Int) -> Int {
            let next = drawn | (1 << UInt32(edge))
            var c = 0
            for b in edgeBoxes[edge] where next & boxMasks[b] == boxMasks[b] { c += 1 }
            return c
        }
        func solve(_ drawn: UInt32) -> Int {
            if drawn == full { return 0 }
            let cached = memo[Int(drawn)]
            if cached != Int16.min { return Int(cached) }
            var best = Int.min
            for e in 0..<k where drawn & (1 << UInt32(e)) == 0 {
                let c = completed(drawn, e)
                let next = drawn | (1 << UInt32(e))
                let v = c > 0 ? c + solve(next) : -solve(next)
                if v > best { best = v }
            }
            memo[Int(drawn)] = Int16(best)
            return best
        }

        var bestValue = Int.min
        var scored: [(Int, Int, DotsAndBoxesEdge)] = [] // (value, boxesCompleted, edge)
        for e in 0..<k {
            let c = completed(0, e)
            let next: UInt32 = 1 << UInt32(e)
            let v = c > 0 ? c + solve(next) : -solve(next)
            scored.append((v, c, legal[e]))
            bestValue = max(bestValue, v)
        }
        let optimal = scored.filter { $0.0 == bestValue }
        let mostBoxes = optimal.map(\.1).max() ?? 0
        return pick(among: optimal.filter { $0.1 == mostBoxes }.map(\.2))
    }

    // MARK: Chain phase (chains + loops only)

    private struct ChainComponent {
        var boxes: [DotsAndBoxesBox]
        var edges: [DotsAndBoxesEdge]
        var isLoop: Bool
        /// Boxes in this component with exactly one open side (capturable now).
        var capturableBoxes: [DotsAndBoxesBox]
        var size: Int { boxes.count }
    }

    private func openEdges(of box: DotsAndBoxesBox) -> [DotsAndBoxesEdge] {
        box.edges().filter { state.claimedBy[$0] == nil }
    }

    /// Splits the board into chains and loops, or returns nil when any box
    /// still has 3+ open sides (a junction: not yet a pure chain position).
    private func chainComponents() -> [ChainComponent]? {
        var degree: [DotsAndBoxesBox: Int] = [:]
        var live: [DotsAndBoxesBox] = []
        for row in 0..<state.gridSize {
            for col in 0..<state.gridSize where state.boxOwner[row][col] == nil {
                let box = DotsAndBoxesBox(row: row, col: col)
                let d = openEdges(of: box).count
                if d >= 3 { return nil }
                if d == 0 { continue }
                degree[box] = d
                live.append(box)
            }
        }
        var visited = Set<DotsAndBoxesBox>()
        var comps: [ChainComponent] = []
        for start in live where !visited.contains(start) {
            var queue = [start]
            visited.insert(start)
            var boxes: [DotsAndBoxesBox] = []
            var edgeSet = Set<DotsAndBoxesEdge>()
            var hasGround = false
            while let box = queue.popLast() {
                boxes.append(box)
                for e in openEdges(of: box) {
                    edgeSet.insert(e)
                    let adj = adjacentBoxes(to: e)
                    if adj.count == 1 { hasGround = true }
                    for other in adj where other != box && degree[other] != nil && !visited.contains(other) {
                        visited.insert(other)
                        queue.append(other)
                    }
                }
            }
            let capturable = boxes.filter { degree[$0] == 1 }
            let isLoop = capturable.isEmpty && !hasGround && boxes.allSatisfy { degree[$0] == 2 }
            comps.append(ChainComponent(boxes: boxes, edges: Array(edgeSet), isLoop: isLoop,
                                        capturableBoxes: capturable))
        }
        // Deterministic order (Set/queue iteration order must not leak).
        func key(_ c: ChainComponent) -> Int {
            c.boxes.map { $0.row * 100 + $0.col }.min() ?? 0
        }
        return comps.sorted { key($0) < key($1) }
    }

    /// Value, for the player FORCED TO OPEN a component, of the position
    /// made only of untouched components `chains`/`loops` (sizes), assuming
    /// best play by both (controller may decline: chains give 2, loops give
    /// 4). Positive = opener nets that many boxes over the rest of the game.
    private static var chainValueMemo: [String: Int] = [:]
    private static func chainValue(chains: [Int], loops: [Int]) -> Int {
        if chains.isEmpty && loops.isEmpty { return 0 }
        let key = chains.map(String.init).joined(separator: ",") + "|" + loops.map(String.init).joined(separator: ",")
        if let v = chainValueMemo[key] { return v }
        var best = Int.min
        var tried = Set<Int>()
        for (i, n) in chains.enumerated() where !tried.contains(n) {
            tried.insert(n)
            var rest = chains; rest.remove(at: i)
            let v = openerNet(chainLength: n, rest: (rest, loops))
            best = max(best, v)
        }
        tried.removeAll()
        for (i, n) in loops.enumerated() where !tried.contains(n) {
            tried.insert(n)
            var rest = loops; rest.remove(at: i)
            let v = openerNet(loopLength: n, rest: (chains, rest))
            best = max(best, v)
        }
        chainValueMemo[key] = best
        return best
    }

    private static func openerNet(chainLength n: Int, rest: (chains: [Int], loops: [Int])) -> Int {
        let v = chainValue(chains: rest.chains, loops: rest.loops)
        let takeAll = -n - v
        if n <= 2 { return takeAll } // 1-chain: nothing to decline; 2-chain opened in the middle: cannot be declined
        return min(takeAll, 4 - n + v)
    }

    private static func openerNet(loopLength n: Int, rest: (chains: [Int], loops: [Int])) -> Int {
        let v = chainValue(chains: rest.chains, loops: rest.loops)
        return min(-n - v, 8 - n + v)
    }

    private func chainPhaseEdge(legal: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge? {
        guard let comps = chainComponents(), !comps.isEmpty else { return nil }
        let open = comps.filter { !$0.capturableBoxes.isEmpty }
        let closed = comps.filter { $0.capturableBoxes.isEmpty }
        let chains = closed.filter { !$0.isLoop }.map(\.size).sorted()
        let loops = closed.filter { $0.isLoop }.map(\.size).sorted()
        let v = Self.chainValue(chains: chains, loops: loops)

        if !open.isEmpty {
            // Largest open component is the one we may decline on; clear the
            // others first (deterministic order).
            let target = open.max { $0.size < $1.size }!
            if let other = open.first(where: { $0.boxes != target.boxes }),
               let box = other.capturableBoxes.first, let edge = openEdges(of: box).first {
                return edge
            }
            let m = target.size
            let ends = target.capturableBoxes.count
            if ends == 1, m == 2 {
                if m - 4 - v > m + v, let edge = declineEdge(of: target) { return edge }
            } else if ends == 2, m == 4 {
                if m - 8 - v > m + v, let edge = declineEdge(of: target) { return edge }
            }
            // Capture: finish the capturable box (largest component first).
            if let box = target.capturableBoxes.first, let edge = openEdges(of: box).first {
                return edge
            }
            return nil
        }

        // Nothing to capture: open the component that costs least.
        var bestNet = Int.min
        var bestComps: [ChainComponent] = []
        for c in closed {
            var restChains = chains, restLoops = loops
            if c.isLoop, let i = restLoops.firstIndex(of: c.size) { restLoops.remove(at: i) }
            else if let i = restChains.firstIndex(of: c.size) { restChains.remove(at: i) }
            let net = c.isLoop ? Self.openerNet(loopLength: c.size, rest: (restChains, restLoops))
                               : Self.openerNet(chainLength: c.size, rest: (restChains, restLoops))
            if net > bestNet { bestNet = net; bestComps = [c] } else if net == bestNet { bestComps.append(c) }
        }
        guard !bestComps.isEmpty else { return nil }
        let chosen = bestComps[bestComps.count == 1 ? 0 : Int(rng.next() % UInt64(bestComps.count))]
        return openingEdge(of: chosen)
    }

    /// The line that declines the last boxes of an open chain (draw the far
    /// end, leaving a two-box domino) or the middle of a half-eaten loop
    /// (leaving two dominoes).
    private func declineEdge(of comp: ChainComponent) -> DotsAndBoxesEdge? {
        if comp.capturableBoxes.count == 1 {
            // Two boxes: capturable A and its neighbour B; decline by drawing
            // B's OTHER open side.
            guard let a = comp.capturableBoxes.first, let aEdge = openEdges(of: a).first,
                  let b = comp.boxes.first(where: { $0 != a }) else { return nil }
            return openEdges(of: b).first { $0 != aEdge }
        }
        // Four-box open loop path A-B-C-D: draw the edge between B and C,
        // i.e. the open edge whose two boxes are both NOT capturable.
        return comp.edges.first { e in
            let adj = adjacentBoxes(to: e)
            return adj.count == 2 && adj.allSatisfy { box in !comp.capturableBoxes.contains(box) }
        }
    }

    /// The line to draw to open `comp` as cheaply as possible: a 1-chain's
    /// only box, a 2-chain in the middle (hard-hearted: no decline), a
    /// longer chain at an end, a loop anywhere.
    private func openingEdge(of comp: ChainComponent) -> DotsAndBoxesEdge? {
        let sorted = comp.edges.sorted {
            ($0.orientation.rawValue, $0.row, $0.col) < ($1.orientation.rawValue, $1.row, $1.col)
        }
        if comp.isLoop { return sorted.first }
        if comp.size == 1 { return sorted.first }
        if comp.size == 2 {
            return sorted.first { adjacentBoxes(to: $0).count == 2 } ?? sorted.first
        }
        // End line: a border line (one adjacent box), preferring the ends.
        return sorted.first { adjacentBoxes(to: $0).count == 1 } ?? sorted.first
    }

    /// Boxes that would reach 4 filled sides if `edge` were drawn next —
    /// i.e. boxes currently sitting at 3.
    private func boxesCompleted(ifPlayed edge: DotsAndBoxesEdge) -> [DotsAndBoxesBox] {
        adjacentBoxes(to: edge).filter { filledSideCount(of: $0) == 3 }
    }

    /// True when drawing `edge` brings no adjacent box to 3 filled sides —
    /// i.e. it doesn't open a box for the opponent to take next turn. Only
    /// meaningful for non-capturing edges (callers filter those first).
    private func isSafe(_ edge: DotsAndBoxesEdge) -> Bool {
        !adjacentBoxes(to: edge).contains { filledSideCount(of: $0) == 2 }
    }

    /// If `edge` is played, how many boxes fall in the forced capture
    /// cascade that follows — every box pushed to 3 sides gets its last
    /// side claimed immediately, which may push its neighbor to 3, and so
    /// on. This is exactly "how long is the chain this move opens," used
    /// to pick the least-bad sacrifice when no safe move exists.
    private func chainSweepSize(openedBy edge: DotsAndBoxesEdge) -> Int {
        var claimed = state.claimedBy
        claimed[edge] = -1 // sentinel "someone" — the sweeping owner doesn't matter for a count
        var alreadyOwned = Set<DotsAndBoxesBox>()
        for row in 0..<state.gridSize {
            for col in 0..<state.gridSize where state.boxOwner[row][col] != nil {
                alreadyOwned.insert(DotsAndBoxesBox(row: row, col: col))
            }
        }

        var sweepCount = 0
        var changed = true
        while changed {
            changed = false
            for row in 0..<state.gridSize {
                for col in 0..<state.gridSize {
                    let box = DotsAndBoxesBox(row: row, col: col)
                    guard !alreadyOwned.contains(box) else { continue }
                    let filled = filledSideCount(of: box, in: claimed)
                    if filled == 4 {
                        alreadyOwned.insert(box)
                        sweepCount += 1
                        changed = true
                    } else if filled == 3, let missing = box.edges().first(where: { claimed[$0] == nil }) {
                        claimed[missing] = -1
                        alreadyOwned.insert(box)
                        sweepCount += 1
                        changed = true
                    }
                }
            }
        }
        return sweepCount
    }

    /// Deterministic pick from a non-empty candidate list, seeded so a
    /// given game seed always plays the same game.
    private func pick(among candidates: [DotsAndBoxesEdge]) -> DotsAndBoxesEdge {
        guard candidates.count > 1 else { return candidates[0] }
        let index = Int(rng.next() % UInt64(candidates.count))
        return candidates[index]
    }
}
