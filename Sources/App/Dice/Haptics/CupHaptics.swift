import CoreHaptics
import UIKit
import QuartzCore

/// The cup in your hand, felt: a CHHapticEngine design that replaces the old
/// pair of UIImpactFeedbackGenerator clacks. Four voices, all on the main
/// queue (the cup's contact throttle already delivers there):
///
/// 1. CONTACT — one transient per audible physics contact. Intensity and
///    sharpness both follow the contact strength (0...1, from
///    `DiceContactThrottle`): a feather-light tick for a die settling on
///    felt, a crisp hard knock for bone on bone. Strong contacts (>0.45) add
///    a short low "body" continuous event under the transient so a big
///    landing has weight, not just a click.
///    - intensity = 0.22 + 0.78 * s^0.85
///    - sharpness = 0.30 + 0.45 * s   (+0.15 for die-on-die)
///
/// 2. RATTLE TEXTURE — while you shake, or while dice are airborne/tumbling,
///    a looped 0.8s "grain" pattern runs: a low continuous hum (sharpness
///    0.12) plus ~14 irregular tiny transients (a seeded, fixed scatter, so
///    it reads as gravel rolling rather than a metronome). Nothing about the
///    pattern changes while it plays; shake energy drives two dynamic
///    parameter controls instead — intensity multiplier = 0.06 + 0.54 *
///    (energy/1.2)^0.75, sharpness shift = 0.2 + 0.3 * (energy/1.2) — sent
///    at most every 30ms. Fast attack (~55ms), slow release (~300ms), so the
///    texture swells with a shake and dies away as the dice settle. Starts
///    above energy 0.10, stops below 0.06 (hysteresis).
///
/// 3. POUR — a distinct ~0.9s gesture when you tip the cup: a continuous
///    event whose intensity curve ramps 0.2 -> 1.0 over the first half (the
///    dice sliding toward the mouth) then falls to 0 (emptied), with the
///    sharpness curve rising 0.15 -> 0.5 (smooth slide turning into
///    spill), and four staggered, decaying transients at 0.22/0.34/0.44/
///    0.55s (the dice leaving one by one). Overall gain scales with the
///    pour intensity (0.3...1.5 on the wire).
///
/// 4. TABLE ECHO — when the table reports the roll's result back, a soft
///    double-tap (two transients 0.11s apart, intensity 0.45 then 0.30,
///    sharpness 0.25): the table "answering" the pour.
///
/// Engine lifecycle: `start()` on cup appear (idempotent), `stop()` on
/// disappear; `resetHandler` rebuilds the engine after a media-services
/// reset, `stoppedHandler` just marks it stopped and the next event restarts
/// it lazily (auto-shutdown after idle is enabled to save power). Without
/// hardware haptics (iPad, Simulator, some devices) every voice falls back to
/// the old UIKit feedback generators, so behavior there is unchanged.
final class CupHaptics {
    enum ContactClass { case die, other }

    private(set) var isEngineBacked = false
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private var rattlePlayer: CHHapticAdvancedPatternPlayer?
    private var rattleRunning = false
    private var smoothedLevel = 0.0
    private var lastLevelTime = CACurrentMediaTime()
    private var lastSend = 0.0
    private var lastFallbackRattle = 0.0
    private var started = false

    // Fallback voices (also kept warm when the engine is unavailable).
    private let lightGen = UIImpactFeedbackGenerator(style: .light)
    private let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private let softGen = UIImpactFeedbackGenerator(style: .soft)
    private let notifyGen = UINotificationFeedbackGenerator()

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        lightGen.prepare()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            isEngineBacked = false
            NSLog("CupHaptics: Core Haptics unsupported on this hardware - UIKit feedback fallback")
            Self.selfTestPatterns()
            return
        }
        do {
            try buildEngine()
            isEngineBacked = true
            NSLog("CupHaptics: CHHapticEngine started OK")
        } catch {
            isEngineBacked = false
            NSLog("CupHaptics: engine failed to start (%@) - UIKit feedback fallback",
                  error.localizedDescription)
        }
        Self.selfTestPatterns()
    }

    func stop() {
        guard started else { return }
        started = false
        stopRattle(immediately: true)
        smoothedLevel = 0
        rattlePlayer = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        engineRunning = false
        isEngineBacked = false
    }

    private func buildEngine() throws {
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak self] in
            // Media services reset: everything we held is invalid. Restart
            // and drop the rattle player so it's rebuilt on next use.
            guard let self else { return }
            DispatchQueue.main.async {
                self.rattlePlayer = nil
                self.rattleRunning = false
                self.engineRunning = false
                do {
                    try self.engine?.start()
                    self.engineRunning = true
                } catch {
                    NSLog("CupHaptics: restart after reset failed: %@", error.localizedDescription)
                    self.isEngineBacked = false
                }
            }
        }
        engine.stoppedHandler = { [weak self] reason in
            // Idle timeout / audio interruption / system error. Lazy
            // restart: the next event calls `ensureRunning()`.
            DispatchQueue.main.async {
                self?.engineRunning = false
                self?.rattleRunning = false
                NSLog("CupHaptics: engine stopped (reason %d) - will restart on demand", reason.rawValue)
            }
        }
        try engine.start()
        self.engine = engine
        engineRunning = true
    }

    private func ensureRunning() -> Bool {
        guard isEngineBacked, let engine else { return false }
        if engineRunning { return true }
        do {
            try engine.start()
            engineRunning = true
            return true
        } catch {
            return false
        }
    }

    // MARK: 1. contact

    func contact(strength rawStrength: Double, kind: ContactClass = .other) {
        let s = min(1, max(0, rawStrength))
        guard ensureRunning(), let pattern = Self.contactPattern(strength: s, kind: kind),
              let player = try? engine?.makePlayer(with: pattern) else {
            if s > 0.5 {
                mediumGen.impactOccurred(intensity: min(1, 0.4 + s * 0.6))
            } else {
                lightGen.impactOccurred(intensity: min(1, 0.3 + s))
            }
            return
        }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    static func contactPattern(strength s: Double, kind: ContactClass) -> CHHapticPattern? {
        let intensity = Float(min(1, 0.22 + 0.78 * pow(s, 0.85)))
        let sharpness = Float(min(1, 0.30 + 0.45 * s + (kind == .die ? 0.15 : 0)))
        var events = [CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
            relativeTime: 0)]
        if s > 0.45 {
            events.append(CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity,
                                                    value: Float(0.30 + 0.40 * s)),
                             CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.10)],
                relativeTime: 0.004, duration: 0.035 + 0.04 * s))
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    // MARK: 2. rattle texture

    /// Call at motion rate (~60Hz) with the current shake/tumble level,
    /// 0...1.2 (the shake-energy scale `DiceCupModel.energy` uses). Cheap
    /// when nothing changes; parameter sends are throttled to ~30ms.
    func updateRattle(level: Double) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastLevelTime))
        lastLevelTime = now
        let rate = level > smoothedLevel ? 18.0 : 3.5
        smoothedLevel += (level - smoothedLevel) * min(1, dt * rate)

        guard isEngineBacked else {
            // Fallback texture: sparse light ticks while it's rattling.
            if smoothedLevel > 0.25, now - lastFallbackRattle > 0.14 - min(0.08, smoothedLevel * 0.06) {
                lastFallbackRattle = now
                softGen.impactOccurred(intensity: min(1, 0.25 + smoothedLevel * 0.5))
            }
            return
        }
        if !rattleRunning {
            guard smoothedLevel > 0.10, startRattle() else { return }
        } else if smoothedLevel < 0.06 {
            stopRattle(immediately: false)
            return
        }
        guard rattleRunning, now - lastSend > 0.03, let player = rattlePlayer else { return }
        lastSend = now
        let norm = min(1, smoothedLevel / 1.2)
        let intensity = Float(0.06 + 0.54 * pow(norm, 0.75))
        let sharpness = Float(0.2 + 0.3 * norm)
        try? player.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    private func startRattle() -> Bool {
        guard ensureRunning(), let engine else { return false }
        if rattlePlayer == nil {
            guard let pattern = Self.rattlePattern(),
                  let player = try? engine.makeAdvancedPlayer(with: pattern) else { return false }
            player.loopEnabled = true
            player.loopEnd = Self.rattleLoop
            rattlePlayer = player
        }
        do {
            try rattlePlayer?.start(atTime: CHHapticTimeImmediate)
            rattleRunning = true
            return true
        } catch {
            rattlePlayer = nil
            return false
        }
    }

    private func stopRattle(immediately: Bool) {
        guard rattleRunning else { return }
        rattleRunning = false
        try? rattlePlayer?.stop(atTime: CHHapticTimeImmediate)
    }

    private static let rattleLoop: TimeInterval = 0.8

    static func rattlePattern() -> CHHapticPattern? {
        var events = [CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)],
            relativeTime: 0, duration: rattleLoop)]
        // Fixed pseudo-random scatter (LCG) so the grain is irregular but
        // identical every loop pass and every launch.
        var seed: UInt32 = 0x9E3779B1
        func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        var t = 0.02
        while t < rattleLoop - 0.03 {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity,
                                                    value: Float(0.35 + 0.55 * next())),
                             CHHapticEventParameter(parameterID: .hapticSharpness,
                                                    value: Float(0.45 + 0.35 * next()))],
                relativeTime: t))
            t += 0.030 + 0.050 * next()
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    // MARK: 3. pour

    func pour(intensity wire: Double) {
        stopRattle(immediately: true)
        smoothedLevel = 0
        let norm = min(1, max(0, (wire - 0.3) / 1.2))
        guard ensureRunning(), let pattern = Self.pourPattern(norm: norm),
              let player = try? engine?.makePlayer(with: pattern) else {
            notifyGen.notificationOccurred(.success)
            return
        }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    static func pourPattern(norm: Double) -> CHHapticPattern? {
        let gain = Float(0.55 + 0.45 * norm)
        let slide = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: gain),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)],
            relativeTime: 0, duration: 0.9)
        var events = [slide]
        for (i, at) in [0.22, 0.34, 0.44, 0.55].enumerated() {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity,
                                                    value: gain * Float(0.95 - 0.18 * Double(i))),
                             CHHapticEventParameter(parameterID: .hapticSharpness,
                                                    value: Float(0.45 + 0.05 * Double(i)))],
                relativeTime: at))
        }
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [.init(relativeTime: 0.00, value: 0.20),
                            .init(relativeTime: 0.20, value: 0.55),
                            .init(relativeTime: 0.45, value: 1.00),
                            .init(relativeTime: 0.70, value: 0.45),
                            .init(relativeTime: 0.90, value: 0.00)],
            relativeTime: 0)
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [.init(relativeTime: 0.00, value: 0.00),
                            .init(relativeTime: 0.45, value: 0.20),
                            .init(relativeTime: 0.90, value: 0.35)],
            relativeTime: 0)
        return try? CHHapticPattern(events: events, parameterCurves: [intensityCurve, sharpnessCurve])
    }

    // MARK: 4. table echo

    /// The table's roll result coming back: a soft double-tap.
    func tableEcho() {
        guard ensureRunning(), let pattern = Self.echoPattern(),
              let player = try? engine?.makePlayer(with: pattern) else {
            softGen.impactOccurred(intensity: 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [softGen] in
                softGen.impactOccurred(intensity: 0.4)
            }
            return
        }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    static func echoPattern() -> CHHapticPattern? {
        let tap = { (at: TimeInterval, intensity: Float) in
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)],
                          relativeTime: at)
        }
        return try? CHHapticPattern(events: [tap(0, 0.45), tap(0.11, 0.30)], parameters: [])
    }

    // MARK: verification

    /// Builds every pattern once and logs the result - proves the event
    /// data is valid even where no haptic hardware exists (Simulator).
    private static func selfTestPatterns() {
        let built = [contactPattern(strength: 0.2, kind: .other) != nil,
                     contactPattern(strength: 0.9, kind: .die) != nil,
                     rattlePattern() != nil, pourPattern(norm: 0.7) != nil, echoPattern() != nil]
        NSLog("CupHaptics: pattern self-test %@ (%d/5 built)",
              built.allSatisfy { $0 } ? "OK" : "FAILED", built.filter { $0 }.count)
    }
}
