import Foundation

/// Registry so the external-display scene (a separate `UIWindowScene` from
/// the main table, spun up by `ExternalSceneDelegate` when the iPad is
/// AirPlayed/HDMI-connected to a TV) can observe the SAME
/// `GameHostController` the main table owns, instead of standing up its own
/// engine or trying to pass state across scenes some other way.
///
/// Integration (the ONE line the lead adds, in `TableRootView`):
///
///     SharedHost.controller = host
///
/// e.g. inside `TableRootView`'s `.onAppear`, right next to the other
/// `wire(to: host)` calls. Everything downstream (`SpectatorScreen`) just
/// reads `SharedHost.controller` on a timer and renders whatever it finds.
///
/// `weak`: the external scene must never keep the host controller (and
/// therefore the whole engine + session) alive after the main scene's
/// `TableRootView` goes away. If the main scene is ever torn down, the TV
/// should fall back to the idle screen, not pin memory.
enum SharedHost {
    static weak var controller: GameHostController?
}
