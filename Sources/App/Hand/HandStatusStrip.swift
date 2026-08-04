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
                if let round = client.snapshot?.round?.roundNumber {
                    Text("Round \(round)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            if let trump = client.snapshot?.round?.trumpSuit {
                // UNO reuses trumpSuit as the wire format for a declared
                // color — show it as a color swatch, not a suit glyph.
                if client.snapshot?.gameKind == .uno {
                    UnoColorChip(color: trump.unoColor)
                } else {
                    TrumpChip(suit: trump)
                }
            }
            if let bid = myBid {
                BidProgressChip(bid: bid, taken: myTricksWon ?? 0)
            }
            if client.snapshot?.gameKind == .freePlay {
                ThrowStyleChip()
            }
            HandSortChip()
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

    // Bids/tricks live on RoundState now (keyed by seat), not flattened onto
    // the snapshot — trick-taking games only, so nil for UNO/Crazy Eights/
    // Free Play.
    private var myBid: Int? {
        guard let snap = client.snapshot else { return nil }
        return snap.round?.bids[snap.mySeat]
    }

    private var myTricksWon: Int? {
        guard let snap = client.snapshot else { return nil }
        return snap.round?.tricksWon[snap.mySeat]
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

/// UNO's equivalent of TrumpChip: the declared color after a wild, shown as
/// a swatch rather than a suit glyph.
struct UnoColorChip: View {
    let color: UnoColor

    var body: some View {
        HStack(spacing: 4) {
            Text("Color")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Circle()
                .fill(UnoStyle.field(for: color))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.12)))
    }
}

/// One small capsule, no label: tap cycles as-dealt → grouped → by rank.
/// Shares its @AppStorage key with HandView, which does the actual
/// reordering — this chip is purely the tap target and current-mode glyph.
struct HandSortChip: View {
    @AppStorage("gn.handSort") private var sortModeRaw: String = HandSortMode.asDealt.rawValue

    private var mode: HandSortMode { HandSortMode(rawValue: sortModeRaw) ?? .asDealt }

    var body: some View {
        Button {
            Haptics.tick()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                sortModeRaw = mode.next.rawValue
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Dev tool, free play only: which play animation your flicks use on the
/// table. Tap toggles between the trick-game friction slide and the
/// airborne pile-drop arc. Persisted so it survives app relaunch, matches
/// HandSortChip's small capsule footprint.
struct ThrowStyleChip: View {
    @AppStorage("gn.devThrowStyle") private var throwStyleRaw: String = "slide"

    private var isPile: Bool { throwStyleRaw == "pile" }

    var body: some View {
        Button {
            Haptics.tick()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                throwStyleRaw = isPile ? "slide" : "pile"
            }
        } label: {
            Image(systemName: isPile ? "arrow.up.forward" : "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPile ? "Throw style: pile" : "Throw style: slide")
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
