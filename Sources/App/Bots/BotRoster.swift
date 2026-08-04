import Foundation

/// A computer player's table identity: a name the announcer can actually
/// say (all six appear in the announcer manifest's name list) plus a fixed
/// PlayerPalette color so "Hank" is always slate no matter the seat.
struct BotIdentity: Identifiable, Equatable {
    let name: String
    let colorIndex: Int
    var id: String { name }
}

/// The six regulars who fill empty chairs. Names picked from
/// `Sources/App/Resources/Announcer/manifest.json`, deliberately avoiding
/// the household humans (Justin, Sarah, Vinny, Chase).
enum BotRoster {
    static let all: [BotIdentity] = [
        BotIdentity(name: "Hank", colorIndex: 6),   // slate
        BotIdentity(name: "Ruthie", colorIndex: 5), // rose
        BotIdentity(name: "Marco", colorIndex: 4),  // pine
        BotIdentity(name: "Mae", colorIndex: 2),    // amber
        BotIdentity(name: "Tucker", colorIndex: 7), // saddle
        BotIdentity(name: "Julie", colorIndex: 3),  // plum
    ]

    /// The menu asks for N bots; order is shuffled so the same faces don't
    /// always show up first.
    static func random(count: Int) -> [BotIdentity] {
        Array(all.shuffled().prefix(max(0, count)))
    }

    /// Case-insensitive lookup so a SeatSpec name round-trips to its color.
    static func identity(named name: String) -> BotIdentity? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
