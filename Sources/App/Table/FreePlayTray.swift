import SwiftUI

/// Free Play's control tray: the sandbox's live dashboard. "Let me do
/// everything in Free Play — any game's stuff, no rules/player limits."
/// This is the one surface that lets the felt reconfigure itself while
/// sitting at the table: swap decks, and (later) drop dice on the felt.
///
/// FreePlayTray is presentation-only — a compact horizontal capsule meant
/// to sit bottom-center-left on the free-play table. It never touches
/// `GameHostController` or the engine directly; it only reports taps
/// through two closures and reads back whatever state its owner hands it.
/// The table view (owned elsewhere) decides placement and wiring; drop it
/// in with something like:
/// ```swift
/// FreePlayTray(selectedDeck: host.state?.rules.freePlayDeck ?? .standard52,
///              diceOn: diceOn,
///              onDeckChange: switchFreePlayDeck,
///              onToggleDice: { diceOn = $0 })
///     .position(x: 130, y: size.height - 44)
/// ```
///
/// ## Closure contract
///
/// - `onDeckChange(FreePlayDeck)` — fired when a different deck mini-back
///   is tapped. Free Play has no in-place reshuffle for this: `.newDeal`
///   only re-deals a game's active `round`, which free play leaves `nil`,
///   so it's a no-op there. Switching decks means restarting the free-play
///   table with the new deck baked into `RulesConfig`:
///   ```swift
///   func switchFreePlayDeck(_ deck: FreePlayDeck) {
///       var rules = host.state?.rules ?? RulesConfig()
///       rules.freePlayDeck = deck
///       host.tableAction(.startGame(.freePlay, rules,
///                                    seed: .random(in: .min ... .max)))
///   }
///   ```
///   That's a full restart (fresh draw pile, empty hands/table) — expected
///   for a "start over with a different deck" control, not a live swap of
///   cards already in play.
/// - `onToggleDice(Bool)` — fired with the toggle's new on/off value when
///   the Dice button is tapped. FreePlayTray owns no dice state of its
///   own; the dice-platform integration (`Sources/App/Dice/`) is left
///   entirely to whoever wires this in.
/// - `onToggleCoins(Bool)` — same contract as `onToggleDice`, for the coin
///   toy (`FreePlayCoinsLayer` in `Sources/App/Dice/FreePlayCoinToy.swift`).
///
/// All closures are fire-and-forget. `selectedDeck`/`diceOn`/`coinsOn` are
/// plain values, not bindings — the tray always renders whatever its
/// owner's source of truth currently says, so it can never drift out of
/// sync with what actually happened in the engine.
struct FreePlayTray: View {
    var selectedDeck: FreePlayDeck
    var diceOn: Bool
    var coinsOn: Bool = false
    var onDeckChange: (FreePlayDeck) -> Void
    var onToggleDice: (Bool) -> Void
    var onToggleCoins: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                deckButton(.standard52, badge: nil)
                deckButton(.wizard60, badge: "W")
                deckButton(.uno108, badge: nil)
            }
            Rectangle()
                .fill(CardStyle.gold.opacity(0.3))
                .frame(width: 1, height: 22)
            diceToggle
            coinsToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.4)))
    }

    // MARK: deck picker

    private func deckButton(_ deck: FreePlayDeck, badge: String?) -> some View {
        let isSelected = deck == selectedDeck
        return Button {
            Haptics.tick()
            onDeckChange(deck)
        } label: {
            miniBack(for: deck, badge: badge)
                .frame(height: 30)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? CardStyle.gold.opacity(0.35) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? CardStyle.gold : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    /// UNO already reads as its own deck (`UnoCardBackView`'s black/red
    /// art); standard and wizard share the same programmatic lattice back,
    /// so wizard gets a small corner badge to tell them apart at a glance.
    @ViewBuilder
    private func miniBack(for deck: FreePlayDeck, badge: String?) -> some View {
        switch deck {
        case .standard52, .wizard60:
            ZStack(alignment: .topTrailing) {
                CardBackView()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(CardStyle.ink)
                        .padding(3)
                        .background(Circle().fill(CardStyle.gold))
                        .offset(x: 4, y: -4)
                }
            }
        case .uno108:
            UnoCardBackView()
        }
    }

    // MARK: dice toggle

    private var diceToggle: some View {
        Button {
            Haptics.tick()
            onToggleDice(!diceOn)
        } label: {
            Label("Dice", systemImage: diceOn ? "die.face.5.fill" : "die.face.5")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(diceOn ? CardStyle.ink : CardStyle.gold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(diceOn ? CardStyle.gold : .white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: coins toggle

    private var coinsToggle: some View {
        Button {
            Haptics.tick()
            onToggleCoins(!coinsOn)
        } label: {
            Label("Coins", systemImage: coinsOn ? "circle.circle.fill" : "circle.circle")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(coinsOn ? CardStyle.ink : CardStyle.gold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(coinsOn ? CardStyle.gold : .white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview("Free Play tray") {
    VStack(spacing: 20) {
        FreePlayTray(selectedDeck: .standard52, diceOn: false, onDeckChange: { _ in }, onToggleDice: { _ in })
        FreePlayTray(selectedDeck: .wizard60, diceOn: true, coinsOn: true, onDeckChange: { _ in }, onToggleDice: { _ in }, onToggleCoins: { _ in })
        FreePlayTray(selectedDeck: .uno108, diceOn: false, onDeckChange: { _ in }, onToggleDice: { _ in })
    }
    .padding(40)
    .background(CardStyle.feltGreen)
}
