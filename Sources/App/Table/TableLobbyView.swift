import SwiftUI

/// The pre-deal home screen now lives in `Sources/App/Menu/MenuView.swift`.
/// This file survives only to host `PlayerPalette` — the one seat color
/// voice shared by the menu, the seat plates, and the recap overlays — so
/// none of those files needed to change when the lobby moved.
enum PlayerPalette {
    private static let colors: [Color] = [
        Color(red: 0.75, green: 0.29, blue: 0.24), // brick
        Color(red: 0.24, green: 0.44, blue: 0.66), // lake
        Color(red: 0.80, green: 0.58, blue: 0.22), // amber
        Color(red: 0.42, green: 0.32, blue: 0.58), // plum
        Color(red: 0.30, green: 0.55, blue: 0.42), // pine
        Color(red: 0.72, green: 0.42, blue: 0.55), // rose
        Color(red: 0.45, green: 0.50, blue: 0.55), // slate
        Color(red: 0.60, green: 0.46, blue: 0.32), // saddle
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}
