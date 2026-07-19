import SwiftUI

/// The iPad. Lobby until the host taps Deal, then the felt stage.
struct TableRootView: View {
    @State private var host = GameHostController()
    @State private var announcer = AnnouncerDirectorHolder()

    var body: some View {
        ZStack {
            TableSurface()
            if host.state == nil {
                TableLobbyView(host: host)
            } else {
                TableGameView(host: host)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // the table never sleeps
            announcer.wire(to: host)
            if DemoData.wantsTableDemo, host.state == nil {
                host.adoptDemoEngine(DemoData.makeTableEngine())
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// The physical stage: walnut rail around a felt playing surface, lit from
/// above. Everything on the table draws over this.
struct TableSurface: View {
    var body: some View {
        ZStack {
            // Walnut rail: photographic grain under a lighting gradient.
            Color(red: 0.28, green: 0.19, blue: 0.13).ignoresSafeArea()
            Image("WalnutTexture")
                .resizable(resizingMode: .tile)
                .ignoresSafeArea()
                .opacity(0.7)
                .blendMode(.overlay)
            LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // Felt inset with a soft inner shadow where it meets the rail.
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(
                    RadialGradient(colors: [CardStyle.feltGreen.opacity(1.06),
                                            CardStyle.feltGreen,
                                            CardStyle.feltGreen.opacity(0.82)],
                                   center: .center, startRadius: 60, endRadius: 900)
                )
                .overlay(
                    Image("FeltTexture")
                        .resizable(resizingMode: .tile)
                        .opacity(0.5)
                        .blendMode(.overlay)
                        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .strokeBorder(CardStyle.gold.opacity(0.35), lineWidth: 1.5)
                        .padding(6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .strokeBorder(.black.opacity(0.45), lineWidth: 10)
                        .blur(radius: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                )
                .padding(14)
            // Overhead lamp vignette.
            RadialGradient(colors: [.clear, .black.opacity(0.30)],
                           center: .center, startRadius: 260, endRadius: 950)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// Holds the announcer wiring so TableRootView stays declarative.
/// AnnouncerDirector maps GameEvents → announcer + SFX calls.
@Observable
final class AnnouncerDirectorHolder {
    private var wired = false

    func wire(to host: GameHostController) {
        guard !wired else { return }
        wired = true
        let previous = host.onEvents
        host.onEvents = { events in
            previous?(events)
            AnnouncerDirector.shared.handle(events: events, state: host.state)
        }
    }
}
