import SwiftUI

/// The customization sheet: pick a card back and a table skin. Same design
/// language as the rest of the app — parchment and felt, serif headers, gold
/// accents, no gray system Forms. Presented as a sheet from the table's menu.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeStore.shared

    var body: some View {
        ZStack {
            backgroundFelt

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        cardBacksSection
                        tableSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }
                footer
            }
        }
    }

    // MARK: background

    private var backgroundFelt: some View {
        RoundedRectangle(cornerRadius: 0, style: .continuous)
            .fill(
                RadialGradient(colors: [CardStyle.feltGreen.opacity(1.05),
                                        CardStyle.feltGreen,
                                        CardStyle.feltGreen.opacity(0.8)],
                               center: .center, startRadius: 60, endRadius: 900)
            )
            .ignoresSafeArea()
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Table Settings")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(CardStyle.stockTop)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text("Choose a card back and a table")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(CardStyle.gold)
        }
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(CardStyle.stockTop.opacity(0.7), .black.opacity(0.25))
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
        }
    }

    // MARK: card backs

    private var cardBacksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Card Backs")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(CardBackCatalog.options) { option in
                        CardBackSwatch(
                            option: option,
                            isSelected: theme.selectedBack == option.key
                        ) {
                            Haptics.tick()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                theme.selectedBack = option.key
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: table skins

    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Table")
            HStack(spacing: 18) {
                ForEach(TableSkin.all) { skin in
                    TableSkinSwatch(
                        skin: skin,
                        isSelected: theme.selectedSkin == skin.key
                    ) {
                        Haptics.tick()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            theme.selectedSkin = skin.key
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption, design: .serif).weight(.bold))
            .kerning(1.5)
            .foregroundStyle(CardStyle.gold)
    }

    // MARK: footer

    private var footer: some View {
        Text("Game Night \(appVersionString)")
            .font(.system(.caption2, design: .serif))
            .foregroundStyle(CardStyle.stockTop.opacity(0.45))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.12))
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build { return "v\(version) (\(build))" }
        return "v\(version)"
    }
}

/// One card-back option in the horizontal gallery: a real, miniature
/// CardBackView (so what you pick is exactly what you'll see on the table)
/// with a gold selection ring and its name underneath.
private struct CardBackSwatch: View {
    let option: CardBackOption
    let isSelected: Bool
    let action: () -> Void

    private let width: CGFloat = 90

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                CardBackView(forcedBackImage: option.imageName)
                    .frame(width: width)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: CardStyle.cornerRadius(width: width), style: .continuous)
                            .strokeBorder(isSelected ? CardStyle.gold : .clear, lineWidth: 3)
                            .padding(-3)
                    )
                Text(option.displayName)
                    .font(.system(.caption, design: .serif).weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? CardStyle.gold : CardStyle.stockTop.opacity(0.85))
                    .lineLimit(1)
                    .frame(width: width + 16)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One table-skin option: a mini felt rectangle with a rail border, so the
/// swatch reads as "a little table" rather than a flat color chip.
private struct TableSkinSwatch: View {
    let skin: TableSkin
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(skin.railColor)
                    .frame(width: 108, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                RadialGradient(colors: [skin.feltHighlight, skin.feltBase],
                                               center: .center, startRadius: 4, endRadius: 60)
                            )
                            .padding(7)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(skin.accentGold.opacity(0.6), lineWidth: 1.5)
                            .padding(7)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? CardStyle.gold : .clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                Text(skin.displayName)
                    .font(.system(.caption, design: .serif).weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? CardStyle.gold : CardStyle.stockTop.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("Settings") {
    SettingsView()
}
