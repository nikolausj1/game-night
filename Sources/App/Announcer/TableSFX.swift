import AVFoundation
import Foundation

/// Contact class for a 3D dice collision — routes to a per-material sample
/// bank instead of one repeated "knock" for every hit (the sound-design
/// audit's #1 complaint: dice used to be a machine gun of identical
/// clacks regardless of what actually hit what). `DiceTableSceneCoordinator`
/// classifies each physics contact by node identity and hands the class to
/// `TableSFX.playDiceContact`.
enum DiceContactClass {
    /// A die landing or rolling on the felt — soft, dull, no bright
    /// transient (felt kills the attack).
    case felt
    /// Die-on-die — bone-on-bone, the brightest and sharpest of the three.
    case die
    /// Die-on-rail/wall — a woodier, more resonant knock than felt, less
    /// sharp than bone-on-bone.
    case rail
    /// A single die transitioning to rest — one soft, quiet tick, never
    /// competing with the roll itself.
    case settle
}

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
        /// Dice spilling out of the cup onto the felt (dice mode;
        /// `tools/generate_dice_sfx.py`).
        case dicePour = "dice_pour"
        /// A chip sliding/passing between players (LCR transfers).
        case chipPass = "chip_pass"
        /// Gentle bell: the table finished something politely on the
        /// player's behalf (e.g. the LCR pending-coin watchdog moving an
        /// absent player's owed coins). Synthesized locally as m4a —
        /// `tools/generate_soft_chime.py`.
        case softChime = "soft_chime"

        // MARK: dice-contact bank (DiceContactClass) — see playDiceContact.
        // These play through the pooled contactPools below, not the
        // single-instance `players` dict, so overlapping hits (several
        // dice landing within the same beat) layer instead of stealing
        // each other's playback.

        /// Real dice knocking together — reused here for die-on-die
        /// contacts (three takes so a burst of clacks never repeats one
        /// sample back to back). Also used phone-side by CupAudio for the
        /// shake rattle; same asset, same house voice.
        case diceRattle1 = "dice_rattle_1"
        case diceRattle2 = "dice_rattle_2"
        case diceRattle3 = "dice_rattle_3"
        /// Dull low thud — die-on-felt. Synthesized locally, no bright
        /// transient (felt kills the attack) — `tools/generate_dice_contact_sfx.py`.
        case diceFeltThud = "dice_felt_thud"
        /// Brighter, more resonant knock — die-on-rail. Same tool as above.
        case diceRailKnock = "dice_rail_knock"
        /// Very short, very quiet — one die coming to rest. Same tool.
        case diceSettleTick = "dice_settle_tick"

        // MARK: coin bank (CoinSim) — metal on metal. Synthesized locally
        // by `tools/generate_coin_sfx.py`; pooled like the dice contacts.
        case coinClink1 = "coin_clink_1"
        case coinClink2 = "coin_clink_2"
        case coinClink3 = "coin_clink_3"
        /// The dropped-coin whirr: pings that accelerate into a buzz, then
        /// two settle ticks (~1.1 s, matched to CoinEdgeState.fallDuration).
        case coinSpinDown = "coin_spin_down"
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
        .dicePour: 0.65,
        .chipPass: 0.45,
        .softChime: 0.4,
        // The dice-contact bank (diceRattle1...diceSettleTick) has no
        // entry here on purpose: it's never preloaded into `players` (see
        // preload()) and its volume comes entirely from
        // ContactCurve.volumeRange in playDiceContact, velocity-mapped
        // per hit rather than one fixed default.
    ]

    /// One preloaded, prepared player per effect that resolved at init.
    /// An effect whose clip isn't in the bundle yet (in-progress
    /// `tools/generate_sfx.py` run, or stripped from a build) is simply
    /// absent here — `play(_:)` no-ops for it, same graceful-skip
    /// philosophy as `Announcer`.
    private var players: [Effect: AVAudioPlayer] = [:]

    /// Small round-robin pools for the dice-contact bank: `contactPoolSize`
    /// independent `AVAudioPlayer` instances per sample, so a burst of
    /// same-class hits (several dice landing within the same beat) each
    /// get their own player and ring out together instead of the single
    /// shared player above cutting the previous hit off mid-note.
    private var contactPools: [Effect: [AVAudioPlayer]] = [:]
    private var contactPoolCursor: [Effect: Int] = [:]
    private static let contactPoolSize = 3
    private static let contactEffects: [Effect] = [
        .diceRattle1, .diceRattle2, .diceRattle3,
        .diceFeltThud, .diceRailKnock, .diceSettleTick,
        .coinClink1, .coinClink2, .coinClink3, .coinSpinDown,
    ]

    private init() {
        preload()
        preloadContactPools()
    }

    private func preload() {
        for effect in Effect.allCases {
            // Dice-contact effects live ONLY in contactPools (below) —
            // playDiceContact never touches `players`, so preloading a
            // redundant single instance here would just be a wasted file
            // open + AVAudioPlayer init at startup.
            guard !Self.contactEffects.contains(effect) else { continue }
            guard let url = Self.resolvedURL(basename: effect.rawValue) else { continue }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = Self.volumes[effect] ?? 0.5
            // Rate is set per-play (see play(_:intensity:)) — enabling it
            // once here is what makes .rate assignments take effect at all.
            player.enableRate = true
            player.prepareToPlay()
            players[effect] = player
        }
    }

    private func preloadContactPools() {
        for effect in Self.contactEffects {
            guard let url = Self.resolvedURL(basename: effect.rawValue) else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<Self.contactPoolSize {
                guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.enableRate = true
                player.prepareToPlay()
                pool.append(player)
            }
            guard !pool.isEmpty else { continue }
            contactPools[effect] = pool
        }
    }

    /// Plays `effect` from the start, restarting it if it's already
    /// mid-playback (e.g. rapid taps during a fast multi-card deal).
    /// Silently no-ops if the clip wasn't found/loaded at init.
    func play(_ effect: Effect) {
        play(effect, intensity: 1.0)
    }

    /// Velocity-pitched playback: `intensity` (0.3...1.6, "how hard did
    /// this land") maps to both playback rate (0.85...1.30) and volume, so
    /// a hard flick reads as a hard flick and a gentle nudge stays quiet.
    ///
    /// Players are pooled — one `AVAudioPlayer` per effect, reused across
    /// every call — so `rate` MUST be reset on every play. Without this, a
    /// high-intensity throw's pitch bleeds into the next, unrelated play
    /// of the same effect.
    func play(_ effect: Effect, intensity: Double) {
        guard let player = players[effect] else { return }
        if player.isPlaying { player.stop() }
        let rateIntensity = max(0.3, min(intensity, 1.6))
        let rate = 0.85 + (rateIntensity - 0.3) / (1.6 - 0.3) * (1.30 - 0.85)
        player.rate = Float(rate)
        let baseVolume = Self.volumes[effect] ?? 0.5
        player.volume = baseVolume * Float(0.75 + 0.25 * min(intensity, 1.2))
        player.currentTime = 0
        player.play()
    }

    /// Per-class rate/volume curves, indexed by `strength` (0...1, straight
    /// from `DiceContactThrottle`). This is the generalized form of the
    /// single `intensity` curve `play(_:intensity:)` already does for one
    /// effect at a time — here each contact CLASS gets its own curve, so
    /// felt stays duller/quieter across its whole range while die-on-die
    /// reads brighter and rail sits in between.
    private struct ContactCurve {
        let rateRange: ClosedRange<Double>
        let volumeRange: ClosedRange<Double>
    }

    private static let contactCurves: [DiceContactClass: ContactCurve] = [
        // Felt swallows the transient — stays dull and quiet even at a
        // hard landing; the difference between a soft roll and a hard one
        // shows up far more in volume than pitch here.
        .felt: ContactCurve(rateRange: 0.68...0.92, volumeRange: 0.10...0.42),
        // Bone-on-bone: the brightest, sharpest of the three — this is the
        // hit that should read as a genuine "clack".
        .die: ContactCurve(rateRange: 0.95...1.35, volumeRange: 0.30...0.68),
        // Wood rail: resonant, brighter than felt, not as sharp as bone.
        .rail: ContactCurve(rateRange: 0.85...1.15, volumeRange: 0.22...0.55),
        // Settle tick: always quiet, always on the slow side — one soft
        // "it's done" click that never competes with the roll itself.
        .settle: ContactCurve(rateRange: 0.75...0.95, volumeRange: 0.08...0.16),
    ]

    private static let contactSamples: [DiceContactClass: [Effect]] = [
        .felt: [.diceFeltThud],
        .die: [.diceRattle1, .diceRattle2, .diceRattle3],
        .rail: [.diceRailKnock],
        .settle: [.diceSettleTick],
    ]

    /// One velocity-mapped dice-impact hit: picks a sample for
    /// `contactClass` (random across its bank when it has more than one —
    /// die-on-die has three takes, so a burst of clacks never repeats one
    /// sample back to back), maps `strength` (0...1) to that class's own
    /// rate/volume curve, and jitters the rate an extra ±4% on top so no
    /// two hits — even of the same class, even back to back — are pitch-
    /// identical. Plays from the class's round-robin pool so simultaneous
    /// impacts (several dice landing at once) layer instead of one
    /// stealing another's playback. Generalizes the single-effect
    /// intensity mapping in `play(_:intensity:)` to a per-material curve.
    func playDiceContact(_ contactClass: DiceContactClass, strength: Double) {
        guard let bank = Self.contactSamples[contactClass], let effect = bank.randomElement(),
              let pool = contactPools[effect], !pool.isEmpty,
              let curve = Self.contactCurves[contactClass] else { return }
        let cursor = (contactPoolCursor[effect] ?? 0) % pool.count
        contactPoolCursor[effect] = cursor + 1
        let player = pool[cursor]

        let s = max(0, min(1, strength))
        let baseRate = curve.rateRange.lowerBound
            + s * (curve.rateRange.upperBound - curve.rateRange.lowerBound)
        let jitteredRate = baseRate + Double.random(in: -0.04...0.04)
        player.rate = Float(max(0.5, min(2.0, jitteredRate)))
        player.volume = Float(curve.volumeRange.lowerBound
            + s * (curve.volumeRange.upperBound - curve.volumeRange.lowerBound))
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }

    // MARK: - Coins (CoinSim)

    /// One metallic coin-on-coin clink, layered by `strength` (0...1) the
    /// same way `playDiceContact` layers by class: a pitch-varied ping from
    /// the three-take bank, plus (from a firm hit up) the existing dull felt
    /// thud underneath for body, plus a second, higher ping on a hard hit.
    func playCoinClink(strength: Double) {
        let s = max(0, min(1, strength))
        guard s > 0.04 else { return }
        playCoinPing(volume: 0.10 + 0.50 * s, rate: 0.92 + 0.30 * s)
        if s > 0.35 { playDiceContact(.felt, strength: (s - 0.2) * 0.8) }
        if s > 0.7 { playCoinPing(volume: 0.22 * s, rate: 1.30 + 0.1 * s) }
    }

    /// A coin against the wooden rail: the existing rail knock with a
    /// small metal ping on top.
    func playCoinRail(strength: Double) {
        let s = max(0, min(1, strength))
        guard s > 0.05 else { return }
        playDiceContact(.rail, strength: s * 0.7)
        playCoinPing(volume: 0.06 + 0.26 * s, rate: 0.85 + 0.2 * s)
    }

    /// The edge-roll finish: the dropped-coin whirr.
    func playCoinSpinDown() {
        guard let pool = contactPools[.coinSpinDown], !pool.isEmpty else { return }
        let cursor = (contactPoolCursor[.coinSpinDown] ?? 0) % pool.count
        contactPoolCursor[.coinSpinDown] = cursor + 1
        let player = pool[cursor]
        player.rate = 1.0
        player.volume = 0.5
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }

    private func playCoinPing(volume: Double, rate: Double) {
        let effect = [Effect.coinClink1, .coinClink2, .coinClink3].randomElement()!
        guard let pool = contactPools[effect], !pool.isEmpty else { return }
        let cursor = (contactPoolCursor[effect] ?? 0) % pool.count
        contactPoolCursor[effect] = cursor + 1
        let player = pool[cursor]
        player.rate = Float(max(0.5, min(2.0, rate + Double.random(in: -0.04...0.04))))
        player.volume = Float(max(0, min(1, volume)))
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }

    /// Tries both plausible bundling layouts, same dual-layout fallback as
    /// `Announcer.resolvedURL`: `SFX` as a true subdirectory, and the
    /// top-level bundle root (in case `SFX` gets flattened by an Xcode
    /// group instead of a folder reference).
    /// Formats: mp3 first (the ElevenLabs clips), then m4a (locally
    /// synthesized clips — afconvert can't write mp3).
    private static func resolvedURL(basename: String) -> URL? {
        for ext in ["mp3", "m4a"] {
            if let url = Bundle.main.url(forResource: basename, withExtension: ext, subdirectory: "SFX") {
                return url
            }
            if let url = Bundle.main.url(forResource: basename, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
