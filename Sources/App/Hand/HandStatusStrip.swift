import SwiftUI

/// Top strip of the hand screen: who you are, the round, trump, and how your
/// bid is going. Glanceable — the party is at the table, not on this screen.
struct HandStatusStrip: View {
    @Bindable var client: GameClientController

    var body: some View {
        HStack(spacing: 12) {
            connectionDot
            VStack(alignment: .leading, spacing: 1) {
                Text(client.playerName)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.white)
                if let round = client.snapshot?.roundNumber {
                    Text("Round \(round)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            if let trump = client.snapshot?.trumpSuit {
                TrumpChip(suit: trump)
            }
            if let bid = client.snapshot?.myBid {
                BidProgressChip(bid: bid, taken: client.snapshot?.myTricksWon ?? 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25))
    }

    private var connectionDot: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .shadow(color: (isConnected ? Color.green : .orange).opacity(0.8), radius: 3)
    }

    private var isConnected: Bool {
        if case .connected = client.connectionState { return true }
        return false
    }
}

struct TrumpChip: View {
    let suit: Suit

    var body: some View {
        HStack(spacing: 4) {
            Text("Trump")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(suit.symbol)
                .font(.subheadline)
                .foregroundStyle(suit.isRed ? Color(red: 1, green: 0.5, blue: 0.45) : .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.12)))
    }
}

struct BidProgressChip: View {
    let bid: Int
    let taken: Int

    /// Green when on-track, gold when short, red when busted past the bid.
    private var stateColor: Color {
        if taken > bid { return Color(red: 0.9, green: 0.35, blue: 0.3) }
        if taken == bid { return Color(red: 0.4, green: 0.8, blue: 0.5) }
        return CardStyle.gold
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "target")
                .font(.caption2)
            Text("\(taken)/\(bid)")
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(stateColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.12)))
    }
}
