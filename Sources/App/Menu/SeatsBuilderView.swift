import SwiftUI

/// Live phones fill human seats automatically (`host.lobbyPlayers`); the
/// +/- controls add or remove bot seats, filled from `BotRoster`, up to the
/// selected game's player limits. Bot names are editable via tap.
struct SeatsBuilderView: View {
    @Bindable var host: GameHostController
    let game: GameKind
    @Binding var botDrafts: [BotSeatDraft]

    @State private var editingBotID: BotSeatDraft.ID?
    @State private var editingName = ""

    private var totalSeats: Int { host.lobbyPlayers.count + botDrafts.count }
    private var canAddBot: Bool { totalSeats < game.maxPlayers }
    private var canRemoveBot: Bool { !botDrafts.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                ForEach(Array(host.lobbyPlayers.enumerated()), id: \.offset) { index, player in
                    SeatChip(name: player.name, colorIndex: index, isBot: false, onTap: {})
                        .transition(.scale.combined(with: .opacity))
                }
                ForEach(Array(botDrafts.enumerated()), id: \.element.id) { index, bot in
                    SeatChip(
                        name: bot.name,
                        // BotRoster ties a color to a name for life — match
                        // it here so the builder chip is the same color the
                        // seat plate will be once the game deals.
                        colorIndex: BotRoster.identity(named: bot.name)?.colorIndex
                            ?? (host.lobbyPlayers.count + index),
                        isBot: true,
                        onTap: {
                            Haptics.tick()
                            editingName = bot.name
                            editingBotID = bot.id
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                ForEach(0..<max(0, game.minPlayers - totalSeats), id: \.self) { _ in
                    EmptySeatChip()
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: totalSeats)

            HStack(spacing: 18) {
                SeatStepperButton(systemImage: "minus", enabled: canRemoveBot,
                                  accessibilityLabel: "Remove a bot") {
                    Haptics.tick()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        botDrafts.removeLast()
                    }
                }
                Text("Add a Bot")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.7))
                SeatStepperButton(systemImage: "plus", enabled: canAddBot,
                                  accessibilityLabel: "Add a bot") {
                    addBot()
                }
            }
        }
        .alert("Rename Bot", isPresented: Binding(
            get: { editingBotID != nil },
            set: { if !$0 { editingBotID = nil } }
        )) {
            TextField("Name", text: $editingName)
            Button("Save") {
                if let id = editingBotID, let index = botDrafts.firstIndex(where: { $0.id == id }) {
                    let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { botDrafts[index].name = trimmed }
                }
                editingBotID = nil
            }
            Button("Cancel", role: .cancel) { editingBotID = nil }
        }
    }

    private func addBot() {
        guard canAddBot else { return }
        Haptics.tick()
        let identity = BotRoster.random(count: 1).first
        let name = identity?.name ?? "Bot \(botDrafts.count + 1)"
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            botDrafts.append(BotSeatDraft(name: name))
        }
    }
}

/// A bot seat before it's locked into the engine's seat order — kept local
/// to the menu so renaming/removing never needs to renumber anything until
/// "Deal the cards" assigns final seat ids.
struct BotSeatDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
}

private struct SeatChip: View {
    let name: String
    let colorIndex: Int
    let isBot: Bool
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var botBadgeSize: CGFloat = 18

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(PlayerPalette.color(colorIndex))
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(.title, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                if isBot {
                    Text("🤖")
                        .font(.system(size: botBadgeSize))
                        .padding(3)
                        .background(Circle().fill(CardStyle.ink))
                        .overlay(Circle().strokeBorder(CardStyle.gold.opacity(0.6), lineWidth: 1))
                        .offset(x: 6, y: 6)
                }
            }
            Text(name)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CardStyle.stockTop)
                .lineLimit(1)
                .frame(maxWidth: 84)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isBot { onTap() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBot ? "\(name), bot" : name)
        .accessibilityHint(isBot ? "Double-tap to rename" : "")
        .accessibilityAddTraits(isBot ? .isButton : [])
    }
}

private struct EmptySeatChip: View {
    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(CardStyle.stockTop.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .frame(width: 64, height: 64)
            Text("Open seat")
                .font(.subheadline)
                .foregroundStyle(CardStyle.stockTop.opacity(0.4))
        }
    }
}

private struct SeatStepperButton: View {
    let systemImage: String
    let enabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(enabled ? CardStyle.ink : CardStyle.stockTop.opacity(0.3))
                .frame(width: 36, height: 36)
                .background(Circle().fill(enabled ? CardStyle.gold : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
