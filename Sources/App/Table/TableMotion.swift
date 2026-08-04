import Foundation
import CoreMotion
import CoreGraphics

/// The table feels being touched. The iPad's accelerometer drives two
/// channels of response, both scaled by the user's sensitivity setting:
///
/// - **Nudges** (continuous, gentle): picking the iPad up, setting it
///   down, sliding it across the table — loose objects drift with the
///   motion, subtly. Never disruptive, always alive.
/// - **Bumps** (discrete, thresholded): a real thump on the table — one
///   coherent hop-and-settle of everything loose, with sound. Debounced
///   so a single knock is a single event.
///
/// Settings: "gn.tableMotion" (Bool, default on) and
/// "gn.tableMotionSens" (Double 0.5…2.0, default 1.0).
@Observable
final class TableMotion {
    static let shared = TableMotion()

    /// Gentle drift: direction (unit-ish CGVector in screen space) and
    /// strength 0…1. Fired at most ~10Hz while motion continues.
    var onNudge: ((CGVector, Double) -> Void)?
    /// A real thump: intensity 1…3.
    var onBump: ((Double) -> Void)?

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var lastNudgeAt = Date.distantPast
    @ObservationIgnored private var lastBumpAt = Date.distantPast

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "gn.tableMotion") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "gn.tableMotion")
    }

    static var sensitivity: Double {
        let raw = UserDefaults.standard.double(forKey: "gn.tableMotionSens")
        return raw == 0 ? 1.0 : min(2.0, max(0.5, raw))
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion, Self.isEnabled else { return }
            let sens = Self.sensitivity
            let a = motion.userAcceleration
            // Screen-space direction: device x maps to screen x; device y
            // is inverted (accelerating the iPad away from you slides
            // loose objects toward you).
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let now = Date()

            // Bump: a genuine knock. Threshold drops as sensitivity rises.
            if magnitude > 0.55 / sens, now.timeIntervalSince(lastBumpAt) > 0.4 {
                lastBumpAt = now
                onBump?(min(3.0, 1.0 + magnitude * 1.6 * sens))
                return
            }
            // Nudge: deliberate handling, below bump territory.
            if magnitude > 0.045 / sens, now.timeIntervalSince(lastNudgeAt) > 0.1 {
                lastNudgeAt = now
                let planar = max(0.0001, sqrt(a.x * a.x + a.y * a.y))
                let direction = CGVector(dx: a.x / planar, dy: -a.y / planar)
                onNudge?(direction, min(1.0, magnitude * 2.2 * sens))
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        onNudge = nil
        onBump = nil
    }
}
