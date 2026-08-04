import SwiftUI

/// Persists the player's cosmetic choices — which card back and which table
/// skin to render — and hands out the catalog of what's available. Tiny,
/// single source of truth; every render call site (CardBackView,
/// TableSurface, SettingsView) reads through this instead of its own state.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var selectedBack: String {
        didSet { UserDefaults.standard.set(selectedBack, forKey: Keys.back) }
    }
    var selectedSkin: String {
        didSet { UserDefaults.standard.set(selectedSkin, forKey: Keys.skin) }
    }

    private enum Keys {
        static let back = "theme.selectedBack"
        static let skin = "theme.selectedSkin"
    }

    init() {
        selectedBack = UserDefaults.standard.string(forKey: Keys.back) ?? "guilloche"
        selectedSkin = UserDefaults.standard.string(forKey: Keys.skin) ?? "classicClub"
    }
}

/// One card-back option: a stable key (persisted + used by games that force
/// a specific back, like UNO), a display name for the gallery, and the
/// imageset name to render — nil means the programmatic lattice fallback.
struct CardBackOption: Identifiable, Hashable {
    let key: String
    let displayName: String
    let imageName: String?

    var id: String { key }
}

enum CardBackCatalog {
    static let options: [CardBackOption] = [
        CardBackOption(key: "guilloche", displayName: "Guilloché", imageName: "CardBackArt"),
        CardBackOption(key: "rider_blue", displayName: "Rider Blue", imageName: "CardBack_rider_blue"),
        CardBackOption(key: "rider_red", displayName: "Rider Red", imageName: "CardBack_rider_red"),
        CardBackOption(key: "diamond_red", displayName: "Diamond Red", imageName: "CardBack_diamond_red"),
        CardBackOption(key: "diamond_blue", displayName: "Diamond Blue", imageName: "CardBack_diamond_blue"),
        CardBackOption(key: "deco_gold", displayName: "Art Deco Gold", imageName: "CardBack_deco_gold"),
        CardBackOption(key: "wave_indigo", displayName: "Seigaiha Wave", imageName: "CardBack_wave_indigo"),
        CardBackOption(key: "rocket_fun", displayName: "Rocket Fun", imageName: "CardBack_rocket_fun"),
        CardBackOption(key: "classic", displayName: "Classic Lattice", imageName: nil),
    ]

    static func option(for key: String) -> CardBackOption {
        options.first { $0.key == key } ?? options[0]
    }
}
