import Foundation

// Save/resume snapshots for the table-side dice games (LCR, Yahtzee, Zilch,
// Shut the Box). Their controllers live in the App layer and hold their
// rules state in plain `@Observable` properties rather than an engine
// struct, so these are the Codable shapes those controllers freeze
// themselves into. They sit in Engine, not App, purely so the headless
// smoke suite can round-trip them without SwiftUI (same reason
// `DiceClientState` lives here).
//
// Every snapshot is taken BETWEEN rolls: a roll in flight is never saved
// (the physical dice on the felt are the result, and they're gone once the
// app is), so a resumed turn always starts from "shake to roll". The
// controllers document exactly what each game forgets.

/// One chair, as the dice controllers remember it. `deviceID` is the
/// durable phone identity (nil for bots and unclaimed seats) — on resume
/// the host's `diceSeatByDevice` is rebuilt from it so a returning phone
/// lands straight back in its seat, exactly like `SavedGame.resume` does
/// for the card engine.
public struct DiceSavedSeat: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var isBot: Bool
    public var deviceID: String?
    public var colorIndex: Int

    public init(id: Int, name: String, isBot: Bool, deviceID: String?, colorIndex: Int) {
        self.id = id
        self.name = name
        self.isBot = isBot
        self.deviceID = deviceID
        self.colorIndex = colorIndex
    }
}

/// Left-Right-Center between rolls: chips, pot, whose turn.
public struct LcrSaveState: Codable, Equatable, Sendable {
    public var seats: [DiceSavedSeat]
    public var chips: [Int]
    public var centerPot: Int
    public var turnSeat: Int

    public init(seats: [DiceSavedSeat], chips: [Int], centerPot: Int, turnSeat: Int) {
        self.seats = seats
        self.chips = chips
        self.centerPot = centerPot
        self.turnSeat = turnSeat
    }
}

/// One Yahtzee scoresheet column, category raw values as keys (the App's
/// `YahtzeeCategory` enum is `String`-backed; keeping the keys as strings
/// here keeps this file free of App types).
public struct YahtzeeSavedCard: Codable, Equatable, Sendable {
    public var entries: [String: Int]
    public var yahtzeeBonusCount: Int

    public init(entries: [String: Int], yahtzeeBonusCount: Int) {
        self.entries = entries
        self.yahtzeeBonusCount = yahtzeeBonusCount
    }
}

/// Yahtzee at the top of a turn: every sheet, whose turn. A turn mid-way
/// through its three rolls is not kept — the dice on the felt are the
/// held values, and they don't survive a relaunch — so the roller resumes
/// with a fresh three rolls.
public struct YahtzeeSaveState: Codable, Equatable, Sendable {
    public var seats: [DiceSavedSeat]
    public var turnSeat: Int
    public var scorecards: [YahtzeeSavedCard]

    public init(seats: [DiceSavedSeat], turnSeat: Int, scorecards: [YahtzeeSavedCard]) {
        self.seats = seats
        self.turnSeat = turnSeat
        self.scorecards = scorecards
    }
}

/// Zilch between rolls: banked totals, the live turn total and which dice
/// are already set aside (points already counted), plus the final-chase
/// bookkeeping. Scoring groups from the last roll that were never tapped
/// are dropped — those dice get re-thrown on resume.
public struct ZilchSaveState: Codable, Equatable, Sendable {
    public var seats: [DiceSavedSeat]
    public var bankedScore: [Int]
    public var turnSeat: Int
    public var turnScore: Int
    public var heldIndices: [Int]
    public var finalChaseSeat: Int?
    public var finalChaseRemaining: [Int]

    public init(seats: [DiceSavedSeat], bankedScore: [Int], turnSeat: Int, turnScore: Int,
                heldIndices: [Int], finalChaseSeat: Int?, finalChaseRemaining: [Int]) {
        self.seats = seats
        self.bankedScore = bankedScore
        self.turnSeat = turnSeat
        self.turnScore = turnScore
        self.heldIndices = heldIndices
        self.finalChaseSeat = finalChaseSeat
        self.finalChaseRemaining = finalChaseRemaining
    }
}

/// Shut the Box between rolls: the box as it stands for the current
/// player, the round's scores so far, and the match bookkeeping. A roll
/// waiting for a tile set is dropped (re-rolled on resume).
public struct ShutBoxSaveState: Codable, Equatable, Sendable {
    public var seats: [DiceSavedSeat]
    public var standing: [Bool]
    public var turnSeat: Int
    public var roundIndex: Int
    public var roundsToWin: Int
    public var roundsWon: [Int]
    public var roundScores: [Int?]
    public var usingOneDie: Bool
    public var oneDieAvailable: Bool
    public var shutTheBoxSeat: Int?

    public init(seats: [DiceSavedSeat], standing: [Bool], turnSeat: Int, roundIndex: Int, roundsToWin: Int,
                roundsWon: [Int], roundScores: [Int?], usingOneDie: Bool, oneDieAvailable: Bool,
                shutTheBoxSeat: Int?) {
        self.seats = seats
        self.standing = standing
        self.turnSeat = turnSeat
        self.roundIndex = roundIndex
        self.roundsToWin = roundsToWin
        self.roundsWon = roundsWon
        self.roundScores = roundScores
        self.usingOneDie = usingOneDie
        self.oneDieAvailable = oneDieAvailable
        self.shutTheBoxSeat = shutTheBoxSeat
    }
}
