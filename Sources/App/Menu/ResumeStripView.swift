import SwiftUI

/// Suspended games, front and center when there are any: a row of cards
/// above the game shelves, one per `ResumeEntry` in `ResumeCatalog` (engine
/// games, Cribbage, side games, dice, board games, Solitaire, all in one
/// list). Tap to resume; long-press any card to enter wiggle edit mode
/// (every card gets a corner ⓧ), tap ⓧ to delete immediately, no
/// confirmation, like springboard icon deletion. Tap anywhere else exits
/// edit mode without resuming.
struct ResumeStripView: View {
    let entries: [ResumeEntry]
    let onResume: (ResumeEntry) -> Void
    let onDelete: (ResumeEntry) -> Void

    @State private var isEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var deleteBadgeSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick Up Where You Left Off")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(entries) { entry in
                        ResumeCard(entry: entry, isEditing: isEditing, wiggles: !reduceMotion)
                            .onTapGesture {
                                if isEditing {
                                    exitEditing()
                                } else {
                                    Haptics.tick()
                                    onResume(entry)
                                }
                            }
                            .onLongPressGesture {
                                guard !isEditing else { return }
                                Haptics.arm()
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
                                    isEditing = true
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if isEditing {
                                    Button {
                                        Haptics.tick()
                                        onDelete(entry)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: deleteBadgeSize))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, CardStyle.crimson)
                                            .background(Circle().fill(.white).padding(3))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -8, y: -8)
                                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                                    .accessibilityLabel("Delete saved \(entry.title) game")
                                }
                            }
                            // Editing: keep the delete badge individually
                            // reachable (children: .contain). Otherwise the
                            // whole card reads as one resume button.
                            .accessibilityElement(children: isEditing ? .contain : .ignore)
                            .accessibilityLabel(isEditing ? "" : "\(entry.title), \(entry.subtitle)")
                            .accessibilityHint(isEditing ? "" : "Double-tap to resume")
                            .accessibilityAddTraits(isEditing ? [] : .isButton)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            // Tapping the scroll strip's own background (not a card, not the
            // ⓧ badge) is "anywhere else": it exits edit mode.
            .contentShape(Rectangle())
            .onTapGesture { if isEditing { exitEditing() } }
        }
    }

    private func exitEditing() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            isEditing = false
        }
    }
}

private struct ResumeCard: View {
    let entry: ResumeEntry
    var isEditing: Bool
    /// False under Reduce Motion: edit mode shows the ⓧ badges without
    /// the springboard wiggle.
    var wiggles: Bool

    @State private var wiggleUp = false
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 168

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.savedAt, relativeTo: Date())
    }

    /// A per-card phase offset (from the entry's own id) so a whole row of
    /// wiggling cards doesn't move in lockstep: reads as loose, alive
    /// felt-adjacent chaos rather than one rigid block sliding together.
    private var wigglePhaseDelay: Double {
        Double(abs(entry.id.hashValue) % 5) * 0.03
    }

    var body: some View {
        VStack(spacing: 6) {
            // The shelves' own card/dice/board art, picked by save kind,
            // so a suspended Yahtzee game wears the same pip die its tile
            // does instead of a generic glyph.
            ResumeKindEmblem(kind: entry.kind)
                .frame(height: GameEmblem.height)
            Text(entry.title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(entry.subtitle)
                .font(.system(.caption, design: .serif).italic())
                .foregroundStyle(CardStyle.stockTop.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(CardStyle.stockTop.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        )
        .rotationEffect(.degrees(isEditing && wiggles ? (wiggleUp ? 1.6 : -1.6) : 0))
        .animation(
            isEditing && wiggles
                ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true).delay(wigglePhaseDelay)
                : .easeOut(duration: 0.15),
            value: wiggleUp
        )
        .onChange(of: isEditing) { _, editing in
            wiggleUp = editing && wiggles
        }
    }
}
