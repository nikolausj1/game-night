import SwiftUI
import CoreMotion

/// The phone's shake-to-roll detector: the same CoreMotion
/// `userAcceleration` jolt test `DiceCupModel` uses (magnitude over a
/// threshold, debounced), kept in its own file so the dice cup platform
/// stays untouched. A handful of jolts counts as a proper shake.
///
/// There is no CoreMotion in the Simulator, so `simulateJolt()` (wired to
/// the on-screen "Tap to roll" fallback and the `-autoShakeLiarsDice`
/// launch flag) drives the same path.
@Observable
final class LiarsDiceShakeDetector {
    /// Banked shake energy 0...1 (decays between jolts) - drives the cup wobble.
    private(set) var energy: Double = 0
    private(set) var jolts = 0
    /// Jolts needed before `onEnough` fires.
    let joltsNeeded = 5

    /// True once `joltsNeeded` jolts have landed; views observe this with
    /// `.onChange` (no closures, so there is no stale-struct capture).
    private(set) var fired = false

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var lastJolt = Date.distantPast
    @ObservationIgnored private var lastUpdate: Date?
    @ObservationIgnored private var running = false

    func start() {
        guard !running else { return }
        running = true
        fired = false
        jolts = 0
        energy = 0
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let self, let deviceMotion else { return }
            self.process(deviceMotion)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        lastUpdate = nil
    }

    func reset() {
        fired = false
        jolts = 0
        energy = 0
    }

    /// Simulator / accessibility path: one synthetic jolt.
    func simulateJolt() { registerJolt(strength: 1.0) }

    private func process(_ dm: CMDeviceMotion) {
        let now = Date()
        let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0
        lastUpdate = now
        energy = max(0, energy * exp(-1.1 * dt))
        let a = dm.userAcceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        if magnitude > 0.9, now.timeIntervalSince(lastJolt) > 0.12 {
            lastJolt = now
            registerJolt(strength: min(1.5, magnitude / 1.6))
        }
    }

    private func registerJolt(strength: Double) {
        guard !fired else { return }
        jolts += 1
        energy = min(1, energy + 0.22 + strength * 0.12)
        if jolts >= joltsNeeded { fired = true }
    }
}
