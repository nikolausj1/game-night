import SwiftUI

/// Suspended games, front and center when there are any: a row of cards
/// above the game picker. Tap to resume, long-press to delete.
struct ResumeStripView: View {
    let games: [SavedGame]
    let onResume: (SavedGame) -> Void
    let onDelete: (SavedGame) -> Void

    @State private var pendingDelete: SavedGame?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick Up Where You Left Off")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.gold.opacity(0.85))
                .padding(.leading, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(games) { saved in
                        ResumeCard(saved: saved)
                            .onTapGesture {
                                Haptics.tick()
                                onResume(saved)
                            }
                            .onLongPressGesture {
                                Haptics.arm()
                                pendingDelete = saved
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .confirmationDialog(
            "Delete this saved game? This can't be undone.",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Save", role: .destructive) {
                if let saved = pendingDelete { onDelete(saved) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }
}

private struct ResumeCard: View {
    let saved: SavedGame

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: saved.savedAt, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(saved.gameKind.emblem)
                .font(.system(size: 32))
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
    }
}
