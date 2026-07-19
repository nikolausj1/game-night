import AVFoundation
import Foundation

/// Short one-shot table sound effects (card slide, shuffle, trick sweep,
/// etc.), design-time generated via ElevenLabs' sound-generation endpoint
/// (`tools/generate_sfx.py`, `POST /v1/sound-generation`) into
/// `Sources/App/Resources/SFX/`.
///
/// A tiny preloaded `AVAudioPlayer` pool — one player per effect — so
/// `play(_:)` fires and forgets, no queueing or ducking: these are ambient
/// table sounds meant to layer quietly under announcer speech and game
/// UI, not compete with either. Contrast with `Announcer`, which queues
/// sequential speech clips on a single `AVQueuePlayer` and ducks other
/// audio.
///
/// Foundation/AVFoundation only, zero dependency on this app's game
/// engine — compiles standalone:
///
///   xcrun -sdk iphonesimulator swiftc -parse \
///     -target arm64-apple-ios17.0-simulator \
///     Sources/App/Announcer/TableSFX.swift
final class TableSFX {
    static let shared = TableSFX()

    enum Effect: String, CaseIterable {
        case cardSlide = "card_slide"
        case cardFlip = "card_flip"
        /// Rapid multi-card deal (several cards landing in quick succession).
        case cardDeal = "card_deal"
        case shuffle = "shuffle"
        case trickSweep = "trick_sweep"
        case chipPlace = "chip_place"
        case tableKnock = "table_knock"
        case fanfareWin = "fanfare_win"
    }

    /// Polite default playback volumes per effect (0...1) — the
    /// deal/shuffle/fanfare sounds read louder by nature than a single
    /// card slide or knock at the same gain, so they're leveled down to
    /// sit evenly against each other and under announcer speech.
    private static let volumes: [Effect: Float] = [
        .cardSlide: 0.5,
        .cardFlip: 0.5,
        .cardDeal: 0.6,
        .shuffle: 0.6,
        .trickSweep: 0.55,
        .chipPlace: 0.45,
        .tableKnock: 0.5,
        .fanfareWin: 0.7,
    ]

    /// One preloaded, prepared player per effect that resolved at init.
    /// An effect whose clip isn't in the bundle yet (in-progress
    /// `tools/generate_sfx.py` run, or stripped from a build) is simply
    /// absent here — `play(_:)` no-ops for it, same graceful-skip
    /// philosophy as `Announcer`.
    private var players: [Effect: AVAudioPlayer] = [:]

    private init() {
        preload()
    }

    private func preload() {
        for effect in Effect.allCases {
            guard let url = Self.resolvedURL(basename: effect.rawValue) else { continue }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = Self.volumes[effect] ?? 0.5
            player.prepareToPlay()
            players[effect] = player
        }
    }

    /// Plays `effect` from the start, restarting it if it's already
    /// mid-playback (e.g. rapid taps during a fast multi-card deal).
    /// Silently no-ops if the clip wasn't found/loaded at init.
    func play(_ effect: Effect) {
        guard let player = players[effect] else { return }
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }

    /// Tries both plausible bundling layouts, same dual-layout fallback as
    /// `Announcer.resolvedURL`: `SFX` as a true subdirectory, and the
    /// top-level bundle root (in case `SFX` gets flattened by an Xcode
    /// group instead of a folder reference).
    private static func resolvedURL(basename: String) -> URL? {
        if let url = Bundle.main.url(forResource: basename, withExtension: "mp3", subdirectory: "SFX") {
            return url
        }
        return Bundle.main.url(forResource: basename, withExtension: "mp3")
    }
}
