import SwiftUI

/// One row in the GameHUD's disclosure panel. Two flavors:
/// - `HUDToggle(label:isOn:)` — a switch bound to live state (rules that
///   are safe to change mid-game, UX toggles like Auto-deal).
/// - `HUDToggle(label:action:)` — a one-shot tappable row (e.g. "New deal").
/// `label` doubles as the row's stable identity, so keep labels unique
/// within one HUD.
struct HUDToggle: Identifiable {
    let label: String
    let isOn: Binding<Bool>?
    let action: (() -> Void)?

    var id: String { label }

    init(label: String, isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
        self.action = nil
    }

    init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.isOn = nil
        self.action = action
    }
}

/// Compact top-right cluster for in-game screens: the game's name, a
/// gear disclosure of mid-game toggles, and an Exit button.
///
/// API: `GameHUD(title: String, onExit: @escaping () -> Void,
///               toggles: [HUDToggle] = [])`.
///
/// Integration (the lead mounts this):
/// - Place top-right: `.overlay(alignment: .topTrailing) { GameHUD(...) }`
///   with ~16pt padding; the panel expands DOWNWARD from the cluster, so
///   nothing above it needs clearance.
/// - `onExit` — wire to the existing close flow (`onClose` on
///   TableGameView / TableRootView). Exit is two-step inside the HUD: a tap
///   arms a gold "Sure?" confirm that disarms itself after 3 seconds, so a
///   stray elbow can't kill the game — the hold-to-close dial can retire or
///   stay as a backup.
/// - `toggles` — pass mid-game-safe rules and UX switches, e.g.
///     `HUDToggle(label: "Auto-deal", isOn: $autoDeal)` (lead binds this to
///       the live `rules.autoDeal`, applying it to the engine on change),
///     `HUDToggle(label: "Ask before blocking", isOn: $softEnforcement)`.
/// - Spectator screens: don't mount the HUD at all (it's all controls).
struct GameHUD: View {
    let title: String
    let onExit: () -> Void
    var toggles: [HUDToggle] = []

    @State private var expanded = false
    /// Two-step exit: first tap arms, second tap (within 3s) fires.
    @State private var exitArmed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            cluster
            if expanded, !toggles.isEmpty {
                panel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: exitArmed)
    }

    // MARK: - The capsule cluster

    private var cluster: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.92))
                .lineLimit(1)

            if !toggles.isEmpty {
                Button {
                    Haptics.tick()
                    expanded.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.subheadline)
                        .foregroundStyle(CardStyle.gold.opacity(expanded ? 1 : 0.75))
                        .rotationEffect(.degrees(expanded ? 45 : 0))
                }
                .buttonStyle(.plain)
            }

            exitButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.5))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }

    /// Elbow-proof exit: tap once to arm ("Sure?"), tap again to leave.
    /// Disarms itself after 3 seconds untouched.
    private var exitButton: some View {
        Button {
            if exitArmed {
                Haptics.play()
                exitArmed = false
                onExit()
            } else {
                Haptics.tick()
                exitArmed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { exitArmed = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                if exitArmed {
                    Text("Sure?")
                        .font(.system(.caption, design: .serif).weight(.bold))
                }
            }
            .foregroundStyle(exitArmed ? CardStyle.ink : CardStyle.stockTop.opacity(0.8))
            .padding(.horizontal, exitArmed ? 10 : 7)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(exitArmed ? CardStyle.gold : .white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - The disclosure panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(toggles) { toggle in
                if let isOn = toggle.isOn {
                    Toggle(isOn: isOn) {
                        Text(toggle.label)
                            .font(.system(.subheadline, design: .serif).weight(.semibold))
                            .foregroundStyle(CardStyle.stockTop)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: CardStyle.gold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } else if let action = toggle.action {
                    Button {
                        Haptics.tick()
                        action()
                    } label: {
                        HStack {
                            Text(toggle.label)
                                .font(.system(.subheadline, design: .serif).weight(.semibold))
                                .foregroundStyle(CardStyle.gold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(CardStyle.gold.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
    }
}

#Preview("Game HUD") {
    struct HUDPreview: View {
        @State private var autoDeal = true
        @State private var soft = true
        var body: some View {
            ZStack(alignment: .topTrailing) {
                CardStyle.feltGreen.ignoresSafeArea()
                GameHUD(
                    title: "UNO",
                    onExit: {},
                    toggles: [
                        HUDToggle(label: "Auto-deal", isOn: $autoDeal),
                        HUDToggle(label: "Ask before blocking", isOn: $soft),
                        HUDToggle(label: "New deal", action: {}),
                    ])
                    .padding(16)
            }
        }
    }
    return HUDPreview()
}
