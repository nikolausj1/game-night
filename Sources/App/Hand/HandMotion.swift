import Foundation
import CoreMotion
import UIKit
import Observation

/// Gyroscope-driven parallax for the hand: tilt the phone and the fanned
/// cards drift like something actually resting in your palm. Same plumbing
/// shape as DiceCupModel (single CMMotionManager, `isDeviceMotionAvailable`
/// guard so the simulator no-ops), but this exists purely to drive tiny
/// SwiftUI offsets — no physics, no game state.
///
/// The key trick is that `tiltX`/`tiltY` are NOT the device's absolute
/// attitude. They're deltas from a slowly-recentering baseline: whatever
/// angle you're currently holding the phone at becomes "neutral" over a
/// few seconds, and parallax reacts only to CHANGES from there. Without
/// this, resting the phone at a comfortable off-level angle (nobody holds
/// a phone perfectly flat) would peg the parallax at one extreme forever.
@Observable
final class HandMotion {
    /// Horizontal tilt signal, roughly −1...1. Positive ≈ phone rolled
    /// toward its right edge (relative to the recentering baseline).
    private(set) var tiltX: Double = 0
    /// Vertical tilt signal, roughly −1...1. Positive ≈ top of phone
    /// pitched away from you (relative to the recentering baseline).
    private(set) var tiltY: Double = 0

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var active = false

    // Recentering baseline (slow low-pass of raw attitude) and the
    // silky output signal (fast low-pass of the delta from baseline).
    @ObservationIgnored private var baselineRoll: Double = 0
    @ObservationIgnored private var baselinePitch: Double = 0
    @ObservationIgnored private var baselineInitialized = false
    @ObservationIgnored private var filteredX: Double = 0
    @ObservationIgnored private var filteredY: Double = 0
    @ObservationIgnored private var lastSampleAt: Date?

    /// ~30Hz sampling — plenty for a subtle visual effect, easy on battery.
    private let sampleInterval: TimeInterval = 1.0 / 30.0
    /// Baseline recenters with a ~3s time constant: hold the phone at any
    /// angle for a few seconds and that becomes the new "neutral".
    private let baselineTimeConstant: Double = 3.0
    /// Output low-pass cutoff — smooths sensor noise into something silky
    /// rather than jittery, without feeling laggy.
    private let outputCutoffHz: Double = 8.0
    /// Radians-of-delta-attitude that map to the full ±1 output range.
    /// ~0.33 rad (≈19°) of change from baseline reaches the clamp.
    private let radiansPerUnit: Double = 3.0

    /// Call from the view's `.onAppear`. No-ops on Reduce Motion or when
    /// device motion hardware isn't available (e.g. the simulator).
    func start() {
        guard !active else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        guard motion.isDeviceMotionAvailable else { return }
        active = true
        baselineInitialized = false
        lastSampleAt = nil
        motion.deviceMotionUpdateInterval = sampleInterval
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] deviceMotion, _ in
            guard let self, let deviceMotion else { return }
            self.process(deviceMotion)
        }
    }

    /// Call from the view's `.onDisappear`. Safe to call even if never started.
    func stop() {
        guard active else { return }
        active = false
        motion.stopDeviceMotionUpdates()
        lastSampleAt = nil
        baselineInitialized = false
    }

    private func process(_ dm: CMDeviceMotion) {
        let now = Date()
        let dt = lastSampleAt.map { now.timeIntervalSince($0) } ?? sampleInterval
        lastSampleAt = now

        let roll = dm.attitude.roll
        let pitch = dm.attitude.pitch

        if !baselineInitialized {
            // First sample: neutral is wherever the phone already is,
            // no jump from zero.
            baselineRoll = roll
            baselinePitch = pitch
            baselineInitialized = true
        } else {
            let recenterAlpha = lowPassAlpha(dt: dt, timeConstant: baselineTimeConstant)
            baselineRoll += (roll - baselineRoll) * recenterAlpha
            baselinePitch += (pitch - baselinePitch) * recenterAlpha
        }

        // Delta from the recentering baseline, scaled to ~−1...1 and clamped.
        let targetX = clamp((roll - baselineRoll) * radiansPerUnit)
        let targetY = clamp((pitch - baselinePitch) * radiansPerUnit)

        // Output low-pass — this IS the smoothing; callers apply the
        // observed values directly with no further animation needed.
        let outputAlpha = lowPassAlpha(dt: dt, cutoffHz: outputCutoffHz)
        filteredX += (targetX - filteredX) * outputAlpha
        filteredY += (targetY - filteredY) * outputAlpha

        tiltX = filteredX
        tiltY = filteredY
    }

    private func clamp(_ value: Double) -> Double {
        max(-1, min(1, value))
    }

    private func lowPassAlpha(dt: Double, timeConstant: Double) -> Double {
        1 - exp(-dt / timeConstant)
    }

    private func lowPassAlpha(dt: Double, cutoffHz: Double) -> Double {
        let timeConstant = 1 / (2 * .pi * cutoffHz)
        return 1 - exp(-dt / timeConstant)
    }
}
