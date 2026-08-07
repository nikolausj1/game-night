import SwiftUI

/// Geometry of the 121-hole track drawn on `CribbageBoardWood`. Twin
/// straight lanes per player — out along the top row, back along the
/// bottom row — grouped into 5-hole runs with a hairline extra gap between
/// groups (a real board's counting rhythm, and what makes leg-reading at a
/// glance possible). Chosen over the classic S-curve for the same beauty
/// at far less geometry risk: two straight lanes per player read cleanly
/// at any board width, where a curved track's hole spacing distorts unless
/// hand-tuned to one exact aspect ratio.
///
/// All positions are UNIT coordinates (0...1 in both axes) over the board
/// image's own frame; callers scale by the rendered board size.
enum CribbageBoardLayout {
    static let holesPerLane = 60
    static let laneX: ClosedRange<CGFloat> = 0.085...0.94

    /// `lane` 0 = the outbound row (scores 1...60), 1 = the homebound row
    /// (61...120).
    static func laneY(player: Int, lane: Int) -> CGFloat {
        let base: CGFloat = player == 0 ? 0.30 : 0.72
        return base + (lane == 0 ? -0.085 : 0.085)
    }

    /// Unit position of the peg marking `score` (0...121) on `player`'s
    /// track. 0 sits just behind hole 1 (no points yet); 121 is the game
    /// hole, tucked back at the same end as the start — the peg travels
    /// out along the top lane and all the way back along the bottom one.
    static func position(score: Int, player: Int) -> CGPoint {
        let s = max(0, min(121, score))
        if s == 0 {
            return CGPoint(x: laneX.lowerBound - 0.035, y: laneY(player: player, lane: 0))
        }
        if s >= 121 {
            return CGPoint(x: laneX.lowerBound - 0.035, y: laneY(player: player, lane: 1))
        }
        if s <= holesPerLane {
            return CGPoint(x: holeX(index: s), y: laneY(player: player, lane: 0))
        }
        let backIndex = s - holesPerLane // 1...60, counting up as you head home
        return CGPoint(x: holeX(index: holesPerLane + 1 - backIndex), y: laneY(player: player, lane: 1))
    }

    /// x for hole `index` (1...60), grouped into 12 runs of 5 with a small
    /// extra gap at each group boundary.
    static func holeX(index: Int) -> CGFloat {
        let i = CGFloat(index - 1)
        let groupsCrossed = CGFloat((index - 1) / 5)
        let groupGap: CGFloat = 0.010
        let totalWidth = laneX.upperBound - laneX.lowerBound
        let usableWidth = totalWidth - 11 * groupGap
        let step = usableWidth / 59
        return laneX.lowerBound + i * step + groupsCrossed * groupGap
    }

    /// The skunk line: 30 holes short of the game hole (score 91), on the
    /// homebound row — marked with a gold tick so a glance says whether
    /// someone's at risk.
    static let skunkScore = 91
}

/// The pegboard: photoreal walnut plank (`CribbageBoardWood`) with the
/// 121-hole track drawn on top via `Canvas`, and this game's four pegs
/// (brass for seat 0, ivory for seat 1 — two each, front/back) leapfrogging
/// along it. Owns its own hop-animation state; the table just hands it
/// scores.
///
/// Leapfrog mechanic: each player has two pegs. Scoring moves whichever
/// peg is currently TRAILING out past the other, in one arc, to the new
/// score — it becomes the new leading peg, and the old leader (already
/// sitting at the pre-move score) becomes the new trailing marker for
/// free. That's the real board's dispute-proofing ritual, reproduced here
/// exactly: the trailing peg always shows "where you were a moment ago."
struct CribbagePegBoardView: View {
    let scores: [Int: Int]
    var reduceMotion: Bool = false

    private struct PegTrack {
        var scoreA = 0
        var scoreB = 0
        /// True when peg A is the current leader (peg B trails).
        var activeIsA = false
        var restA: CGPoint = .zero
        var restB: CGPoint = .zero
    }

    @State private var tracks: [Int: PegTrack] = [:]
    @State private var hopProgress: [String: CGFloat] = [:]
    @State private var hopFrom: [String: CGPoint] = [:]
    @State private var hopTo: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Image("CribbageBoardWood")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                Canvas { context, canvasSize in
                    drawTrack(context: context, size: canvasSize)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                ForEach([0, 1], id: \.self) { player in
                    pegPair(player: player, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { snapToCurrent() }
            .onChange(of: scores[0] ?? 0) { _, new in movePeg(player: 0, to: new) }
            .onChange(of: scores[1] ?? 0) { _, new in movePeg(player: 1, to: new) }
        }
        .aspectRatio(700.0 / 327.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pegboard, seat 1 at \(scores[0] ?? 0), seat 2 at \(scores[1] ?? 0), first to 121")
    }

    // MARK: drawing

    private func drawTrack(context: GraphicsContext, size: CGSize) {
        for player in [0, 1] {
            for lane in [0, 1] {
                let y = CribbageBoardLayout.laneY(player: player, lane: lane) * size.height
                for index in 1...CribbageBoardLayout.holesPerLane {
                    let x = CribbageBoardLayout.holeX(index: index) * size.width
                    let r: CGFloat = max(1.6, size.width * 0.0026)
                    let hole = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    // Drilled-hole shading: a dark well with a faint
                    // upper-left highlight, so it reads recessed rather
                    // than printed on.
                    context.fill(Path(ellipseIn: hole), with: .color(.black.opacity(0.55)))
                    let hi = CGRect(x: x - r * 0.55, y: y - r * 0.85, width: r * 0.6, height: r * 0.6)
                    context.fill(Path(ellipseIn: hi), with: .color(.white.opacity(0.16)))
                }
            }
            // Skunk line: a gold tick across the homebound row.
            let skunkX = CribbageBoardLayout
                .position(score: CribbageBoardLayout.skunkScore, player: player).x * size.width
            let midY = CribbageBoardLayout.laneY(player: player, lane: 1) * size.height
            var tick = Path()
            tick.move(to: CGPoint(x: skunkX, y: midY - size.height * 0.035))
            tick.addLine(to: CGPoint(x: skunkX, y: midY + size.height * 0.035))
            context.stroke(tick, with: .color(CardStyle.gold.opacity(0.7)), lineWidth: 1.4)

            // Start / game-hole rings.
            for score in [0, 121] {
                let p = CribbageBoardLayout.position(score: score, player: player)
                let x = p.x * size.width, y = p.y * size.height
                let r: CGFloat = max(2.2, size.width * 0.0045)
                context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color(CardStyle.gold.opacity(0.65)), lineWidth: 1.2)
            }
        }
    }

    // MARK: pegs

    @ViewBuilder
    private func pegPair(player: Int, size: CGSize) -> some View {
        let track = tracks[player] ?? PegTrack()
        let imageName = player == 0 ? "CribbagePegBrass" : "CribbagePegIvory"
        let pegWidth = max(6, size.width * 0.016)
        ForEach(["A", "B"], id: \.self) { slot in
            let key = "\(player)\(slot)"
            let restPos = slot == "A" ? track.restA : track.restB
            let progress = hopProgress[key] ?? 1
            let from = hopFrom[key] ?? restPos
            let to = hopTo[key] ?? restPos
            HoppingPegView(progress: progress, from: from, to: to, boardSize: size,
                          imageName: imageName, pegWidth: pegWidth)
                .zIndex((slot == "A") == track.activeIsA ? 2 : 1)
        }
    }

    /// Initial placement (or a jump straight to score, no hop) — first
    /// paint, and the reset between hands never needs an arc.
    private func snapToCurrent() {
        for player in [0, 1] {
            let s = scores[player] ?? 0
            let pos = CribbageBoardLayout.position(score: s, player: player)
            tracks[player] = PegTrack(scoreA: s, scoreB: s, activeIsA: false, restA: pos, restB: pos)
            hopFrom["\(player)A"] = pos; hopTo["\(player)A"] = pos; hopProgress["\(player)A"] = 1
            hopFrom["\(player)B"] = pos; hopTo["\(player)B"] = pos; hopProgress["\(player)B"] = 1
        }
    }

    /// The leapfrog move: the trailing peg jumps to `newScore` in one arc
    /// (never incrementally, however many points the score just gained)
    /// and becomes the new leader.
    private func movePeg(player: Int, to newScore: Int) {
        var track = tracks[player] ?? PegTrack()
        let jumpingSlot = track.activeIsA ? "B" : "A"
        let fromPos = track.activeIsA ? track.restB : track.restA
        let toPos = CribbageBoardLayout.position(score: newScore, player: player)
        let key = "\(player)\(jumpingSlot)"

        if track.activeIsA { track.scoreB = newScore } else { track.scoreA = newScore }
        track.activeIsA.toggle()
        tracks[player] = track

        hopFrom[key] = fromPos
        hopTo[key] = toPos
        if reduceMotion {
            hopProgress[key] = 1
            commitRest(player: player, slot: jumpingSlot, pos: toPos)
            return
        }
        hopProgress[key] = 0
        withAnimation(.timingCurve(0.3, 0.0, 0.2, 1, duration: 0.55)) {
            hopProgress[key] = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            commitRest(player: player, slot: jumpingSlot, pos: toPos)
        }
    }

    private func commitRest(player: Int, slot: String, pos: CGPoint) {
        var track = tracks[player] ?? PegTrack()
        if slot == "A" { track.restA = pos } else { track.restB = pos }
        tracks[player] = track
        let key = "\(player)\(slot)"
        hopFrom[key] = pos
        hopTo[key] = pos
        hopProgress[key] = 1
    }
}

/// One peg, mid-hop or at rest. `progress` is the ONLY animated value —
/// same single-progress idiom `PileTossCardView` uses for felt-card
/// throws — so position and arc height can never fall out of step with
/// each other.
private struct HoppingPegView: View, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let to: CGPoint
    let boardSize: CGSize
    let imageName: String
    let pegWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        let x = (from.x + (to.x - from.x) * p) * boardSize.width
        let baseY = (from.y + (to.y - from.y) * p) * boardSize.height
        let hop = sin(Double(p) * .pi) * Double(boardSize.height) * 0.10
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: pegWidth, height: pegWidth * 2.0)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 2)
            .position(x: x, y: baseY - CGFloat(hop))
    }
}
