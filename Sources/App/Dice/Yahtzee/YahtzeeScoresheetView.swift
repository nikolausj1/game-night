import SwiftUI

/// This game's own small paper vocabulary — reuses the house `PaperGraph`
/// stock (already shipped, already used by Dots & Boxes and Quarto) and the
/// same `SnellRoundhand` system font Dots & Boxes uses for handwriting, but
/// kept as its OWN theme rather than importing `DotsAndBoxesTheme`: a
/// scoresheet's ink is felt-tip ballpoint on a printed grid, not colored
/// pencil, and each player's column reads in their own `PlayerPalette`
/// color (the same color voice their table plate/turn-glow already use)
/// rather than Dots & Boxes' four fixed pencil colors.
enum YahtzeeSheetTheme {
    static let paperBase = Color(red: 0.965, green: 0.955, blue: 0.92)
    static let inkFaded = Color(red: 0.32, green: 0.30, blue: 0.28)
    static let handwritingFont = "SnellRoundhand-Bold"
}

/// The physical scoresheet lying on the felt near the rail: 13 category
/// rows (upper section, its bonus row, a divider, then the 7 lower-section
/// combinations), one handwritten column per player, plus a totals strip.
/// Category picking is a TABLE action — tapping an open cell in the CURRENT
/// ROLLER's own column, once they've rolled at least once this turn, scores
/// it (`onScore`); every other cell is inert. This is deliberate per the
/// platform-wave mission: holds and category choice both happen on the
/// table, never the phone — see `YahtzeeController`'s doc and
/// `DiceCupView`'s generalized standings screen, which only ever tells a
/// player to "pick a category on the table."
struct YahtzeeScoresheetView: View {
    @Bindable var controller: YahtzeeController
    var onScore: (YahtzeeCategory) -> Void

    @Environment(\.accessibilityReduceMotion) private var motionReduced

    private var scoreableSeat: Int? {
        guard !controller.gameOver, !controller.rollInFlight, controller.rollsUsed >= 1,
              controller.seats.indices.contains(controller.turnSeat),
              !controller.seats[controller.turnSeat].isBot else { return nil }
        return controller.turnSeat
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(YahtzeeSheetTheme.inkFaded.opacity(0.35))
                .padding(.vertical, 6)
            VStack(spacing: 2) {
                ForEach(YahtzeeCategory.upperOrder) { row($0) }
                upperBonusRow
                Divider().overlay(YahtzeeSheetTheme.inkFaded.opacity(0.35))
                    .padding(.vertical, 6)
                ForEach(YahtzeeCategory.lowerOrder) { row($0) }
            }
            Divider().overlay(YahtzeeSheetTheme.inkFaded.opacity(0.35))
                .padding(.vertical, 6)
            totalRow
        }
        .padding(16)
        .frame(width: sheetWidth)
        .background(sheetBackground)
        .rotationEffect(.degrees(-0.4))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 6, y: 10)
    }

    private var sheetWidth: CGFloat { 148 + CGFloat(max(1, controller.seats.count)) * 62 }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("YAHTZEE")
                .font(.custom(YahtzeeSheetTheme.handwritingFont, size: 20))
                .foregroundStyle(YahtzeeSheetTheme.inkFaded)
                .frame(width: 116, alignment: .leading)
            ForEach(controller.seats) { seat in
                VStack(spacing: 1) {
                    Text(seat.name)
                        .font(.system(.caption2, design: .serif).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(PlayerPalette.color(seat.colorIndex))
                    if seat.id == controller.turnSeat && !controller.gameOver {
                        Capsule()
                            .fill(PlayerPalette.color(seat.colorIndex))
                            .frame(width: 22, height: 3)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Rows

    private func row(_ category: YahtzeeCategory) -> some View {
        HStack(spacing: 0) {
            Text(category.label)
                .font(.system(.caption2, design: .serif)
                    .weight(category == .yahtzee ? .black : .semibold))
                .foregroundStyle(YahtzeeSheetTheme.inkFaded)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 116, alignment: .leading)
            ForEach(controller.seats) { seat in
                cell(category: category, seat: seat)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func cell(category: YahtzeeCategory, seat: YahtzeeController.YahtzeeSeat) -> some View {
        let entry = controller.scorecards[safe: seat.id]?.entries[category]
        let isScoreableCell = entry == nil && seat.id == scoreableSeat
        let preview = isScoreableCell ? controller.previewScore(category, forSeat: seat.id) : nil

        ZStack {
            if isScoreableCell {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(CardStyle.gold.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.55), lineWidth: 1))
            }
            // A category never unfills, so `entry` only ever makes ONE
            // nil → value transition in this cell's whole lifetime — the
            // ink "wipes in" via SwiftUI's own insertion transition on
            // that transition, no manual event-id bookkeeping needed.
            Group {
                if let entry {
                    Text("\(entry)")
                        .font(.custom(YahtzeeSheetTheme.handwritingFont, size: 18))
                        .foregroundStyle(PlayerPalette.color(seat.colorIndex))
                        .transition(motionReduced ? .opacity
                            : .scale(scale: 0.3).combined(with: .opacity))
                } else if let preview {
                    Text("\(preview)")
                        .font(.system(.caption2, design: .serif))
                        .foregroundStyle(CardStyle.gold.opacity(0.65))
                } else {
                    Text("–")
                        .font(.caption2)
                        .foregroundStyle(YahtzeeSheetTheme.inkFaded.opacity(0.25))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.62), value: entry)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isScoreableCell else { return }
            Haptics.arm()
            onScore(category)
        }
        .accessibilityLabel(accessibilityLabel(category: category, seat: seat, entry: entry, preview: preview))
        .accessibilityAddTraits(isScoreableCell ? .isButton : [])
    }

    private var upperBonusRow: some View {
        HStack(spacing: 0) {
            Text("Bonus (63+)")
                .font(.system(.caption2, design: .serif).italic())
                .foregroundStyle(YahtzeeSheetTheme.inkFaded.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 116, alignment: .leading)
            ForEach(controller.seats) { seat in
                let card = controller.scorecards[safe: seat.id]
                let earned = (card?.upperBonus ?? 0) > 0
                let remaining = max(0, YahtzeeScoring.upperBonusThreshold - (card?.upperSubtotal ?? 0))
                Text(earned ? "+35" : (card?.isComplete == true ? "—" : "\(remaining) to go"))
                    .font(.system(.caption2, design: .serif))
                    .foregroundStyle(earned ? CardStyle.gold : YahtzeeSheetTheme.inkFaded.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 20)
    }

    private var totalRow: some View {
        HStack(spacing: 0) {
            Text("Total")
                .font(.system(.subheadline, design: .serif).weight(.black))
                .foregroundStyle(YahtzeeSheetTheme.inkFaded)
                .frame(width: 116, alignment: .leading)
            ForEach(controller.seats) { seat in
                let isWinner = controller.gameOver && controller.winnerSeats.contains(seat.id)
                Text("\(controller.scorecards[safe: seat.id]?.total ?? 0)")
                    .font(.custom(YahtzeeSheetTheme.handwritingFont, size: 22))
                    .foregroundStyle(isWinner ? CardStyle.gold : PlayerPalette.color(seat.colorIndex))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func accessibilityLabel(category: YahtzeeCategory, seat: YahtzeeController.YahtzeeSeat,
                                    entry: Int?, preview: Int?) -> String {
        if let entry {
            return "\(seat.name), \(category.label): \(entry) points"
        }
        if let preview {
            return "\(seat.name), \(category.label), open. Tap to score \(preview) points."
        }
        return "\(seat.name), \(category.label), open"
    }

    // MARK: - Paper background

    /// Same "asset if it's landed, cheap procedural stand-in otherwise"
    /// convention `DotsAndBoxesPaperTexture`/`CardBackView` use — `PaperGraph`
    /// is already in the asset catalog (Dots & Boxes and Quarto both draw
    /// it today), so this resolves to the real texture in practice; the
    /// flat-tint fallback only matters if a future asset swap ever ships
    /// without it.
    private var sheetBackground: some View {
        ZStack {
            if let named = UIImage(named: "PaperGraph") {
                Image(uiImage: named)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                YahtzeeSheetTheme.paperBase
            }
            RadialGradient(colors: [.clear, .black.opacity(0.08)], center: .center,
                           startRadius: 60, endRadius: 360)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.black.opacity(0.1), lineWidth: 0.75))
    }
}
