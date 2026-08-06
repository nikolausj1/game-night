import SwiftUI

/// Top strip of the hand screen: who you are, the round, trump, and how your
/// bid is going. Glanceable — the party is at the table, not on this screen.
struct HandStatusStrip: View {
    @Bindable var client: GameClientController
    /// Wired by RoleRouter so "Leave table" (in the Menu sheet below) can
    /// pop back to the role picker. See HandRootView's doc comment for the
    /// one-line change that connects it; falls back to a NotificationCenter
    /// post if nothing observes it, so leaving still stops the session even
    /// unwired.
    var onLeave: (() -> Void)? = nil

    @State private var showMenu = false

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
            controlCluster
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25))
        .sheet(isPresented: $showMenu) {
            TableMenuSheet(onLeaveConfirmed: {
                showMenu = false
                leaveTable()
            })
        }
    }

    /// The upper-right control cluster: labeled capsules, not the old
    /// tiny unlabeled icon chips — "Sort", "Style" (free play only), and
    /// "Menu", which is where Leave Table and future toggles live.
    private var controlCluster: some View {
        HStack(spacing: 8) {
            HandSortChip()
            if client.snapshot?.gameKind == .freePlay {
                ThrowStyleChip()
            }
            MenuChip {
                Haptics.tick()
                showMenu = true
            }
        }
    }

    private func leaveTable() {
        client.session.stop()
        onLeave?() ?? NotificationCenter.default.post(name: .gameNightLeaveTable, object: nil)
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

/// Shared look for the upper-right control cluster: bigger than the old
/// icon-only chips and labeled, so a first-time player doesn't have to
/// guess what a bare glyph means. Serif label, gold hairline border, felt
/// fill — the same visual language as the rest of the app's chrome.
private struct ControlCapsuleLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.system(.caption, design: .serif).weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.14)))
        .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1))
    }
}

/// Labeled capsule: tap cycles as-dealt → grouped → by rank. Shares its
/// @AppStorage key with HandView, which does the actual reordering — this
/// chip is purely the tap target and current-mode glyph.
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
            ControlCapsuleLabel(icon: mode.icon, text: "Sort")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort: \(mode.rawValue)")
    }
}

/// Dev tool, free play only: which play animation your flicks use on the
/// table. Tap toggles between the trick-game friction slide and the
/// airborne pile-drop arc. Persisted so it survives app relaunch.
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
            ControlCapsuleLabel(icon: isPile ? "arrow.up.forward" : "arrow.right", text: "Style")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPile ? "Throw style: pile" : "Throw style: slide")
    }
}

/// Opens the small sheet with Leave Table and (later) other toggles.
struct MenuChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlCapsuleLabel(icon: "line.3.horizontal", text: "Menu")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }
}

/// The control cluster's "Menu" sheet: Leave Table today, room for future
/// per-hand toggles below it. Felt/serif/gold, matching SettingsView's
/// bespoke sheet look rather than a stock system List.
struct TableMenuSheet: View {
    /// Fired only after the leave is confirmed — the caller stops the
    /// session and navigates away.
    let onLeaveConfirmed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showLeaveConfirm = false

    var body: some View {
        ZStack {
            CardStyle.feltGreen.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Menu")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CardStyle.gold)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider().background(.white.opacity(0.15))

                Button {
                    Haptics.tick()
                    showLeaveConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Leave table")
                        Spacer()
                    }
                    .font(.system(.body, design: .serif).weight(.medium))
                    .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.35))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().background(.white.opacity(0.1))

                HStack {
                    Text("More table controls coming soon.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Spacer()
            }
        }
        .presentationDetents([.height(240), .medium])
        .confirmationDialog(
            "Leave the table?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave table", role: .destructive) { onLeaveConfirmed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to rejoin to keep playing.")
        }
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
