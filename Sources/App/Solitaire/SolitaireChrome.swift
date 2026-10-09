import SwiftUI

/// Presentation-only controls in the app's brass/gold chrome language —
/// no engine coupling, just the pieces `SolitaireView` arranges. Split out
/// of `SolitaireView.swift` because that file already carries the board,
/// the gesture plumbing, and the flight/animation state; none of that
/// belongs mixed in with what's fundamentally static button/sheet layout.

// MARK: - Brass corner button (Undo, New Deal)

/// A round brass-rimmed icon button, the same visual family as the app's
/// other felt-side controls (`GameHUD`'s capsule, `HoldToCloseButton`'s
/// ring) — dark glass fill, gold rim, gold glyph, dims when disabled
/// instead of disappearing so its position on the felt stays predictable.
struct SolitaireBrassButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.5))
                    .overlay(Circle().strokeBorder(CardStyle.gold.opacity(isEnabled ? 0.55 : 0.22), lineWidth: 1.5))
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isEnabled ? CardStyle.gold : CardStyle.gold.opacity(0.28))
            }
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Press-and-hold exit dial

/// Local twin of `TableGameView.HoldToCloseButton` (that one lives inside a
/// file this worker's allowlist doesn't cover) — same elbow-proof
/// press-and-hold ring, same visual language, kept independent so
/// Solitaire never has to import TableGameView to get it.
struct SolitaireHoldToCloseButton: View {
    @Binding var progress: CGFloat
    let onComplete: () -> Void
    @State private var holding = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.55)).frame(width: 64, height: 64)
            Circle().stroke(.white.opacity(0.15), lineWidth: 4).frame(width: 56, height: 56)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(CardStyle.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .scaleEffect(holding ? 1.1 : 1)
        .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 40) {
            Haptics.play()
            progress = 0
            onComplete()
        } onPressingChanged: { pressing in
            holding = pressing
            if pressing {
                Haptics.tick()
                withAnimation(.linear(duration: 1.2)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: holding)
        .accessibilityLabel("Close Solitaire")
        .accessibilityHint("Press and hold to close")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Rules sheet

/// The draw-1/draw-3 toggle, presented as a small sheet (per spec) rather
/// than `RulesPanelView`'s inline disclosure — Solitaire has exactly one
/// rule to expose, so a whole persistent panel would outweigh its content.
struct SolitaireRulesSheet: View {
    @Binding var drawMode: SolitaireDrawMode
    let onNewDeal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Draw", selection: $drawMode) {
                        ForEach(SolitaireDrawMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(drawMode == .drawOne
                         ? "One card turns from the stock at a time."
                         : "Three cards turn at once; only the top one is playable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Stock")
                }
                Section {
                    Text("Redeals are unlimited — the stock keeps recycling from the waste for as long as you want to keep trying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("New Deal…", role: .destructive) {
                        dismiss()
                        onNewDeal()
                    }
                }
            }
            .navigationTitle("Solitaire Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Win celebration

/// The trophy moment's aftermath — a tasteful felt glow, not confetti. A
// MARK: - Auto-finish prompt

/// Appears once the board is provably safe to autoplay (see
/// `SolitaireState.isAutoCompletable`) — the trophy-moment cascade is
/// player-initiated rather than a surprise auto-trigger, so a player mid-
/// thought isn't yanked into a victory lap they didn't ask for yet.
struct SolitaireAutoFinishPrompt: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.arm()
            action()
        } label: {
            Label("Auto-Finish", systemImage: "wand.and.stars")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(CardStyle.gold))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
}
