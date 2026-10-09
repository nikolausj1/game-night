import SwiftUI

/// Turns the engine's event list for one move into a `MancalaPlan`.
///
/// SOWING (the centrepiece): the player taps a pit; every stone in it rises
/// (a hair of stagger, like a scoop) into a hovering cluster that follows
/// the "hand". Then, one stone every `cadence` (90 ms), the hand arrives
/// over the next pit on the `.sowed` path and ONE stone falls into it: a
/// short fall under gravity, a tiny settle bounce, and a glass tick on the
/// landing frame. A fifteen-stone sowing is therefore a ~1.4 s even patter
/// round the board, exactly the rhythm of real hands.
///
/// What follows depends on the rest of the event list:
///   - `.captured`: both pits glow gold, then the opposite stones and the
///     capturing stone pour into the store, one every 70 ms.
///   - `.extraTurn`: the store glows and "Go again" is cued.
///   - `.swept`: after a beat, each side's leftovers slide into its owner's
///     store, 50 ms apart.
enum MancalaChoreographer {
    static let cadence = 0.09
    static let fall = 0.30

    static func plan(events: [MancalaEvent], slots startSlots: [[Int]], animated: Bool) -> MancalaPlan {
        var slots = startSlots
        var plan = MancalaPlan()
        var lastEnd = 0.0
        var extraTurnSeat: Int?

        for event in events {
            switch event {
            case .sowed(_, let from, let path):
                let hand = slots[from]
                let n = min(path.count, hand.count)
                let original = hand
                slots[from] = []
                guard animated else {
                    for k in 0..<n { slots[path[k]].append(original[k]) }
                    lastEnd = 0.35
                    continue
                }
                let c0 = MancalaGeometry.center(of: from)
                let stagger = min(0.016, 0.14 / Double(max(n, 1)))
                let liftTime = 0.20
                let liftEnd = liftTime + stagger * Double(n)
                let firstDepart = liftEnd + 0.10
                plan.hand = [(0, c0), (liftEnd, c0)]
                plan.cues.append((0.02, .lift))
                var segEnd: [Int: Double] = [:]
                for k in 0..<n {
                    let id = original[k]
                    let off = MancalaGeometry.handOffset(k)
                    let rest = MancalaGeometry.restPoint(slot: from, index: k, stoneID: id)
                    let ls = stagger * Double(k)
                    plan.segments[id] = [.init(kind: .lift, t0: ls, t1: ls + liftTime,
                                               from: rest, to: CGPoint(x: c0.x + off.x, y: c0.y + off.y))]
                    segEnd[id] = ls + liftTime
                }
                for k in 0..<n {
                    let id = original[k]
                    let dest = path[k]
                    let off = MancalaGeometry.handOffset(k)
                    let depart = firstDepart + cadence * Double(k)
                    let dc = MancalaGeometry.center(of: dest)
                    plan.hand.append((depart, dc))
                    let destIndex = slots[dest].count
                    let rest = MancalaGeometry.restPoint(slot: dest, index: destIndex, stoneID: id)
                    slots[dest].append(id)
                    plan.segments[id, default: []] += [
                        .init(kind: .held, t0: segEnd[id] ?? 0, t1: depart, from: off, to: off),
                        .init(kind: .drop, t0: depart, t1: depart + fall,
                              from: CGPoint(x: dc.x + off.x, y: dc.y + off.y), to: rest, endIndex: destIndex),
                    ]
                    let landing = depart + fall * 0.80
                    plan.cues.append((landing, MancalaGeometry.isStore(dest) ? .storeTick : .pitTick))
                    lastEnd = depart + fall
                }

            case .captured(let seat, let pit, let opposite, _):
                let store = MancalaRules.store(of: seat)
                let movers = slots[opposite] + slots[pit]
                // Resting positions BEFORE the stones leave their pits.
                var fromPoints: [Int: CGPoint] = [:]
                for (i, id) in slots[opposite].enumerated() { fromPoints[id] = MancalaGeometry.restPoint(slot: opposite, index: i, stoneID: id) }
                for (i, id) in slots[pit].enumerated() { fromPoints[id] = MancalaGeometry.restPoint(slot: pit, index: i, stoneID: id) }
                slots[opposite] = []
                slots[pit] = []
                var end = lastEnd
                if animated {
                    let t0 = lastEnd + 0.34
                    plan.glows.append(.init(slots: [pit, opposite], t0: t0, t1: t0 + 0.55))
                    plan.cues.append((t0, .captureFlash))
                    for (i, id) in movers.enumerated() {
                        let ts = t0 + 0.50 + 0.07 * Double(i)
                        let storeIndex = slots[store].count
                        let rest = MancalaGeometry.restPoint(slot: store, index: storeIndex, stoneID: id)
                        plan.segments[id, default: []].append(
                            .init(kind: .glide, t0: ts, t1: ts + 0.42, from: fromPoints[id] ?? rest, to: rest, endIndex: storeIndex))
                        plan.cues.append((ts + 0.36, .storeTick))
                        end = ts + 0.42
                        slots[store].append(id)
                    }
                    lastEnd = end
                } else {
                    for id in movers { slots[store].append(id) }
                }

            case .extraTurn(let seat):
                extraTurnSeat = seat
                if animated {
                    let store = MancalaRules.store(of: seat)
                    plan.glows.append(.init(slots: [store], t0: lastEnd, t1: lastEnd + 1.0))
                }
                plan.cues.append((animated ? lastEnd + 0.05 : 0.0, .goAgain(seat: seat)))
                plan.cues.append((animated ? lastEnd + 1.15 : 1.1, .clearGoAgain))

            case .swept(let seat, let pits, _):
                let store = MancalaRules.store(of: seat)
                var fromPoints: [(Int, CGPoint)] = []
                for p in pits {
                    for (i, id) in slots[p].enumerated() {
                        fromPoints.append((id, MancalaGeometry.restPoint(slot: p, index: i, stoneID: id)))
                    }
                    slots[p] = []
                }
                if animated {
                    let t0 = lastEnd + 0.70
                    var end = t0
                    for (i, entry) in fromPoints.enumerated() {
                        let ts = t0 + 0.05 * Double(i)
                        let storeIndex = slots[store].count
                        let rest = MancalaGeometry.restPoint(slot: store, index: storeIndex, stoneID: entry.0)
                        plan.segments[entry.0, default: []].append(
                            .init(kind: .glide, t0: ts, t1: ts + 0.55, from: entry.1, to: rest, endIndex: storeIndex))
                        plan.cues.append((ts + 0.48, .storeTick))
                        end = ts + 0.55
                        slots[store].append(entry.0)
                    }
                    lastEnd = end
                } else {
                    for entry in fromPoints { slots[store].append(entry.0) }
                }

            case .gameWon, .draw:
                plan.cues.append((animated ? lastEnd + 0.25 : 0.1, .chime))

            default:
                break
            }
        }

        let tail: Double = extraTurnSeat != nil ? 0.95 : 0.30
        plan.duration = animated ? lastEnd + tail : max(0.35, extraTurnSeat != nil ? 1.2 : 0.35)
        plan.finalSlots = slots
        plan.cues.sort { $0.t < $1.t }
        return plan
    }
}
