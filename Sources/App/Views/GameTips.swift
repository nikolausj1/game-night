import SwiftUI
import TipKit

/// The three "magic gesture" onboarding tips (accessibility-floor pass):
/// flicking a hand card, shaking/tipping the phone cup, and bumping the
/// table. Each fires once — TipKit tracks that itself (see `Tips.configure`
/// in `GameNightApp`) — via a `MaxDisplayCount(1)` option plus a single
/// boolean `@Parameter` the owning screen flips true when it's actually
/// relevant. Text reuses the app's existing italic ghost-hint voice.

/// Hand: first time it's your turn with cards to play.
struct HandFlickTip: Tip {
    @Parameter
    static var isEligible: Bool = false

    var title: Text { Text("Flick a card up to play it") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
    }

    var options: [TipOption] { MaxDisplayCount(1) }
}

/// Phone cup: first dice turn. Replaces the old `@AppStorage`-gated first-
/// use hint in DiceCupView (audit item: one mechanism, not two).
struct DiceCupPourTip: Tip {
    @Parameter
    static var isEligible: Bool = false

    var title: Text { Text("Shake to rattle, tip forward to pour") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
    }

    var options: [TipOption] { MaxDisplayCount(1) }
}

/// Table: first game with table motion enabled.
struct TableNudgeTip: Tip {
    @Parameter
    static var isEligible: Bool = false

    var title: Text { Text("Bump the table to nudge the felt") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
    }

    var options: [TipOption] { MaxDisplayCount(1) }
}

/// The default TipKit popover reads as a stray system control against
/// green felt — this renders the same title in the app's own italic
/// ghost-hint voice (gold-on-dark, serif) with a tap-to-dismiss instead.
/// Mounts nothing when the tip isn't currently eligible/shown.
struct GhostHintTipView<T: Tip>: View {
    let tip: T

    var body: some View {
        TipView(tip)
            .tipBackground(.black.opacity(0.4))
            .tipCornerRadius(12)
            .tint(CardStyle.gold)
    }
}
