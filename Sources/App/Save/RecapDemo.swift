import SwiftUI

/// Sim-verify hook for the game-over recaps, one flag for every game:
///
///     -demoRecap <kind>
///
/// drops the table straight onto a finished game's `GameRecapCard` for
/// that kind, over the felt, so every recap can be eyeballed from one
/// launch argument instead of playing sixteen games to the end. Kinds are
/// the save-slot names: `battleship ginRummy blackjack liarsDice goFish
/// oldMaid war cribbage yahtzee zilch shutBox mancala checkers connectFour
/// quarto solitaire`. An unknown kind lists them on screen (loud, not
/// blank — same spirit as `SideGameMissingView`).
///
/// ROUTING (RoleRouter.swift, one branch ahead of `roleSwitch`, the same
/// shape as `-demoSolitaire`):
///
///     } else if let kind = RecapDemo.requestedKind {
///         RecapDemo.view(for: kind)
///     }
///
/// The cards here are built from representative finished-game numbers
/// (roster bots, plausible totals) through the SAME `GameRecapCard` the
/// live views mount, so what this shows is exactly the component the
/// player sees — only the figures are staged, never the card.
enum RecapDemo {
    static var requestedKind: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-demoRecap"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static let kinds = ["battleship", "ginRummy", "blackjack", "liarsDice", "goFish", "oldMaid", "war",
                        "cribbage", "yahtzee", "zilch", "shutBox", "mancala", "checkers", "connectFour",
                        "quarto", "solitaire"]

    @ViewBuilder
    static func view(for kind: String) -> some View {
        ZStack {
            TableSurface()
            if let card = card(for: kind) {
                card
            } else {
                VStack(spacing: 10) {
                    Text("No recap demo for “\(kind)”")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(CardStyle.gold)
                    Text(kinds.joined(separator: " · "))
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(CardStyle.stockTop.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            }
        }
        .statusBarHidden()
    }

    private static func color(_ name: String, fallback: Int) -> Int {
        BotRoster.identity(named: name)?.colorIndex ?? fallback
    }

    private static func row(_ seat: Int, _ name: String, _ score: String, _ detail: String? = nil,
                            winner: Bool = false, colorIndex: Int? = nil) -> RecapRow {
        RecapRow(id: seat, name: name, colorIndex: colorIndex ?? color(name, fallback: seat),
                 score: score, detail: detail, isWinner: winner)
    }

    static func card(for kind: String) -> GameRecapCard? {
        let noop: () -> Void = {}
        switch kind {
        case "battleship":
            return GameRecapCard(
                title: "Ruthie wins the battle",
                rows: [row(1, "Ruthie", "17 of 38", "fleet sunk · hits of shots", winner: true),
                       row(0, "Hank", "11 of 37", "2 ships afloat · hits of shots")],
                highlight: "Ruthie sank the carrier on shot 38", onRematch: noop, onDone: noop)
        case "ginRummy":
            return GameRecapCard(
                title: "Mae wins Gin Rummy",
                rows: [row(0, "Mae", "262", "112 hand points · 4 hands won · box +100", winner: true),
                       row(1, "Marco", "74", "74 hand points · 2 hands won · box +50")],
                highlight: "Took 4 of 6 hands, game bonus 100", onRematch: noop, onDone: noop)
        case "blackjack":
            return GameRecapCard(
                title: "The table is cleaned out",
                rows: [row(2, "Tucker", "15", "chips", winner: true, colorIndex: 2),
                       row(0, "Hank", "5", "chips", colorIndex: 0),
                       row(1, "Julie", "0", "chips", colorIndex: 1)],
                highlight: "23 rounds dealt and the house holds the chips",
                rematchLabel: "Buy back in", onRematch: noop, onDone: noop)
        case "liarsDice":
            return GameRecapCard(
                title: "Hank wins Liar's Dice",
                rows: [row(0, "Hank", "3 dice", "last cup standing", winner: true),
                       row(2, "Mae", "out", "2nd place"),
                       row(1, "Ruthie", "out", "3rd place"),
                       row(3, "Marco", "out", "4th place")],
                highlight: "Hank called Mae's four 5s: there were two", onRematch: noop, onDone: noop)
        case "goFish":
            return GameRecapCard(
                title: "Vinny wins!",
                rows: [row(1, "Vinny", "6 books", winner: true, colorIndex: 1),
                       row(0, "Chase", "4 books", colorIndex: 0),
                       row(2, "Mae", "3 books", colorIndex: 2)],
                highlight: "6 books!", kidMode: true, onRematch: noop, onDone: noop)
        case "oldMaid":
            return GameRecapCard(
                title: "Chase has the Old Maid",
                rows: [row(2, "Mae", "safe", winner: true, colorIndex: 2),
                       row(1, "Vinny", "safe", colorIndex: 1),
                       row(0, "Chase", "Old Maid", colorIndex: 0)],
                highlight: "Just the luck of the cards. Go again?", kidMode: true, onRematch: noop, onDone: noop)
        case "war":
            return GameRecapCard(
                title: "Chase wins!",
                rows: [row(0, "Chase", "52 cards", winner: true, colorIndex: 0),
                       row(1, "Vinny", "0 cards", colorIndex: 1)],
                highlight: "Every card, in 71 battles", kidMode: true, onRematch: noop, onDone: noop)
        case "cribbage":
            return GameRecapCard(
                title: "Mae wins the crib",
                rows: [row(1, "Mae", "121", nil, winner: true, colorIndex: 1),
                       row(0, "Hank", "97", "dealt the last hand", colorIndex: 0)],
                highlight: "Pegged out 24 ahead over 9 hands", onRematch: noop, onDone: noop)
        case "yahtzee":
            return GameRecapCard(
                title: "Mae wins Yahtzee",
                rows: [row(1, "Mae", "248", "2 Yahtzees", winner: true),
                       row(0, "Hank", "203", "upper bonus"),
                       row(2, "Ruthie", "171")],
                highlight: "Mae rolled 2 Yahtzees", onRematch: noop, onDone: noop)
        case "zilch":
            return GameRecapCard(
                title: "Tucker wins Zilch",
                rows: [row(2, "Tucker", "5,450", nil, winner: true),
                       row(0, "Marco", "5,100", "crossed 5000 first"),
                       row(1, "Julie", "3,250")],
                highlight: "Marco hit 5000 first, but Tucker chased past on the last turn",
                rematchLabel: "Roll again", onRematch: noop, onDone: noop)
        case "shutBox":
            return GameRecapCard(
                title: "Hank wins Shut the Box",
                rows: [row(0, "Hank", "shut", "shut the box", winner: true),
                       row(1, "Ruthie", "7", "left standing"),
                       row(2, "Marco", "19", "left standing")],
                highlight: "Hank shut the box!", rematchLabel: "Roll again", onRematch: noop, onDone: noop)
        case "mancala":
            return GameRecapCard(
                title: "Julie wins Mancala",
                rows: [row(1, "Julie", "29", "stones in store", winner: true, colorIndex: 1),
                       row(0, "Marco", "19", "stones in store", colorIndex: 0)],
                highlight: "Won by 10 stones after 31 sowings", onRematch: noop, onDone: noop)
        case "checkers":
            return GameRecapCard(
                title: "Hank wins Checkers",
                rows: [row(0, "Hank", "12", "captured", winner: true, colorIndex: 1),
                       row(1, "Mae", "8", "captured", colorIndex: 0)],
                highlight: "Every one of their pieces was captured", onRematch: noop, onDone: noop)
        case "connectFour":
            return GameRecapCard(
                title: "Ruthie wins Connect Four",
                rows: [row(1, "Ruthie", "14", "yellow discs", winner: true, colorIndex: 2),
                       row(0, "Tucker", "14", "red discs", colorIndex: 1)],
                highlight: "Four in a row on move 28", onRematch: noop, onDone: noop)
        case "quarto":
            return GameRecapCard(
                title: "Marco wins Quarto",
                rows: [row(1, "Marco", "6", "pieces placed", winner: true, colorIndex: 1),
                       row(0, "Julie", "5", "pieces placed", colorIndex: 0)],
                highlight: "Four tall, four dark!", onRematch: noop, onDone: noop)
        case "solitaire":
            return GameRecapCard(
                title: "You win!",
                rows: [RecapRow(id: 0, name: "Every card home", score: "143 moves", detail: "draw one", isWinner: true)],
                highlight: "All 52 cards up in 143 moves", rematchLabel: "New deal", onRematch: noop, onDone: noop)
        default:
            return nil
        }
    }
}
