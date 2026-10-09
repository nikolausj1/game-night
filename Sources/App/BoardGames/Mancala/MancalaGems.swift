import SwiftUI
import UIKit

/// The eight glass gems of the `MancalaStones` sheet (104 x 52 pt, a 4 x 2
/// grid of 26 pt cells: ruby, sapphire, emerald, amber / amethyst, pearl,
/// onyx, turquoise). Each gem is cropped out ONCE at the @2x/@3x pixel
/// resolution and cached, so Canvas can draw eight crisp sprites hundreds of
/// times a second.
enum MancalaGems {
    /// Gem index for a stone id. Deterministic, and balanced: of the 48
    /// stones each colour appears exactly six times, shuffled once by a fixed
    /// seed so neighbouring stones are never an obvious pattern.
    static func gem(forStone id: Int) -> Int { order[((id % order.count) + order.count) % order.count] }

    private static let order: [Int] = {
        var generator = SeededGenerator(seed: 0x6E_4A_3D)
        var gems = (0..<48).map { $0 % 8 }
        gems.shuffle(using: &generator)
        return gems
    }()

    /// Sheet geometry (fractions of the sheet's own size).
    private static let originX: [CGFloat] = [0.0192, 0.2692, 0.5192, 0.7692]
    private static let originY: [CGFloat] = [0.0385, 0.5385]
    private static let gemW: CGFloat = 0.2115
    private static let gemH: CGFloat = 0.4231

    static let sprites: [UIImage?] = {
        guard let sheet = UIImage(named: "MancalaStones"), let cg = sheet.cgImage else { return Array(repeating: nil, count: 8) }
        let pw = CGFloat(cg.width), ph = CGFloat(cg.height)
        return (0..<8).map { gem in
            let col = gem % 4, row = gem / 4
            // Pad a pixel so the antialiased rim isn't clipped, but stay
            // inside the 26 pt cell so a neighbour never bleeds in.
            let rect = CGRect(x: originX[col] * pw, y: originY[row] * ph, width: gemW * pw, height: gemH * ph)
                .insetBy(dx: -1, dy: -1)
                .intersection(CGRect(x: 0, y: 0, width: pw, height: ph))
            guard let cropped = cg.cropping(to: rect.integral) else { return nil }
            return UIImage(cgImage: cropped, scale: sheet.scale, orientation: .up)
        }
    }()
}
