import SwiftUI

/// Bidding on the phone: private, tactile, one decision presented honestly.
/// A horizontal wheel of big numbers; the coach whispers underneath.
struct BidEntryView: View {
    @Bindable var client: GameClientController
    @State private var bid: Int = 0

    private var maxBid: Int { client.snapshot?.cardsPerRound ?? 0 }
    private var isMyBidTurn: Bool {
        guard let snap = client.snapshot, let seat = client.mySeat else { return false }
        return snap.phase == .bidding && snap.turnSeat == seat
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(isMyBidTurn ? "How many tricks will you take?" : "Bidding…")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)

            if isMyBidTurn {
                bidWheel
                if let hint = coachHint {
                    CoachWhisper(text: hint)
                }
                Button {
                    Haptics.play()
                    client.placeBid(bid)
                } label: {
                    Text("Bid \(bid)")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .padding(.horizontal, 40)
            } else {
                waitingRow
            }
            Spacer()
        }
    }

    private var bidWheel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0...max(maxBid, 0), id: \.self) { value in
                    Button {
                        Haptics.tick()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { bid = value }
                    } label: {
                        Text("\(value)")
                            .font(.system(size: 34, weight: .bold, design: .serif).monospacedDigit())
                            .foregroundStyle(bid == value ? CardStyle.ink : .white.opacity(0.75))
                            .frame(width: 64, height: 64)
                            .background(
                                Circle().fill(bid == value ? CardStyle.gold : .white.opacity(0.10))
                            )
                            .scaleEffect(bid == value ? 1.15 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
        }
    }

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white.opacity(0.6))
            Text("Waiting for other bids")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// v1 heuristic: count near-certain winners. The full coach engine
    /// (teach mode, per-play hints) grows from this seam.
    private var coachHint: String? {
        guard let hand = client.snapshot?.myHand, !hand.isEmpty else { return nil }
        var strong = 0
        for card in hand {
            switch card.kind {
            case .wizard: strong += 1
            case .standard(let suit, let rank):
                if rank == 14 { strong += 1 }
                else if let trump = client.snapshot?.trumpSuit, suit == trump, rank >= 12 { strong += 1 }
            case .jester: break
            }
        }
        return "Coach: \(strong) likely \(strong == 1 ? "winner" : "winners") in this hand."
    }
}

struct CoachWhisper: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .font(.caption)
            Text(text)
                .font(.footnote)
        }
        .foregroundStyle(CardStyle.gold.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}
