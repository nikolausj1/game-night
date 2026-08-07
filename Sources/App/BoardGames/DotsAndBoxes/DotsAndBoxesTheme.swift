import SwiftUI

/// Dots & Boxes' own small design vocabulary: pencil colors and paper
/// tones. Kept separate from `CardStyle` because this game isn't a printed
/// card — it's a sheet of paper with pencil marks on it, a different
/// physical object with its own palette, even though it borrows the house
/// gold and serif type for chrome (buttons, the setup sheet, the HUD).
enum DotsAndBoxesTheme {
    /// Four pencils, in setup order. Deliberately muted/desaturated —
    /// "colored pencil," not a UI accent color — so a claimed line reads
    /// as drawn, not painted. Gold reuses `CardStyle.gold` so a gold
    /// pencil still feels like the same house gold everywhere else.
    static let pencilColors: [Color] = [
        Color(red: 0.30, green: 0.34, blue: 0.42),  // graphite blue-gray
        Color(red: 0.62, green: 0.16, blue: 0.14),  // pencil red
        Color(red: 0.20, green: 0.42, blue: 0.29),  // pencil green
        CardStyle.gold,                             // pencil gold
    ]

    static func pencilColor(for colorIndex: Int) -> Color {
        pencilColors[((colorIndex % pencilColors.count) + pencilColors.count) % pencilColors.count]
    }

    /// Off-white paper stock — warmer and duller than `CardStyle.stockTop`
    /// (real card ivory), closer to a legal pad than fresh printer paper.
    static let paperBase = Color(red: 0.949, green: 0.937, blue: 0.898)
    static let paperShadowEdge = Color(red: 0.80, green: 0.78, blue: 0.72)
    /// Faded ballpoint/pencil ink for the printed dot grid — never full
    /// black, a dot grid this old has gone soft gray-brown.
    static let inkFaded = Color(red: 0.50, green: 0.47, blue: 0.42)

    /// Handwriting font for box initials and the scoreboard headline.
    /// `SnellRoundhand` ships on every iOS device (no bundled font asset
    /// needed) and reads as genuinely cursive rather than a generic serif
    /// italic standing in for one.
    static let handwritingFont = "SnellRoundhand-Bold"
}
