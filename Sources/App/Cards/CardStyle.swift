import SwiftUI

/// The printed-card design language. One place to tune the whole deck.
enum CardStyle {
    /// Poker card aspect: 2.5" × 3.5".
    static let aspectRatio: CGFloat = 2.5 / 3.5

    // Ivory card stock, not pure white — printed cards are warm.
    static let stockTop = Color(red: 0.988, green: 0.973, blue: 0.929)
    static let stockBottom = Color(red: 0.965, green: 0.941, blue: 0.882)

    // Rich ink tones, not #F00/#000 — old-print feel.
    static let crimson = Color(red: 0.702, green: 0.204, blue: 0.180)
    static let ink = Color(red: 0.118, green: 0.129, blue: 0.141)
    static let gold = Color(red: 0.760, green: 0.620, blue: 0.330)
    static let feltGreen = Color(red: 0.180, green: 0.369, blue: 0.282)
    static let wizardIndigo = Color(red: 0.235, green: 0.180, blue: 0.420)
    static let jesterPlum = Color(red: 0.549, green: 0.243, blue: 0.365)

    static func inkColor(for suit: Suit) -> Color {
        suit.isRed ? crimson : ink
    }

    /// Corner radius scales with card size (real cards ≈ 9% of width).
    static func cornerRadius(width: CGFloat) -> CGFloat { width * 0.09 }
}
