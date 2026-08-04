import SwiftUI

/// A compact disclosure exposing the selected game's house-rule toggles in
/// plain language. Collapsed by default — the deal button stays reachable
/// without scrolling past rules nobody's changing tonight.
struct RulesPanelView: View {
    let game: GameKind
    @Binding var rules: RulesConfig

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                rows
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "scroll.fill")
                Text("House Rules")
            }
            .font(.system(.headline, design: .serif))
            .foregroundStyle(CardStyle.gold)
        }
        .tint(CardStyle.gold)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.25), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var rows: some View {
        switch game {
        case .wizard, .ohHell:
            RuleToggleRow(title: "Screw the Dealer",
                          subtitle: "Dealer's bid can't make everyone's bids add up exactly.",
                          isOn: $rules.screwTheDealer)
            RuleToggleRow(title: "Miss Still Scores",
                          subtitle: "A missed bid still earns a point per trick taken.",
                          isOn: $rules.missScoresTricks)
            RuleToggleRow(title: "Ask Before Blocking",
                          subtitle: "Illegal plays get a warning instead of a hard block.",
                          isOn: $rules.softEnforcement)
        case .crazyEights:
            RuleToggleRow(title: "Ask Before Blocking",
                          subtitle: "Illegal plays get a warning instead of a hard block.",
                          isOn: $rules.softEnforcement)
        case .uno:
            RuleToggleRow(title: "Stack Draw Cards",
                          subtitle: "Draw 2s and Wild Draw 4s pile up until someone plays one or draws the lot.",
                          isOn: $rules.stackDrawCards)
            RuleToggleRow(title: "Draw Until Playable",
                          subtitle: "Can't play? Keep drawing until you can.",
                          isOn: $rules.drawUntilPlayable)
        case .freePlay:
            EmptyView()
        }
    }
}

private struct RuleToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CardStyle.stockTop)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(CardStyle.stockTop.opacity(0.6))
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: CardStyle.gold))
    }
}
