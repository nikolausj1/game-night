import SwiftUI

/// Sim-verify hook: `-autoCupPreview` renders the cup interior standalone
/// (no table, no lobby, no motion hardware needed — the scene's default
/// "natural hold" gravity poses the dice). Lets a build be screenshotted
/// to check the cup's geometry, lighting, and dice placement exactly as a
/// player would see them mid-turn. Same spirit as `-autoRole` /
/// `-autoStartLcr`.
struct DiceCupPreviewHarness: View {
    @State private var model = DiceCupModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiceCupSceneView(diceCount: 3, model: model)
                .ignoresSafeArea()
        }
    }
}
