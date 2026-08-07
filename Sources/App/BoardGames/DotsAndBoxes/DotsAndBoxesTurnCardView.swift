import SwiftUI

/// A small card pinned at the paper's edge: whose pencil it is right now.
/// Kept upright rather than rotated to face whoever's "across the table" —
/// unlike the card games, Dots & Boxes has no seat geometry at all (players
/// are just an ordered list, not positions around the felt), so there's no
/// principled "which way is across" to rotate toward. Pass-and-play already
/// asks the group to physically hand the iPad to the next pencil; an
/// upright card is one less thing to parse mid-handoff. Documented as a
/// judgment call per the build brief, not an oversight.
struct DotsAndBoxesTurnCardView: View {
    let player: DotsAndBoxesPlayer
    var isBotThinking: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .foregroundStyle(DotsAndBoxesTheme.pencilColor(for: player.colorIndex))
            Text(isBotThinking ? "\(player.name) is thinking…" : "\(player.name)’s pencil")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(CardStyle.stockTop)
                .overlay(
                    Capsule().strokeBorder(DotsAndBoxesTheme.pencilColor(for: player.colorIndex).opacity(0.55), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isBotThinking ? "\(player.name) is thinking" : "\(player.name)'s turn")
    }
}
