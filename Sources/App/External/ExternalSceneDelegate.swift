import SwiftUI
import UIKit

/// Scene delegate for the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// session role declared in `project.yml`'s `UIApplicationSceneManifest`.
/// UIKit instantiates this — separately from SwiftUI's own scene delegate for
/// the main `WindowGroup` — the moment the iPad is AirPlayed or plugged into
/// a TV over HDMI. It hosts a single, read-only `SpectatorScreen` in its own
/// window on the external display.
///
/// This class does NOT own any game state. It reads the main scene's
/// `GameHostController` through `SharedHost` (see `SharedHost.swift`) so the
/// TV always mirrors the exact same table the iPad is running.
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: SpectatorScreen())
        // Non-interactive external scenes are never "key" in the normal
        // sense (there's no touch/keyboard focus on a TV), but the window
        // still needs to be made visible for UIKit to present it.
        window.makeKeyAndVisible()
        self.window = window
    }
}
