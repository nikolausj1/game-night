import SwiftUI

/// What the TV shows: a clean, read-only, cinematic view of the table —
/// never a raw mirror of the iPad's UI (no menus, no drag handles, no
/// close button). Hosted by `ExternalSceneDelegate` in its own window on
/// the external display.
///
/// There is no `@Observable`/`@Bindable` wiring back to the main scene's
/// `GameHostController` here on purpose: `SharedHost.controller` is a plain
/// weak static var, so its own comings-and-goings (nil → set, or the main
/// scene tearing down) aren't tracked by SwiftUI's Observation. A lightweight
/// `TimelineView` re-reads it on a steady cadence instead, which also means
/// this view doesn't need to know or care exactly which of the host's
/// properties changed — it just redraws off the current snapshot every tick.
struct SpectatorScreen: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                    tableStage(host: SharedHost.controller, size: geo.size)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
    }

    /// The felt has a natural aspect (tuned for an iPad's screen, seat
    /// anchors and all) that shouldn't be stretched to fit whatever
    /// widescreen TV it lands on. So: render it into a fixed-aspect
    /// reference canvas, then scale that canvas to fit inside the TV's
    /// bounds (contain, not fill) — the classic letterbox/pillarbox move.
    private let referenceSize = CGSize(width: 1024, height: 768) // iPad-ish 4:3 landscape felt

    @ViewBuilder
    private func tableStage(host: GameHostController?, size: CGSize) -> some View {
        let scale = min(size.width / referenceSize.width, size.height / referenceSize.height)

        ZStack {
            TableSurface()
            if let host, host.state != nil {
                // isSpectator disables gestures/buttons inside the view
                // itself (lead's change); allowsHitTesting(false) below is
                // belt-and-suspenders so nothing on the TV is ever tappable
                // even if a future control forgets to check the flag.
                TableGameView(host: host, isSpectator: true)
            } else {
                IdleSpectatorView()
            }
        }
        .frame(width: referenceSize.width, height: referenceSize.height)
        .scaleEffect(scale)
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .clipped()
    }
}

/// Menu/lobby state on the TV: never the raw host-picking menu (that's for
/// the iPad in the host's hands), just a handsome holding screen while the
/// table gets set. Also what shows before the main scene has published a
/// controller at all (cold AirPlay connect racing app launch).
private struct IdleSpectatorView: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [.white.opacity(glow ? 0.12 : 0.05), .clear],
                           center: .center, startRadius: 40, endRadius: 700)
                .onAppear {
                    withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                        glow = true
                    }
                }
            VStack(spacing: 16) {
                Text("Game Night")
                    .font(.system(size: 64, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Text("The table is being set…")
                    .font(.system(.title2, design: .serif).italic())
                    .foregroundStyle(CardStyle.gold)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Spectator — idle") {
    IdleSpectatorView()
        .background(TableSurface())
}
