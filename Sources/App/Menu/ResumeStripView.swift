import SwiftUI

/// Suspended games, front and center when there are any: a row of cards
/// above the game picker. Tap to resume; long-press any card to enter wiggle
/// edit mode (every card gets a corner ⓧ), tap ⓧ to delete immediately — no
/// confirmation, like springboard icon deletion. Tap anywhere else exits
/// edit mode without resuming.
struct ResumeStripView: View {
    let games: [SavedGame]
    let onResume: (SavedGame) -> Void
    let onDelete: (SavedGame) -> Void

    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick Up Where You Left Off")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.leading, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(games) { saved in
                        ResumeCard(saved: saved, isEditing: isEditing)
                            .onTapGesture {
                                if isEditing {
                                    exitEditing()
                                } else {
                                    Haptics.tick()
                                    onResume(saved)
                                }
                            }
                            .onLongPressGesture {
                                guard !isEditing else { return }
                                Haptics.arm()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    isEditing = true
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if isEditing {
                                    Button {
                                        Haptics.tick()
                                        onDelete(saved)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 22))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, CardStyle.crimson)
                                            .background(Circle().fill(.white).padding(3))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -8, y: -8)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            // Tapping the scroll strip's own background (not a card, not the
            // ⓧ badge) is "anywhere else" — it exits edit mode.
            .contentShape(Rectangle())
            .onTapGesture { if isEditing { exitEditing() } }
        }
    }

    private func exitEditing() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isEditing = false
        }
    }
}

private struct ResumeCard: View {
    let saved: SavedGame
    var isEditing: Bool

    @State private var wiggleUp = false

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: saved.savedAt, relativeTo: Date())
    }

    /// A per-card phase offset (from the save's own id) so a whole row of
    /// wiggling cards doesn't move in lockstep — reads as loose, alive
    /// felt-adjacent chaos rather than one rigid block sliding together.
    private var wigglePhaseDelay: Double {
        Double(abs(saved.id.hashValue) % 5) * 0.03
    }

    var body: some View {
        VStack(spacing: 8) {
            // The picker's own card-art mark, not the raw emoji `emblem`
            // string — a suspended UNO game shouldn't wear a rainbow on its
            // resume card when the picker itself hasn't since the redesign.
            GameEmblem(kind: saved.gameKind)
                .frame(height: GameEmblem.height)
            Text(saved.label)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop)
                .lineLimit(1)
            Text(relativeTime)
                .font(.caption)
                .foregroundStyle(CardStyle.stockTop.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .frame(width: 152, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        )
        .rotationEffect(.degrees(isEditing ? (wiggleUp ? 1.6 : -1.6) : 0))
        .animation(
            isEditing
                ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true).delay(wigglePhaseDelay)
                : .easeOut(duration: 0.15),
            value: wiggleUp
        )
        .onChange(of: isEditing) { _, editing in
            wiggleUp = editing
        }
    }
}
