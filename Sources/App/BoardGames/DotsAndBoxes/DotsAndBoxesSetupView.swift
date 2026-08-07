import SwiftUI

/// Pre-game overlay: pick a sheet size, seat 2-4 pencils (human or bot),
/// then start. This is a single-device, pass-and-play game — there's no
/// live `GameHostController` seat-builder tie-in the way card games have
/// (`SeatsBuilderView`); a "player" here is just a name and a color that
/// whoever's holding the iPad plays as when it's their turn.
struct DotsAndBoxesSetupView: View {
    var onStart: (_ gridSize: Int, _ players: [DotsAndBoxesPlayer]) -> Void
    var onClose: () -> Void

    private struct Draft: Identifiable {
        let id = UUID()
        var name: String
        var isBot: Bool
    }

    @State private var gridSize = 4
    @State private var drafts: [Draft] = [
        Draft(name: DemoData.names[0], isBot: false),
        Draft(name: DemoData.names[1], isBot: false),
    ]

    private var canStart: Bool { (2...4).contains(drafts.count) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("Dots & Boxes")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(CardStyle.stockTop)
                Text("Pass the iPad around the table. Finger's your pencil.")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
            }

            gridSizePicker

            VStack(spacing: 12) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    playerRow(index: index, draft: draft)
                }
            }

            HStack(spacing: 16) {
                Button {
                    Haptics.tick()
                    let next = DemoData.names[drafts.count % DemoData.names.count]
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        drafts.append(Draft(name: next, isBot: false))
                    }
                } label: {
                    Label("Add Pencil", systemImage: "plus.circle.fill")
                }
                .disabled(drafts.count >= 4)

                Button(role: .destructive) {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        _ = drafts.removeLast()
                    }
                } label: {
                    Label("Remove", systemImage: "minus.circle.fill")
                }
                .disabled(drafts.count <= 2)
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, design: .serif).weight(.semibold))
            .foregroundStyle(CardStyle.gold)

            HStack(spacing: 20) {
                Button("Cancel", action: onClose)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.white.opacity(0.6))

                Button {
                    Haptics.play()
                    let players = drafts.enumerated().map { index, draft -> DotsAndBoxesPlayer in
                        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        return DotsAndBoxesPlayer(name: trimmed.isEmpty ? "Player \(index + 1)" : trimmed,
                                                  colorIndex: index, isBot: draft.isBot)
                    }
                    onStart(gridSize, players)
                } label: {
                    Text("Start")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .frame(maxWidth: 200)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                .disabled(!canStart)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(CardStyle.feltGreen.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.4), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        )
    }

    private var gridSizePicker: some View {
        VStack(spacing: 8) {
            Text("Sheet Size")
                .font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(CardStyle.stockTop.opacity(0.7))
            Picker("Sheet size", selection: $gridSize) {
                ForEach(DotsAndBoxesEngine.allowedGridSizes, id: \.self) { size in
                    Text("\(size)×\(size)").tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
    }

    private func playerRow(index: Int, draft: Draft) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(DotsAndBoxesTheme.pencilColor(for: index))
                .frame(width: 22, height: 22)
            TextField("Name", text: Binding(
                get: { drafts[index].name },
                set: { drafts[index].name = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 180)
            Spacer()
            Picker("", selection: Binding(
                get: { drafts[index].isBot },
                set: { drafts[index].isBot = $0 }
            )) {
                Text("Human").tag(false)
                Text("Bot").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
    }
}
