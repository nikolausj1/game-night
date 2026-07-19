import AVFoundation
import Foundation

/// Announcer commentary intensity — three listener-facing tone tiers, each
/// drawing from a MERGED pool of the underlying ElevenLabs generation
/// buckets (ported straight from Wizard Keeper's `AnnouncerStyle` — see
/// `tools/generate_announcer.py`'s header comment there for why buckets
/// 2+3 and 4+5 are merged: the original five tones were too close
/// together at the table). File naming still uses the original five
/// buckets (`tail_<bucket>_<kind>_<i>`); only the bucket GROUPING is
/// tier-based.
///
/// Spicy draws from buckets 4-5, which include mild-to-real profanity —
/// adults-only, strip before any App Store submission without an age
/// gate, never on the kids' iPads.
enum AnnouncerTier: Int, CaseIterable, Identifiable {
    case classic = 1
    case fun = 2
    case spicy = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .fun: return "Fun"
        case .spicy: return "Spicy"
        }
    }

    /// The on-disk clip-style buckets this tier draws from.
    var buckets: [Int] {
        switch self {
        case .classic: return [1]
        case .fun: return [2, 3]
        case .spicy: return [4, 5]
        }
    }
}

/// Table announcer for live play — plays sequences of pre-generated
/// Charlie-voice MP3 clips from `Sources/App/Resources/Announcer/` for
/// live table events (game start, trump reveal, trick winner, bidding,
/// round/game scoring).
///
/// Ported from Wizard Keeper's `AnnouncerPlayer`
/// (`Sources/App/Announcer.swift` there — same proven core: AVQueuePlayer
/// sequencing, audio-session ducking + interruption recovery, graceful
/// skip of missing clips, no-repeat variant selection, tone tiers, and the
/// `silence_400` engineered dramatic pause before a shouted number) and
/// restructured with a strings/ints-in public API for live table play, so
/// this file has ZERO dependency on this app's game engine and compiles
/// standalone:
///
///   xcrun -sdk iphonesimulator swiftc -parse \
///     -target arm64-apple-ios17.0-simulator \
///     Sources/App/Announcer/Announcer.swift
///
/// Game Night is single-voice ("iPad is the sole voice" per the PRD) — the
/// voice is always Charlie, and unlike Wizard Keeper there's no voice
/// parameter anywhere in this API.
///
/// Design-time generation (`tools/generate_announcer.py`, ported verbatim
/// from Wizard Keeper's corpus, plus this app's own
/// `tools/generate_playbyplay.py` for the new live-event clip families)
/// may still be filling in `Resources/Announcer/charlie/` when this ships
/// to a build. Every lookup here gracefully skips a clip that isn't
/// present yet rather than failing, and if an entire call resolves to zero
/// segments, it's a silent no-op.
final class Announcer {
    static let shared = Announcer()

    /// Game Night bundles a single voice pack.
    private static let voice = "charlie"

    /// The currently selected tone tier (set once from Settings; the
    /// per-event `announce*` calls below take no tier parameter — only
    /// `preview(tier:)` does, for auditioning a tier without committing to
    /// it as the live setting).
    var tier: AnnouncerTier = .classic

    /// Strong reference to the in-flight playback. A new `announce*` call
    /// simply replaces this, which stops (and, once nothing else retains
    /// it, deallocates) whatever was playing before.
    private var queuePlayer: AVQueuePlayer?

    /// Observes the last queued `AVPlayerItem`'s end-of-playback
    /// notification so `isPlaying` flips back to `false` once the whole
    /// sequence has finished (not just the first clip). Torn down and
    /// replaced on every new `play(urls:attempted:)` call and in `stop()`.
    private var endOfQueueObserver: NSObjectProtocol?

    /// One observer per queued `AVPlayerItem` for
    /// `.AVPlayerItemFailedToPlayToEndTime` — a mid-queue decode/IO failure
    /// otherwise leaves `isPlaying` stuck `true` forever, since it never
    /// fires the last item's normal end-of-playback notification. Torn
    /// down and replaced on every new `play(urls:attempted:)` call and in
    /// `stop()`, same lifecycle as `endOfQueueObserver`.
    private var failureObservers: [NSObjectProtocol] = []

    /// Observes `AVAudioSession.interruptionNotification` so an incoming
    /// call/Siri/alarm that interrupts playback also stops us cleanly
    /// instead of leaving `isPlaying` stuck `true` with a silently-paused
    /// player. Registered once (see `init`) and never torn down — it
    /// outlives any individual playback session.
    private var interruptionObserver: NSObjectProtocol?

    /// Whether a clip sequence is currently queued/playing. This file only
    /// imports AVFoundation/Foundation (no Combine/SwiftUI), so there's no
    /// `@Published` here — call `onPlayingChanged` to observe transitions,
    /// or poll `isPlaying` directly.
    private(set) var isPlaying = false
    var onPlayingChanged: ((Bool) -> Void)?

    private struct Manifest: Decodable {
        let voices: [String]
        /// style number (as string, "1"..."5") -> kind name -> variant count.
        let styles: [String: [String: Int]]
        let names: [String]
        let aliases: [String: String]
        /// Score-grammar lead-ins: listener TIER (as string, "1"..."3",
        /// mapping directly from `AnnouncerTier.rawValue`) -> kind name ->
        /// variant count. Optional so a manifest without this key still
        /// decodes.
        let leadins: [String: [String: Int]]?
    }

    private let manifest: Manifest?

    private init() {
        manifest = Self.loadManifest()
        if manifest == nil {
            print("Announcer: manifest.json not found or unreadable — announcer will be silent")
        }
        registerInterruptionObserver()
    }

    /// Registered once at init: on `.began` (interruption starting — a
    /// call, Siri, an alarm, another app grabbing the session), stop
    /// playback so `isPlaying` doesn't stay stuck `true` while the system
    /// has already silently paused us. `.ended` is intentionally not
    /// resumed automatically — the announcer is a one-shot callout, not a
    /// music player.
    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
                  type == .began else { return }
            self?.stop()
        }
    }

    private static func loadManifest() -> Manifest? {
        guard let url = resourceURL(basename: "manifest", ext: "json") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Public API

    /// Roll call (each name that resolves, in order) + a "kickoff" tail in
    /// the current tier. Missing names (not in the ported corpus's name
    /// library) are simply skipped — a table of unfamiliar names still
    /// gets the kickoff line.
    @discardableResult
    func announceGameStart(playerNames: [String]) -> Int {
        beginAssembly()
        var urls: [URL] = []
        var attempted = 0

        for name in playerNames {
            attempted += 1
            if let u = nameURL(name) { urls.append(u) }
        }

        attempted += 1
        if let u = tailURL(kindName: "kickoff", tier: tier) { urls.append(u) }

        return play(urls: urls, attempted: attempted)
    }

    /// Single clip: `trump_<suit>` (hearts/diamonds/clubs/spades) or
    /// `trump_none` when `suitName` is `nil`. Not tone-tiered — trump
    /// reveal reads the same regardless of tier.
    @discardableResult
    func announceTrumpReveal(suitName: String?) -> Int {
        beginAssembly()
        var urls: [URL] = []
        let attempted = 1

        let basename: String
        if let suitName {
            basename = "trump_\(suitSlug(suitName))"
        } else {
            basename = "trump_none"
        }
        if let u = resolvedURL(basename: basename) { urls.append(u) }

        return play(urls: urls, attempted: attempted)
    }

    /// name + a no-repeat "takes it!"-family tail (`takes_<i>`, flat pool,
    /// not tone-tiered — trick calls happen too often per round for tone
    /// variance to matter).
    @discardableResult
    func announceTrickWon(playerName: String) -> Int {
        beginAssembly()
        var urls: [URL] = []
        var attempted = 0

        attempted += 1
        if let u = nameURL(playerName) { urls.append(u) }

        attempted += 1
        if let u = flatVariantURL(category: "takes") { urls.append(u) }

        return play(urls: urls, attempted: attempted)
    }

    /// name + `bids_<n>` (0...10 only — out-of-range bids just skip the
    /// number segment, name still plays).
    @discardableResult
    func announceBid(playerName: String, bid: Int) -> Int {
        beginAssembly()
        var urls: [URL] = []
        var attempted = 0

        attempted += 1
        if let u = nameURL(playerName) { urls.append(u) }

        attempted += 1
        if (0...10).contains(bid), let u = resolvedURL(basename: "bids_\(bid)") { urls.append(u) }

        return play(urls: urls, attempted: attempted)
    }

    /// Over/underbid color line once bidding wraps: `overbid_<i>` if the
    /// table bid more tricks than are available, `underbid_<i>` if fewer.
    /// An exact match (bids == tricks) has no clip by design — silent
    /// no-op, same graceful-skip philosophy as everywhere else.
    @discardableResult
    func announceBiddingComplete(totalBids: Int, tricksAvailable: Int) -> Int {
        beginAssembly()
        var urls: [URL] = []
        let attempted = 1

        if totalBids > tricksAvailable {
            if let u = flatVariantURL(category: "overbid") { urls.append(u) }
        } else if totalBids < tricksAvailable {
            if let u = flatVariantURL(category: "underbid") { urls.append(u) }
        }

        return play(urls: urls, attempted: attempted)
    }

    /// Reuses Wizard Keeper's standings-broadcast grammar (NAME + lead-in
    /// ending mid-sentence + `silence_400` dramatic pause + shouted number,
    /// same shape as `announceRoundUpdate`/`announceGameWrap` there):
    /// - Tied for first (2+ players share the top score): both names +
    ///   `leadin_tiedAt` + the shared score.
    /// - Otherwise: leader name + `leadin_leaderTotal` + score + a
    ///   "leading" tail; then (3+ players) runner-up name + `leadin_chase`
    ///   + the gap behind the leader (`back_<n>`).
    /// - With 3+ players and a sole last place (not also tied for first):
    ///   name + `leadin_bottomStatic` (a complete sentence, no number) + a
    ///   "trailing" tail.
    /// `standings` need not be pre-sorted; empty input is a silent no-op.
    @discardableResult
    func announceRoundScored(standings: [(name: String, score: Int)]) -> Int {
        beginAssembly()
        guard !standings.isEmpty else { return 0 }

        var urls: [URL] = []
        var attempted = 0

        let sorted = standings.sorted { $0.score > $1.score }
        let topScore = sorted[0].score
        let tiedLeaders = sorted.filter { $0.score == topScore }

        if tiedLeaders.count >= 2 {
            for entry in tiedLeaders.prefix(2) {
                attempted += 1
                if let u = nameURL(entry.name) { urls.append(u) }
            }

            attempted += 1
            var leadinResolved = false
            if let u = leadinURL(kindName: "tiedAt", tier: tier) {
                urls.append(u)
                leadinResolved = true
            }
            attempted += 1
            if let numURL = numClipURL(score: topScore) {
                if leadinResolved, let pause = resolvedURL(basename: "silence_400") { urls.append(pause) }
                urls.append(numURL)
            }
        } else {
            let leader = sorted[0]
            attempted += 1
            if let u = nameURL(leader.name) { urls.append(u) }

            attempted += 1
            var leadinResolved = false
            if let u = leadinURL(kindName: "leaderTotal", tier: tier) {
                urls.append(u)
                leadinResolved = true
            }
            attempted += 1
            if let numURL = numClipURL(score: leader.score) {
                if leadinResolved, let pause = resolvedURL(basename: "silence_400") { urls.append(pause) }
                urls.append(numURL)
            }

            attempted += 1
            if let u = tailURL(kindName: "leading", tier: tier) { urls.append(u) }

            if sorted.count > 1 {
                let second = sorted[1]
                let gap = leader.score - second.score

                attempted += 1
                if let u = nameURL(second.name) { urls.append(u) }

                attempted += 1
                var chaseLeadinResolved = false
                if let u = leadinURL(kindName: "chase", tier: tier) {
                    urls.append(u)
                    chaseLeadinResolved = true
                }
                attempted += 1
                if let backURL = backClipURL(score: gap) {
                    if chaseLeadinResolved, let pause = resolvedURL(basename: "silence_400") { urls.append(pause) }
                    urls.append(backURL)
                }
            }
        }

        if sorted.count > 2 {
            let last = sorted[sorted.count - 1]
            if last.score != topScore {
                attempted += 1
                if let u = nameURL(last.name) { urls.append(u) }
                attempted += 1
                if let u = leadinURL(kindName: "bottomStatic", tier: tier) { urls.append(u) }
                attempted += 1
                if let u = tailURL(kindName: "trailing", tier: tier) { urls.append(u) }
            }
        }

        return play(urls: urls, attempted: attempted)
    }

    /// Winner name + "winner" tail; if `margin` is positive, the winner's
    /// name again + `leadin_winnerBy` + `silence_400` + the shouted margin
    /// number (same shape as Wizard Keeper's `announceGameWrap` winnerBy
    /// segment). `margin` of 0 (a tie) skips the second half entirely.
    @discardableResult
    func announceGameWon(winnerName: String, margin: Int) -> Int {
        beginAssembly()
        var urls: [URL] = []
        var attempted = 0

        attempted += 1
        if let u = nameURL(winnerName) { urls.append(u) }
        attempted += 1
        if let u = tailURL(kindName: "winner", tier: tier) { urls.append(u) }

        if margin > 0 {
            attempted += 1
            if let u = nameURL(winnerName) { urls.append(u) }

            attempted += 1
            var leadinResolved = false
            if let u = leadinURL(kindName: "winnerBy", tier: tier) {
                urls.append(u)
                leadinResolved = true
            }
            attempted += 1
            if let numURL = numClipURL(score: margin, emphasized: true) {
                if leadinResolved, let pause = resolvedURL(basename: "silence_400") { urls.append(pause) }
                urls.append(numURL)
            }
        }

        return play(urls: urls, attempted: attempted)
    }

    /// Special-card callouts for Wizard's deck: a wizard or jester landing
    /// on the trick, or a player down to their last card. Flat pools, not
    /// tone-tiered.
    @discardableResult
    func announceWizardPlayed() -> Int {
        beginAssembly()
        var urls: [URL] = []
        let attempted = 1
        if let u = flatVariantURL(category: "wizardplayed") { urls.append(u) }
        return play(urls: urls, attempted: attempted)
    }

    @discardableResult
    func announceJesterPlayed() -> Int {
        beginAssembly()
        var urls: [URL] = []
        let attempted = 1
        if let u = flatVariantURL(category: "jesterplayed") { urls.append(u) }
        return play(urls: urls, attempted: attempted)
    }

    @discardableResult
    func announceLastCard() -> Int {
        beginAssembly()
        var urls: [URL] = []
        let attempted = 1
        if let u = flatVariantURL(category: "lastcard") { urls.append(u) }
        return play(urls: urls, attempted: attempted)
    }

    /// Short sample of the given tier for the Settings "Preview" button:
    /// [seg intro] + [tail winner], same shape as Wizard Keeper's
    /// `preview(voice:style:)`. Unlike the live-event calls above, this
    /// takes an explicit `tier` so Settings can audition a tier without
    /// changing the live `tier` setting.
    @discardableResult
    func preview(tier: AnnouncerTier) -> Int {
        beginAssembly()
        var urls: [URL] = []
        var attempted = 0

        attempted += 1
        if let u = connectiveURL(kind: "intro", tier: tier) { urls.append(u) }

        attempted += 1
        if let u = tailURL(kindName: "winner", tier: tier) { urls.append(u) }

        return play(urls: urls, attempted: attempted)
    }

    /// Stops any in-flight playback immediately, flips `isPlaying` back to
    /// `false`, and deactivates the audio session
    /// (`.notifyOthersOnDeactivation` so ducked background music resumes).
    func stop() {
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        if let endOfQueueObserver {
            NotificationCenter.default.removeObserver(endOfQueueObserver)
        }
        endOfQueueObserver = nil
        for observer in failureObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        failureObservers.removeAll()
        isPlaying = false
        onPlayingChanged?(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Segment basenames (filename minus ".mp3")

    private func nameURL(_ playerName: String) -> URL? {
        resolvedURL(basename: "name_\(slug(for: playerName))")
    }

    private func suitSlug(_ suitName: String) -> String {
        suitName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Variant bookkeeping (ported from Wizard Keeper: the same clip
    /// playing twice in one broadcast was a game-night bug).
    /// `usedInAssembly` is cleared at the start of every announce* call and
    /// guarantees no clip repeats within a single announcement;
    /// `lastVariant` persists across announcements so the next broadcast
    /// avoids opening with the identical line when there's an alternative.
    private var usedInAssembly: Set<String> = []
    private var lastVariant: [String: Int] = [:]

    /// Called at the top of every announce* assembly.
    private func beginAssembly() {
        usedInAssembly.removeAll()
    }

    /// Draws a variant index for a category without repeating within the
    /// current announcement, and avoiding the previous announcement's pick
    /// when an alternative exists. Falls back to reuse only when every
    /// variant is already spent (better a repeat than silence). `scope`
    /// namespaces the pick (tier for tone-graded categories, a constant
    /// for flat/tone-neutral ones) so e.g. Classic and Spicy don't share
    /// no-repeat state.
    private func pickVariant(category: String, count: Int, scope: Int) -> Int {
        let key = "\(scope)_\(category)"
        let pool = Array(0..<count)
        var candidates = pool.filter { !usedInAssembly.contains("\(key)_\($0)") }
        if candidates.isEmpty { candidates = pool }
        if candidates.count > 1, let last = lastVariant[key] {
            let withoutLast = candidates.filter { $0 != last }
            if !withoutLast.isEmpty { candidates = withoutLast }
        }
        let chosen = candidates.randomElement() ?? 0
        usedInAssembly.insert("\(key)_\(chosen)")
        lastVariant[key] = chosen
        return chosen
    }

    /// Picks a no-repeat tail variant for (tier, kind) from the manifest's
    /// variant count, and falls back to variant 0 if the chosen file isn't
    /// on disk yet (generation may still be in progress). Returns `nil`
    /// only if nothing is resolvable.
    private func tailURL(kindName: String, tier: AnnouncerTier) -> URL? {
        // Merged pool across the tier's clip buckets: flat index space over
        // every (bucket, variant) pair, so Fun draws from both of its
        // buckets, etc. — twice the variety per tier.
        var pool: [(bucket: Int, variant: Int)] = []
        for bucket in tier.buckets {
            let count = manifest?.styles[String(bucket)]?[kindName] ?? 0
            for v in 0..<count { pool.append((bucket, v)) }
        }
        guard !pool.isEmpty else { return nil }
        let flat = pickVariant(category: "tail_\(kindName)", count: pool.count, scope: tier.rawValue)
        let pick = pool[flat]
        if let url = resolvedURL(basename: "tail_\(pick.bucket)_\(kindName)_\(pick.variant)") {
            return url
        }
        // Fallback: first pool entry (generation may still be in flight).
        let first = pool[0]
        if flat != 0, let url = resolvedURL(basename: "tail_\(first.bucket)_\(kindName)_\(first.variant)") {
            return url
        }
        return nil
    }

    /// Random connective clip lookup for the preview broadcast —
    /// `seg_<bucket>_<kind>_<i>`. No manifest-backed variant count exists
    /// for these, so this probes a shuffled 0..<8 index range and caches
    /// the discovered count per (bucket, kind).
    private func connectiveURL(kind: String, tier: AnnouncerTier) -> URL? {
        var pool: [(bucket: Int, variant: Int)] = []
        for bucket in tier.buckets {
            let cacheKey = "\(bucket)_\(kind)"
            let count: Int
            if let cached = connectiveCounts[cacheKey] {
                count = cached
            } else {
                var probed = 0
                while probed < 8, resolvedURL(basename: "seg_\(bucket)_\(kind)_\(probed)") != nil {
                    probed += 1
                }
                connectiveCounts[cacheKey] = probed
                count = probed
            }
            for v in 0..<count { pool.append((bucket, v)) }
        }
        guard !pool.isEmpty else { return nil }
        let flat = pickVariant(category: "seg_\(kind)", count: pool.count, scope: tier.rawValue)
        let pick = pool[flat]
        return resolvedURL(basename: "seg_\(pick.bucket)_\(kind)_\(pick.variant)")
    }

    /// On-disk connective variant counts, probed once per (bucket, kind).
    private var connectiveCounts: [String: Int] = [:]

    /// On-disk variant counts for the flat (tone-neutral) play-by-play
    /// families — `takes_<i>`, `overbid_<i>`, `underbid_<i>`,
    /// `wizardplayed_<i>`, `jesterplayed_<i>`, `lastcard_<i>` — probed once
    /// per category and cached. These have no manifest-backed count and no
    /// tier bucketing (see `tools/generate_playbyplay.py`).
    private var flatVariantCounts: [String: Int] = [:]

    private func flatVariantURL(category: String) -> URL? {
        let count: Int
        if let cached = flatVariantCounts[category] {
            count = cached
        } else {
            var probed = 0
            while probed < 12, resolvedURL(basename: "\(category)_\(probed)") != nil {
                probed += 1
            }
            flatVariantCounts[category] = probed
            count = probed
        }
        guard count > 0 else { return nil }
        // scope: 0 — these categories aren't tier-scoped, so no-repeat
        // state is shared across tiers (there's only one pool).
        let variant = pickVariant(category: category, count: count, scope: 0)
        if let u = resolvedURL(basename: "\(category)_\(variant)") { return u }
        if variant != 0, let u = resolvedURL(basename: "\(category)_0") { return u }
        return nil
    }

    // MARK: - Score-grammar clip resolution (NAME! + lead-in + number)

    /// Picks a no-repeat lead-in variant for (tier, kind) from the
    /// manifest's `leadins` counts and falls back to variant 0 if the
    /// chosen file isn't on disk yet, same pattern as `tailURL`. Unlike
    /// `tailURL`'s merged bucket pool, `tier` maps DIRECTLY to the
    /// manifest's lead-in tier key (1 Classic, 2 Fun, 3 Spicy) — lead-ins
    /// carry facts, not spice, so there's no bucket merging here.
    private func leadinURL(kindName: String, tier: AnnouncerTier) -> URL? {
        let t = tier.rawValue
        let count = manifest?.leadins?[String(t)]?[kindName] ?? 0
        guard count > 0 else { return nil }
        let variant = pickVariant(category: "leadin_\(kindName)", count: count, scope: t)
        if let url = resolvedURL(basename: "leadin_\(t)_\(kindName)_\(variant)") {
            return url
        }
        if variant != 0, let url = resolvedURL(basename: "leadin_\(t)_\(kindName)_0") {
            return url
        }
        return nil
    }

    /// `num_<n>` / `num_m<n>` (tens family — Wizard scores/gaps/deltas are
    /// always multiples of 10) or `num1_<n>` (integer family, for other
    /// future variants whose scores move in 1s) — bare terminal numbers
    /// (leader totals, gaps, margins). Tries the tens family first when
    /// `score` is a multiple of 10 (clamping into the generated
    /// −100...300 range), alternating between the natural `num_` and
    /// shouted `numx_` sets per `emphasized`; falls back to the integer
    /// family (clamped into 0...160, natural delivery only) otherwise. A
    /// clip that isn't on disk yet just resolves to `nil` and gets skipped
    /// upstream, same as any other missing clip.
    private func numClipURL(score: Int, emphasized: Bool = false) -> URL? {
        if score % 10 == 0 {
            let clamped = max(-100, min(300, score))
            let prefixes = emphasized ? ["numx_", "num_"] : ["num_", "numx_"]
            for prefix in prefixes {
                if let u = resolvedURL(basename: "\(prefix)\(numSlug(clamped))") { return u }
            }
        }
        let clampedInt = max(0, min(160, score))
        return resolvedURL(basename: "num1_\(clampedInt)")
    }

    private func numSlug(_ n: Int) -> String {
        n < 0 ? "m\(-n)" : "\(n)"
    }

    /// `back_<n>` (tens family) or `back1_<n>` (integer family) — "<N>
    /// back!", the margin behind the leader (`chase`). Same tens-then-ones
    /// fallback as `numClipURL`.
    private func backClipURL(score: Int) -> URL? {
        if score % 10 == 0 {
            let clamped = max(10, min(150, score))
            // Chase margins always use the natural read — the hunt is
            // tension, not a celebration.
            for prefix in ["back_", "backx_"] {
                if let u = resolvedURL(basename: "\(prefix)\(clamped)") { return u }
            }
        }
        let clampedInt = max(1, min(40, score))
        return resolvedURL(basename: "back1_\(clampedInt)")
    }

    // MARK: - Name slugging

    /// Lowercased, trimmed, diacritic-folded, then run through the
    /// manifest's aliases (e.g. "nicky" -> "nikki") so callers can pass
    /// whatever display name is on file.
    private func slug(for playerName: String) -> String {
        let folded = playerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
        return manifest?.aliases[folded] ?? folded
    }

    // MARK: - File resolution

    /// Tries both plausible bundling layouts for a clip, since Xcode's
    /// handling of nested folder references vs. flattened groups can
    /// differ: `Announcer/<voice>/<basename>.mp3` as a true subdirectory,
    /// and `Announcer` as the subdirectory with `<voice>/` baked into the
    /// resource name.
    private func resolvedURL(basename: String) -> URL? {
        if let url = Bundle.main.url(forResource: basename, withExtension: "mp3", subdirectory: "Announcer/\(Self.voice)") {
            return url
        }
        if let url = Bundle.main.url(forResource: "\(Self.voice)/\(basename)", withExtension: "mp3", subdirectory: "Announcer") {
            return url
        }
        return nil
    }

    /// Same dual-layout fallback as `resolvedURL`, for the top-level
    /// `manifest.json` (no voice subdirectory).
    private static func resourceURL(basename: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: basename, withExtension: ext, subdirectory: "Announcer") {
            return url
        }
        return Bundle.main.url(forResource: basename, withExtension: ext)
    }

    // MARK: - Playback

    /// Queues `urls` on a fresh `AVQueuePlayer`, replacing any playback in
    /// progress. Prints a resolved/missing/attempted summary either way so
    /// on-device verification can be done from console logs alone. The
    /// session is set up with `.duckOthers` so backgrounded music (e.g.
    /// Spotify/Music) ducks instead of getting killed outright, and is
    /// deactivated with `.notifyOthersOnDeactivation` — both when the
    /// queue finishes naturally and in `stop()` — so that music comes back
    /// up afterward.
    @discardableResult
    private func play(urls: [URL], attempted: Int) -> Int {
        let missing = attempted - urls.count
        print("Announcer: \(urls.count) segment(s) resolved, \(missing) missing (of \(attempted) attempted)")
        guard !urls.isEmpty else { return 0 }

        if let endOfQueueObserver {
            NotificationCenter.default.removeObserver(endOfQueueObserver)
            self.endOfQueueObserver = nil
        }
        for observer in failureObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        failureObservers.removeAll()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)

        let items = urls.map { AVPlayerItem(url: $0) }
        let player = AVQueuePlayer(items: items)
        queuePlayer = player

        // Observe the LAST item specifically (not just any item finishing)
        // so `isPlaying` stays true through a multi-clip sequence and only
        // flips false once the whole broadcast has played out. Also
        // deactivates the session (ducked music resumes) now that
        // playback is genuinely done.
        endOfQueueObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: items.last,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.onPlayingChanged?(false)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        // A mid-queue decode/IO failure never fires the last item's normal
        // end-of-playback notification, which would otherwise leave
        // `isPlaying` stuck `true` forever — one observer per queued item
        // routes any of them failing through the same `stop()` cleanup
        // (removes observers, deactivates the session, flips `isPlaying`).
        failureObservers = items.map { item in
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.stop()
            }
        }

        isPlaying = true
        onPlayingChanged?(true)
        player.play()
        return urls.count
    }
}
