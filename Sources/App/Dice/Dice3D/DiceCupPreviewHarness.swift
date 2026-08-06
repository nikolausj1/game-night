import SwiftUI

/// Sim-verify hook: `-autoCupPreview` renders the cup interior standalone
/// (no table, no lobby, no motion hardware needed — the scene's default
/// "natural hold" gravity poses the dice). Lets a build be screenshotted
/// to check the cup's geometry, lighting, and dice placement exactly as a
/// player would see them mid-turn. Same spirit as `-autoRole` /
/// `-autoStartLcr`.
///
/// `-cupConcept 0|1|2` forces a specific look (Cross-section / Look-in /
/// Glass bottom) for screenshotting; without it the harness shows the
/// persisted choice and the live toggle works exactly as in the game.
struct DiceCupPreviewHarness: View {
    @State private var model = DiceCupModel()
    @AppStorage("gn.cupConcept") private var cupConceptRaw = CupConcept.crossSection.rawValue

    private var concept: CupConcept {
        if let index = CommandLine.arguments.firstIndex(of: "-cupConcept"),
           CommandLine.arguments.indices.contains(index + 1),
           let raw = Int(CommandLine.arguments[index + 1]),
           let forced = CupConcept(rawValue: raw) {
            return forced
        }
        return CupConcept(rawValue: cupConceptRaw) ?? .crossSection
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiceCupSceneView(diceCount: 3, model: model, concept: concept)
                .id(concept)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    CupConceptToggle(concept: concept) {
                        cupConceptRaw = concept.next.rawValue
                    }
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.trailing, 14)
        }
    }
}
